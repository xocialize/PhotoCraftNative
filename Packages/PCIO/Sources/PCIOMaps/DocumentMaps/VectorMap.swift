// Port of photocraft-io (crates/io/src/vector_map.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// Vector data ⇄ PSD: path records (vector masks `vmsk`/`vsms`, saved paths 2000–2997, the work
// path 1025), live-shape origination (`vogk`), shape fill content (`vscg`) and shape strokes
// (`vstk`).
//
// Export follows the "keep verbatim while unchanged" rule used for fills and adjustments: a
// preserved block is written back byte-identical while it still decodes to the layer's current
// model; otherwise it is regenerated from the model.

import CoreGraphics
import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD

public enum VectorMap {
    /// Saved path resource ids (Adobe spec: 2000–2997).
    public static let savedPaths: ClosedRange<UInt16> = 2000 ... 2997
    /// Work path resource id.
    public static let workPath: UInt16 = 1025
    /// Clipping path name resource id.
    public static let clippingPath: UInt16 = 2999

    static func opFromPSD(_ v: Int16) -> PathOp {
        switch v {
        case 0: .exclude
        case 2: .subtract
        case 3: .intersect
        // Continues the previous subpath's shape component.
        case -1: .join
        default: .combine
        }
    }

    static func opToPSD(_ op: PathOp) -> Int16 {
        switch op {
        case .combine: 1
        case .subtract: 2
        case .intersect: 3
        case .exclude: 0
        case .join: -1
        }
    }

    /// Path records → model path in document pixels (`w`×`h` canvas).
    public static func pathFromRecords(_ p: PSDPathData, _ w: UInt32, _ h: UInt32) -> VectorPath {
        let (fw, fh) = (Double(w), Double(h))
        func pt(_ q: CGPoint) -> PCPoint { PCPoint(Double(q.x) * fw, Double(q.y) * fh) }
        let subpaths = p.subpaths.map { s in
            Subpath(closed: s.closed,
                    knots: s.knots.map { k in Knot(anchor: pt(k.anchor), inCtrl: pt(k.pre), outCtrl: pt(k.post), smooth: k.linked) },
                    op: opFromPSD(s.operation))
        }
        return VectorPath(subpaths, fillRule: .nonZero, inverted: p.initialFill)
    }

    /// Model path → path records.
    public static func pathToRecords(_ p: VectorPath, _ w: UInt32, _ h: UInt32) -> PSDPathData {
        let (fw, fh) = (Double(max(w, 1)), Double(max(h, 1)))
        // photocraft's fixed-point conversion maps NaN to 0 (a saturating `as` cast); PCPSD's
        // saturates NaN to Int32.max, so NaN fractions are passed on as 0.
        func fr(_ q: PCPoint) -> CGPoint { CGPoint(x: nanToZero(q.x / fw), y: nanToZero(q.y / fh)) }
        let subs = p.subpaths.map { s in
            PSDSubpath(closed: s.closed, operation: opToPSD(s.op),
                       knots: s.knots.map { k in PSDKnot(linked: k.smooth, pre: fr(k.inCtrl), anchor: fr(k.anchor), post: fr(k.outCtrl)) })
        }
        return PSDPathData(subpaths: subs, initialFill: p.inverted)
    }

    /// Path from a saved-path / work-path resource.
    public static func pathFromResource(_ data: [UInt8], _ w: UInt32, _ h: UInt32) -> VectorPath? {
        guard let p = try? PSDPathData(bytes: Data(data)) else { return nil }
        return pathFromRecords(p, w, h)
    }

