// Compositor's own parity fixtures (CanvasFixtureGenerator, AB-T-0239): every `.comp` it writes
// opens, and PCRender's composite of the imported document matches the oracle PNG Compositor
// exported for it. Levels are compared premultiplied at 8 bits, with PCRender's composite rounded
// to the 8-bit straight RGBA a PNG export would hold. The blend, opacity, mask and clip sets are
// held to 2 levels; the folder, effects, adjust and motion sets are measured and reported (their
// semantics differ by design: Pass Through folders, Photoshop's layer styles and adjustments).
// New; MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import CoreImage
import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCRender
import simd
import Testing
@testable import PCIO
@testable import PCIOFormats

enum CompFixtures {
    /// `PCIO_COMP_FIXTURES`, default `<fixtures>/comp-fixtures`: the generator's output folder
    /// (`index.json`, `index-motion.json` and one folder per set).
    static var directory: URL? { Fixtures.directory("PCIO_COMP_FIXTURES", default: "comp-fixtures") }
    static var available: Bool { directory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.json").path) } ?? false }

    struct Entry: Decodable {
        var name: String
        var group: String
        var oracle: String
        var formatVersion: Int
        var features: [String]
    }

    static func entries(_ index: String) throws -> [Entry] {
        guard let d = directory else { return [] }
        let url = d.appendingPathComponent(index)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
    }

    /// The files of the main set (index.json and every file of its groups; not the motion set).
    static func mainSetFiles() -> [URL] {
        guard let d = directory, let e = FileManager.default.enumerator(at: d, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { u in
            let rel = u.path.dropFirst(d.path.count + 1)
            return (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && !rel.hasPrefix("motion/") && rel != "index-motion.json"
        }
    }
}

struct CompParity {
    var maxLevels: Float = 0
    var meanLevels: Double = 0
    var pixelsOver2 = 0

    /// `got` (PCRender's straight float RGBA) against `oracle` (an 8-bit straight PNG decoded to
    /// floats), premultiplied, in 8-bit levels; `got` is first rounded to 8 bits as an export would.
    static func measure(_ got: [SIMD4<Float>], _ oracle: [SIMD4<Float>]) -> CompParity {
        var p = CompParity()
        var sum = 0.0
        func premultiplied8(_ v: SIMD4<Float>) -> SIMD4<Float> {
            let one = SIMD4<Float>(repeating: 1)
            let q: SIMD4<Float> = (simd_clamp(v, SIMD4<Float>.zero, one) * Float(255)).rounded(.toNearestOrAwayFromZero)
            let a: Float = q.w / 255
            return SIMD4<Float>(q.x * a, q.y * a, q.z * a, q.w)
        }
        for (a, b) in zip(got, oracle) {
            let d: SIMD4<Float> = simd_abs(premultiplied8(a) - premultiplied8(b))
            let m = d.max()
            p.maxLevels = max(p.maxLevels, m)
            sum += Double(d.sum())
            if m > 2 { p.pixelsOver2 += 1 }
        }
        p.meanLevels = got.isEmpty ? 0 : sum / Double(got.count * 4)
        return p
    }
}

@Suite(.serialized) struct CompCorpusTests {
    struct Row {
        var group: String
        var name: String
        var cpu: CompParity
        var metal: CompParity?
        var warnings: [String]
    }

    /// Fixtures where Compositor's oracle engine (CoreGraphics' blend modes, or Core Image pinned to
    /// sRGB, as Compositor's `SeparableBlend` uses them) is not Photoshop's, so PCRender, which
    /// follows Photoshop, can't land within 2 levels of it. Measured by running those engines on the
    /// layers of Photoshop 27.11's own ps-corpus blend-*.psd files against Photoshop's composite
    /// (PCRender on the same files: ≤ 1 level for Hue, Saturation, Color and Luminosity).
    static let engineDeviations: [String: (levels: Float, pixels: Int, why: String)] = [
        "blend/hue": (3, 15, "CoreGraphics Hue is up to 4 levels off Photoshop (blend-hue.psd; PCRender 1.0)"),
        "blend/saturation": (9, 96, "CoreGraphics Saturation is up to 8 levels off Photoshop (blend-saturation.psd; PCRender 1.0)"),
        "blend/color": (4, 18, "CoreGraphics Color is up to 3 levels off Photoshop (blend-color.psd; PCRender 1.0)"),
        "blend/hardMix": (255, 74, "Core Image's Hard Mix gives 0 on every b + s = 255 tie; Photoshop gives 255 when s ≤ 127 (75 of 75 ties in blend-hardMix.psd)"),
        "blend/vividLight": (255, 2, "the two 0/0 ends (base 0 under blend 255, base 255 under blend 0): Core Image gives 0 and 255, PCRender 255 and 0 (photocraft's psblend expectations; no Photoshop sample of them in the corpus). Core Image's Vivid Light is up to 25 levels off Photoshop on blend-vividLight.psd"),
    ]

    /// Imports and composites every fixture of `index`, printing one `COMP` line each.
    static func run(_ index: String) throws -> (rows: [Row], failed: [String]) {
        guard let dir = CompFixtures.directory else { return ([], []) }
        let compositor = PCRender.DocumentCompositor(rasterizer: PlaceholderRasterizer())
        var rows: [Row] = [], failed: [String] = []
        for e in try CompFixtures.entries(index) {
            let url = dir.appendingPathComponent(e.group).appendingPathComponent("\(e.name).comp")
            do {
                let r = try DocumentIO.importFile(contentsOf: url)
                let doc = r.document
                let oracle = try ImageIOCodec().decode([UInt8](Data(contentsOf: dir.appendingPathComponent(e.oracle))))
                #expect(oracle.width == doc.size.width && oracle.height == doc.size.height, "\(e.group)/\(e.name): oracle size")
                let ref = oracle.surface.readRGBA(doc.bounds)
                let cpu = CompParity.measure(try compositor.renderCPU(doc, region: doc.bounds).px, ref)
                var metal: CompParity?
                if compositor.metal != nil {
                    compositor.backend = .metal
                    metal = CompParity.measure(try compositor.render(doc, region: doc.bounds).px, ref)
                    compositor.backend = .automatic
                }
                rows.append(Row(group: e.group, name: e.name, cpu: cpu, metal: metal, warnings: r.warnings))
                let m = metal.map { String(format: " | metal max %.2f mean %.3f >2: %d", $0.maxLevels, $0.meanLevels, $0.pixelsOver2) } ?? ""
                print(String(format: "COMP %@/%@ v%d: cpu max %.2f mean %.3f >2: %d%@ | %d warning(s)", e.group, e.name, e.formatVersion,
                             cpu.maxLevels, cpu.meanLevels, cpu.pixelsOver2, m, r.warnings.count))
                for w in r.warnings { print("COMP-WARN \(e.group)/\(e.name): \(w)") }
            } catch {
                failed.append("\(e.group)/\(e.name): \(error)")
                print("COMP-FAIL \(e.group)/\(e.name): \(error)")
            }
        }
        return (rows, failed)
    }

    /// One `COMP-PARITY` line per set: the largest difference on each backend, how many fixtures
    /// are within 2 levels, and the largest among them.
    static func table(_ rows: [Row]) {
        var groups: [String] = []
        for r in rows where !groups.contains(r.group) { groups.append(r.group) }
        for g in groups {
            let rs = rows.filter { $0.group == g }
            func worst(_ r: Row) -> Float { max(r.cpu.maxLevels, r.metal?.maxLevels ?? 0) }
            let within = rs.filter { worst($0) <= 2 }
            let cpu = rs.map(\.cpu.maxLevels).max() ?? 0
            let metal = rs.compactMap { $0.metal?.maxLevels }.max()
            let over = rs.filter { worst($0) > 2 }.map { String(format: "%@ %.0f", $0.name, worst($0)) }
            print(String(format: "COMP-PARITY %@: %d fixtures, cpu max %.2f, metal max %@; %d within 2 levels (max %.2f)%@", g, rs.count, cpu,
                         metal.map { String(format: "%.2f", $0) } ?? "n/a", within.count, within.map(worst).max() ?? 0,
                         over.isEmpty ? "" : "; over: " + over.joined(separator: ", ")))
        }
    }

    @Test(.enabled(if: CompFixtures.available, "Compositor fixtures not present (set PHOTOCRAFT_FIXTURES or PCIO_COMP_FIXTURES)"))
    func everyFixtureImportsAndMatchesItsOracle() throws {
        let files = CompFixtures.mainSetFiles()
        let entries = try CompFixtures.entries("index.json")
        print("COMP-SET \(entries.count) fixtures, \(files.count) files")
        let (rows, failed) = try Self.run("index.json")
        Self.table(rows)
        print("COMP-IMPORTED \(rows.count)/\(entries.count) fixtures (\(files.count) files)")
        #expect(failed.isEmpty)
        #expect(rows.count == entries.count)
        #expect(!rows.isEmpty)
        // The acceptance sets: within 2 levels on the CPU reference and on Metal, except where the
        // oracle's own engine is not Photoshop's (pinned at what it measures).
        for r in rows where ["blend", "opacity", "mask", "clip"].contains(r.group) {
            let key = "\(r.group)/\(r.name)"
            let bound = Self.engineDeviations[key]
            for (backend, p) in [("CPU", Optional(r.cpu)), ("Metal", r.metal)] {
                guard let p else { continue }
                if let bound {
                    #expect(p.maxLevels <= bound.levels && p.pixelsOver2 <= bound.pixels, "\(key): \(backend) \(p.maxLevels) levels, \(p.pixelsOver2) px over 2")
                } else {
                    #expect(p.maxLevels <= 2, "\(key): \(backend) \(p.maxLevels) levels")
                }
            }
        }
        for (k, v) in Self.engineDeviations.sorted(by: { $0.key < $1.key }) { print("COMP-ENGINE \(k): \(v.why)") }
    }

    /// The folder fixture differs from its oracle by design (a Pass Through folder's opacity and mask
    /// apply to its combined result; Compositor applies them to each layer inside). Pushed down into
    /// the layers, Compositor's way, the imported document matches, so the rest of it (nesting, the
    /// folder mask's placement, the overlay layer) is right.
    @Test(.enabled(if: CompFixtures.available, "Compositor fixtures not present (set PHOTOCRAFT_FIXTURES or PCIO_COMP_FIXTURES)"))
    func folderMatchesWithItsOpacityAndMaskPushedIntoItsLayers() throws {
        let dir = try #require(CompFixtures.directory)
        var doc = try DocumentIO.importFile(contentsOf: dir.appendingPathComponent("folder/nested.comp")).document
        func push(_ layers: inout [Layer], opacity: Float, mask: LayerMask?) {
            for i in layers.indices {
                if layers[i].isGroup {
                    let o = opacity * layers[i].opacity, m = layers[i].mask ?? mask
                    layers[i].opacity = 1
                    layers[i].mask = nil
                    layers[i].withChildren { push(&$0, opacity: o, mask: m) }
                } else {
                    layers[i].opacity *= opacity
                    if layers[i].mask == nil { layers[i].mask = mask }
                }
            }
        }
        push(&doc.layers, opacity: 1, mask: nil)
        let oracle = try ImageIOCodec().decode([UInt8](Data(contentsOf: dir.appendingPathComponent("folder/nested.oracle.png"))))
        let got = try PCRender.DocumentCompositor(rasterizer: PlaceholderRasterizer()).renderCPU(doc, region: doc.bounds).px
        let p = CompParity.measure(got, oracle.surface.readRGBA(doc.bounds))
        print(String(format: "COMP-FOLDER per-layer semantics: max %.2f, %d px over 2", p.maxLevels, p.pixelsOver2))
        #expect(p.maxLevels <= 3 && p.pixelsOver2 <= 16)
    }

    /// Compositor's oracle engines on Photoshop's own blend-*.psd layers (ps-corpus) against
    /// Photoshop's composite: the receipt behind `engineDeviations`. Measured and reported.
    @Test(.enabled(if: Corpus.psAvailable, "Photoshop corpus not present (set PHOTOCRAFT_FIXTURES or PCIO_PS_CORPUS)"))
    func oracleEnginesAgainstPhotoshop() throws {
        let dir = try #require(Corpus.psDirectory)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ci = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: space])
        let modes: [(String, CGBlendMode?, String?)] = [
            ("hue", .hue, nil), ("saturation", .saturation, nil), ("color", .color, nil), ("luminosity", .luminosity, nil),
            ("multiply", .multiply, nil), ("screen", .screen, nil), ("overlay", .overlay, nil), ("hardLight", .hardLight, nil),
            ("darken", .darken, nil), ("lighten", .lighten, nil), ("difference", .difference, nil), ("exclusion", .exclusion, nil),
            ("hardMix", nil, "CIHardMixBlendMode"), ("vividLight", nil, "CIVividLightBlendMode"), ("colorBurn", nil, "CIColorBurnBlendMode"),
            ("colorDodge", nil, "CIColorDodgeBlendMode"), ("softLight", nil, "CISoftLightBlendMode"), ("linearBurn", nil, "CILinearBurnBlendMode"),
            ("linearDodge", nil, "CILinearDodgeBlendMode"), ("linearLight", nil, "CILinearLightBlendMode"), ("pinLight", nil, "CIPinLightBlendMode"),
        ]
        /// Straight RGBA → an 8-bit premultiplied sRGB image, as Compositor holds a layer.
        func image(_ px: [SIMD4<Float>], _ w: Int, _ h: Int) throws -> CGImage {
            let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let b = try #require(ctx.data).bindMemory(to: UInt8.self, capacity: w * h * 4)
            for (i, p) in px.enumerated() {
                let a = (p.w * 255).rounded()
                b[i * 4] = UInt8((p.x * a).rounded()); b[i * 4 + 1] = UInt8((p.y * a).rounded())
                b[i * 4 + 2] = UInt8((p.z * a).rounded()); b[i * 4 + 3] = UInt8(a)
            }
            return try #require(ctx.makeImage())
        }
        var measured = 0
        for (name, cg, filter) in modes {
            guard let c = try PSDCompositeOracle.oracleCase(contentsOf: dir.appendingPathComponent("blend-\(name).psd")) else { continue }
            let doc = c.document, w = doc.size.width, h = doc.size.height
            var layers: [[SIMD4<Float>]] = []
            doc.forEachLayer { _, _, l in if let s = l.surface { layers.append(s.readRGBA(doc.bounds)) } }
            guard layers.count == 3, doc.layers[2].opacity == 1 else { continue }
            let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            ctx.draw(try image(layers[0], w, h), in: rect)
            ctx.draw(try image(layers[1], w, h), in: rect)
            if let cg {
                ctx.setBlendMode(cg)
                ctx.draw(try image(layers[2], w, h), in: rect)
            } else if let filter, let f = CIFilter(name: filter) {
                f.setValue(CIImage(cgImage: try image(layers[2], w, h)), forKey: kCIInputImageKey)
                f.setValue(CIImage(cgImage: try #require(ctx.makeImage())), forKey: kCIInputBackgroundImageKey)
                let out = try #require(f.outputImage.flatMap { ci.createCGImage($0, from: rect, format: .RGBA8, colorSpace: space) })
                ctx.setBlendMode(.copy)
                ctx.draw(out, in: rect)
            }
            let data = try #require(ctx.data).bindMemory(to: UInt8.self, capacity: w * h * 4)
            var maxD: Float = 0, off = 0
            for i in 0 ..< w * h {
                let eng = SIMD4<Float>(Float(data[i * 4]), Float(data[i * 4 + 1]), Float(data[i * 4 + 2]), Float(data[i * 4 + 3]))
                let r = c.reference.px[i]
                let ps = SIMD4<Float>(r.x * r.w * 255, r.y * r.w * 255, r.z * r.w * 255, r.w * 255)
                let d = simd_abs(eng - ps).max()
                maxD = max(maxD, d)
                if d > 2 { off += 1 }
            }
            measured += 1
            print(String(format: "COMP-ENGINE-PS %@ (%@): max %.1f levels, %d of %d px over 2", name, cg != nil ? "CoreGraphics" : "Core Image, sRGB",
                         maxD, off, w * h))
        }
        #expect(measured == modes.count)
    }

    @Test(.enabled(if: CompFixtures.available, "Compositor fixtures not present (set PHOTOCRAFT_FIXTURES or PCIO_COMP_FIXTURES)"))
    func motionFixturesImport() throws {
        let entries = try CompFixtures.entries("index-motion.json")
        let (rows, failed) = try Self.run("index-motion.json")
        Self.table(rows)
        #expect(failed.isEmpty)
        #expect(rows.count == entries.count)
        // Motion Blur has no adjustment layer here: every one of them says so.
        for r in rows { #expect(r.warnings.contains { $0.contains("Motion Blur") }) }
    }
}
