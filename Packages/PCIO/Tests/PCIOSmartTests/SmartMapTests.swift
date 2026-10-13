// Tests ported from photocraft-io (crates/io/src/smart_map.rs `#[cfg(test)]`, and the parts of
// crates/io/tests/smart_contents_identity.rs that only need this module), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors. The FEid mask tests are new.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
@testable import PCIOSmart
import PCPSD
import Testing

func sf(_ command: String, _ params: JSONValue) -> SmartFilter {
    SmartFilter(command: command, params: params, blend: .normal, opacity: 1, visible: true)
}

func occurrences(_ hay: [UInt8], _ needle: [UInt8]) -> Int {
    guard hay.count >= needle.count else { return 0 }
    return (0 ... hay.count - needle.count).filter { hay[$0 ..< $0 + needle.count].elementsEqual(needle) }.count
}

func spec(_ idnt: String = "id", _ placed: String = "pl", transform: PCAffine = .identity, perspective: [Double]? = nil,
          size: SIMD2<Double>, warp: Warp? = nil, filterFX: PSDDescriptor? = nil) -> SmartMap.PlacedSpec {
    SmartMap.PlacedSpec(idnt: idnt, placed: placed, transform: transform, perspective: perspective, size: size, dpi: 72, warp: warp,
                        filterFX: filterFX)
}

@Suite struct SmartMapTests {
    /// A freshly built placed layer writes `warp` (key and class) as a length-4 string, as
    /// Photoshop does; the code form is a different key to Photoshop.
    @Test func freshPlacedWarpIsAStringID() throws {
        let s = spec("id", "id", size: SIMD2(10, 10))
        var warnings: [String] = []
        let sold = SmartMap.soldBytes(nil, s, &warnings)
        let plld = SmartMap.plldBytes(s, &warnings)
        // `SoLd`: the `warp` key and the warp descriptor's class; `PlLd`: the descriptor's class.
        for (bytes, n) in [(sold, 2), (plld, 1)] {
            #expect(occurrences(bytes, [0, 0, 0, 4] + Array("warp".utf8)) == n)
            #expect(occurrences(bytes, [0, 0, 0, 0] + Array("warp".utf8)) == 0)
        }
        let d = try #require(SmartMap.soldDescriptor(sold))
        guard case let .descriptor(w)? = d["warp"] else {
            Issue.record("no warp descriptor")
            return
        }
        #expect(w.classID == .string(Array("warp".utf8)))
    }

    @Test func modelledFiltersRoundTrip() throws {
        let filters: [SmartFilter] = [
            sf("filter.blur.gaussianBlur", ["radius": 4.0]),
            sf("filter.blur.boxBlur", ["radius": 5.0]),
            sf("filter.blur.motionBlur", ["angle": -20, "distance": 10.0]),
            sf("filter.sharpen.unsharpMask", ["amount": 150.0, "radius": 2.0, "threshold": 0]),
            sf("filter.noise.addNoise", ["amount": 12.0, "distribution": "uniform", "monochromatic": false, "seed": 1234]),
            sf("filter.noise.median", ["radius": 3.0]),
            sf("filter.other.highPass", ["radius": 3.0]),
            sf("filter.other.maximum", ["radius": 2.0]),
            sf("filter.other.minimum", ["radius": 2.0]),
            sf("filter.pixelate.mosaic", ["cellSize": 8.0]),
            sf("filter.stylize.emboss", ["angle": 135, "height": 3, "amount": 100]),
            sf("image.adjustments.levels", ["inBlack": 20, "inWhite": 220, "gamma": 1.4, "red": ["inBlack": 0, "inWhite": 255, "gamma": 0.8]]),
            sf("image.adjustments.curves", ["points": [[0.0, 0.0], [64.0, 40.0], [255.0, 255.0]], "blue": [[0.0, 20.0], [255.0, 235.0]]]),
            sf("image.adjustments.shadowsHighlights", [:]),
            // A pencil-drawn curve: 256 output levels (`Mpng`).
            sf("image.adjustments.curves", ["pencil": true, "points": .array((0 ..< 256).reversed().map { .number(Double($0)) })]),
        ]
        for var f in filters {
            f.blend = .overlay
            f.opacity = 0.75
            f.visible = false
            let d = try SmartMap.itemForFilter(f)
            let back = SmartMap.filterFromItem(try PSDDescriptor(bytes: d.serializedBytes()))
            #expect(back == f, "\(f.command)")
        }
    }