    /// Layer vector data (`vmsk`/`vsms`) → model path, with Photoshop's reading of the records
    /// (matching its rendering of the psd-tools corpus):
    /// - without subpaths, the initial-fill record alone decides coverage (1 = everything);
    /// - with subpaths the initial-fill record is ignored; a first component that subtracts starts
    ///   from a full canvas (the shape is inverted);
    /// - a subpath with operation -1 continues the previous component (`PathOp.join`: filled
    ///   together with it, so subpaths wound the other way cut holes).
    ///
    /// The model applies the first subpath as "combine" and inverts the final result, so a leading
    /// subtract becomes `inverted` with every later operation replaced by its complement dual
    /// (combine ↔ subtract; exclude is self-dual; intersect has no dual and is kept as is).
    static func layerPathFromRecords(_ p: PSDPathData, _ w: UInt32, _ h: UInt32) -> VectorPath {
        var path = pathFromRecords(p, w, h)
        if path.subpaths.isEmpty { return path }
        // `pathFromRecords` maps -1 to `.join` (the component's operation is its first subpath's);
        // a leading -1 acts as the first component.
        path.inverted = path.subpaths.first?.op == .subtract
        if path.inverted {
            for i in path.subpaths.indices.dropFirst() {
                switch path.subpaths[i].op {
                case .combine: path.subpaths[i].op = .subtract
                case .subtract: path.subpaths[i].op = .combine
                default: break
                }
            }
            path.subpaths[0].op = .combine
        }
        return path
    }

    /// A `vmsk`/`vsms` block → (path with the invert flag applied, flags). Coverage semantics: an
    /// empty path covers everything when `inverted` (shape layers; vector masks flip this, see
    /// `vectorMaskFromBlock`).
    public static func pathFromVmsk(_ data: [UInt8], _ w: UInt32, _ h: UInt32) -> (path: VectorPath, flags: UInt32)? {
        guard let b = try? PSDVectorMask(bytes: Data(data)) else { return nil }
        var p = layerPathFromRecords(b.path, w, h)
        if b.flags & PSDVectorMask.flagInvert != 0 { p.inverted.toggle() }
        return (p, b.flags)
    }

    /// A `vmsk` block for `path` with extra flags (not linked / disabled). An empty path is written
    /// as the initial-fill record (Photoshop's form); otherwise inversion uses the invert flag.
    public static func vmskBytes(_ path: VectorPath, _ flags: UInt32, _ w: UInt32, _ h: UInt32) -> [UInt8] {
        var p = path
        var flags = flags & ~PSDVectorMask.flagInvert
        if p.inverted && !p.subpaths.isEmpty {
            flags |= PSDVectorMask.flagInvert
            p.inverted = false
        }
        // The model draws the first subpath as "combine"; a stored leading subtract would read back
        // as an inverted shape.
        if p.subpaths.first?.op == .subtract { p.subpaths[0].op = .combine }
        return [UInt8](PSDVectorMask(version: 3, flags: flags, path: pathToRecords(p, w, h)).serialized())
    }

    /// A layer's vector mask from its `vmsk`/`vsms` block. A vector mask without subpaths reveals
    /// everything unless inverted, the opposite of a shape's coverage, hence the flip.
    public static func vectorMaskFromBlock(_ data: [UInt8], _ w: UInt32, _ h: UInt32) -> VectorMask? {
        guard let (decoded, flags) = pathFromVmsk(data, w, h) else { return nil }
        var path = decoded
        if path.subpaths.isEmpty { path.inverted.toggle() }
        return VectorMask(path: path, enabled: flags & PSDVectorMask.flagDisabled == 0, linked: flags & PSDVectorMask.flagNotLinked == 0,
                          density: 1, feather: 0)
    }

    /// `vmsk` data for a vector mask.
    public static func vectorMaskBytes(_ m: VectorMask, _ w: UInt32, _ h: UInt32) -> [UInt8] {
        var flags: UInt32 = 0
        if !m.enabled { flags |= PSDVectorMask.flagDisabled }
        if !m.linked { flags |= PSDVectorMask.flagNotLinked }
        var path = m.path
        if path.subpaths.isEmpty { path.inverted.toggle() }
        return vmskBytes(path, flags, w, h)
    }

    /// Compares the parts of a vector mask stored in the block (density/feather live elsewhere).
    public static func vectorMaskBlockMatches(_ data: [UInt8], _ m: VectorMask, _ w: UInt32, _ h: UInt32) -> Bool {
        guard let b = vectorMaskFromBlock(data, w, h) else { return false }
        return b.path == m.path && b.enabled == m.enabled && b.linked == m.linked
    }

    // MARK: vscg (shape fill content)

