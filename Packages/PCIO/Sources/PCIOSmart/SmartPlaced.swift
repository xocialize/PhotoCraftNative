// Port of photocraft-io (crates/io/src/smart_map.rs: PlacedSpec, sold_bytes, plld_bytes,
// stored_size, mask_from_item, feid_item, uuid_from), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// The placed-layer blocks a smart object is written with (`SoLd` with its transform quad, warp and
// filter stack; the legacy `PlLd` record next to it), the smart filter mask in the global `FEid`
// filter cache, and the deterministic uuids of regenerated placements.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD

extension SmartMap {
    /// Everything needed to write the placed-layer blocks of a smart object.
    public struct PlacedSpec: Sendable {
        public var idnt: String
        public var placed: String
        /// Source pixels → document pixels.
        public var transform: PCAffine
        /// Distort / Perspective: the full projective map (row-major 3×3), overriding `transform`.
        /// Anything but 9 values is ignored (photocraft's type is `[f64; 9]`).
        public var perspective: [Double]?
        /// Source size in pixels.
        public var size: SIMD2<Double>
        /// Source resolution.
        public var dpi: Double
        public var warp: Warp?
        /// `filterFX`, when the smart object has filters.
        public var filterFX: PSDDescriptor?

        public init(idnt: String, placed: String, transform: PCAffine, perspective: [Double]? = nil, size: SIMD2<Double>, dpi: Double = 72,
                    warp: Warp? = nil, filterFX: PSDDescriptor? = nil) {
            self.idnt = idnt
            self.placed = placed
            self.transform = transform
            self.perspective = perspective
            self.size = size
            self.dpi = dpi
            self.warp = warp
            self.filterFX = filterFX
        }

        /// The projective map when it is well formed.
        var homography: Homography? {
            guard let p = perspective, p.count == 9 else { return nil }
            return Homography(p)
        }
    }

    /// Where the frame corners land (top-left, top-right, bottom-right, bottom-left), as x, y pairs.
    /// The frame is `Blocks.placedFrame` for an affine placement (the inverse of `parseSmart`), the
    /// source rect for a projective one (as `parseSmartPerspective` reads it).
    static func quadPoints(_ s: PlacedSpec) -> [Double] {
        let (w, h) = (s.size.x, s.size.y)
        let t = s.transform
        let hom = s.homography
        func map(_ x: Double, _ y: Double) -> SIMD2<Double> {
            if let hom { return hom.apply(x, y) }
            return SIMD2(t.a * x + t.c * y + t.e, t.b * x + t.d * y + t.f)
        }
        let f = hom != nil ? SIMD4(0, 0, w, h) : Blocks.placedFrame(s.warp, w, h)
        var out: [Double] = []
        out.reserveCapacity(8)
        for (x, y) in [(f.x, f.y), (f.z, f.y), (f.z, f.w), (f.x, f.w)] {
            let p = map(x, y)
            out += [p.x, p.y]
        }
        return out
    }

    /// The transform quad: the source corners (top-left, top-right, bottom-right, bottom-left).
    static func quad(_ s: PlacedSpec) -> DValue { .list(quadPoints(s).map { .double($0) }) }

    /// Has the placement moved from the quad a template descriptor stores (`Trnf`)?
    static func quadMoved(_ template: PSDDescriptor, _ s: PlacedSpec) -> Bool {
        guard case let .list(pts)? = template["Trnf"] else { return true }
        let old = pts.compactMap { Blocks.num($0) }
        let new = quadPoints(s)
        return old.count != 8 || zip(old, new).contains { a, b in abs(a - b) > 1e-6 * (1 + abs(a)) }
    }

    static func enumv(_ t: String, _ v: String) -> DValue { .enumerated(type: DID(t), value: DID(v)) }

