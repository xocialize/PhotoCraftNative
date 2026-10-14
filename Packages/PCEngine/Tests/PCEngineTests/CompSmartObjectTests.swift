// Compositor `.comp` layers as smart objects, end to end (AB-T-0275, bridge decision AB-D-0140):
// PCIO's import makes a layer Compositor shows scaled, turned or flipped a smart object holding its
// full-resolution image and the transform. It survives a `.pcraft` save (package and single file)
// and a PSD save, a transform back to 100 % re-renders the image exactly, and PCRender composites
// it on the GPU as on the CPU, at full resolution and at a level of detail.
// New; MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import Foundation
@testable import PCEngine
import PCDocument
import PCFoundation
import PCIO
import PCIOCore
import PCRender
import Testing

@Suite struct CompSmartObjectTests {
    /// One layer of the test package: its image and where Compositor shows it.
    struct Placed {
        var name: String
        var width: Int, height: Int
        var origin: (Double, Double)
        var size: (Double, Double)
        var rotation = 0.0
        var flipX = false, flipY = false
    }

    static let canvas = (width: 160, height: 120)
    static let layers = [
        Placed(name: "Base", width: 160, height: 120, origin: (0, 0), size: (160, 120)),
        // 25 %, across more than one tile of the source.
        Placed(name: "Scaled", width: 300, height: 220, origin: (8, 6), size: (75, 55)),
        Placed(name: "Turned", width: 40, height: 30, origin: (90, 12), size: (40, 30), rotation: 30),
        Placed(name: "Flipped", width: 32, height: 24, origin: (20.5, 60), size: (64, 48), flipX: true),
        Placed(name: "Quarter", width: 30, height: 20, origin: (110, 70), size: (30, 20), rotation: 90, flipY: true),
    ]

    /// A textured straight-alpha image: neighbouring pixels differ, the first row and column half transparent.
    static func image(_ p: Placed, _ fmt: PixelFormat, seed: Int) -> Surface {
        var s = Surface(format: fmt)
        var px: [SIMD4<Float>] = []
        px.reserveCapacity(p.width * p.height)
        for y in 0 ..< p.height {
            for x in 0 ..< p.width {
                let r = Float((x * 37 + y * 11 + seed * 5) % 251) / 250
                let g = Float((x * 13 + y * 29 + seed) % 241) / 240
                let b = Float((x * y + seed * 3) % 239) / 238
                px.append(SIMD4(r, g, b, x == 0 || y == 0 ? 0.5 : 1))
            }
        }
        s.writeRGBA(grid(p), px)
        return s
    }

    static func grid(_ p: Placed) -> PixelRect { PixelRect(x: 0, y: 0, width: p.width, height: p.height) }

    static func id(_ n: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", n) }

    /// Writes a version-13 `.comp` package of `layers` (8- or 16-bit PNGs) and returns it with each
    /// layer's image.
    static func writePackage(sixteen: Bool) throws -> (URL, [String: Surface]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("comp-smart-\(UUID().uuidString).comp")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
        let fmt: PixelFormat = sixteen ? .rgba16 : .rgba8
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData().map { [UInt8]($0 as Data) }
        var images: [String: Surface] = [:]
        var records: [[String: Any]] = []
        for (i, p) in layers.enumerated() {
            let img = image(p, fmt, seed: i)
            images[p.name] = img
            let png = try ImageIOCodec().encode(img, rect: grid(p), as: .png, quality: nil, iccProfile: srgb)
            try Data(png).write(to: dir.appendingPathComponent("images/\(id(i + 1)).png"))
            records.append(["id": id(i + 1), "name": p.name, "isVisible": true, "imageFile": "\(id(i + 1)).png",
                            "transform": ["origin": [p.origin.0, p.origin.1], "size": [p.size.0, p.size.1], "rotation": p.rotation,
                                          "flipX": p.flipX, "flipY": p.flipY, "sampling": "High quality"]])
        }
        let manifest: [String: Any] = ["format": "com.compositor.project", "version": 13, "colorSpace": "sRGB", "documentID": id(999),
                                       "width": canvas.width, "height": canvas.height, "layers": records]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: dir.appendingPathComponent("manifest.json"))
        return (dir, images)
    }