    /// `vscg`: content key (`SoCo`/`GdFl`/`PtFl`) + version-16 descriptor.
    public static func fillFromVscg(_ data: [UInt8]) -> Fill? {
        guard data.count >= 4 else { return nil }
        let key = FourCC(bytes: data[0 ..< 4])
        guard let d = Blocks.parsePrefixVersioned(Array(data[4...])) else { return nil }
        return Blocks.fillFromDesc(key, d)
    }

    public static func vscgBytes(_ f: Fill) -> [UInt8] {
        let (k, d) = Blocks.fillToDesc(f)
        return k.bytes + Blocks.versionedBytes(d)
    }

    // MARK: vstk (shape stroke)

    /// Decoded `vstk`: the stroke (nil when disabled) and whether the fill is enabled.
    public struct VstkInfo: Equatable, Sendable {
        public var stroke: ShapeStroke?
        public var fillEnabled: Bool

        public init(stroke: ShapeStroke?, fillEnabled: Bool) {
            self.stroke = stroke
            self.fillEnabled = fillEnabled
        }
    }

    static func contentFill(_ d: PSDDescriptor) -> Fill? {
        let key: FourCC
        if d.classID.is("solidColorLayer") {
            key = "SoCo"
        } else if d.classID.is("gradientLayer") {
            key = "GdFl"
        } else if d.classID.is("patternLayer") {
            key = "PtFl"
        } else if d["Clr "] != nil {
            key = "SoCo"
        } else if d["Grad"] != nil {
            key = "GdFl"
        } else {
            key = "PtFl"
        }
        return Blocks.fillFromDesc(key, d)
    }

    static func unitPx(_ v: DValue?, _ dpi: Float) -> Double? {
        guard let v else { return nil }
        if case let .unitFloat(unit, value) = v {
            if unit == "#Pnt" { return value * Double(dpi) / 72 }
            if unit == "#Mlm" { return value * Double(dpi) / 25.4 }
        }
        return Blocks.num(v)
    }

    public static func parseVstk(_ data: [UInt8], _ dpi: Float) -> VstkInfo? {
        guard let d = Blocks.parsePrefixVersioned(data) else { return nil }
        var fillEnabled = true
        if case .boolean(false)? = d["fillEnabled"] { fillEnabled = false }
        if !Blocks.boolOf(d, "strokeEnabled") { return VstkInfo(stroke: nil, fillEnabled: fillEnabled) }
        func e(_ k: String) -> String { Blocks.enumOf(d, k) ?? "" }
        let cap: LineCap = switch e("strokeStyleLineCapType") {
        case "strokeStyleRoundCap": .round
        case "strokeStyleSquareCap": .square
        default: .butt
        }
        let join: LineJoin = switch e("strokeStyleLineJoinType") {
        case "strokeStyleRoundJoin": .round
        case "strokeStyleBevelJoin": .bevel
        default: .miter
        }
        let align: StrokeAlign = switch e("strokeStyleLineAlignment") {
        case "strokeStyleAlignInside": .inside
        case "strokeStyleAlignOutside": .outside
        default: .center
        }
        var dashes: [Float] = []
        if case let .list(l)? = d["strokeStyleLineDashSet"] { dashes = l.compactMap { Blocks.num($0) }.map { Float($0) } }
        let paint = Blocks.getDesc(d, "strokeStyleContent").flatMap(contentFill) ?? .solid(.black)
        let stroke = ShapeStroke(
            width: Float(unitPx(d["strokeStyleLineWidth"], dpi) ?? 1),
            paint: paint,
            opacity: Blocks.num(d["strokeStyleOpacity"]).map { Float($0) / 100 } ?? 1,
            align: align,
            cap: cap,
            join: join,
            miterLimit: Float(Blocks.num(d["strokeStyleMiterLimit"]) ?? 100),
            dashes: dashes,
            dashOffset: Float(Blocks.num(d["strokeStyleLineDashOffset"]) ?? 0)
        )
        return VstkInfo(stroke: stroke, fillEnabled: fillEnabled)
    }