    /// The `warp` descriptor (also the `PlLd` warp). Multi-patch meshes have no 1 × 1 envelope and
    /// are written as no warp, with a message.
    static func warpDesc(_ warp: Warp?, _ size: SIMD2<Double>, _ warnings: inout [String]) -> PSDDescriptor {
        let none = Warp.none(SIMD4(0, 0, size.x, size.y))
        var w = warp ?? none
        var mesh: BezierMesh?
        if w.style == .custom {
            if let m = w.mesh, m.points.count == 16 {
                mesh = m
            } else {
                warnings.append("a custom warp with more than one patch was written to PSD without its warp")
                w = none
            }
        }
        let b = w.bounds
        let bounds = PSDDescriptor(classID: "classFloatRect")
            .with("Top ", .double(b.y))
            .with("Left", .double(b.x))
            .with("Btom", .double(b.w))
            .with("Rght", .double(b.z))
        var d = PSDDescriptor(classID: "warp")
            .with("warpStyle", enumv("warpStyle", w.style.psdName))
            .with("warpValue", .double(w.bend))
            .with("warpPerspective", .double(w.hDistort))
            .with("warpPerspectiveOther", .double(w.vDistort))
            .with("warpRotate", enumv("Ornt", w.vertical ? "Vrtc" : "Hrzn"))
            .with("bounds", .descriptor(bounds))
            .with("uOrder", .integer(4))
            .with("vOrder", .integer(4))
        if let m = mesh {
            let body = PSDDescriptor(classID: "rationalPoint")
                .with("Hrzn", .unitFloats(unit: "#Pxl", values: m.points.map(\.x)))
                .with("Vrtc", .unitFloats(unit: "#Pxl", values: m.points.map(\.y)))
            d = d.with("customEnvelopeWarp",
                       .descriptor(PSDDescriptor(classID: "customEnvelopeWarp").with("meshPoints", .objectArray(.init(prefix: 16, body: body)))))
        }
        return d
    }

    static func ratio(_ n: Int32, _ d: Int32) -> DValue {
        .descriptor(PSDDescriptor(classID: "null").with("numerator", .integer(n)).with("denominator", .integer(d)))
    }

    static func pad4(_ v: [UInt8]) -> [UInt8] {
        var v = v
        while v.count % 4 != 0 { v.append(0) }
        return v
    }

    /// `SoLd` block data. With `template` (the imported descriptor) every key it has is kept and
    /// only the placed id (for a duplicate), transform (when it moved), warp and filter stack are
    /// rewritten; otherwise a fresh descriptor in Photoshop's key order.
    public static func soldBytes(_ template: PSDDescriptor?, _ s: PlacedSpec, _ warnings: inout [String]) -> [UInt8] {
        let warp = DValue.descriptor(warpDesc(s.warp, s.size, &warnings))
        var d: PSDDescriptor
        if let t = template {
            d = t
            if textOf(t, "placed") != s.placed { set(&d, "placed", .text(.nulTerminated(s.placed))) }
            if quadMoved(t, s) {
                set(&d, "Trnf", quad(s))
                set(&d, "nonAffineTransform", quad(s))
            }
            set(&d, "warp", warp)
            if let fx = s.filterFX {
                set(&d, "filterFX", .descriptor(fx))
            } else {
                d.items.removeAll { $0.key.is("filterFX") }
            }
        } else {
            d = PSDDescriptor(classID: "null")
                .with("Idnt", .text(.nulTerminated(s.idnt)))
                .with("placed", .text(.nulTerminated(s.placed)))
                .with("PgNm", .integer(1))
                .with("totalPages", .integer(1))
                .with("Crop", .integer(1))
                .with("frameStep", ratio(0, 600))
                .with("duration", ratio(0, 600))
                .with("frameCount", .integer(1))
                .with("Annt", .integer(16))
                .with("Type", .integer(2))
                .with("Trnf", quad(s))
                .with("nonAffineTransform", quad(s))
                .with("warp", warp)
                .with("Sz  ", .descriptor(PSDDescriptor(classID: "Pnt ").with("Wdth", .double(s.size.x)).with("Hght", .double(s.size.y))))
                .with("Rslt", unit("#Rsl", s.dpi))
            if let fx = s.filterFX { d = d.with("filterFX", .descriptor(fx)) }
            d = d.with("comp", .integer(-1))
                .with("compInfo", .descriptor(PSDDescriptor(classID: "null").with("compID", .integer(-1)).with("originalCompID", .integer(-1))))
        }
        var w = BEWriter()
        w.fourCC("soLD")
        w.u32(4)
        w.put(Blocks.versionedBytes(d))
        return pad4(w.bytes)
    }

