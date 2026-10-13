// Port of photocraft-io (crates/io/src/ora/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// photocraft's tests use its own PNG codec and compositor; here the containers take an injected
// codec and compositor. Exact round trips use `ContainerTestKit.RawCodec` (lossless); the tests
// marked "ImageIO" run real PNGs through `ImageIOCodec`, whose decoder premultiplies (so pixels
// are compared with a tolerance there).

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Testing
@testable import PCIOFormats

@Suite("OpenRaster")
struct OpenRasterTests {
    typealias Kit = ContainerTestKit
    static let canvas = PixelSize(width: 70, height: 50)

    enum CodecKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case raw, imageIO
        var codec: any FlatImageCodec { self == .raw ? Kit.RawCodec() : ImageIOCodec() }
        var testDescription: String { rawValue }
    }

    static func doc(_ depth: SampleType) -> Document {
        let fmt = PixelFormat(mode: .rgb, sample: depth, alpha: true)
        var d = Document(name: "t.ora", size: canvas, mode: .rgb, depth: depth)
        var base = Kit.block("Base", fmt, 0, 0, 70, 50, 1)
        base.locks.transparency = true
        var off = Kit.block("Off canvas", fmt, -12, 30, 40, 30, 2)
        off.blend = .multiply
        off.opacity = 0.5
        var hidden = Kit.block("Hidden", fmt, 10, 10, 5, 5, 3)
        hidden.visible = false
        var inner = Kit.block("Inner screen", fmt, 20, 5, 30, 20, 4)
        inner.blend = .screen
        var group = Layer.group("Isolated", [inner, Kit.block("Inner plain", fmt, 5, 5, 8, 8, 5)])
        group.blend = .overlay
        group.opacity = 0.75
        var throughChild = Kit.block("Through child", fmt, 40, 20, 25, 25, 6)
        throughChild.blend = .linearLight
        throughChild.locks.all = true
        let through = Layer.group("Pass <&> \"through\"", [throughChild])
        d.layers = [base, off, hidden, group, through]
        return d
    }

    static func roundTrip(_ d: Document, _ codec: any FlatImageCodec = Kit.RawCodec()) throws -> (Document, [String], [String]) {
        let out = try OpenRaster.export(d, compositor: Kit.Compositor(), codec: codec)
        let back = try OpenRaster.importDocument(name: "back.ora", bytes: out.bytes, codec: codec, interrupt: .none)
        return (back.document, out.warnings, back.warnings)
    }

    /// Layer trees equal in what OpenRaster stores; pixels within `tolerance` (0 = byte-exact).
    static func assertSame(_ a: [Layer], _ b: [Layer], tolerance: Float = 0) {
        #expect(a.count == b.count)
        for (x, y) in zip(a, b) {
            #expect(x.name == y.name)
            #expect(x.visible == y.visible, "\(x.name)")
            #expect(x.blend == y.blend, "\(x.name)")
            #expect(abs(x.opacity - y.opacity) < 1e-6, "\(x.name)")
            #expect(x.locks.all == y.locks.all, "\(x.name)")
            #expect(x.locks.transparency == y.locks.transparency, "\(x.name)")
            switch (x.content, y.content) {
            case let (.raster(p), .raster(q)):
                let r = p.contentBounds
                #expect(r == q.contentBounds, "\(x.name)")
                if tolerance == 0 {
                    #expect(p.readInterleaved(r) == q.readInterleaved(r), "\(x.name)")
                } else {
                    let err = zip(p.readRegion(r), q.readRegion(r)).map { abs($0 - $1) }.max() ?? 0
                    #expect(err <= tolerance, "\(x.name): \(err)")
                }
            case let (.group(g), .group(h)):
                assertSame(g.children, h.children, tolerance: tolerance)
            default:
                Issue.record("layer kinds differ for \(x.name)")
            }
        }
    }

    @Test func layersGroupsAndPropertiesRoundTripAt8And16Bit() throws {
        for depth in [SampleType.u8, .u16] {
            let d = Self.doc(depth)
            let (back, exportWarnings, importWarnings) = try Self.roundTrip(d)
            #expect(exportWarnings.isEmpty, "\(exportWarnings)")
            #expect(importWarnings.isEmpty, "\(importWarnings)")
            #expect(back.size == d.size)
            #expect(back.depth == depth)
            Self.assertSame(d.layers, back.layers)
            #expect(Kit.flatten(d) == Kit.flatten(back))
        }
    }

    @Test("ImageIO: layers, groups and properties round-trip through real PNGs")
    func imageIORoundTrip() throws {
        for depth in [SampleType.u8, .u16] {
            let d = Self.doc(depth)
            let (back, exportWarnings, importWarnings) = try Self.roundTrip(d, ImageIOCodec())
            #expect(exportWarnings.isEmpty, "\(exportWarnings)")
            #expect(importWarnings.isEmpty, "\(importWarnings)")
            #expect(back.depth == depth)
            // Premultiplied decoding at alpha >= 1/4: at most a few levels off.
            Self.assertSame(d.layers, back.layers, tolerance: depth == .u8 ? 3 / 255 : 3 / 65535)
        }
    }

    @Test func floatDocumentsSaveAs16Bit() throws {
        var d = Self.doc(.u16)
        d.depth = .f32
        d.layers = [Kit.block("Float", .rgba32f, 0, 0, 10, 10, 9)]
        let (back, warnings, _) = try Self.roundTrip(d)
        #expect(warnings.contains { $0.contains("16-bit") }, "\(warnings)")
        #expect(back.depth == .u16)
        let (a, b) = (Kit.flatten(d), Kit.flatten(back))
        let err = zip(a, b).map { abs($0 - $1) }.max() ?? 0
        #expect(err < 1 / 65535 + 1e-6, "\(err)")
    }

    @Test func everyBlendModeIsWrittenOrReported() throws {
        for mode in BlendMode.layerModes {
            var d = Document(name: "m.ora", size: Self.canvas, mode: .rgb, depth: .u8)
            var l = Kit.block("L", .rgba8, 0, 0, 4, 4, 0)
            l.blend = mode
            d.layers.append(l)
            let (back, warnings, _) = try Self.roundTrip(d)
            let got = back.layers.first?.blend
            if OpenRaster.opName(mode) != nil {
                #expect(got == mode, "\(mode)")
                #expect(warnings.isEmpty, "\(mode): \(warnings)")
            } else {
                #expect(got == .normal, "\(mode)")
                #expect(warnings.contains { $0.contains("no OpenRaster equivalent") }, "\(mode)")
            }
        }
        // The Paint.NET-only modes: Xor has no name; Reflect, Glow and Negation go through Krita's.
        for mode in BlendMode.paintNetModes {
            var d = Document(name: "m.ora", size: Self.canvas, mode: .rgb, depth: .u8)
            var l = Kit.block("L", .rgba8, 0, 0, 4, 4, 0)
            l.blend = mode
            d.layers.append(l)
            let (back, warnings, _) = try Self.roundTrip(d)
            if let name = OpenRaster.opName(mode) {
                #expect(name.hasPrefix("krita:"))
                #expect(back.layers.first?.blend == mode, "\(mode)")
            } else {
                #expect(back.layers.first?.blend == .normal, "\(mode)")
                #expect(warnings.contains { $0.contains("no OpenRaster equivalent") }, "\(mode)")
            }
        }
    }

    @Test func masksAreAppliedToPixelsAndReported() throws {
        var d = Document(name: "m.ora", size: Self.canvas, mode: .rgb, depth: .u8)
        var l = Kit.block("Masked", .rgba8, 0, 0, 20, 20, 0)
        var mask = LayerMask.hideAll()
        mask.surface.fill(PixelRect(x: 0, y: 0, width: 10, height: 20), with: [1])
        l.mask = mask
        d.layers.append(l)
        let (back, warnings, _) = try Self.roundTrip(d)
        #expect(warnings.contains { $0.contains("layer masks were applied") }, "\(warnings)")
        let s = try #require(back.layers.first?.surface)
        #expect(s.contentBounds == PixelRect(x: 0, y: 0, width: 10, height: 20))
        #expect(Kit.flatten(d) == Kit.flatten(back))
    }

    @Test func otherLayerKindsAreRenderedOrLeftOut() throws {
        var d = Document(name: "k.ora", size: Self.canvas, mode: .rgb, depth: .u8)
        d.layers.append(Kit.block("Base", .rgba8, 0, 0, 70, 50, 0))
        d.layers.append(Layer(name: "Solid", content: .fill(.solid(.rgb(0.2, 0.4, 0.6)))))
        d.layers.append(Layer(name: "Invert", content: .adjustment(.invert)))
        let (back, warnings, _) = try Self.roundTrip(d)
        #expect(back.layers.count == 2)
        #expect(warnings.contains { $0.contains("fill layers are saved to OpenRaster as pixels") }, "\(warnings)")
        #expect(warnings.contains { $0.contains("adjustment layers cannot be saved") }, "\(warnings)")
        let solid = try #require(back.layers[1].surface)
        #expect(solid.contentBounds == back.bounds)
    }

    @Test func grayscaleSavesAsRGBAndCMYKIsRefused() throws {
        var g = Document(name: "g.ora", size: Self.canvas, mode: .grayscale, depth: .u8)
        g.layers.append(Kit.block("Gray", .graya8, 0, 0, 10, 10, 0))
        let (back, warnings, _) = try Self.roundTrip(g)
        #expect(warnings.contains { $0.contains("grayscale") }, "\(warnings)")
        #expect(back.mode == .rgb)
        // The gray values come back on all three channels.
        let s = try #require(back.layers.first?.surface)
        let p = s.pixel(x: 3, y: 4)
        #expect(p[0] == p[1] && p[1] == p[2])
        let c = Document(name: "c.ora", size: Self.canvas, mode: .cmyk, depth: .u8)
        let e = Kit.error { try OpenRaster.export(c, compositor: Kit.Compositor(), codec: Kit.RawCodec()) }
        #expect(Kit.isUnsupported(e), "\(String(describing: e))")
    }

    @Test(arguments: CodecKind.allCases)
    func archiveLayoutFollowsTheSpecification(_ kind: CodecKind) throws {
        let codec = kind.codec
        let out = try OpenRaster.export(Self.doc(.u8), compositor: Kit.Compositor(), codec: codec)
        // A stored `mimetype` first, readable at a fixed offset.
        #expect(Array(out.bytes[30 ..< 38]) == Array("mimetype".utf8))
        #expect(Array(out.bytes[38 ..< 54]) == OpenRaster.mimetype)
        #expect(OpenRaster.isORA(out.bytes))
        let zip = try ZipReader(out.bytes)
        for entry in ["stack.xml", "mergedimage.png", "Thumbnails/thumbnail.png"] {
            #expect(zip.find(entry) != nil, "\(entry)")
        }
        let thumb = try codec.decode(try zip.read(named: "Thumbnails/thumbnail.png", max: 1 << 20))
        #expect(thumb.width <= 256 && thumb.height <= 256)
        let merged = try codec.decode(try zip.read(named: "mergedimage.png", max: 1 << 20))
        #expect(merged.width == 70 && merged.height == 50)
        let xml = String(decoding: try zip.read(named: "stack.xml", max: 1 << 20), as: UTF8.self)
        #expect(xml.contains("name=\"Pass &lt;&amp;&gt; &quot;through&quot;\""), "\(xml)")
        #expect(xml.contains("isolation=\"auto\""), "\(xml)")
        #expect(xml.contains("composite-op=\"krita:linear light\""), "\(xml)")
        #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<image version=\"0.0.6\" w=\"70\" h=\"50\" xres=\"72\" yres=\"72\"><stack>"), "\(xml)")
        if kind == .imageIO {
            #expect(OpenRaster.isPNG(try zip.read(named: "data/layer0.png", max: 1 << 20)))
        }
    }

    /// An ORA archive from a hand-written stack.xml and named image entries.
    static func archive(_ stack: String, _ images: [(String, [UInt8])]) -> [UInt8] {
        Kit.archive(OpenRaster.mimetype, [("stack.xml", Array(stack.utf8))] + images)
    }

    @Test(arguments: CodecKind.allCases)
    func readsOtherApplicationsStacks(_ kind: CodecKind) throws {
        // `ImageIOCodec` reads 16-bit gray (+ alpha) PNGs from the image's own samples.
        try readOtherApplicationsStacks(kind.codec)
    }

    func readOtherApplicationsStacks(_ codec: any FlatImageCodec) throws {
        // The shapes Krita, MyPaint and GIMP write: a root stack with attributes, `auto` isolation,
        // svg:plus, krita: ids, unknown elements, fractional positions.
        let xml = """
        <?xml version='1.0' encoding='UTF-8'?>
        <image version="0.0.3" w="8" h="6" xres="150" yres="150">
         <stack opacity="1" name="root" isolation="isolate" composite-op="svg:src-over">
          <layer name="Plus" src="data/a.png" x="2.4" y="1" composite-op="svg:plus" opacity="0.5" selected="true"/>
          <stack name="Folder" isolation="auto" composite-op="krita:darker color">
           <layer name="Inside" src="data/b.png" composite-op="krita:hard mix" visibility="hidden" alpha-preserve="true"/>
          </stack>
          <stack name="Through"><layer src="data/b.png"/></stack>
          <text name="Caption">hello</text>
          <layer name="Gray16" src="data/g.png" composite-op="svg:soft-light" edit-locked="true"/>
          <layer name="Strange" src="data/a.png" composite-op="svg:dst-in"/>
          <layer name="Lost" src="data/missing.png"/>
         </stack>
        </image>
        """
        let bytes = Self.archive(xml, [("data/a.png", Kit.solidPNG(3, 2, [255, 0, 0, 255], codec: codec)),
                                       ("data/b.png", Kit.solidPNG(8, 6, [0, 0, 255, 128], codec: codec)),
                                       ("data/g.png", Kit.gray16PNG(4, 4, codec: codec))])
        // Detected by content, whatever the name says.
        #expect(OpenRaster.isORA(bytes))
        let r = try OpenRaster.importDocument(name: "no extension", bytes: bytes, codec: codec, interrupt: .none)
        let d = r.document
        #expect(d.size == PixelSize(width: 8, height: 6))
        #expect(d.depth == .u16)
        #expect(d.resolutionDpi == 150)
        #expect(d.layers.map(\.name) == ["Lost", "Strange", "Gray16", "Through", "Folder", "Plus"])
        func get(_ n: String) throws -> Layer { try #require(d.layers.first { $0.name == n }) }
        let plus = try get("Plus")
        #expect(plus.blend == .linearDodge && plus.opacity == 0.5)
        #expect(plus.surface?.contentBounds == PixelRect(x: 2, y: 1, width: 3, height: 2))
        let folder = try get("Folder")
        #expect(folder.blend == .darkerColor, "a blend mode isolates an auto group")
        let inside = try #require(folder.children?.first)
        #expect(!inside.visible && inside.locks.transparency)
        #expect(inside.blend == .hardMix)
        #expect(try get("Through").blend == .passThrough)
        let gray = try get("Gray16")
        #expect(gray.locks.all)
        #expect(gray.blend == .softLight)
        #expect(gray.surface?.format == .rgba16)
        // The gray ramp lands on all three channels at 16 bits.
        let g = try #require(gray.surface).pixel(x: 3, y: 0)
        #expect(abs(g[0] - 3000 / 65535) < 1e-6 && g[0] == g[1] && g[1] == g[2] && g[3] == 1)
        #expect(try get("Strange").blend == .normal)
        #expect(try get("Lost").surface?.contentBounds.isEmpty == true)
        let all = r.warnings.joined(separator: "\n")
        for needle in ["svg:dst-in", "<text>", "missing from the archive", "krita:hard mix", "svg:soft-light"] {
            #expect(all.contains(needle), "\(needle) not in \(all)")
        }
    }

    @Test func preservesSurroundingWhitespaceInLayerAndGroupNames() throws {
        let xml = """
        <image w="2" h="2"><stack>
              <stack name=" Folder "><layer name=" Pixel " src="a.png"/></stack>
              <layer name="  " src="a.png"/>
            </stack></image>
        """
        let bytes = Self.archive(xml, [("a.png", Kit.solidPNG(2, 2, [255, 0, 0, 255], codec: Kit.RawCodec()))])
        let result = try OpenRaster.importDocument(name: "names.ora", bytes: bytes, codec: Kit.RawCodec(), interrupt: .none)
        let layers = result.document.layers
        let folder = try #require(layers.first { $0.name == " Folder " }, "group name is preserved")
        #expect(folder.children?.first?.name == " Pixel ")
        #expect(layers.contains { $0.name == "Layer 3" }, "blank names keep the fallback")
    }

    @Test func malformedArchivesFailCleanly() throws {
        let codec = Kit.RawCodec()
        let png = Kit.solidPNG(2, 2, [1, 2, 3, 4], codec: codec)
        func ok(_ s: String) -> [UInt8] { Self.archive(s, [("a.png", png)]) }
        let cases: [(String, [UInt8])] = [
            ("not a zip", Array("definitely not a zip archive at all".utf8)),
            ("no stack", Kit.archive(OpenRaster.mimetype, [])),
            ("wrong mimetype", Kit.archive(Array("image/png".utf8), [("stack.xml", Array("<image w='1' h='1'><stack/></image>".utf8))])),
            ("bad xml", ok("<image w='2' h='2'><stack>")),
            ("wrong root", ok("<picture w='2' h='2'><stack/></picture>")),
            ("no root stack", ok("<image w='2' h='2'/>")),
            ("zero width", ok("<image w='0' h='2'><stack/></image>")),
            ("fractional width", ok("<image w='2.5' h='2'><stack/></image>")),
            ("huge canvas", ok("<image w='300000' h='300000'><stack/></image>")),
            ("bad opacity", ok("<image w='2' h='2'><stack><layer src='a.png' opacity='lots'/></stack></image>")),
            ("nan opacity", ok("<image w='2' h='2'><stack><layer src='a.png' opacity='NaN'/></stack></image>")),
            ("far offset", ok("<image w='2' h='2'><stack><layer src='a.png' x='99999999999'/></stack></image>")),
            ("not an image", Self.archive("<image w='2' h='2'><stack><layer src='a.png'/></stack></image>", [("a.png", Array("garbage".utf8))])),
            ("not utf-8", Self.archive("", [])),
            ("latin-1 stack.xml", Kit.archive(OpenRaster.mimetype, [("stack.xml", Array("<image w='2' h='2'><stack><layer name='".utf8) + [0xE9] + Array("'/></stack></image>".utf8))])),
        ]
        for (what, bytes) in cases {
            #expect(throws: (any Error).self, "\(what)") {
                try OpenRaster.importDocument(name: "x.ora", bytes: bytes, codec: codec, interrupt: .none)
            }
        }
        let deep = "<image w='2' h='2'><stack>" + String(repeating: "<stack>", count: 200) + String(repeating: "</stack>", count: 200) + "</stack></image>"
        let e = Kit.error { try OpenRaster.importDocument(name: "x.ora", bytes: ok(deep), codec: codec, interrupt: .none) }
        #expect(Kit.isUnsupported(e), "\(String(describing: e))")
        // Format errors carry the OpenRaster prefix.
        let f = Kit.error { try OpenRaster.importDocument(name: "x.ora", bytes: ok("<picture/>"), codec: codec, interrupt: .none) }
        #expect(f as? PCIOError == .format("OpenRaster", "stack.xml has no <image> root"), "\(String(describing: f))")
    }

    @Test func layerAndPixelBudgetsAreEnforced() throws {
        let many = "<image w='2' h='2'><stack>" + String(repeating: "<stack/>", count: OpenRaster.maxNodes + 1) + "</stack></image>"
        #expect(throws: (any Error).self) {
            try OpenRaster.importDocument(name: "x.ora", bytes: Self.archive(many, []), codec: Kit.RawCodec(), interrupt: .none)
        }
        // A tiny PNG claiming a vast size is refused by the decoder limits, not allocated.
        for codec in [Kit.RawCodec() as any FlatImageCodec, ImageIOCodec()] {
            var forged = Kit.solidPNG(1, 1, [0, 0, 0, 0], codec: codec)
            forged.replaceSubrange(16 ..< 24, with: [0, 0, 0x75, 0x30, 0, 0, 0x75, 0x30])
            let xml = "<image w='2' h='2'><stack><layer src='a.png'/></stack></image>"
            #expect(throws: (any Error).self) {
                try OpenRaster.importDocument(name: "x.ora", bytes: Self.archive(xml, [("a.png", forged)]), codec: codec, interrupt: .none)
            }
        }
    }

    @Test func truncatedAndCorruptedFilesNeverPanic() throws {
        let codec = Kit.RawCodec()
        let bytes = try OpenRaster.export(Self.doc(.u8), compositor: Kit.Compositor(), codec: codec).bytes
        let step = max(1, bytes.count / 300)
        for cut in stride(from: 0, to: bytes.count, by: step) {
            _ = try? OpenRaster.importDocument(name: "x.ora", bytes: Array(bytes[..<cut]), codec: codec, interrupt: .none)
        }
        var rng = Kit.XorShift(state: 0x9E37_79B9)
        for _ in 0 ..< 300 {
            var b = bytes
            for _ in 0 ..< 4 {
                let s = rng.next()
                b[Int(s) % b.count] ^= UInt8(truncatingIfNeeded: s >> 24) | 1
            }
            _ = try? OpenRaster.importDocument(name: "x.ora", bytes: b, codec: codec, interrupt: .none)
        }
    }

    @Test("ImageIO: corrupted layer PNGs fail cleanly")
    func corruptedPNGsNeverPanic() throws {
        let codec = ImageIOCodec()
        let bytes = try OpenRaster.export(Self.doc(.u8), compositor: Kit.Compositor(), codec: codec).bytes
        var rng = Kit.XorShift(state: 0x1234_5678)
        for _ in 0 ..< 60 {
            var b = bytes
            for _ in 0 ..< 4 {
                let s = rng.next()
                b[Int(s) % b.count] ^= UInt8(truncatingIfNeeded: s >> 24) | 1
            }
            _ = try? OpenRaster.importDocument(name: "x.ora", bytes: b, codec: codec, interrupt: .none)
        }
    }

    @Test func zipMimetypeReadsOnlyALeadingStoredEntry() throws {
        #expect(ZipReader.mimetype(Self.archive("<image/>", [])) == OpenRaster.mimetype)
        #expect(ZipReader.mimetype(Array("PK\u{03}\u{04}".utf8)) == nil)
        #expect(ZipReader.mimetype([]) == nil)
        var z = ZipWriter()
        try z.add("stack.xml", Array("x".utf8))
        try z.add("mimetype", OpenRaster.mimetype)
        let bytes = try z.finish()
        #expect(ZipReader.mimetype(bytes) == nil)
        #expect(!OpenRaster.isORA(bytes))
    }

    @Test func exportedFilesReopenAsEditableSources() throws {
        let out = try OpenRaster.export(Self.doc(.u8), compositor: Kit.Compositor(), codec: Kit.RawCodec())
        #expect(OpenRaster.isORA(out.bytes))
        let back = try OpenRaster.importDocument(name: "picture.ora", bytes: out.bytes, codec: Kit.RawCodec(), interrupt: .none)
        #expect(!back.sourceReadOnly)
        #expect(!back.previewOnly)
    }

    @Test func normalGroupFillOpacitySurvivesOpenRasterExport() throws {
        var d = Document(name: "group.ora", size: PixelSize(width: 8, height: 8), mode: .rgb, depth: .u8)
        let s = Surface(format: .rgba8, rect: PixelRect(x: 0, y: 0, width: 8, height: 8),
                        interleaved: Array([[UInt8]](repeating: [255, 0, 0, 255], count: 64).joined()))
        var group = Layer.group("Folder", [Layer(name: "Red", content: .raster(s))])
        group.blend = .normal
        group.opacity = 1
        group.fillOpacity = 0.5
        d.layers.append(group)
        let (back, warnings, _) = try Self.roundTrip(d)
        #expect(warnings.contains { $0.contains("fill opacity was combined") }, "\(warnings)")
        let imported = try #require(back.layers.first)
        #expect(abs(imported.opacity - 0.5) < 1e-6)
        #expect(imported.fillOpacity == 1)
        let (before, after) = (Kit.flatten(d), Kit.flatten(back))
        for i in stride(from: 3, to: before.count, by: 4) {
            #expect(abs(before[i] - after[i]) < 1 / 255 + 1e-6, "alpha \(before[i]) vs \(after[i])")
        }
    }

    @Test func groupOpacityAndFillAreCombinedWithoutAffectingRasterOpacity() throws {
        var d = Document(name: "opacity.ora", size: PixelSize(width: 8, height: 8), mode: .rgb, depth: .u8)
        var group = Layer.group("Folder", [Kit.block("Child", .rgba8, 0, 0, 8, 8, 0)])
        group.blend = .normal
        group.opacity = 0.5
        group.fillOpacity = 0.5
        d.layers.append(group)
        let (back, _, _) = try Self.roundTrip(d)
        #expect(abs(back.layers[0].opacity - 0.25) < 1e-6)
        #expect(back.layers[0].children?.first?.opacity == 1)
    }

    // MARK: - Beyond photocraft's tests: the tables and helpers

    @Test func kritaIdsRoundTripThroughTheBlendTable() {
        for mode in BlendMode.allLayerModes {
            guard let id = OpenRaster.kritaID(mode) else {
                #expect([.xor, .paintNetColorBurn, .paintNetColorDodge].contains(mode))
                continue
            }
            let back = OpenRaster.kritaBlend(id)
            #expect(back?.mode == mode, "\(mode) → \(id)")
            #expect(back?.approximate == false, "\(id)")
        }
        #expect(OpenRaster.kritaBlend("add")?.mode == .linearDodge)
        #expect(OpenRaster.kritaBlend("soft_light_svg")?.approximate == true)
        #expect(OpenRaster.kritaBlend("hard mix")?.approximate == true)
        #expect(OpenRaster.kritaBlend("xor")?.approximate == true)
        #expect(OpenRaster.kritaBlend("nope") == nil)
    }

    @Test func attributesAreEscapedAndNumbersWrittenAsRustDoes() {
        #expect(OpenRaster.escape("a&b<c>\"d'\te\nf\u{1}g\u{85}h") == "a&amp;b&lt;c&gt;&quot;d&apos;&#9;e&#10;fgh")
        #expect(OpenRaster.rustDisplay(Float(1)) == "1")
        #expect(OpenRaster.rustDisplay(Float(0.5)) == "0.5")
        #expect(OpenRaster.rustDisplay(Float(128) / 255) == "0.5019608")
        #expect(OpenRaster.rustDisplay(Float(1e-5)) == "0.00001")
        #expect(OpenRaster.rustDisplay(Float(1.5e-7)) == "0.00000015")
        #expect(OpenRaster.rustDisplay(Float(3e8)) == "300000000")
        #expect(OpenRaster.rustDisplay(Float(-0.0)) == "-0")
        #expect(OpenRaster.rustDisplay(2.5) == "2.5")
        #expect(OpenRaster.rustDisplay(300_001.0) == "300001")
    }

    @Test func interruptCancelsAnImport() throws {
        let bytes = try OpenRaster.export(Self.doc(.u8), compositor: Kit.Compositor(), codec: Kit.RawCodec()).bytes
        #expect(throws: PCIOError.cancelled) {
            try OpenRaster.importDocument(name: "x.ora", bytes: bytes, codec: Kit.RawCodec(), interrupt: .cancelOnly { true })
        }
    }
}