    public static func vstkBytes(_ stroke: ShapeStroke?, _ fillEnabled: Bool, _ dpi: Float) -> [UInt8] {
        let s = stroke ?? ShapeStroke()
        var content = Blocks.fillToDesc(s.paint).descriptor
        content.classID = switch s.paint {
        case .solid: "solidColorLayer"
        case .gradient: "gradientLayer"
        case .pattern: "patternLayer"
        }
        let capName = switch s.cap {
        case .butt: "strokeStyleButtCap"
        case .round: "strokeStyleRoundCap"
        case .square: "strokeStyleSquareCap"
        }
        let joinName = switch s.join {
        case .miter: "strokeStyleMiterJoin"
        case .round: "strokeStyleRoundJoin"
        case .bevel: "strokeStyleBevelJoin"
        }
        let alignName = switch s.align {
        case .inside: "strokeStyleAlignInside"
        case .center: "strokeStyleAlignCenter"
        case .outside: "strokeStyleAlignOutside"
        }
        let d = PSDDescriptor(classID: "strokeStyle")
            .with("strokeStyleVersion", .integer(2))
            .with("strokeEnabled", .boolean(stroke != nil))
            .with("fillEnabled", .boolean(fillEnabled))
            .with("strokeStyleLineWidth", .unitFloat(unit: "#Pxl", value: Double(s.width)))
            .with("strokeStyleLineDashOffset", .unitFloat(unit: "#Pnt", value: Double(s.dashOffset)))
            .with("strokeStyleMiterLimit", .double(Double(s.miterLimit)))
            .with("strokeStyleLineCapType", Blocks.enumValue("strokeStyleLineCapType", capName))
            .with("strokeStyleLineJoinType", Blocks.enumValue("strokeStyleLineJoinType", joinName))
            .with("strokeStyleLineAlignment", Blocks.enumValue("strokeStyleLineAlignment", alignName))
            .with("strokeStyleScaleLock", .boolean(false))
            .with("strokeStyleStrokeAdjust", .boolean(false))
            .with("strokeStyleLineDashSet", .list(s.dashes.map { .unitFloat(unit: "#Nne", value: Double($0)) }))
            .with("strokeStyleBlendMode", Blocks.enumValue("BlnM", "Nrml"))
            .with("strokeStyleOpacity", .unitFloat(unit: "#Prc", value: Double(s.opacity * 100)))
            .with("strokeStyleContent", .descriptor(content))
            .with("strokeStyleResolution", .double(Double(dpi)))
        return Blocks.versionedBytes(d)
    }

    // MARK: vogk (live shape origination)

    static func rectOf(_ d: PSDDescriptor) -> SIMD4<Double>? {
        guard let b = Blocks.getDesc(d, "keyOriginShapeBBox"), let t = Blocks.num(b["Top "]), let l = Blocks.num(b["Left"]),
              let bt = Blocks.num(b["Btom"]), let r = Blocks.num(b["Rght"]) else { return nil }
        return SIMD4(l, t, r - l, bt - t)
    }

    static func pointOf(_ d: PSDDescriptor, _ key: String) -> SIMD2<Double>? {
        guard let p = Blocks.getDesc(d, key), let x = Blocks.num(p["Hrzn"]), let y = Blocks.num(p["Vrtc"]) else { return nil }
        return SIMD2(x, y)
    }

