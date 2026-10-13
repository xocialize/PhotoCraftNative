// Port of photocraft-io (crates/io/tests/psd_structure.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// PSD (testgen / builder) → Document → PSD structural equality. The re-saves run with photocraft's
// record shape and with Photoshop's (the default); both must keep the structure.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import Testing
@testable import PCIO

@Suite struct PSDStructureTests {
    init() { ExportSweep.install() }
    struct Key: Hashable {
        var layer: Int
        var id: Int16
    }

    /// Sample of a layer channel in document coordinates (0 outside the rect).
    static func sample(_ f: PSDFile, _ li: Int, _ id: Int16, _ x: Int32, _ y: Int32, _ cache: inout [Key: [UInt8]]) -> [UInt8] {
        let rec = f.layers[li]
        let r = rec.channelRect(id)
        let bps = Int(f.header.depth / 8)
        if x < r.left || x >= r.right || y < r.top || y >= r.bottom || rec.channel(id) == nil {
            let def: UInt8 = id == -2 ? (rec.layerMask?.defaultColor ?? 0) : 0
            return def == 0 || bps != 1 ? [UInt8](repeating: 0, count: bps) : [def]
        }
        let key = Key(layer: li, id: id)
        let plane: [UInt8]
        if let p = cache[key] {
            plane = p
        } else {
            plane = (try? rec.decodeChannel(id, depth: f.header.depth, version: f.header.version)) ?? []
            cache[key] = plane
        }
        let w = Int(r.right - r.left)
        let i = (Int(y - r.top) * w + Int(x - r.left)) * bps
        return i >= 0 && i + bps <= plane.count ? Array(plane[i ..< i + bps]) : [UInt8](repeating: 0, count: bps)
    }

    static func shape(_ f: PSDFile, _ nodes: [PSDLayerNode]) -> String {
        nodes.map { n in
            let r = f.layers[n.index]
            let kids = n.isGroup ? "[\(shape(f, n.children))]" : ""
            return "\(r.displayName)\(r.sectionType == .closedFolder ? "(c)" : "")\(kids)"
        }.joined(separator: ",")
    }

    static func leaves(_ nodes: [PSDLayerNode], _ out: inout [Int]) {
        for n in nodes {
            out.append(n.index)
            leaves(n.children, &out)
        }
    }

    /// photocraft `assert_structurally_equal`: the differences between `a` and `b` (empty: equal).
    static func structuralDifferences(_ a: PSDFile, _ b: PSDFile) -> [String] {
        var problems: [String] = []
        func check(_ ok: Bool, _ what: @autoclosure () -> String) { if !ok { problems.append(what()) } }
        check(a.header.width == b.header.width, "width")
        check(a.header.height == b.header.height, "height")
        check(a.header.depth == b.header.depth, "depth")
        check(a.header.colorMode == b.header.colorMode, "colour mode")
        let (ta, tb) = (a.layerTree(), b.layerTree())
        check(shape(a, ta) == shape(b, tb), "tree shape: \(shape(a, ta)) vs \(shape(b, tb))")
        var (la, lb) = ([Int](), [Int]())
        leaves(ta, &la)
        leaves(tb, &lb)
        let cc = Int16(PSDKit.modeChannels(a.header.colorMode))
        var (ca, cb) = ([Key: [UInt8]](), [Key: [UInt8]]())
        for (ia, ib) in zip(la, lb) {
            let (ra, rb) = (a.layers[ia], b.layers[ib])
            let n = ra.displayName
            check(n == rb.displayName, "name \(n) vs \(rb.displayName)")
            var blend = ra.blendMode
            if case .unknown = blend { blend = .normal }
            if ra.sectionType.isFolder {
                check(ra.sectionDivider?.blendMode == rb.sectionDivider?.blendMode, "\(n): group blend")
            } else {
                check(blend == rb.blendMode, "\(n): blend \(blend) vs \(rb.blendMode)")
            }
            check(ra.opacity == rb.opacity, "\(n): opacity")
            check(ra.fillOpacity == rb.fillOpacity, "\(n): fill")
            check(ra.isVisible == rb.isVisible, "\(n): visible")
            check(ra.clipping == rb.clipping, "\(n): clipping")
            check(ra.block("lfx2")?.data == rb.block("lfx2")?.data, "\(n): lfx2")
            if ra.sectionType.isFolder { continue }
            // Pixels: every channel over the union of both rects.
            var ids = (Int16(-1) ..< cc).map { $0 }
            if ra.layerMask != nil && (ra.channel(-2) != nil || ra.channel(-3) != nil) { ids.append(-2) }
            for id in ids {
                // The exporter writes the real mask (-3) as the user mask (-2).
                let src: Int16 = id == -2 && ra.channel(-3) != nil && ra.layerMask?.real != nil ? -3 : id
                let (r, s) = (ra.channelRect(src), rb.channelRect(id))
                let (x0, y0, x1, y1) = (min(r.left, s.left), min(r.top, s.top), max(r.right, s.right), max(r.bottom, s.bottom))
                var y = y0
                outer: while y < y1 {
                    var x = x0
                    while x < x1 {
                        let pa = sample(a, ia, src, x, y, &ca)
                        let pb = sample(b, ib, id, x, y, &cb)
                        if pa != pb {
                            problems.append("\(n): channel \(id) at (\(x),\(y)): \(pa) vs \(pb)")
                            break outer
                        }
                        x += 1
                    }
                    y += 1
                }
            }
        }
        return problems
    }