    /// A `soLD` whose descriptor holds only `Idnt` and `Trnf` (hand-built, or stripped by another
    /// writer), completed with the rest of Photoshop's placement keys in its order: the source size
    /// from the quad's sides, no warp, 72 ppi. Photoshop 27.11 refuses a file whose bare `SoLd`
    /// names no linked-file item, and opens it with the full descriptor (a missing link; PCPSD
    /// `placedLayerWithoutLinkedData`). nil when the block isn't such a descriptor.
    public static func completedPlacedData(_ data: [UInt8]) -> [UInt8]? {
        guard let so = try? PSDPlacedLayerData(bytes: Data(data)), so.identifier == "soLD" else { return nil }
        let t = so.descriptor.descriptor
        guard Set(t.items.map { "\($0.key)" }).isSubset(of: ["Idnt", "Trnf"]), let idnt = textOf(t, "Idnt"),
              case let .list(trnf)? = t["Trnf"] else { return nil }
        let q = trnf.compactMap { Blocks.num($0) }
        guard q.count == 8, q.allSatisfy(\.isFinite) else { return nil }
        let size = SIMD2(((q[2] - q[0]) * (q[2] - q[0]) + (q[3] - q[1]) * (q[3] - q[1])).squareRoot(),
                         ((q[6] - q[0]) * (q[6] - q[0]) + (q[7] - q[1]) * (q[7] - q[1])).squareRoot())
        guard size.x > 0, size.y > 0 else { return nil }
        var warnings: [String] = []
        let quad = DValue.list(q.map { .double($0) })
        let d = PSDDescriptor(classID: "null")
            .with("Idnt", .text(.nulTerminated(idnt)))
            .with("placed", .text(.nulTerminated(idnt)))
            .with("PgNm", .integer(1))
            .with("totalPages", .integer(1))
            .with("Crop", .integer(1))
            .with("frameStep", ratio(0, 600))
            .with("duration", ratio(0, 600))
            .with("frameCount", .integer(1))
            .with("Annt", .integer(16))
            .with("Type", .integer(2))
            .with("Trnf", quad)
            .with("nonAffineTransform", quad)
            .with("warp", .descriptor(warpDesc(nil, size, &warnings)))
            .with("Sz  ", .descriptor(PSDDescriptor(classID: "Pnt ").with("Wdth", .double(size.x)).with("Hght", .double(size.y))))
            .with("Rslt", unit("#Rsl", 72))
            .with("comp", .integer(-1))
            .with("compInfo", .descriptor(PSDDescriptor(classID: "null").with("compID", .integer(-1)).with("originalCompID", .integer(-1))))
        var w = BEWriter()
        w.fourCC("soLD")
        w.u32(so.version)
        w.put(Blocks.versionedBytes(d))
        return pad4(w.bytes)
    }

    /// `PlLd` block data (`plcL` version 3): the legacy placed-layer record Photoshop writes next to
    /// `SoLd`.
    public static func plldBytes(_ s: PlacedSpec, _ warnings: inout [String]) -> [UInt8] {
        var w = BEWriter()
        w.fourCC("plcL")
        w.u32(3)
        let id = Array(s.idnt.utf8.prefix(255))
        w.u8(UInt8(id.count))
        w.put(id)
        for v: Int32 in [1, 1, 16, 2] { w.i32(v) }
        for x in quadPoints(s) { w.f64(x) }
        w.u32(0)
        w.put(Blocks.versionedBytes(warpDesc(s.warp, s.size, &warnings)))
        return pad4(w.bytes)
    }

    /// The source size a `soLD` descriptor stores (`Sz  `).
    public static func storedSize(_ d: PSDDescriptor) -> SIMD2<Double>? {
        guard let sz = getDesc(d, "Sz  "), let w = Blocks.num(sz["Wdth"]), let h = Blocks.num(sz["Hght"]), w > 0, h > 0 else { return nil }
        return SIMD2(w, h)
    }

    // MARK: - The filter mask (`FEid`)