    @Test func unknownFiltersKeepTheirDescriptor() throws {
        let item = PSDDescriptor(classID: "filterFX")
            .with("Nm  ", .text(.nulTerminated("Twirl...")))
            .with("blendOptions", .descriptor(PSDDescriptor(classID: "blendOptions").with("Opct", SmartMap.unit("#Prc", 100))
                    .with("Md  ", SmartMap.enumv("BlnM", "normal"))))
            .with("enab", .boolean(true))
            .with("Fltr", .descriptor(PSDDescriptor(classID: "Twrl").with("Angl", .integer(50))))
            .with("filterID", .integer(SmartMap.code("Twrl")))
        let f = SmartMap.filterFromItem(item)
        #expect(f.command == SmartMap.unsupportedFilter)
        #expect(f.params["name"] == "Twirl...")
        #expect(try SmartMap.itemForFilter(f) == item)
        // Hidden and re-blended: only those keys change.
        var g = f
        g.visible = false
        g.blend = .screen
        let back = SmartMap.filterFromItem(try SmartMap.itemForFilter(g))
        #expect(back.visible == false && back.blend == .screen && back.params == f.params)
        // A known filter with a setting we don't model is kept verbatim too.
        let odd = PSDDescriptor(classID: "filterFX").with("Fltr", .descriptor(PSDDescriptor(classID: "GsnB")))
            .with("filterID", .integer(SmartMap.code("GsnB")))
        #expect(SmartMap.filterFromItem(odd).command == SmartMap.unsupportedFilter)
    }

    @Test func unwritableFiltersAreReportedNotFatal() {
        let stack = SmartMap.FilterStack(filters: [
            sf("filter.distort.twirl", ["angle": 50]),
            sf("filter.blur.gaussianBlur", ["radius": 2.0]),
            sf(SmartMap.unsupportedFilter, ["psd": "zz"]),
            sf("image.adjustments.levels", ["cyan": ["gamma": 2.0]]),
            sf("image.adjustments.shadowsHighlights", ["shadowAmount": 50]),
        ])
        var w: [String] = []
        let d = SmartMap.filterFX(stack, "L", &w)
        #expect(w.count == 4, "\(w)")
        #expect(w.first == "layer \"L\": smart filter filter.distort.twirl was not written to PSD: this filter has no PSD equivalent")
        let back = SmartMap.filterStack(d)
        #expect(back.filters == [stack.filters[1]])
    }