    static let testgenCases: [(name: String, version: PSDVersion, mode: PSDColorMode, depth: UInt16, compression: PSDCompression)] = [
        ("rgb8_rle", .psd, .rgb, 8, .rle),
        ("rgb8_raw", .psd, .rgb, 8, .raw),
        ("rgb16_zip", .psd, .rgb, 16, .zip),
        ("rgb32_zipp", .psd, .rgb, 32, .zipPrediction),
        ("gray8_zipp", .psd, .grayscale, 8, .zipPrediction),
        ("gray16_rle", .psd, .grayscale, 16, .rle),
        ("gray32_raw", .psd, .grayscale, 32, .raw),
        ("cmyk8_rle", .psd, .cmyk, 8, .rle),
        ("cmyk16_zip", .psd, .cmyk, 16, .zip),
        ("lab8_rle", .psd, .lab, 8, .rle),
        ("psb_rgb8_rle", .psb, .rgb, 8, .rle),
        ("psb_cmyk16_zipp", .psb, .cmyk, 16, .zipPrediction),
    ]

    /// photocraft's `tg!` cases.
    @Test(arguments: testgenCases.indices, PSDKit.conventions) func testgenStructureSurvives(_ i: Int, _ photoshop: Bool) throws {
        let c = PSDStructureTests.testgenCases[i]
        let f = try PSDKit.layered(c.version, c.mode, c.depth, c.compression)
        let g = try PSDKit.viaDoc(f, photoshop: photoshop)
        let d = PSDStructureTests.structuralDifferences(f, g)
        #expect(d.isEmpty, "\(c.name) photoshop=\(photoshop): \(d.prefix(6))")
    }

    @Test(arguments: PSDKit.conventions) func testgenSmallAllCompressions(_ photoshop: Bool) throws {
        for v in PSDVersion.allCases {
            for c in PSDCompression.all {
                let f = try PSDKit.small(v, c)
                let d = PSDStructureTests.structuralDifferences(f, try PSDKit.viaDoc(f, photoshop: photoshop))
                #expect(d.isEmpty, "\(v) \(c): \(d.prefix(6))")
            }
        }
    }