    /// The filter mask stored in an `FEid` item, in document coordinates and white beyond its
    /// bounds (`filterMaskExtendWithWhite`), as a grayscale mask of `sample` depth. nil when the
    /// item has no mask or it is all white (no mask); throws when it can't be decoded.
    public static func maskFromItem(_ item: PSDFilterEffectsItem, _ sample: SampleType, _ stack: FilterStack) throws -> LayerMask? {
        if item.mask == nil { return nil }
        guard let (rect, plane) = item.decodedMask() else { throw PCIOError.corrupt("the smart filter mask could not be decoded") }
        if item.depth != UInt32(PSDPixels.psdDepth(sample)) {
            throw PCIOError.unsupported("the smart filter mask is \(item.depth)-bit in a \(sample.serdeName) document")
        }
        let (w, h): (Int, Int)
        do { (w, h) = try rect.size() } catch { throw PCIOError.corrupt(String(describing: error)) }
        let fmt = PixelFormat(mode: .grayscale, sample: sample, alpha: false)
        var surface = Surface(format: fmt, defaultPixel: [1])
        let (n, overflow) = w.multipliedReportingOverflow(by: h)
        if overflow { throw PCIOError.corrupt("the smart filter mask is too large") }
        let bytes = PSDPixels.interleave([plane], [PSDPixels.zeroSample(sample)], n, sample, [false])
        let r = PixelRect(x0: rect.left, y0: rect.top, x1: rect.right, y1: rect.bottom)
        if r.area > 0, bytes.count >= r.area * fmt.bytesPerPixel { surface.writeInterleaved(r, bytes) }
        surface.prune()
        if surface.contentBounds.isEmpty { return nil }
        return LayerMask(surface: surface, enabled: stack.maskEnabled, linked: stack.maskLinked, density: 1, feather: 0)
    }

    /// An `FEid` item for a smart object with filters: the unfiltered placed pixels Photoshop
    /// filters from (colour channels from slot 0, transparency in the last slot; in the document's
    /// pixel format, CMYK inverted as in layer channels) and the filter mask over `bounds` (white
    /// when `mask` is nil). Photoshop needs the planes: re-rendering the filters of an item without
    /// them crashes it. nil when there are no unfiltered pixels.
    public static func feidItem(_ placed: String, _ unfiltered: Surface, _ mask: LayerMask?, _ bounds: PixelRect,
                                _ docFormat: PixelFormat) -> PSDFilterEffectsItem? {
        let sample = docFormat.sample
        let px = unfiltered.format == docFormat ? unfiltered : convertSurface(unfiltered, docFormat)
        let content = px.contentBounds
        if content.isEmpty { return nil }
        // Over the whole area the filters may draw into: Photoshop clips the filtered result to
        // these planes, so the content bounds alone would cut blurs off at the source's edge.
        let r = content.union(bounds)
        let cc = docFormat.mode.colorChannels
        let depth = PSDPixels.psdDepth(sample)
        let compression: PSDCompression = sample == .f32 ? .zipPrediction : .rle
        func encode(_ plane: [UInt8], _ w: Int, _ h: Int) -> PSDEffectsPlane {
            if let p = try? PSDEffectsPlane.encode(compression, decoded: plane, width: w, height: h, depth: depth) { return p }
            if let p = try? PSDEffectsPlane.encode(.raw, decoded: plane, width: w, height: h, depth: depth) { return p }
            return PSDEffectsPlane(compression: .raw, data: Data(plane))
        }
        var invert = [Bool](repeating: docFormat.mode == .cmyk, count: cc)
        invert.append(false)
        // Fully transparent pixels carry white, as in Photoshop's own cache: filters that look at
        // colour regardless of alpha (Shadows/Highlights) read it.
        var vals = px.readRegion(r)
        let white = docFormat.components(fromRGBA: SIMD4(1, 1, 1, 1))
        let stride = cc + 1
        var at = 0
        while at + stride <= vals.count {
            if vals[at + cc] <= 0 {
                for k in 0 ..< min(cc, white.count) { vals[at + k] = white[k] }
            }
            at += stride
        }
        var filled = Surface(format: docFormat)
        filled.writeRegion(r, vals)
        vals = []
        var bytes = filled.readInterleaved(r)
        if docFormat.mode == .lab && sample == .u16 {
            // 16-bit Lab a*/b* in Photoshop's scale, as in layer channels.
            PSDPixels.lab16Chroma(&bytes, cc + 1, toDoc: false)
        }
        let planes = PSDPixels.deinterleave(bytes, cc + 1, sample, invert)
        let (w, h) = (r.width, r.height)
        var slots = [PSDEffectsPlane?](repeating: nil, count: 26)
        for (i, p) in planes.enumerated() {
            let slot = i == cc ? 25 : i
            if slot < slots.count { slots[slot] = encode(p, w, h) }
        }
        var item = filterMaskItem(placed, mask, bounds, sample)
        item.rect = PSDRect(top: r.y0, left: r.x0, bottom: r.y1, right: r.x1)
        item.slots = slots
        return item
    }