    /// Live shape from `vogk` (version 1 + versioned descriptor). Only a single, valid,
    /// untransformed origination maps to a `LiveShape`.
    public static func liveFromVogk(_ data: [UInt8]) -> LiveShape? {
        guard data.count >= 4, let d = Blocks.parsePrefixVersioned(Array(data[4...])) else { return nil }
        guard case let .list(list)? = d["keyDescriptorList"], list.count == 1, case let .descriptor(o) = list[0] else { return nil }
        if Blocks.boolOf(o, "keyShapeInvalidated") { return nil }
        if let t = Blocks.getDesc(o, "Trnf") {
            func g(_ k: String, _ dv: Double) -> Double { Blocks.num(t[k]) ?? dv }
            let identity: [(String, Double)] = [("xx", 1), ("xy", 0), ("yx", 0), ("yy", 1), ("tx", 0), ("ty", 0)]
            // NaN fails the comparison, as in photocraft.
            if !identity.allSatisfy({ abs(g($0.0, $0.1) - $0.1) < 1e-9 }) { return nil }
        }
        guard case let .integer(ty)? = o["keyOriginType"] else { return nil }
        switch ty {
        case 1:
            guard let r = rectOf(o) else { return nil }
            return .rect(rect: r, radii: .zero)
        case 2:
            guard let r = Blocks.getDesc(o, "keyOriginRRectRadii") else { return nil }
            func g(_ k: String) -> Double { Blocks.num(r[k]) ?? 0 }
            let radii = SIMD4(g("topLeft"), g("topRight"), g("bottomRight"), g("bottomLeft"))
            guard let rect = rectOf(o) else { return nil }
            return .rect(rect: rect, radii: radii)
        case 5:
            guard let r = rectOf(o) else { return nil }
            return .ellipse(rect: r)
        case 4:
            guard let from = pointOf(o, "keyOriginLineStart"), let to = pointOf(o, "keyOriginLineEnd") else { return nil }
            return .line(from: from, to: to, weight: Blocks.num(o["keyOriginLineWeight"]) ?? 1)
        default:
            return nil
        }
    }

    static func px(_ v: Double) -> DValue { .unitFloat(unit: "#Pxl", value: v) }

    /// `vogk` for a live shape (nil for kinds Photoshop has no origination type for here).
    public static func vogkBytes(_ s: LiveShape, _ dpi: Float) -> [UInt8]? {
        func bbox(_ r: SIMD4<Double>) -> DValue {
            .descriptor(PSDDescriptor(classID: "unitRect")
                .with("unitValueQuadVersion", .integer(1))
                .with("Top ", px(r[1]))
                .with("Left", px(r[0]))
                .with("Btom", px(r[1] + r[3]))
                .with("Rght", px(r[0] + r[2])))
        }
        func base(_ ty: Int32) -> PSDDescriptor {
            PSDDescriptor(classID: "null").with("keyOriginType", .integer(ty)).with("keyOriginResolution", .double(Double(dpi)))
        }
        var o: PSDDescriptor
        switch s {
        case let .rect(rect, radii) where (0 ..< 4).allSatisfy({ radii[$0] == 0 }):
            o = base(1).with("keyOriginShapeBBox", bbox(rect))
        case let .rect(rect, radii):
            o = base(2)
                .with("keyOriginRRectRadii", .descriptor(PSDDescriptor(classID: "radii")
                        .with("unitValueQuadVersion", .integer(1))
                        .with("topRight", px(radii[1]))
                        .with("topLeft", px(radii[0]))
                        .with("bottomLeft", px(radii[3]))
                        .with("bottomRight", px(radii[2]))))
                .with("keyOriginShapeBBox", bbox(rect))
        case let .ellipse(rect):
            o = base(5).with("keyOriginShapeBBox", bbox(rect))
        case let .line(from, to, weight):
            func pnt(_ p: SIMD2<Double>) -> DValue {
                .descriptor(PSDDescriptor(classID: "Pnt ").with("Hrzn", .double(p[0])).with("Vrtc", .double(p[1])))
            }
            let r = SIMD4(Double.minimum(from[0], to[0]), Double.minimum(from[1], to[1]), abs(from[0] - to[0]), abs(from[1] - to[1]))
            o = base(4)
                .with("keyOriginShapeBBox", bbox(r))
                .with("keyOriginLineEnd", pnt(to))
                .with("keyOriginLineStart", pnt(from))
                .with("keyOriginLineWeight", .double(weight))
                .with("keyOriginLineArrowSt", .boolean(false))
                .with("keyOriginLineArrowEnd", .boolean(false))
                .with("keyOriginLineArrWdth", .double(0))
                .with("keyOriginLineArrLngth", .double(0))
                .with("keyOriginLineArrConc", .integer(0))
        case .polygon:
            return nil
        }
        o = o.with("keyOriginIndex", .integer(0))
        let d = PSDDescriptor(classID: "null").with("keyDescriptorList", .list([.descriptor(o)]))
        return [0, 0, 0, 1] + Blocks.versionedBytes(d)
    }