    @Test func testgenImportDetails() throws {
        let f = try PSDKit.layered(.psd, .rgb, 8, .rle, invalidBlendModes: true)
        let (d, warnings) = try PSDKit.psdToDocument(f)
        // Unknown blend mode warned about.
        #expect(warnings.contains { $0.contains("unknown blend mode") }, "\(warnings)")
        // Groups: Outer (open) containing Inner (closed).
        let outer = try #require(d.layers.first { $0.name == "Outer" })
        let g = try #require(outer.group)
        #expect(g.expanded)
        #expect(outer.blend == .passThrough)
        let inner = try #require(g.children.first { $0.name == "Inner" })
        #expect(inner.group?.expanded == false)
        // Negative offsets preserved.
        let neg = try #require(d.layers.first { $0.name.hasPrefix("Neg offset") })
        let b = try #require(neg.surface).contentBounds
        #expect(b.x0 < 0 && b.y0 < 0)
        #expect(neg.mask != nil)
        #expect(d.iccProfile != nil)
        #expect(abs(d.resolutionDpi - 72) < 1e-3)
        #expect(d.metadata.xmp != nil)
        // Named saved-path resource (2000) becomes a document path, raw bytes kept for export.
        #expect(d.paths.contains { $0.name == "Path 1" && $0.psdRaw == [1, 2, 3] }, "paths \(d.paths.map(\.name))")
        // Global blocks preserved.
        #expect(d.metadata.psdGlobalBlocks.contains { $0.key == "Patt" })
        // lfx2 kept on effects.
        #expect(d.walk().contains { $0.layer.effects.psdRaw != nil })
    }

    @Test(arguments: PSDKit.conventions) func fallbackModesImportFlattened(_ photoshop: Bool) throws {
        for mode in [PSDColorMode.indexed, .bitmap, .duotone] {
            let depth = PSDKit.modeDepths(mode)[0]
            let f = try PSDKit.mergedOnly(.psd, mode, depth, .rle, 9, 5)
            let (d, w) = try PSDKit.psdToDocument(f)
            #expect(d.layers.count == 1, "\(mode)")
            #expect(!w.isEmpty, "\(mode) should warn")
            #expect(d.depth == .u8)
            // Re-export produces a valid PSD.
            let out = try PSDKit.export(d, "x.psd", PSDKit.options(photoshop))
            #expect(throws: Never.self) { try PSDFile(bytes: out.bytes) }
        }
    }

    @Test(arguments: PSDKit.conventions) func multichannelImportsInkChannels(_ photoshop: Bool) throws {
        for depth in PSDKit.modeDepths(.multichannel) {
            let f = try PSDKit.mergedOnly(.psd, .multichannel, depth, .rle, 9, 5)
            let (d, _) = try PSDKit.psdToDocument(f)
            #expect(d.mode == .multichannel)
            #expect(d.layers.isEmpty)
            #expect(d.channels.count == Int(f.header.channels))
            #expect(d.channels.allSatisfy { $0.spot != nil })
            // Stored dark = ink: the channel value is 1 − the stored sample.
            let merged = try f.decodeMerged()
            let first = depth == 8 ? Float(merged[0]) / 255 : Float(PSDKit.be16(merged, 0)) / 65535
            let v = try #require(d.channels.first).surface.pixel(x: 0, y: 0)[0]
            #expect(abs(v - (1 - first)) < 1e-3)
            // Re-export writes the same planes.
            let out = try PSDKit.export(d, "x.psd", PSDKit.options(photoshop))
            let back = try PSDFile(bytes: out.bytes)
            #expect(back.header.colorMode == .multichannel)
            #expect(try back.decodeMerged() == merged, "\(depth)")
        }
    }

