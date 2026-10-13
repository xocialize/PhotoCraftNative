// Port of photocraft-io's container tests that go through the crate entry points
// (`photocraft_io::import`/`export`, here `DocumentIO.importFile`/`export`): crates/io/src/pdn/tests.rs
// (`psd_export_reports_paint_net_blend_loss` and the dispatch cases), kra.rs `mod tests`, and
// ora/tests.rs. MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// The containers' own tests (direct `OpenRaster`/`Krita`/`PaintDotNet` calls, fuzzing) are in
// PCIOFormatsTests/Containers.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Synchronization
import Testing
@testable import PCIO
@testable import PCIOFormats

@Suite struct ContainerDispatchTests {
    init() { ExportSweep.install() }
    typealias Kit = FlatKit

    // MARK: - Paint.NET (pdn/tests.rs)

    @Test func allPDNBlendModesAndLayerPropertiesImportAndSaveNatively() throws {
        let modes = (0 ..< 14).map { Int32($0) }
        for legacy in [false, true] {
            for compressed in [false, true] {
                let bytes = Kit.pdn(modes, legacy: legacy, compressed: compressed)
                // Detection must work without an extension too.
                let imported = try Kit.importFile("sample", bytes)
                #expect(imported.sourceReadOnly)
                #expect(!imported.previewOnly)
                let doc = imported.document
                #expect(doc.layers.count == 14)
                #expect(doc.size == PixelSize(width: 2, height: 2))
                for (i, layer) in doc.layers.enumerated() {
                    #expect(layer.name == "Läyer \(i)")
                    #expect(layer.blend == PaintDotNet.modes[i])
                    #expect(layer.visible == (i != 1))
                    #expect(layer.opacity == (i == 0 ? 1 : Float(128) / 255))
                    #expect(!layer.locks.all && !layer.locks.pixels && !layer.locks.position)
                    let surface = try #require(layer.surface)
                    for (x, y, expected) in [(0, 0, [10, 20, 30, 255]), (1, 0, [40, 50, 60, 128]), (0, 1, [70, 80, 90, 64]), (1, 1, [100, 110, 120, 0])] {
                        #expect(surface.pixel(x: Int32(x), y: Int32(y)).map { Int(($0 * 255).rounded()) } == expected)
                    }
                }
                let saved = try Kit.export(doc, "sample.pcraft")
                #expect(saved.warnings.isEmpty, "\(saved.warnings)")
                let back = try Kit.importFile("sample.pcraft", saved.bytes).document
                #expect(back.layers == doc.layers)
                #expect(try Kit.flatten(doc) == Kit.flatten(back))
            }
        }
    }

    @Test func truncationUnknownModesAndCorruptChunksFailThroughTheDispatch() {
        let raw = Kit.pdn([0], legacy: false, compressed: false)
        for len in 0 ..< raw.count {
            #expect(throws: (any Error).self, "length \(len)") { try Kit.importFile("truncated.pdn", Array(raw[..<len])) }
        }
        #expect(throws: (any Error).self) { try Kit.importFile("unknown.pdn", Kit.pdn([999], legacy: false, compressed: false)) }
        var corrupt = raw
        let block = corrupt.count - 45
        // Zero chunk size.
        corrupt.replaceSubrange(block + 1 ..< block + 5, with: [0, 0, 0, 0])
        #expect(throws: (any Error).self) { try Kit.importFile("corrupt.pdn", corrupt) }
        var duplicate = raw
        // Both row chunks claim index 1.
        duplicate.replaceSubrange(block + 25 ..< block + 29, with: [0, 0, 0, 1])
        #expect(throws: (any Error).self) { try Kit.importFile("duplicate.pdn", duplicate) }
        var zipped = Kit.pdn([0], legacy: false, compressed: true)
        zipped[zipped.count - 1] ^= 1
        #expect(throws: (any Error).self) { try Kit.importFile("checksum.pdn", zipped) }
    }

    @Test func pdnImportCanBeCancelledThroughTheDispatch() {
        let bytes = Kit.pdn([0, 1], legacy: false, compressed: true)
        for limit in [0, 10] {
            let checks = Mutex(0)
            var o = Kit.options()
            o.interrupt = .cancelOnly { checks.withLock { v in defer { v += 1 }; return v } >= limit }
            #expect(throws: PCIOError.cancelled) { try Kit.importFile("cancel.pdn", bytes, options: o) }
        }
        let flag = Mutex(false)
        var o = Kit.options()
        o.interrupt = Interrupt(cancel: { flag.withLock { $0 } }, progress: { _ in flag.withLock { $0 = true } })
        #expect(throws: PCIOError.cancelled) { try Kit.importFile("cancel.pdn", bytes, options: o) }
    }

