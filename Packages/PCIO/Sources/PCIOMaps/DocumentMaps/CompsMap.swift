// Port of photocraft-io (crates/io/src/comps_map.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// Layer comps and artboards ⇄ PSD.
//
// * Layer comps: image resource 1065 holds a `CompList` descriptor (`list` of `Comp` objects with
//   `Nm  `, `compID`, `capturedInfo` bit flags and an optional `comment`, plus `lastAppliedComp`).
//   Each layer's state per comp lives in its `shmd` block under the `cmls` key: `layerSettings`,
//   one object per comp id list with `enab` (visibility) and `Ofst` (offset from the layer's saved
//   position). Comp id 0 is the Last Document State.
// * Artboards: the per-layer `artb` block (older files: `artd`/`abdd`) is an `artboard` descriptor
//   with `artboardRect`, `guideIndeces`, `artboardPresetName`, `Clr ` and
//   `artboardBackgroundType` (1 white, 2 black, 3 transparent, 4 other).
//
// Both are re-emitted verbatim while they still decode to the document's state, and are
// regenerated otherwise (comp appearance is not written to PSD; `.pcraft` keeps it).

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD

public enum CompsMap {
    /// Image resource id of the layer comp list.
    public static let layerComps: UInt16 = 1065
    /// Per-layer artboard block keys, preferred first.
    public static let artboardKeys: [FourCC] = ["artb", "artd", "abdd"]

    static var nulName: PSDUnicodeString { PSDUnicodeString(units: [0]) }

    static func obj(_ cls: String) -> PSDDescriptor { PSDDescriptor(classID: DID(cls), name: nulName) }

    static func padEven(_ v: [UInt8]) -> [UInt8] { v.count % 2 == 1 ? v + [0] : v }

    static func text(_ d: PSDDescriptor, _ key: String) -> String? {
        if case let .text(t)? = d[key] { return t.string }
        return nil
    }

    static func int(_ d: PSDDescriptor, _ key: String) -> Int64? {
        switch d[key] {
        case let .integer(i)?: Int64(i)
        case let .largeInteger(i)?: i
        case let .double(f)?: roundCast(f)
        case let .unitFloat(_, value)?: roundCast(value)
        default: nil
        }
    }

    // MARK: Artboards

    /// Decodes an `artb`/`artd`/`abdd` block.
    public static func parseArtboard(_ data: [UInt8]) -> Artboard? {
        guard let d = try? PSDVersionedDescriptor.parsePrefix(Data(data)).0.descriptor, let r = Blocks.getDesc(d, "artboardRect") else { return nil }
        func g(_ k: String) -> Int32? { Blocks.num(r[k]).map { roundCast($0) } }
        guard let x0 = g("Left"), let y0 = g("Top "), let x1 = g("Rght"), let y1 = g("Btom") else { return nil }
        let background: ArtboardBackground = switch int(d, "artboardBackgroundType") ?? 1 {
        case 2: .black
        case 3: .transparent
        case 4: .custom(Blocks.getDesc(d, "Clr ").flatMap(Blocks.colorFromDesc) ?? .white)
        default: .white
        }
        let preset = text(d, "artboardPresetName") ?? ""
        return Artboard(rect: PixelRect(x0: x0, y0: y0, x1: x1, y1: y1), background: background, preset: preset)
    }

    /// Encodes an `artb` block. `guides` are indices into the document's guide list (resource 1032)
    /// that belong to the board.
    public static func writeArtboard(_ a: Artboard, _ guides: [Int32]) -> [UInt8] {
        func f(_ v: Int32) -> DValue { .double(Double(v)) }
        let rect = PSDDescriptor(classID: "classFloatRect").with("Top ", f(a.rect.y0)).with("Left", f(a.rect.x0)).with("Btom", f(a.rect.y1))
            .with("Rght", f(a.rect.x1))
        let color: PCColor = switch a.background {
        case let .custom(c): c
        case .black: .black
        default: .white
        }
        let d = PSDDescriptor(classID: "artboard")
            .with("artboardRect", .descriptor(rect))
            .with("guideIndeces", .list(guides.map { .integer($0) }))
            .with("artboardPresetName", .text(.nulTerminated(a.preset)))
            .with("Clr ", .descriptor(Blocks.colorToDesc(color)))
            .with("artboardBackgroundType", .integer(a.background.psdType))
        return padEven(Blocks.versionedBytes(d))
    }

    /// Indices of the document guides (vertical first, then horizontal, as in resource 1032) that
    /// lie inside `r`.
    public static func guidesIn(_ guides: Guides, _ r: PixelRect) -> [Int32] {
        let v = guides.vertical.map { $0 > Double(r.x0) && $0 < Double(r.x1) }
        let h = guides.horizontal.map { $0 > Double(r.y0) && $0 < Double(r.y1) }
        return (v + h).enumerated().filter(\.element).map { Int32(truncatingIfNeeded: $0.offset) }
    }