    @Test func indexedColorsMatchPalette() throws {
        let f = try PSDKit.mergedOnly(.psd, .indexed, 8, .raw, 4, 2)
        let (d, _) = try PSDKit.psdToDocument(f)
        let s = try #require(d.layers.first?.surface)
        let rgba = try f.compositeRGBA8()
        for y in 0 ..< 2 {
            for x in 0 ..< 4 {
                let p = s.pixel(x: Int32(x), y: Int32(y))
                let i = (y * 4 + x) * 4
                for c in 0 ..< 3 { #expect(UInt8((p[c] * 255).rounded()) == rgba.data[i + c], "(\(x),\(y)) \(c)") }
            }
        }
    }

    @Test func flattenedPSDBecomesBackground() throws {
        let f = try PSDKit.mergedOnly(.psd, .rgb, 16, .zipPrediction, 7, 3)
        let (d, _) = try PSDKit.psdToDocument(f)
        #expect(d.layers.count == 1)
        #expect(d.layers.first?.name == "Background")
        #expect(d.depth == .u16)
        let s = try #require(d.layers.first?.surface)
        let merged = try f.decodeMerged()
        #expect(UInt16((s.pixel(x: 0, y: 0)[0] * 65535).rounded()) == PSDKit.be16(merged, 0))
    }

    @Test func builderPSDImports() throws {
        var b = PSDKit.builder(4, 4)
        var s = PSDLayerSpec(name: "a", left: 0, top: 0, width: 2, height: 2, pixels: .u8([255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 9, 9, 9, 9]))
        s.mask = PSDMaskSpec(rect: PSDRect(x: 0, y: 0, width: 1, height: 1), data: [100], defaultColor: 255, disabled: true)
        s.fillOpacity = 77
        b.pushLayer(s)
        var gs = PSDGroupSpec(name: "G")
        gs.open = false
        b.beginGroup(gs)
        b.pushLayer(PSDLayerSpec(name: "b", left: 1, top: 1, width: 1, height: 1, pixels: .u8([1, 2, 3, 4])))
        try b.endGroup()
        let bytes = [UInt8](try b.serialized())
        let d = try PSDKit.importFile("b.psd", bytes).document
        #expect(d.layers.count == 2)
        let a = try #require(d.layers.first)
        #expect(a.fillOpacity == Float(77) / 255)
        let m = try #require(a.mask)
        #expect(!m.enabled)
        #expect(m.surface.pixel(x: 0, y: 0) == [Float(100) / 255])
        #expect(m.surface.pixel(x: 3, y: 3) == [1])
        let px: [Float] = [0, 1, 0, 128 / 255]
        #expect(try #require(a.surface).pixel(x: 1, y: 0) == px)
        let g = try #require(d.layers.last?.group)
        #expect(!g.expanded && g.children.count == 1)
    }

    /// A file of `levels` nested groups around one layer (photocraft's builder).
    static func nested(_ levels: Int) throws -> [UInt8] {
        var b = PSDKit.builder(4, 4)
        for _ in 0 ..< levels { b.beginGroup(PSDGroupSpec(name: "g")) }
        b.pushLayer(PSDLayerSpec(name: "deep", left: 0, top: 0, width: 1, height: 1, pixels: .u8([1, 2, 3, 4])))
        for _ in 0 ..< levels { try b.endGroup() }
        return [UInt8](try b.serialized())
    }

    /// The import of a tree 100 groups deep recurses ~5.6 KB per level in `Importer.build`
    /// (release); it overflows a 512 KB Swift-concurrency stack, so these imports run on an 8 MB
    /// thread (photocraft's Rust test threads have 2 MiB). The overflow itself is pinned by
    /// `importAtTheGroupCapFitsA512KBStack`.
    static let deepStack = 8 << 20

    @Test func groupNestingPastTheCapIsRejected() throws {
        let bytes = try PSDStructureTests.nested(101)
        do {
            _ = try PSDKit.importFile("deep.psd", bytes)
            Issue.record("a file nested deeper than the cap must not open")
        } catch {
            #expect("\(error)".contains("nested deeper than 100"), "\(error)")
        }
        // The never-fail converter still returns a document — capped, with a warning about the
        // part that was not imported.
        let file = try PSDFile(bytes: bytes)
        let (depth, warnings) = try PSDKit.onThread(stackSize: PSDStructureTests.deepStack) {
            let (d, w) = try PSDKit.psdToDocument(file)
            return (d.maxGroupDepth, w)
        }
        #expect(depth == 100)
        #expect(warnings.contains { $0.contains("deeper than 100") }, "\(warnings)")
    }

    @Test func groupNestingAtTheCapImports() throws {
        let bytes = try PSDStructureTests.nested(100)
        let (depth, warnings) = try PSDKit.onThread(stackSize: PSDStructureTests.deepStack) {
            let r = try PSDKit.importFile("hundred.psd", bytes)
            return (r.document.maxGroupDepth, r.warnings)
        }
        #expect(depth == 100)
        #expect(!warnings.contains { $0.contains("deeper") }, "\(warnings)")
    }

    /// A file at the nesting cap opens on a 512 KB thread (every Swift-concurrency thread and
    /// secondary `Thread`): the layer tree is built iteratively. Run in a child process so a
    /// regression (stack overflow) fails the test instead of the run.
    @Test func importAtTheGroupCapFitsA512KBStack() async {
        await #expect(processExitsWith: .success) {
            let bytes = try PSDStructureTests.nested(100)
            let depth = try PSDKit.onThread(stackSize: 512 << 10) { try PSDKit.importFile("hundred.psd", bytes).document.maxGroupDepth }
            if depth != 100 { exit(1) }
        }
    }