    static func filterMaskItem(_ placed: String, _ mask: LayerMask?, _ bounds: PixelRect, _ sample: SampleType) -> PSDFilterEffectsItem {
        let fmt = PixelFormat(mode: .grayscale, sample: sample, alpha: false)
        var area = mask.map { $0.surface.contentBounds.union(bounds) } ?? bounds
        if area.isEmpty { area = PixelRect(x0: 0, y0: 0, x1: 1, y1: 1) }
        let rect = PSDRect(top: area.y0, left: area.x0, bottom: area.y1, right: area.x1)
        let (w, h) = (area.width, area.height)
        var plane: [UInt8]
        if let m = mask {
            let s = m.surface.format == fmt ? m.surface : convertSurface(m.surface, fmt)
            plane = PSDPixels.deinterleave(s.readInterleaved(area), 1, sample, [false]).first ?? []
        } else {
            var one: [UInt8] = []
            PSDPixels.encodeBE(1, sample, &one)
            plane = []
            plane.reserveCapacity(w * h * one.count)
            for _ in 0 ..< w * h { plane += one }
        }
        let depth = PSDPixels.psdDepth(sample)
        let compression: PSDCompression = sample == .f32 ? .zipPrediction : .rle
        let encoded = (try? PSDEffectsPlane.encode(compression, decoded: plane, width: w, height: h, depth: depth))
            ?? (try? PSDEffectsPlane.encode(.raw, decoded: plane, width: w, height: h, depth: depth))
            ?? PSDEffectsPlane(compression: .raw, data: Data(plane))
        return PSDFilterEffectsItem(id: placed, version: 1, rect: rect, depth: UInt32(depth), maxChannels: 24,
                                    slots: [PSDEffectsPlane?](repeating: nil, count: 26), mask: (rect, encoded))
    }

    /// photocraft-raster `Surface::convert`: every stored tile converted pixel by pixel (depth
    /// and/or colour model, models through sRGB RGBA as `convert_pixel` does).
    static func convertSurface(_ s: Surface, _ to: PixelFormat) -> Surface {
        let from = s.format
        var out = Surface(format: to, defaultPixel: convertPixel(from, to, s.defaultPixelValue))
        var coords: [TileCoord] = []
        s.forEachTile { c, _ in coords.append(c) }
        for c in coords {
            let r = c.rect
            let src = s.readRegion(r)
            let (fn, tn) = (from.channels, to.channels)
            guard fn > 0 else { continue }
            var dst = [Float](repeating: 0, count: r.area * tn)
            for i in 0 ..< r.area {
                let px = convertPixel(from, to, Array(src[i * fn ..< (i + 1) * fn]))
                for k in 0 ..< min(tn, px.count) { dst[i * tn + k] = px[k] }
            }
            out.writeRegion(r, dst)
        }
        return out
    }

    /// photocraft-raster `convert_pixel`.
    static func convertPixel(_ from: PixelFormat, _ to: PixelFormat, _ px: [Float]) -> [Float] {
        let n = from.mode.colorChannels
        func at(_ i: Int) -> Float { i < px.count ? px[i] : 0 }
        if from.mode == to.mode {
            var out = (0 ..< n).map(at)
            if to.alpha { out.append(from.alpha ? at(n) : 1) }
            return out
        }
        let a: Float = from.alpha ? at(n) : 1
        let rgb: SIMD3<Float> = switch from.mode {
        case .grayscale, .bitmap, .duotone: SIMD3(repeating: at(0))
        case .cmyk: ColorConvert.cmykToRGB(SIMD4(at(0), at(1), at(2), at(3)))
        case .lab: ColorConvert.labToSRGB(SIMD3(at(0) * 100, at(1) * 255 - 128, at(2) * 255 - 128))
        default: SIMD3(at(0), at(1), at(2))
        }
        return to.components(fromRGBA: SIMD4(rgb, a))
    }

    /// A deterministic uuid-shaped id (8-4-4-4-12 hex digits) derived from `seed`.
    public static func uuidFrom(_ seed: [UInt8]) -> String {
        let x = Array(toHex(Array(BLAKE3.hash(seed).prefix(16))))
        func part(_ r: Range<Int>) -> String { String(x[r]) }
        return "\(part(0 ..< 8))-\(part(8 ..< 12))-\(part(12 ..< 16))-\(part(16 ..< 20))-\(part(20 ..< 32))"
    }
}