    @Test func psdExportReportsPaintNetBlendLoss() throws {
        var doc = try Kit.importFile("sample.pdn", Kit.pdn([5], legacy: false, compressed: false)).document
        doc.layers[0].effects.items.append(.colorOverlay(Effect.ColorOverlay(common: FxCommon(.glow, 1), color: .black)))
        let result = try Kit.export(doc, "sample.psd")
        #expect(result.warnings.contains { $0.contains("Reflect") && $0.contains("no PSD equivalent") }, "\(result.warnings)")
        #expect(result.warnings.contains { $0.contains("Color Overlay") && $0.contains("Glow") && $0.contains("no PSD equivalent") }, "\(result.warnings)")
        let native = try Kit.export(doc, "sample.pcraft")
        #expect(try Kit.importFile("sample.pcraft", native.bytes).document.layers == doc.layers)
    }

    @Test func malformedPDNReportsAFormatError() {
        for bytes in [[], Array("PDN3".utf8), Array("PDN3".utf8) + [0xFF, 0xFF, 0xFF], Array("PDN4".utf8) + [0, 0, 0]] {
            let e = Kit.error { try Kit.importFile("bad.pdn", bytes) }
            guard case .format("PDN", _)? = e as? PCIOError else {
                Issue.record("\(bytes): \(String(describing: e))")
                continue
            }
        }
    }

    @Test func pdnExportIsExplicitlyUnsupported() {
        let doc = Document(name: "x", size: PixelSize(width: 1, height: 1), mode: .rgb, depth: .u8)
        let e = Kit.error { try Kit.export(doc, "x.pdn") }
        guard case .unsupported? = e as? PCIOError else {
            Issue.record("\(String(describing: e))")
            return
        }
    }

    // MARK: - Krita (kra.rs)

    static func kraPNG() -> [UInt8] {
        let rect = PixelRect(x0: 0, y0: 0, x1: 2, y1: 1)
        let s = Surface(format: .rgba8, rect: rect, interleaved: [255, 0, 0, 255, 0, 0, 255, 128])
        return (try? ImageIOCodec().encode(s, rect: rect, as: .png, quality: nil, iccProfile: nil)) ?? []
    }

    @Test func importsKritaCompositeWithoutClaimingToPreserveLayers() throws {
        let bytes = Kit.archive(Krita.mimetype, [("maindoc.xml", Array("<DOC/>".utf8)), ("mergedimage.png", Self.kraPNG())])
        // The mimetype is authoritative even without a .kra extension.
        for name in ["scene.kra", "download"] {
            let r = try Kit.importFile(name, bytes)
            #expect(r.document.size == PixelSize(width: 2, height: 1))
            #expect(r.document.name == name)
            #expect(r.document.layers.count == 1)
            #expect(r.document.layers.first?.name == "Layer 0", "alpha-bearing composite")
            let pixels = try #require(r.document.layers.first?.surface)
            #expect(pixels.rgba(x: 0, y: 0).x > 0.99)
            #expect(pixels.rgba(x: 1, y: 0).z > 0.99)
            #expect(abs(pixels.rgba(x: 1, y: 0).w - 128 / 255) < 0.01)
            #expect(r.sourceReadOnly, ".kra must not be overwritten by a flat save")
            #expect(!r.previewOnly, "the flattened image is editable")
            #expect(r.warnings.contains { $0.contains("layers") && $0.contains("not imported") }, "\(r.warnings)")
        }
    }

    @Test func aPNGWithAMisleadingKraExtensionRemainsAPNG() throws {
        let r = try Kit.importFile("renamed.kra", Self.kraPNG())
        #expect(r.document.size.width == 2)
        #expect(!r.sourceReadOnly, "a real PNG must not be treated as a Krita source")
    }

    // MARK: - OpenRaster (ora/tests.rs)

    static func oraArchive(_ stack: String, _ images: [(String, [UInt8])]) -> [UInt8] {
        Kit.archive(OpenRaster.mimetype, [("stack.xml", Array(stack.utf8))] + images)
    }