    /// Keeps, regenerates or removes the artboard block among a layer's raw blocks.
    public static func artboardBlock(_ guides: Guides, _ l: Layer, _ raw: inout RawBlocks) {
        let pos = raw.firstIndex { artboardKeys.contains($0.key) }
        switch (l.artboard, pos) {
        case (nil, _?):
            raw.removeAll { artboardKeys.contains($0.key) }
        case (nil, nil):
            break
        case let (a?, p):
            if let i = p, parseArtboard(raw[i].data) == a { return }
            let data = writeArtboard(a, guidesIn(guides, a.rect))
            if let i = p { raw[i] = ("artb", data) } else { raw.append(("artb", data)) }
        }
    }

    // MARK: Layer comps

    /// One `layerSettings` entry of a `cmls` descriptor.
    struct Setting: Equatable {
        var comps: [UInt32]
        var visible: Bool?
        /// Kept at the file's width: whether origin + offset fits an `Int32` is decided per layer
        /// (#1017).
        var offset: SIMD2<Int64>?
    }

    static func parseCmls(_ data: [UInt8]) -> [Setting]? {
        guard let d = try? PSDVersionedDescriptor.parsePrefix(Data(data)).0.descriptor, case let .list(items)? = d["layerSettings"] else {
            return nil
        }
        var out: [Setting] = []
        for it in items {
            guard case let .descriptor(s) = it else { continue }
            var comps: [UInt32] = []
            if case let .list(ids)? = s["compList"] {
                comps = ids.compactMap { if case let .integer(i) = $0 { UInt32(bitPattern: i) } else { nil } }
            }
            var visible: Bool?
            if case let .boolean(b)? = s["enab"] { visible = b }
            let offset = Blocks.getDesc(s, "Ofst").flatMap { o -> SIMD2<Int64>? in
                guard let x = int(o, "Hrzn"), let y = int(o, "Vrtc") else { return nil }
                return SIMD2(x, y)
            }
            out.append(Setting(comps: comps, visible: visible, offset: offset))
        }
        return out
    }

    /// The `cmls` item data of a layer's preserved `shmd` block.
    static func layerCmls(_ l: Layer) -> [UInt8]? {
        guard let shmd = l.psdBlocks.first(where: { $0.key == "shmd" }), let items = try? PSDMetadataItem.parse(Data(shmd.data)) else { return nil }
        return items.first { $0.key == "cmls" }.map { [UInt8]($0.data) }
    }

    /// Absolute comp position of a layer at `here` moved by a file offset; nil when it does not fit
    /// an `Int32` (the offsets come from the file, so the sum must not wrap or overflow, #1017).
    static func offsetPosition(_ here: SIMD2<Int32>, _ d: SIMD2<Int64>) -> SIMD2<Int32>? {
        func add(_ a: Int32, _ d: Int64) -> Int32? {
            let (v, o) = Int64(a).addingReportingOverflow(d)
            return o ? nil : Int32(exactly: v)
        }
        guard let x = add(here.x, d.x), let y = add(here.y, d.y) else { return nil }
        return SIMD2(x, y)
    }

    /// Comps, last applied comp and Last Document State described by `resource` (1065 data) and
    /// the layers' `cmls` metadata.
    public static func compsFromPSD(_ resource: [UInt8]?, _ doc: Document) -> (comps: [LayerComp], lastApplied: UInt32?, lastDocumentState: LayerComp?) {
        let r = decodeComps(resource, doc)
        return (r.comps, r.lastApplied, r.lastDocumentState)
    }

    /// `compsFromPSD` plus import warnings for comp data that could not be represented.
    public static func decodeComps(_ resource: [UInt8]?, _ doc: Document)
        -> (comps: [LayerComp], lastApplied: UInt32?, lastDocumentState: LayerComp?, warnings: [String])
    {
        var warnings: [String] = []
        guard let data = resource, let d = try? PSDVersionedDescriptor.parsePrefix(Data(data)).0.descriptor else {
            return ([], nil, nil, warnings)
        }
        var comps: [LayerComp] = []
        if case let .list(items)? = d["list"] {
            for it in items {
                guard case let .descriptor(c) = it, let id = int(c, "compID") else { continue }
                var comp = LayerComp(id: UInt32(truncatingIfNeeded: id), name: text(c, "Nm  ") ?? "", comment: text(c, "comment") ?? "",
                                     applyVisibility: false, applyPosition: false, applyAppearance: false, states: [])
                comp.capturedInfo = Int32(truncatingIfNeeded: int(c, "capturedInfo") ?? 0)
                comps.append(comp)
            }
        }
        let lastApplied = int(d, "lastAppliedComp").map { UInt32(truncatingIfNeeded: $0) }.flatMap { id in
            comps.contains { $0.id == id } ? id : nil
        }
        var last = LayerComp(id: 0, name: "Last Document State", comment: "", applyVisibility: true, applyPosition: true,
                             applyAppearance: false, states: [])
        // First comp of each id, looked up in a table: a scan per layer setting is quadratic in a
        // hostile file (photocraft `7c78c951e`).
        var compIndex: [UInt32: Int] = [:]
        for (i, c) in comps.enumerated() where compIndex[c.id] == nil { compIndex[c.id] = i }
        doc.forEachLayer { _, _, l in
            guard let settings = layerCmls(l).flatMap(parseCmls) else { return }
            let here = l.compPosition
            for s in settings {
                if s.visible == nil && s.offset == nil { continue }
                var position: SIMD2<Int32>?
                if let h = here, let o = s.offset {
                    position = offsetPosition(h, o)
                    if position == nil {
                        warnings.append(
                            "layer \"\(l.name)\": layer comp position offset (\(o.x), \(o.y)) is out of range; that position was not imported")
                    }
                }
                let state = CompLayerState(layer: l.id, visible: s.visible, position: position, appearance: nil)
                for id in s.comps {
                    if id == 0 {
                        last.states.append(state)
                    } else if let i = compIndex[id] {
                        comps[i].states.append(state)
                    }
                }
            }
        }
        return (comps, lastApplied, last.states.isEmpty ? nil : last, warnings)
    }