    @Test func layeredImportSkipsTheUnusedMergedComposite() throws {
        // A layered file whose merged composite carries nothing behind the colour channels never
        // decodes it. Here its data is garbage: the layered import does not touch it, while a file
        // with an extra channel does decode (and warn), which makes the skip observable.
        var b = PSDKit.builder(4, 4)
        b.pushLayer(PSDLayerSpec(name: "a", left: 0, top: 0, width: 2, height: 2, pixels: .u8([UInt8](repeating: 7, count: 16))))
        b.setComposite(.u8([UInt8](repeating: 128, count: 64)))
        var f = try PSDFile(bytes: [UInt8](try b.serialized()))
        f.imageData.data = Data()
        f.layerInfo?.mergedAlpha = true
        let (d, warnings) = try PSDKit.psdToDocument(f)
        #expect(d.layers.count == 1)
        #expect(!warnings.contains { $0.contains("merged image") }, "an unused composite is not decoded: \(warnings)")
        // A real extra channel behind the colour ones is part of the composite: it is decoded,
        // and the garbage above surfaces as a warning.
        f.layerInfo?.mergedAlpha = false
        let (_, w2) = try PSDKit.psdToDocument(f)
        #expect(w2.contains { $0.contains("merged image") }, "\(w2)")
    }

    @Test func locksAndLabelsFromPSD() throws {
        var f = try PSDKit.small(.psd, .raw)
        f.layers[0].blocks.append(.protection(0b101))
        f.layers[0].blocks.append(.sheetColor(3))
        let (d, _) = try PSDKit.psdToDocument(f)
        let l = d.layers[0]
        #expect(l.locks.transparency && l.locks.position && !l.locks.pixels)
        #expect(l.label == .yellow)
    }

    /// Reference files write a Background's locks as lspf = 0x0D (transparency + position + the
    /// bit-3 lock). photocraft read the artboard lock at bit 4, so 0x0D came back as 0x05.
    @Test(arguments: PSDKit.conventions) func artboardLockRoundTripsByteForByte(_ photoshop: Bool) throws {
        var f = try PSDKit.small(.psd, .raw)
        f.layers[0].blocks.append(.protection(0x0D))
        let g = try PSDKit.viaDoc(f, photoshop: photoshop)
        let lspf = try #require(g.layers.lazy.compactMap { $0.block("lspf") }.first, "exported layer should carry an lspf block")
        #expect([UInt8](lspf.data) == [0, 0, 0, 0x0D])
    }

    static var solidRedSoCo: [UInt8] {
        let c = PSDDescriptor(classID: "RGBC").with("Rd  ", .double(255)).with("Grn ", .double(0)).with("Bl  ", .double(0))
        return [UInt8](PSDVersionedDescriptor(PSDDescriptor(classID: "null").with("Clr ", .descriptor(c))).serialized())
    }