    // MARK: Shape layers

    /// Fills the typed parts of a shape layer from its PSD blocks.
    public static func shapeFromBlocks(_ sh: inout ShapeLayer, _ block: (FourCC) -> [UInt8]?, _ w: UInt32, _ h: UInt32, _ dpi: Float) {
        if let d = block("vsms") ?? block("vmsk"), let (p, _) = pathFromVmsk(d, w, h) {
            sh.path = p
        }
        if let f = block("vscg").flatMap(fillFromVscg) {
            sh.fill = f
        }
        if let v = block("vstk").flatMap({ parseVstk($0, dpi) }) {
            sh.stroke = v.stroke
            if !v.fillEnabled { sh.fill = nil }
        }
        sh.live = block("vogk").flatMap(liveFromVogk)
    }

    static func hasFillBlock(_ raw: RawBlocks) -> Bool {
        raw.contains { b in
            switch b.key {
            case "vscg": fillFromVscg(b.data) != nil
            case "SoCo", "GdFl", "PtFl": Blocks.parseFill(b.key, b.data) != nil
            default: false
            }
        }
    }

    /// Rewrites the vector blocks of a shape layer in `raw` (key, data) to match the model: blocks
    /// that still decode to the model are kept byte-identical.
    public static func shapeBlocks(_ sh: ShapeLayer, _ raw: inout RawBlocks, _ w: UInt32, _ h: UInt32, _ dpi: Float) {
        func find(_ k: FourCC) -> Int? { raw.firstIndex { $0.key == k } }
        // Path.
        let pos = find("vsms") ?? find("vmsk")
        func keep(_ d: [UInt8]) -> Bool { pathFromVmsk(d, w, h)?.path == sh.path }
        if let i = pos, keep(raw[i].data) {
            // Unchanged.
        } else {
            // The layer's own raw copy may still be valid (psdRaw is the principal block).
            let data: [UInt8]
            if let r = sh.psdRaw, keep(r) { data = r } else { data = vmskBytes(sh.path, 0, w, h) }
            if let i = pos { raw[i].data = data } else { raw.append(("vmsk", data)) }
        }
        // Fill content.
        if let f = sh.fill, let i = find("vscg"), fillFromVscg(raw[i].data) != f {
            raw[i].data = vscgBytes(f)
        }
        // Photoshop shapes always carry fill content, even with the fill turned off.
        let present = raw.contains { ["vscg", "SoCo", "GdFl", "PtFl"].contains($0.key) }
        if sh.fill == nil && !present {
            raw.append(("vscg", vscgBytes(.solid(.black))))
        }
        // Stroke (+ fill enabled flag). A fill we could not decode counts as unchanged.
        let undecodableFill = sh.fill == nil && present && !hasFillBlock(raw)
        func same(_ v: VstkInfo) -> Bool {
            v.stroke == sh.stroke && (v.fillEnabled == (sh.fill != nil) || (v.fillEnabled && undecodableFill))
        }
        if let i = find("vstk") {
            if let v = parseVstk(raw[i].data, dpi), same(v) {
                // Unchanged.
            } else {
                raw[i].data = vstkBytes(sh.stroke, sh.fill != nil, dpi)
            }
        } else if sh.stroke != nil || (sh.fill == nil && hasFillBlock(raw)) {
            // "No fill" needs a vstk only when a fill block would otherwise paint.
            raw.append(("vstk", vstkBytes(sh.stroke, sh.fill != nil, dpi)))
        }
        // Live shape origination.
        let livePos = find("vogk")
        let current = livePos.flatMap { liveFromVogk(raw[$0].data) }
        if current != sh.live || (livePos == nil && sh.live != nil) {
            let generated = sh.live.flatMap { vogkBytes($0, dpi) }
            switch (livePos, generated) {
            case let (i?, g?): raw[i].data = g
            case let (i?, nil): raw.remove(at: i)
            case let (nil, g?): raw.append(("vogk", g))
            case (nil, nil): break
            }
        }
    }
}

private func nanToZero(_ v: Double) -> Double { v.isNaN ? 0 : v }