    /// The 1065 resource data for `doc`'s comps (nil when there are none).
    public static func writeCompsResource(_ doc: Document) -> [UInt8]? {
        if doc.layerComps.isEmpty { return nil }
        let list: [DValue] = doc.layerComps.map { c in
            var d = PSDDescriptor(classID: "Comp").with("Nm  ", .text(.nulTerminated(c.name)))
            if !c.comment.isEmpty { d = d.with("comment", .text(.nulTerminated(c.comment))) }
            return .descriptor(d.with("compID", .integer(Int32(bitPattern: c.id))).with("capturedInfo", .integer(c.capturedInfo)))
        }
        var d = PSDDescriptor(classID: "CompList").with("list", .list(list))
        if let id = doc.lastAppliedComp { d = d.with("lastAppliedComp", .integer(Int32(bitPattern: id))) }
        return Blocks.versionedBytes(d)
    }

    static func settingValue(_ ids: [UInt32], _ st: CompLayerState?, _ here: SIMD2<Int32>?) -> DValue {
        var s = obj("null")
        if let st {
            if let v = st.visible { s = s.with("enab", .boolean(v)) }
            // A position whose offset from the layer does not fit an `Int32` (e.g. from a `.pcraft`
            // file) is left out rather than wrapped: the comp then records no position (#1017).
            if let p = st.position, let h = here {
                let (dx, ox) = p.x.subtractingReportingOverflow(h.x)
                let (dy, oy) = p.y.subtractingReportingOverflow(h.y)
                if !ox && !oy {
                    s = s.with("Ofst", .descriptor(obj("null").with("Hrzn", .integer(dx)).with("Vrtc", .integer(dy))))
                }
            }
        }
        return .descriptor(s.with("compList", .list(ids.map { .integer(Int32(bitPattern: $0)) })))
    }

    /// The `cmls` item data for one layer (nil when the document has no comps).
    public static func writeCmls(_ comps: [LayerComp], _ last: LayerComp?, _ l: Layer, _ psdId: UInt32) -> [UInt8]? {
        if comps.isEmpty { return nil }
        let here = l.compPosition
        var settings: [DValue] = comps.map { settingValue([$0.id], $0.state(l.id), here) }
        settings.append(settingValue([0], last?.state(l.id), here))
        let origin = obj("null").with("Hrzn", .double(0)).with("Vrtc", .double(0))
        let d = PSDDescriptor(classID: "null")
            .with("origFXRefPoint", .descriptor(origin))
            .with("LyrI", .integer(Int32(bitPattern: psdId)))
            .with("layerSettings", .list(settings))
        return Blocks.versionedBytes(d)
    }

    /// Whether `doc`'s comps still equal what its preserved PSD data (resource 1065 plus the
    /// layers' `cmls`) decodes to, in which case all of it is written back verbatim.
    public static func compsUnchanged(_ doc: Document) -> Bool {
        let raw = doc.metadata.psdResources.first { $0.id == layerComps }?.data
        let (comps, lastApplied, last) = compsFromPSD(raw, doc)
        return comps == doc.layerComps && lastApplied == doc.lastAppliedComp && last == doc.lastDocumentState
    }

    /// Replaces (or removes, with nil) the `cmls` item of a layer's `shmd` block among its raw
    /// blocks, keeping the other metadata items.
    public static func setCmls(_ raw: inout RawBlocks, _ cmls: [UInt8]?) {
        let pos = raw.firstIndex { $0.key == "shmd" }
        var items = pos.flatMap { try? PSDMetadataItem.parse(Data(raw[$0].data)) } ?? []
        switch (items.firstIndex { $0.key == "cmls" }, cmls) {
        case let (i?, data?): items[i].data = Data(padEven(data))
        case let (i?, nil): items.remove(at: i)
        case let (nil, data?): items.insert(PSDMetadataItem(key: "cmls", data: Data(data)), at: 0)
        case (nil, nil): return
        }
        switch (pos, items.isEmpty) {
        case let (i?, true): raw.remove(at: i)
        case let (i?, false): raw[i].data = [UInt8](PSDMetadataItem.serialize(items))
        case (nil, false): raw.append(("shmd", [UInt8](PSDMetadataItem.serialize(items))))
        case (nil, true): break
        }
    }
}