    @Test func readsOtherApplicationsStacksDetectedByContent() throws {
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
        let bytes = Self.oraArchive(xml, [("data/a.png", Kit.solidPNG(3, 2, [255, 0, 0, 255])), ("data/b.png", Kit.solidPNG(8, 6, [0, 0, 255, 128])),
                                          ("data/g.png", Kit.gray16PNG(4, 4))])
        // Detected by content, whatever the name says.
        let r = try Kit.importFile("no extension", bytes)
        let d = r.document
        #expect(d.size == PixelSize(width: 8, height: 6) && d.depth == .u16)
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
        let result = try Kit.importFile("names.ora", Self.oraArchive(xml, [("a.png", Kit.solidPNG(2, 2, [255, 0, 0, 255]))]))
        let layers = result.document.layers
        let folder = try #require(layers.first { $0.name == " Folder " }, "group name is preserved")
        #expect(folder.children?.first?.name == " Pixel ")
        #expect(layers.contains { $0.name == "Layer 3" }, "blank names keep the fallback")
    }

    @Test func malformedArchivesFailCleanly() {
        let png = Kit.solidPNG(2, 2, [1, 2, 3, 4])
        func ok(_ s: String) -> [UInt8] { Self.oraArchive(s, [("a.png", png)]) }
        var noStack = ZipWriter()
        try? noStack.add("mimetype", OpenRaster.mimetype)
        var wrongMime = ZipWriter()
        try? wrongMime.add("mimetype", Array("image/png".utf8))
        try? wrongMime.add("stack.xml", Array("<image w='1' h='1'><stack/></image>".utf8))
        let cases: [(String, [UInt8])] = [
            ("not a zip", Array("definitely not a zip archive at all".utf8)),
            ("no stack", (try? noStack.finish()) ?? []),
            ("wrong mimetype", (try? wrongMime.finish()) ?? []),
            ("bad xml", ok("<image w='2' h='2'><stack>")),
            ("wrong root", ok("<picture w='2' h='2'><stack/></picture>")),
            ("no root stack", ok("<image w='2' h='2'/>")),
            ("zero width", ok("<image w='0' h='2'><stack/></image>")),
            ("fractional width", ok("<image w='2.5' h='2'><stack/></image>")),
            ("huge canvas", ok("<image w='300000' h='300000'><stack/></image>")),
            ("bad opacity", ok("<image w='2' h='2'><stack><layer src='a.png' opacity='lots'/></stack></image>")),
            ("nan opacity", ok("<image w='2' h='2'><stack><layer src='a.png' opacity='NaN'/></stack></image>")),
            ("far offset", ok("<image w='2' h='2'><stack><layer src='a.png' x='99999999999'/></stack></image>")),
            ("not an image", Self.oraArchive("<image w='2' h='2'><stack><layer src='a.png'/></stack></image>", [("a.png", Array("garbage".utf8))])),
            ("not utf-8", Self.oraArchive("", [])),
        ]
        for (what, bytes) in cases {
            #expect(throws: (any Error).self, "\(what)") { try Kit.importFile("x.ora", bytes) }
        }
        let deep = "<image w='2' h='2'><stack>" + String(repeating: "<stack>", count: 200) + String(repeating: "</stack>", count: 200) + "</stack></image>"
        let e = Kit.error { try Kit.importFile("x.ora", ok(deep)) }
        guard case .unsupported? = e as? PCIOError else {
            Issue.record("\(String(describing: e))")
            return
        }
    }

    @Test func truncatedAndCorruptedFilesNeverTrap() throws {
        let bytes = try Kit.export(Kit.oraDoc(.u8), "x.ora").bytes
        let step = max(bytes.count / 300, 1)
        for cut in stride(from: 0, to: bytes.count, by: step) { _ = try? Kit.importFile("x.ora", Array(bytes[..<cut])) }
        var state: UInt32 = 0x9E37_79B9
        for _ in 0 ..< 300 {
            var b = bytes
            for _ in 0 ..< 4 {
                state ^= state << 13
                state ^= state >> 17
                state ^= state << 5
                b[Int(state % UInt32(b.count))] ^= UInt8(truncatingIfNeeded: state >> 24) | 1
            }
            _ = try? Kit.importFile("x.ora", b)
        }
    }

    @Test func exportNamesRouteThroughTheEntryPoint() throws {
        let out = try Kit.export(Kit.oraDoc(.u8), "picture.ORA")
        #expect(OpenRaster.isORA(out.bytes))
        let back = try Kit.importFile("picture.ora", out.bytes)
        #expect(!back.sourceReadOnly)
    }
}