    @Test func placedBlocksParseBack() throws {
        let t = PCAffine(m: [0.5, 0.1, -0.1, 0.5, 10, 20])
        let stack = SmartMap.FilterStack(enabled: false, filters: [sf("filter.blur.gaussianBlur", ["radius": 3.0])], maskEnabled: false,
                                         maskLinked: true)
        var w: [String] = []
        var s = spec("id-1", "pl-2", transform: t, size: SIMD2(64, 32), filterFX: SmartMap.filterFX(stack, "L", &w))
        let sold = SmartMap.soldBytes(nil, s, &w)
        #expect(w.isEmpty)
        #expect(sold.count % 4 == 0)
        let p = try #require(SmartMap.parseSold(sold))
        #expect(p.idnt == "id-1" && p.placed == "pl-2")
        for (a, b) in zip(p.transform.m, t.m) { #expect(abs(a - b) < 1e-9) }
        #expect(p.stack == stack)
        try PSDTaggedBlock(key: "SoLd", bytes: sold).checkStructure()
        try PSDTaggedBlock(key: "PlLd", bytes: SmartMap.plldBytes(s, &w)).checkStructure()
        // A template keeps its other keys; an unmoved transform keeps its exact quad.
        var tmpl = try #require(SmartMap.soldDescriptor(sold))
        tmpl.items.append(PSDDescriptor.Item("extraKey", .integer(7)))
        s.filterFX = nil
        let again = SmartMap.soldBytes(tmpl, s, &w)
        let d = try #require(SmartMap.soldDescriptor(again))
        #expect(d["extraKey"] == .integer(7))
        #expect(d["filterFX"] == nil)
        #expect(d["Trnf"] == tmpl["Trnf"])
    }

    /// A Distort / Perspective placement goes out as its four corners (`Trnf`, `nonAffineTransform`)
    /// and comes back as the same projective map; an affine one reads back as no perspective.
    @Test func perspectivePlacementRoundTripsThroughSold() throws {
        let h = try #require(Homography.rectToQuad(SIMD4(0, 0, 64, 32), [SIMD2(10, 5), SIMD2(80, 8), SIMD2(70, 50), SIMD2(12, 40)]))
        var w: [String] = []
        var s = spec(perspective: h.m, size: SIMD2(64, 32))
        let sold = SmartMap.soldBytes(nil, s, &w)
        let back = try #require(Blocks.parseSmartPerspective("SoLd", sold))
        func n(_ m: [Double]) -> [Double] { m.map { $0 / m[8] } }
        for (a, b) in zip(n(back), n(h.m)) { #expect(abs(a - b) < 1e-9 * (1 + abs(b)), "\(back) vs \(h.m)") }
        // Affine placements carry no perspective.
        s.perspective = nil
        s.transform = PCAffine(m: [2, 0, 0, 2, 5, 7])
        let affine = SmartMap.soldBytes(nil, s, &w)
        #expect(Blocks.parseSmartPerspective("SoLd", affine) == nil)
        #expect(Blocks.parseSmartPerspective("PlLd", affine) == nil)
    }

    /// `quadMoved` compares the corners a template stores with the placement's: unchanged keeps
    /// the template's quad, a moved corner (affine or projective) or a missing quad rewrites it.
    @Test func quadMovedDetectsCornerChanges() throws {
        let t = PCAffine(m: [1, 0, 0, 1, 3, 4])
        var w: [String] = []
        var s = spec(transform: t, size: SIMD2(20, 10))
        let template = try #require(SmartMap.parseSold(SmartMap.soldBytes(nil, s, &w))).descriptor
        #expect(!SmartMap.quadMoved(template, s), "same placement")
        s.transform = PCAffine(m: [1, 0, 0, 1, 3.5, 4])
        #expect(SmartMap.quadMoved(template, s), "moved half a pixel")
        s.transform = t
        s.perspective = Homography.rectToQuad(SIMD4(0, 0, 20, 10), [SIMD2(3, 4), SIMD2(23, 4), SIMD2(20, 12), SIMD2(3, 14)])?.m
        #expect(SmartMap.quadMoved(template, s), "one corner moved (Distort)")
        #expect(SmartMap.quadMoved(PSDDescriptor(classID: "null"), s), "no stored quad")
    }

    /// Corrupted placed-layer data and filter descriptors never trap: they parse to something
    /// (unknown filters stay verbatim) or to nothing.
    @Test func mutatedPlacedDataNeverTraps() {
        let stack = SmartMap.FilterStack(filters: [
            sf("filter.blur.gaussianBlur", ["radius": 3.0]),
            sf("image.adjustments.curves", ["points": [[0.0, 0.0], [255.0, 255.0]]]),
            sf("image.adjustments.levels", ["inBlack": 3, "inWhite": 250, "gamma": 1.1]),
        ])
        var w: [String] = []
        let s = spec(size: SIMD2(8, 8), filterFX: SmartMap.filterFX(stack, "L", &w))
        let sold = SmartMap.soldBytes(nil, s, &w)
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        var parsed = 0
        for _ in 0 ..< 3000 {
            var b = sold
            for _ in 0 ..< 1 + next() % 3 {
                let i = Int(next() % UInt64(b.count))
                b[i] = UInt8(truncatingIfNeeded: next())
            }
            if let p = SmartMap.parseSold(b) {
                parsed += 1
                for f in p.stack?.filters ?? [] { _ = try? SmartMap.itemForFilter(f) }
                _ = SmartMap.soldBytes(p.descriptor, s, &w)
            }
        }
        #expect(parsed > 0)
    }

    @Test func warpsAreWrittenAndReadBack() {
        let bounds = SIMD4<Double>(0, 0, 60, 30)
        var custom = BezierMesh.identity(bounds: bounds, cols: 1, rows: 1)
        custom.points[15] = SIMD2(67, 30)
        var multi = Warp.preset(.custom, bend: 0, bounds: bounds)
        multi.mesh = BezierMesh.identity(bounds: bounds, cols: 2, rows: 2)
        var arc = Warp.preset(.arc, bend: 40, bounds: bounds)
        arc.vertical = true
        arc.hDistort = 10
        var c = Warp.preset(.custom, bend: 0, bounds: bounds)
        c.mesh = custom
        let cases: [(Warp?, Warp?)] = [(arc, arc), (c, c), (multi, nil), (nil, nil)]
        for (w, back) in cases {
            var warnings: [String] = []
            let sold = SmartMap.soldBytes(nil, spec("i", "p", size: SIMD2(60, 30), warp: w), &warnings)
            #expect(Blocks.parsePlacedWarp("SoLd", sold) == back)
            #expect(warnings.count == (w != nil && back == nil ? 1 : 0))
        }
    }

    /// Export writes `Trnf` as the image of the custom warp's control-point box, the inverse of
    /// import: a spilled mesh comes back with the same transform and the quad Photoshop expects.
    @Test func warpControlBoxQuadRoundTrips() throws {
        var mesh = BezierMesh.identity(bounds: SIMD4(0, 0, 50, 25), cols: 1, rows: 1)
        mesh.points[0] = SIMD2(-10, -5)
        mesh.points[15] = SIMD2(60, 25)
        var warp = Warp.preset(.custom, bend: 0, bounds: SIMD4(0, 0, 50, 25))
        warp.mesh = mesh
        let transform = PCAffine(m: [2, 0, 0, 2, 120, 210])
        let s = spec("i", "p", transform: transform, size: SIMD2(50, 25), warp: warp)
        var w: [String] = []
        let p = try #require(SmartMap.parseSold(SmartMap.soldBytes(nil, s, &w)))
        guard case let .list(q)? = p.descriptor["Trnf"] else {
            Issue.record("no Trnf")
            return
        }
        #expect(q.compactMap { Blocks.num($0) } == [100, 200, 240, 200, 240, 260, 100, 260])
        #expect(p.transform == transform)
        // The imported quad reads as unmoved, so the template's `Trnf` is kept as stored.
        #expect(!SmartMap.quadMoved(p.descriptor, s))
    }

    @Test func hexAndUuid() {
        #expect(SmartMap.fromHex(SmartMap.toHex([0, 1, 0xAB, 0xFF])) == [0, 1, 0xAB, 0xFF])
        #expect(SmartMap.fromHex("ABff") == [0xAB, 0xFF])
        #expect(SmartMap.fromHex("abc") == nil)
        #expect(SmartMap.fromHex("zz") == nil)
        let u = SmartMap.uuidFrom(Array("x".utf8))
        #expect(u.count == 36)
        #expect(u == SmartMap.uuidFrom(Array("x".utf8)))
        #expect(u != SmartMap.uuidFrom(Array("y".utf8)))
        let parts = u.split(separator: "-").map(\.count)
        #expect(parts == [8, 4, 4, 4, 12])
        // The uuid is the first 16 bytes of the BLAKE3 hash, in hex.
        #expect(u.replacingOccurrences(of: "-", with: "") == String(BLAKE3.hex(Array("x".utf8)).prefix(32)))
    }

    // MARK: From smart_contents_identity.rs (the parts that need only this module)

    /// A placed layer with no source id parses to an empty `Idnt`, which the importer must not
    /// join to other contents (`missing_source_identifiers_do_not_join_imported_contents`).
    @Test func missingSourceIdentifierParsesEmpty() throws {
        var w: [String] = []
        let data = SmartMap.soldBytes(nil, spec("", "placement", size: SIMD2(2, 2)), &w)
        let p = try #require(SmartMap.parseSold(data))
        #expect(p.idnt.isEmpty)
        #expect(p.placed == "placement")
        #expect(Blocks.parseSmart("SoLd", data).id.isEmpty)
    }

    /// A duplicate written from the imported descriptor keeps the source id and every other key,
    /// and takes the new placement id (`duplicated_imported_layer_keeps_source_but_gets_its_own_placement`).
    @Test func templateKeepsSourceAndTakesNewPlacement() throws {
        var w: [String] = []
        let old = try #require(SmartMap.parseSold(SmartMap.soldBytes(nil, spec("src-uuid", "first", size: SIMD2(2, 2)), &w)))
        let colliding = SmartMap.uuidFrom(Array("\(old.idnt):42".utf8))
        let raw = SmartMap.soldBytes(old.descriptor, spec(old.idnt, colliding, size: SIMD2(2, 2)), &w)
        let back = try #require(SmartMap.parseSold(raw))
        #expect(back.idnt == old.idnt)
        #expect(back.placed == colliding)
        #expect(back.descriptor["Trnf"] == old.descriptor["Trnf"])
        #expect(back.descriptor.items.map(\.key) == old.descriptor.items.map(\.key))
        #expect(w.isEmpty)
    }

    // MARK: FEid filter mask (new)

    @Test func filterMaskRoundTripsThroughFEid() throws {
        let fmt = PixelFormat.rgba8
        var src = Surface(format: fmt)
        src.fill(PixelRect(x0: 2, y0: 3, x1: 10, y1: 9), with: [1, 0, 0, 1])
        var maskSurface = Surface(format: .gray8, defaultPixel: [1])
        maskSurface.fill(PixelRect(x0: 4, y0: 4, x1: 8, y1: 6), with: [0])
        let mask = LayerMask(surface: maskSurface, enabled: false, linked: true)
        let bounds = PixelRect(x0: 0, y0: 0, x1: 16, y1: 12)
        let item = try #require(SmartMap.feidItem("pl-1", src, mask, bounds, fmt))
        #expect(item.id == "pl-1")
        #expect(item.slots.count == 26)
        #expect(item.slots[0] != nil && item.slots[1] != nil && item.slots[2] != nil && item.slots[25] != nil)
        #expect(item.slots[3] == nil)
        #expect(item.rect == PSDRect(top: 0, left: 0, bottom: 12, right: 16))
        // Through the block bytes and back.
        let block = PSDFilterEffects(items: [item]).serialized()
        let parsed = try PSDFilterEffects(bytes: block)
        let stack = SmartMap.FilterStack(filters: [sf("filter.blur.gaussianBlur", ["radius": 1.0])], maskEnabled: false, maskLinked: true)
        let back = try #require(try SmartMap.maskFromItem(parsed.items[0], .u8, stack))
        #expect(back.enabled == false && back.linked == true)
        #expect(back.surface.contentBounds == PixelRect(x0: 4, y0: 4, x1: 8, y1: 6))
        #expect(back.value(x: 5, y: 5) == 1, "disabled masks read 1")
        #expect(back.surface.pixel(x: 5, y: 5) == [0])
        #expect(back.surface.pixel(x: 100, y: 100) == [1], "white beyond its bounds")
        // Transparent pixels carry white in the cache.
        let planes = try (0 ..< 3).map { try #require(parsed.items[0].slots[$0]).decode(width: 16, height: 12, depth: 8) }
        #expect(planes.map { $0[0] } == [255, 255, 255])
        #expect(planes.map { $0[3 * 16 + 2] } == [255, 0, 0])
        // A missing mask writes white (no mask); a 16-bit document refuses an 8-bit mask.
        let white = try #require(SmartMap.feidItem("pl-2", src, nil, bounds, fmt))
        #expect(try SmartMap.maskFromItem(white, .u8, stack) == nil)
        #expect(throws: PCIOError.self) { try SmartMap.maskFromItem(white, .u16, stack) }
        var noMask = white
        noMask.mask = nil
        #expect(try SmartMap.maskFromItem(noMask, .u8, stack) == nil)
        // Nothing to filter: no item.
        #expect(SmartMap.feidItem("pl-3", Surface(format: fmt), nil, bounds, fmt) == nil)
    }

    @Test func feidItemConvertsDepthAndInvertsCMYK() throws {
        var src = Surface(format: .rgba8)
        src.fill(PixelRect(x0: 0, y0: 0, x1: 4, y1: 4), with: [0.5, 0.25, 1, 1])
        let doc16 = PixelFormat.rgba16
        let item = try #require(SmartMap.feidItem("a", src, nil, PixelRect(x0: 0, y0: 0, x1: 4, y1: 4), doc16))
        #expect(item.depth == 16)
        let r = try #require(item.slots[0]).decode(width: 4, height: 4, depth: 16)
        #expect(r.count == 32)
        #expect(UInt16(r[0]) << 8 | UInt16(r[1]) == UInt16(Float(UInt8(0.5 * 255 + 0.5)) / 255 * 65535 + 0.5))
        let cmyk = PixelFormat(mode: .cmyk, sample: .u8, alpha: true)
        var c = Surface(format: cmyk)
        c.fill(PixelRect(x0: 0, y0: 0, x1: 2, y1: 2), with: [1, 0, 0, 0, 1])
        let ci = try #require(SmartMap.feidItem("c", c, nil, PixelRect(x0: 0, y0: 0, x1: 2, y1: 2), cmyk))
        let cyan = try #require(ci.slots[0]).decode(width: 2, height: 2, depth: 8)
        let alpha = try #require(ci.slots[25]).decode(width: 2, height: 2, depth: 8)
        #expect(cyan == [0, 0, 0, 0], "CMYK is stored inverted")
        #expect(alpha == [255, 255, 255, 255])
        #expect(ci.slots[4] == nil)
    }
}