    @Test func adjustmentAndFillLayersFromPSD() throws {
        var f = try PSDKit.small(.psd, .raw)
        func mk(_ name: String, _ key: FourCC, _ data: [UInt8]) -> PSDLayerRecord {
            PSDLayerRecord(name: Array(name.utf8), blocks: [.unicodeName(name), PSDTaggedBlock(key: key, bytes: data)])
        }
        f.layers.append(mk("inv", "nvrt", []))
        f.layers.append(mk("post", "post", [0, 4, 0, 0]))
        f.layers.append(mk("sel", "selc", [1, 2, 3]))
        f.layers.append(mk("red", "SoCo", PSDStructureTests.solidRedSoCo))
        let (d, _) = try PSDKit.psdToDocument(f)
        let n = d.layers.count
        if case .adjustment(.invert) = d.layers[n - 4].content {} else { Issue.record("inv: \(d.layers[n - 4].content.kindName)") }
        if case let .adjustment(.posterize(levels)) = d.layers[n - 3].content { #expect(levels == 4) } else { Issue.record("post") }
        if case let .adjustment(.unsupported(psdKey, raw)) = d.layers[n - 2].content {
            #expect(psdKey == "selc" && raw == [1, 2, 3])
        } else {
            Issue.record("sel: \(d.layers[n - 2].content)")
        }
        if case let .fill(.solid(c)) = d.layers[n - 1].content { #expect(c.c[0] == 1) } else { Issue.record("red") }
    }

    @Test func unmodelledBlocksArePreserved() throws {
        var f = try PSDKit.small(.psd, .raw)
        f.layers[0].blocks.append(PSDTaggedBlock(key: "vmsk", bytes: [UInt8](repeating: 0, count: 8)))
        let (d, _) = try PSDKit.psdToDocument(f)
        #expect(d.layers[0].psdBlocks.contains { $0.key == "vmsk" })
        #expect(!d.layers[0].psdBlocks.contains { $0.key == "luni" || $0.key == "lyid" })
        #expect(d.layers[0].psdId == f.layers[0].layerID)
    }

    @Test func fillLayerKeepsPhotoshopPixels() throws {
        var f = try PSDKit.small(.psd, .raw)
        // Photoshop-rendered pixels deliberately differ from the parametric fill.
        var chans = [UInt8(255), 10, 20, 30].map { PSDChannel(id: 0, compression: .raw, data: Data(repeating: $0, count: 4)) }
        for i in chans.indices { chans[i].id = Int16(i) - 1 }
        f.layers.append(PSDLayerRecord(rect: PSDRect(x: 0, y: 0, width: 2, height: 2), channels: chans, name: Array("fill".utf8),
                                       blocks: [.unicodeName("fill"), PSDTaggedBlock(key: "SoCo", bytes: PSDStructureTests.solidRedSoCo)]))
        let (d, _) = try PSDKit.psdToDocument(f)
        let l = try #require(d.layers.last)
        guard case .fill = l.content else { Issue.record("not a fill: \(l.content.kindName)"); return }
        let fc = try #require(l.fillCache, "cache")
        let want: [Float] = [10 / 255, 20 / 255, 30 / 255, 1]
        #expect(fc.surface.pixel(x: 1, y: 1) == want)
        // The compositor uses the cache while the fill is unchanged.
        let w = d.size.width
        let p = try PSDKit.flatten(d)[1 * w + 1]
        #expect(abs(p.x - Float(10) / 255) < 1e-3, "\(p)")
        // Editing the fill invalidates the cache.
        var d2 = d
        d2.updateLayer(at: [d2.layers.count - 1]) { $0.content = .fill(.solid(.rgb(0, 0, 1))) }
        let q = try PSDKit.flatten(d2)[1 * w + 1]
        #expect(q.z > 0.99 && q.x < 0.01, "\(q)")
    }

    @Test func textAndSmartDetected() throws {
        var f = try PSDKit.small(.psd, .raw)
        for (name, key) in [("t", "TySh"), ("s", "PlLd"), ("sh", "vscg")] as [(String, FourCC)] {
            f.layers.append(PSDLayerRecord(name: Array(name.utf8), blocks: [.unicodeName(name), PSDTaggedBlock(key: key, bytes: [UInt8](repeating: 0, count: 8))]))
        }
        let (d, _) = try PSDKit.psdToDocument(f)
        let n = d.layers.count
        #expect(d.layers[n - 3].content.kindName == "Type")
        #expect(d.layers[n - 2].content.kindName == "Smart Object")
        #expect(d.layers[n - 1].content.kindName == "Shape")
    }

    @Test(arguments: PSDKit.conventions) func guidesAndAlphaNamesRoundtrip(_ photoshop: Bool) throws {
        var d = Document(name: "g", size: PixelSize(width: 8, height: 8), mode: .rgb, depth: .u8)
        d.guides.horizontal = [1, 2.5]
        d.guides.vertical = [7.03125]
        for name in ["Spot \u{e9}", "Alpha 2"] {
            d.channels.append(AlphaChannel(name: name, surface: Surface(format: .gray8)))
        }
        let f = PSDKit.documentToPSD(d, photoshop: photoshop)
        // RGB + merged transparency (the empty document is transparent) + 2 alpha channels.
        #expect(f.header.channels == 6)
        let (d2, _) = try PSDKit.psdToDocument(f)
        #expect(d2.guides == d.guides)
        #expect(d2.channels.map(\.name) == ["Spot \u{e9}", "Alpha 2"])
    }

    @Test func resolutionInCmConverted() throws {
        var f = try PSDKit.small(.psd, .raw)
        var ri = PSDResolutionInfo(dpi: 100)
        ri.hResUnit = 2
        f.resources[0] = PSDImageResource(id: 1005, data: ri.serialized())
        let (d, _) = try PSDKit.psdToDocument(f)
        #expect(abs(d.resolutionDpi - 254) < 1e-3)
    }

    @Test func staleIndexResourcesDropped() throws {
        var f = try PSDKit.small(.psd, .raw)
        let stale: [UInt16] = [1024, 1026, 1036, 1057, 1069, 1072]
        for id in stale { f.resources.append(PSDImageResource(id: id, data: Data([0, 0]))) }
        let (d, _) = try PSDKit.psdToDocument(f)
        let kept = d.metadata.psdResources.map(\.id).filter { stale.contains($0) }
        // A 1026 is kept raw only while it is Photoshop's all-zero list with one id per record.
        #expect(kept.isEmpty, "\(kept)")
    }

    @Test func mergedCompositeUnmattesPhotoshopWhite() throws {
        // A 1×1 RGB+alpha flattened file with colour matted against white:
        // straight red at alpha 0.5, matted: r = 1, g = b = 0.5.
        var f = try PSDKit.mergedOnly(.psd, .rgb, 8, .raw, 1, 1)
        f.header.channels = 4
        f.imageData = PSDImageData(compression: .raw, data: Data([255, 128, 128, 128]))
        let m = try MergedImage.composite(f)
        #expect(abs(m[0].x - 1) < 0.01 && m[0].y < 0.01 && m[0].z < 0.01, "\(m[0])")
        let p = try #require(try PSDKit.psdToDocument(f).document.layers.first?.surface).pixel(x: 0, y: 0)
        #expect(p[1] < 0.01 && abs(p[3] - Float(128) / 255) < 1e-6, "\(p)")

        // HDR and negative straight samples must survive the actual F32 PSD import boundary.
        var hdr = try PSDKit.mergedOnly(.psd, .rgb, 32, .raw, 1, 1)
        hdr.header.channels = 4
        hdr.imageData = PSDImageData(compression: .raw, data: Data(PSDSamples.bytes(f32: [1.5, 0.25, 0.5, 0.5])))
        #expect(try MergedImage.composite(hdr) == [SIMD4<Float>(2, -0.5, 0, 0.5)])
        var deep = try PSDKit.mergedOnly(.psd, .rgb, 16, .raw, 1, 1)
        deep.header.channels = 4
        deep.imageData.data = Data(PSDSamples.bytes(u16: [65535, 65535, 65535, 65500]))
        #expect(try MergedImage.composite(deep)[0].w == Float(65500) / 65535)
        let imported = try PSDKit.importFile("hdr.psd", [UInt8](try hdr.serialized())).document
        #expect(imported.depth == .f32)
        let hdrPixel: [Float] = [2, -0.5, 0, 0.5]
        #expect(try #require(imported.layers.first?.surface).pixel(x: 0, y: 0) == hdrPixel)
    }

    @Test(arguments: PSDKit.conventions) func vectorRenderedMaskNotDoubledOnShapes(_ photoshop: Bool) throws {
        var f = try PSDKit.small(.psd, .raw)
        var mask = PSDLayerMask(rect: .zero, defaultColor: 0, flags: 8)
        mask.flags = 8
        f.layers.append(PSDLayerRecord(channels: [PSDChannel(id: -2, compression: .raw, data: Data())], mask: .mask(mask), name: Array("shape".utf8),
                                       blocks: [.unicodeName("shape"), PSDTaggedBlock(key: "SoCo", bytes: []),
                                                PSDTaggedBlock(key: "vmsk", bytes: [UInt8](repeating: 0, count: 8))]))
        let (d, _) = try PSDKit.psdToDocument(f)
        let l = try #require(d.layers.last)
        #expect(l.content.kindName == "Shape")
        #expect(l.mask == nil)

        var rec = f.layers[f.layers.count - 1]
        guard case var .mask(m) = rec.mask else { Issue.record("fixture has a mask"); return }
        m.real = PSDRealMask(flags: 0, background: 255, rect: PSDRect(top: 0, left: 0, bottom: 1, right: 1))
        rec.mask = .mask(m)
        rec.channels.append(PSDChannel(id: -3, compression: .raw, data: Data([64])))
        f.layers[f.layers.count - 1] = rec
        let (imported, _) = try PSDKit.psdToDocument(f)
        #expect(imported.layers.last?.content.kindName == "Shape")
        let im = try #require(imported.layers.last?.mask, "selected real mask must survive synthetic cleanup")
        #expect(abs(im.surface.pixel(x: 0, y: 0)[0] - Float(64) / 255) < 1e-6)
        // The fixture's 0-byte SoCo is kept raw by the import, but Photoshop refuses a file with it
        // (PCPSD `fillLayerDataUnreadable`): the export drops it and says so. Hand-built: not part
        // of the Photoshop acceptance set.
        let exported = try ExportSweep.excluded { try PSDKit.export(imported, "real-mask.psd", PSDKit.options(photoshop)) }
        #expect(exported.warnings.contains { $0.contains("solid-colour fill data could not be read") }, "\(exported.warnings)")
        #expect(try PSDFile(bytes: exported.bytes).layers.last?.block("SoCo") == nil)
        let reopened = try PSDKit.importFile("real-mask.psd", exported.bytes).document
        #expect(try #require(reopened.layers.last?.mask).surface.pixel(x: 0, y: 0) == im.surface.pixel(x: 0, y: 0))
    }

    @Test func everyBlendModeMapsBothWays() {
        for m in [BlendMode.passThrough] + BlendMode.layerModes {
            let k = PSDBlendMode(key: FourCC(m.psdKey))
            if case .unknown = k { Issue.record("\(m)") }
            #expect(BlendMode(psdKey: k.key.string) == m)
        }
    }

    /// A record can declare a 300000×300000 rectangle in a few bytes. With no channel data to back
    /// it, import used to interleave a ~360 GB buffer and abort on the allocation (#755).
    @Test func layerBoundsWithoutChannelDataAllocateNothing() throws {
        var f = try PSDKit.small(.psd, .raw)
        f.layers.append(PSDLayerRecord(rect: PSDRect(x: 0, y: 0, width: 300_000, height: 300_000), name: Array("huge".utf8)))
        let (d, warnings) = try PSDKit.psdToDocument(f)
        let l = try #require(d.layers.last)
        if case let .raster(s) = l.content { #expect(s.tileCount == 0) } else { Issue.record("not a pixel layer") }
        #expect(warnings.contains { $0.contains("\"huge\"") }, "\(warnings)")
    }
}