    static func layer(_ doc: Document, _ name: String) throws -> Layer {
        var found: Layer?
        doc.forEachLayer { _, _, l in if l.name == name { found = l } }
        return try #require(found, "no layer \(name)")
    }

    static func smart(_ doc: Document, _ name: String) throws -> SmartObject {
        let l = try layer(doc, name)
        guard case .smart(let sm) = l.content else { throw EngineError.other("\(name) is \(l.content.kindName), not a smart object") }
        return sm
    }

    /// The smart object's source file, embedded or (after a PSD round trip) in the document's linked-file blocks.
    static func sourceBytes(_ doc: Document, _ sm: SmartObject) throws -> [UInt8] {
        try #require(SmartCommands.embeddedSourceBytes(doc.metadata, sm.source)).1
    }

    /// Straight RGBA over `r`, alpha-zero pixels as zero (a PSD's channels keep no color under them).
    static func pixels(_ s: Surface, _ r: PixelRect) -> [SIMD4<Float>] {
        s.readRGBA(r).map { $0.w == 0 ? .zero : $0 }
    }

    static func maxLevels(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Float {
        var m: Float = 0
        for (p, q) in zip(a, b) { m = max(m, abs(p.x * p.w - q.x * q.w), abs(p.y * p.w - q.y * q.w), abs(p.z * p.w - q.z * q.w), abs(p.w - q.w)) }
        return m * 255
    }

    /// Opens the package, checks every transformed layer is a smart object whose source is its
    /// image exactly, and returns the session with the document open.
    static func open(sixteen: Bool) throws -> (Session, [String: Surface]) {
        let (dir, images) = try writePackage(sixteen: sixteen)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try DocumentIO.importFile(contentsOf: dir)
        let doc = r.document
        #expect(doc.depth == (sixteen ? .u16 : .u8))
        #expect(!r.warnings.contains { $0.contains("applied to the pixels") }, "\(r.warnings)")
        guard case .raster = try layer(doc, "Base").content else { Issue.record("Base should stay a pixel layer"); throw EngineError.other("Base") }
        for p in layers.dropFirst() {
            let sm = try smart(doc, p.name)
            let decoded = try ImageIOCodec().decode(try sourceBytes(doc, sm))
            #expect(decoded.width == p.width && decoded.height == p.height)
            #expect(pixels(decoded.surface, grid(p)) == pixels(try #require(images[p.name]), grid(p)), "\(p.name): the embedded image isn't the layer's")
            #expect(sm.cache?.contentBounds.isEmpty == false)
        }
        let s = Session()
        _ = s.addDocument(doc)
        return (s, images)
    }

    /// Every smart object of `a` holds what the same layer of `b` holds: the source file, the
    /// transform and the rendered pixels. `quad`: `b` went through a PSD, whose placed layer keeps
    /// the transform as the corners it takes the source to (`Trnf`), so a turn that isn't a quarter
    /// comes back within an ulp of each term; every other placement exactly.
    static func expectSame(_ a: Document, _ b: Document, _ what: String, quad: Bool = false) throws {
        for p in layers.dropFirst() {
            let x = try smart(a, p.name), y = try smart(b, p.name)
            #expect(try sourceBytes(a, x) == sourceBytes(b, y), "\(what) \(p.name): source")
            if quad && p.rotation.truncatingRemainder(dividingBy: 90) != 0 {
                #expect(zip(x.transform.m, y.transform.m).allSatisfy { abs($0 - $1) <= 2 * $0.ulp }, "\(what) \(p.name): transform \(x.transform) → \(y.transform)")
            } else {
                #expect(x.transform == y.transform, "\(what) \(p.name): transform \(x.transform) → \(y.transform)")
            }
            let r = a.bounds.union(try #require(x.cache).contentBounds)
            #expect(pixels(try #require(x.cache), r) == pixels(try #require(y.cache), r), "\(what) \(p.name): rendered pixels")
        }
    }

    /// Transforms every smart object back to 100 %, upright and unflipped, at whole pixel (2, 3):
    /// each then shows its image exactly.
    static func expectScalesBackLosslessly(_ s: Session, _ images: [String: Surface], _ what: String) throws {
        for p in layers.dropFirst() {
            let doc = try #require(s.active?.doc)
            let l = try layer(doc, p.name)
            let inverse = try #require(try smart(doc, p.name).transform.inverse)
            let back = inverse.then(.translate(2, 3))
            try s.execute("edit.transform", ["layer": .id(l.id), "matrix": .doubles(back.m)])
            let sm = try smart(try #require(s.active?.doc), p.name)
            #expect(sm.transform == .translate(2, 3), "\(what) \(p.name): \(sm.transform)")
            let cache = try #require(sm.cache)
            let at = PixelRect(x: 2, y: 3, width: p.width, height: p.height)
            #expect(cache.contentBounds == at, "\(what) \(p.name): \(cache.contentBounds)")
            #expect(pixels(cache, at) == pixels(try #require(images[p.name]), grid(p)), "\(what) \(p.name): not the image at 100 %")
        }
    }

    @Test(arguments: [false, true])
    func transformedLayersSurviveAPcraftSaveAndScaleBackLosslessly(sixteen: Bool) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("comp-smart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for form in ["package", "singleFile"] {
            let (s, images) = try Self.open(sixteen: sixteen)
            let imported = try #require(s.active?.doc)
            let path = dir.appendingPathComponent("\(form).pcraft").path
            try s.execute("file.saveAs", ["path": .string(path), "form": .string(form)])
            let opened = try s.execute("file.open", ["path": .string(path)])
            #expect(opened["document"] != nil)
            try Self.expectSame(imported, try #require(s.active?.doc), form)
            try Self.expectScalesBackLosslessly(s, images, form)
        }
    }

    @Test(arguments: [false, true])
    func transformedLayersSurviveAPSDSaveAsPlacedLayers(sixteen: Bool) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("comp-smart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for ext in ["psd", "psb"] {
            let (s, images) = try Self.open(sixteen: sixteen)
            let imported = try #require(s.active?.doc)
            let path = dir.appendingPathComponent("placed.\(ext)").path
            try s.execute("file.saveAs", ["path": .string(path)])
            // The file holds a placed layer per smart object, its image embedded.
            let bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
            let placed = Array("SoLd".utf8)
            #expect(bytes.indices.dropLast(4).filter { bytes[$0] == placed[0] && Array(bytes[$0 ..< $0 + 4]) == placed }.count >= Self.layers.count - 1)
            _ = try s.execute("file.open", ["path": .string(path)])
            try Self.expectSame(imported, try #require(s.active?.doc), ext, quad: true)
            try Self.expectScalesBackLosslessly(s, images, ext)
        }
    }

    /// PCRender composites the smart objects (their rendered pixels) on the GPU as on the CPU
    /// reference, within its parity bound, at full resolution and at a level of detail.
    @Test func smartObjectsCompositeOnTheGPUAsOnTheCPU() throws {
        let (s, _) = try Self.open(sixteen: false)
        let doc = try #require(s.active?.doc)
        let compositor = PCRender.DocumentCompositor(rasterizer: PlatformRasterizer(), backend: .metal)
        let cpu = try compositor.renderCPU(doc, region: doc.bounds)
        // Every smart object shows: the composite isn't just the base.
        var base = doc
        base.layers = [try Self.layer(doc, "Base")]
        #expect(Self.maxLevels(cpu.px, try compositor.renderCPU(base, region: doc.bounds).px) > 50)
        guard compositor.metal != nil else { return }
        let gpu = try compositor.render(doc, region: doc.bounds)
        #expect(Self.maxLevels(gpu.px, cpu.px) <= 2, "GPU vs CPU: \(Self.maxLevels(gpu.px, cpu.px)) levels")
        for level in [1, 2] {
            let a = try compositor.render(doc, region: doc.bounds, level: level, backend: .metal)
            let b = try compositor.render(doc, region: doc.bounds, level: level, backend: .cpu)
            #expect(a.rect == b.rect)
            #expect(Self.maxLevels(a.px, b.px) <= 2, "level \(level) GPU vs CPU: \(Self.maxLevels(a.px, b.px)) levels")
        }
    }
}
