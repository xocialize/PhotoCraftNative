// Port of photocraft-io (crates/io/tests/adjust_blend_roundtrip.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Every adjustment kind and every blend mode through document → PSD → document.
//
// Asserts doc-model equality where the PSD encoding is lossless, and that the re-imported
// document flattens to the same composite (within 1/255) in every case, so nothing a user made
// in PhotoCraft silently disappears or changes when Photoshop opens the file. photocraft's
// record shape and Photoshop's (the PCIO default) are both checked. The block-level half
// (write → parse of every kind) is PCIOMapsTests' AdjustBlockRoundTripTests.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCIOMaps
import PCPSD
import Testing
@testable import PCIO

@Suite struct AdjustBlendRoundtripTests {
    init() { ExportSweep.install() }
    static let tol: Float = 1.0 / 255 + 1e-5

    static func exportImport(_ doc: Document, photoshop: Bool) throws -> (Document, [String], PSDFile) {
        let o = MapsKit.options(photoshop: photoshop)
        let r = try MapsKit.export(doc, "x.psd", options: o)
        let file = try PSDFile(bytes: r.bytes)
        let back = try MapsKit.importFile(r.bytes, "x.psd", options: o).document
        return (back, r.warnings, file)
    }

    static func expectCompositeEqual(_ a: Document, _ b: Document, _ ctx: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let (x, y) = (try MapsKit.flatten(a), try MapsKit.flatten(b))
        #expect(x.rect == y.rect, "\(ctx): composite rect", sourceLocation: sourceLocation)
        let m = MapsKit.maxDiff(x.px, y.px)
        #expect(m <= tol, "\(ctx): composite differs by \(m) (> 1/255)", sourceLocation: sourceLocation)
    }

    static func q16(_ v: UInt16) -> Float { Float(v) / 65535 }

    /// photocraft-cms `LutFile::from_fn`: red fastest, values clamped.
    static func lut(_ size: Int, _ f: (SIMD3<Float>) -> SIMD3<Float>) -> [Float] {
        let m = Float(max(size, 2) - 1)
        var data: [Float] = []
        for b in 0 ..< size {
            for g in 0 ..< size {
                for r in 0 ..< size {
                    let o = f(SIMD3(Float(r) / m, Float(g) / m, Float(b) / m))
                    data += [o.x, o.y, o.z].map { min(max($0, 0), 1) }
                }
            }
        }
        return data
    }

    /// Every `Adjustment` kind with representative settings, and whether its PSD encoding is
    /// lossless (the document model comes back equal) or only renders the same.
    static func adjustments() -> [(Adjustment, Bool)] {
        func pts(_ v: [(UInt8, UInt8)]) -> [CurvePoint] { v.map { CurvePoint(input: g($0.0), output: g($0.1)) } }
        func lc(_ a: UInt8, _ b: UInt8, _ gamma: Float) -> LevelsChannel { LevelsChannel(inBlack: g(a), inWhite: g(b), gamma: gamma, outBlack: g(5), outWhite: g(250)) }
        let table = lut(5) { c in SIMD3(c.y, c.z * 0.5, 1 - c.x) }
        let all: [(Adjustment, Bool)] = [
            (.brightnessContrast(.init(brightness: 30, contrast: -20, legacy: false)), true),
            (.brightnessContrast(.init(brightness: -40, contrast: 50, legacy: true)), true),
            // Photoshop 27's modes (PCRender phase 5): an explicit Modern, and Light with its controls.
            (.brightnessContrast(.init(brightness: 25, contrast: 35, mode: .modern)), true),
            (.brightnessContrast(.init(contrast: 35, mode: .light, exposure: 0.5, whites: 10, blacks: -5, highlights: 20, shadows: -15)), true),
            (.levels(.init(master: lc(10, 240, 1.2), perChannel: [lc(0, 255, 1), lc(5, 250, 0.8), lc(20, 200, 1.5)], space: .rgb)), true),
            (.curves(.init(master: pts([(0, 0), (128, 150), (255, 255)]),
                           perChannel: [pts([(0, 10), (255, 255)]), pts([(0, 0), (255, 245)]), pts([(0, 0), (64, 32), (255, 255)])], space: .rgb)), true),
            (.exposure(.init(exposure: 0.75, offset: -0.0125, gamma: 0.9)), true),
            (.vibrance(.init(vibrance: 60, saturation: -25)), true),
            (.hueSaturation(.init(hue: 40, saturation: -30, lightness: 10, colorize: false)), true),
            (.hueSaturation(.init(hue: 200, saturation: 50, lightness: -10, colorize: true)), true),
            (.colorBalance(.init(shadows: SIMD3(20, -10, 5), midtones: SIMD3(-15, 10, 30), highlights: SIMD3(0, 5, -20), preserveLuminosity: true)), true),
            (.colorBalance(.init(shadows: SIMD3(60, 0, 0), midtones: .zero, highlights: SIMD3(0, 0, 40), preserveLuminosity: false)), true),
            (.blackWhite(.init(weights: [40, 60, 40, 60, 20, 80], tint: nil)), true),
            (.blackWhite(.init(weights: [70, 20, 50, -10, 90, 130], tint: SIMD3(0.9, 0.7, 0.5))), true),
            (.photoFilter(.init(color: SIMD3(q16(60620), q16(35455), q16(0)), density: 0.4, preserveLuminosity: true)), true),
            (.photoFilter(.init(color: SIMD3(q16(0), q16(39321), q16(65535)), density: 0.3, preserveLuminosity: false)), true),
            (.channelMixer(.init(matrix: [SIMD4(0.5, 0.3, 0.2, 0), SIMD4(0.1, 0.8, 0.1, 0.05), SIMD4(0, 0.2, 0.9, -0.05)], monochrome: false)), true),
            (.channelMixer(.init(matrix: [SIMD4(0.4, 0.4, 0.2, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0)], monochrome: true)), true),
            (.colorLookup(.init(name: "Look.cube", lut: table, size: 5, tetrahedral: false, dither: false)), true),
            // No table chosen: written as Photoshop writes it (an empty descriptor), read back the same.
            (.colorLookup(.init(name: "", lut: nil, size: 0, tetrahedral: false, dither: false)), true),
            (.invert, true),
            (.posterize(levels: 4), true),
            (.threshold(level: g(140)), true),
            (.gradientMap(.init(stops: [GradientMapStop(0, SIMD3(q16(6554), 0, q16(19661))), GradientMapStop(0.5, SIMD3(1, 0.2, 0)),
                                        GradientMapStop(1, SIMD3(1, 1, 0.8))], reverse: false, dither: false)), true),
            (.gradientMap(.init(stops: [GradientMapStop(0, SIMD3(0, 0, 1)), GradientMapStop(1, SIMD3(1, 1, 0))], reverse: true, dither: false)), true),
            // Fewer than two stops: written as the equivalent two-stop gradient.
            (.gradientMap(.init(stops: [], reverse: false, dither: false)), false),
            (.gradientMap(.init(stops: [GradientMapStop(0.4, SIMD3(0.2, 0.6, 0.4))], reverse: false, dither: false)), false),
            (.selectiveColor(.init(relative: true, adjustments: (0 ..< 9).map { SIMD4(Float($0) * 10 - 40, 5, -30, 20) })), true),
            (.selectiveColor(.init(relative: false, adjustments: (0 ..< 9).map { SIMD4(0, Float($0) * 5, 0, -10) })), true),
            // A block this version cannot read (a truncated Selective Color) is kept verbatim.
            (.unsupported(psdKey: "selc", raw: [0, 1, 0, 0]), true),
        ]
        // Exhaustiveness guard: a new Adjustment kind must be added to the list above.
        for (a, _) in all {
            switch a {
            case .brightnessContrast, .levels, .curves, .exposure, .vibrance, .hueSaturation, .colorBalance, .blackWhite, .photoFilter, .channelMixer,
                 .colorLookup, .invert, .posterize, .threshold, .gradientMap, .selectiveColor, .unsupported:
                break
            case .filter:
                // No PSD form: baked to a pixel layer with a warning (FilterAdjustmentPSDTests).
                break
            }
        }
        return all
    }

    /// The enum case of an adjustment (Rust `std::mem::discriminant`).
    static func kind(_ a: Adjustment) -> String { String("\(a)".prefix { $0 != "(" }) }

    /// A colourful base, a clipping base, and `adj` three times: plain; at half opacity with a
    /// mask and a blend mode; clipped to a pixel layer.
    static func adjustmentDoc(_ adj: Adjustment, _ depth: SampleType) -> Document {
        var d = Document(name: "adj", size: PixelSize(width: 32, height: 20), mode: .rgb, depth: depth)
        let fmt = d.pixelFormat
        d.layers.append(rasterLayer("Background", fmt, d.bounds, 1, false))
        var plain = Layer(name: "plain", content: .adjustment(adj))
        plain.opacity = 1
        d.layers.append(plain)
        var masked = Layer(name: "masked", content: .adjustment(adj))
        masked.opacity = g(128)
        masked.blend = .multiply
        masked.mask = LayerMask(surface: maskSurface(depth, rect(4, 3, 20, 15), 1, 3), enabled: true, linked: true, density: 1, feather: 0)
        d.layers.append(masked)
        d.layers.append(rasterLayer("clip base", fmt, rect(10, 2, 28, 18), 9, true))
        var clipped = Layer(name: "clipped", content: .adjustment(adj))
        clipped.clipped = true
        clipped.fillOpacity = g(200)
        d.layers.append(clipped)
        return d
    }

    static func check(_ adj: Adjustment, _ lossless: Bool, _ depth: SampleType, photoshop: Bool) throws {
        let ctx = "\(adj) @ \(depth)\(photoshop ? " (Photoshop records)" : "")"
        let d = adjustmentDoc(adj, depth)
        let (back, warnings, file) = try exportImport(d, photoshop: photoshop)
        #expect(!warnings.contains { $0.contains("adjustment") }, "\(ctx): export warned \(warnings)")
        // The adjustment layers carry an adjustment block, never an empty pixel layer.
        let withAdj = file.layers.filter { l in l.blocks.contains { AdjustMap.adjustmentKeys.contains($0.key) } }.count
        #expect(withAdj == 3, "\(ctx): adjustment blocks written")
        #expect(back.layers.count == d.layers.count, "\(ctx): layer count")
        for (x, y) in zip(d.layers, back.layers) {
            switch (x.content, y.content) {
            case let (.adjustment(a), .adjustment(b)):
                if lossless { #expect(a == b, "\(ctx): adjustment") } else { #expect(kind(a) == kind(b), "\(ctx): kind") }
                #expect(x.blend == y.blend && x.opacity == y.opacity && x.fillOpacity == y.fillOpacity && x.clipped == y.clipped, "\(ctx): \(x.name)")
                #expect((x.mask != nil) == (y.mask != nil), "\(ctx): \(x.name) mask")
            case (.raster, .raster):
                break
            default:
                Issue.record("\(ctx): \(x.content.kindName) became \(y.content.kindName)")
            }
        }
        if lossless {
            let diffs = DocDiff.of(d, back)
            #expect(diffs.isEmpty, "\(ctx): \(diffs.prefix(4))")
        }
        try expectCompositeEqual(d, back, ctx)
        // A second generation is a fixed point for the document model.
        let (again, _, _) = try exportImport(back, photoshop: photoshop)
        for (x, y) in zip(back.layers, again.layers) {
            if case let .adjustment(a) = x.content, case let .adjustment(b) = y.content { #expect(a == b, "\(ctx): second generation") }
        }
    }

    @Test(arguments: [false, true]) func everyAdjustmentKindRoundTrips8bit(_ photoshop: Bool) throws {
        for (adj, lossless) in Self.adjustments() {
            // The truncated block is kept on purpose; Photoshop refuses it, so it is not swept.
            if case .unsupported = adj { try ExportSweep.excluded { try Self.check(adj, lossless, .u8, photoshop: photoshop) }; continue }
            try Self.check(adj, lossless, .u8, photoshop: photoshop)
        }
    }

    @Test(arguments: [false, true]) func everyAdjustmentKindRoundTrips16bit(_ photoshop: Bool) throws {
        for (adj, lossless) in Self.adjustments() {
            // The truncated block is kept on purpose; Photoshop refuses it, so it is not swept.
            if case .unsupported = adj { try ExportSweep.excluded { try Self.check(adj, lossless, .u16, photoshop: photoshop) }; continue }
            try Self.check(adj, lossless, .u16, photoshop: photoshop)
        }
    }

    /// Photoshop's `clrL` has no interpolation setting, so tetrahedral comes back trilinear: the
    /// save must say so (#1347). Trilinear saves without a warning.
    @Test func colorLookupTetrahedralWarnsOnPSDSave() throws {
        let table = Self.lut(2) { c in c == SIMD3(repeating: 1) ? SIMD3(repeating: 1) : .zero }
        for tetrahedral in [true, false] {
            let adj = Adjustment.colorLookup(.init(name: "test.cube", lut: table, size: 2, tetrahedral: tetrahedral, dither: false))
            var d = Document(name: "lut", size: PixelSize(width: 8, height: 8), mode: .rgb, depth: .u8)
            let fmt = d.pixelFormat
            d.layers.append(rasterLayer("Background", fmt, d.bounds, 1, false))
            d.layers.append(Layer(name: "Look", content: .adjustment(adj)))
            let (back, warnings, _) = try Self.exportImport(d, photoshop: false)
            let warned = warnings.contains { $0.contains("\"Look\"") && $0.contains("tetrahedral") && $0.contains("trilinear") }
            #expect(warned == tetrahedral, "tetrahedral=\(tetrahedral): \(warnings)")
            guard back.layers.count > 1, case let .adjustment(.colorLookup(c)) = back.layers[1].content, c.lut != nil, c.size == 2 else {
                Issue.record("Color Lookup lost: \(back.layers.count > 1 ? back.layers[1].content.kindName : "no layer")")
                continue
            }
            #expect(!c.tetrahedral, "PSD reopens as trilinear")
        }
    }

    /// One document per blend mode: the mode on a pixel layer (with fill opacity and a mask), on
    /// a clipped layer, on a group, inside a pass-through group, and on an adjustment layer.
    static func blendDoc(_ mode: BlendMode) -> Document {
        var d = Document(name: "blend", size: PixelSize(width: 24, height: 16), mode: .rgb, depth: .u8)
        let fmt = d.pixelFormat
        d.layers.append(rasterLayer("Background", fmt, d.bounds, 1, false))
        var l = rasterLayer("layer", fmt, rect(2, 1, 20, 12), 2, true)
        l.blend = mode
        l.fillOpacity = g(150)
        l.opacity = g(220)
        l.mask = LayerMask(surface: maskSurface(.u8, rect(3, 2, 15, 10), 1, 4), enabled: true, linked: true, density: 1, feather: 0)
        d.layers.append(l)
        var clipped = rasterLayer("clipped", fmt, rect(0, 0, 12, 16), 3, true)
        clipped.clipped = true
        clipped.blend = mode
        d.layers.append(clipped)
        var inner = rasterLayer("in pass-through", fmt, rect(8, 4, 24, 16), 4, true)
        inner.blend = mode
        d.layers.append(Layer.group("pass-through", [inner]))
        var grp = Layer.group("group", [rasterLayer("group child", fmt, rect(4, 6, 18, 14), 5, true)])
        grp.blend = mode
        grp.opacity = g(200)
        d.layers.append(grp)
        var adj = Layer(name: "adjustment", content: .adjustment(.invert))
        adj.blend = mode
        adj.opacity = g(100)
        d.layers.append(adj)
        return d
    }

    @Test(arguments: [false, true]) func everyBlendModeRoundTrips(_ photoshop: Bool) throws {
        for mode in BlendMode.layerModes + [.passThrough] {
            if mode == .passThrough {
                // Pass-through is a group-only mode; blendDoc's "pass-through" group covers it,
                // and a pass-through group with an adjustment inside checks it affects the backdrop.
                var d = Self.blendDoc(.normal)
                let fmt = d.pixelFormat
                let adj = Layer(name: "inside", content: .adjustment(.invert))
                d.layers.append(Layer.group("pass-through adj", [rasterLayer("px", fmt, rect(0, 0, 6, 6), 6, true), adj]))
                let (back, _, file) = try Self.exportImport(d, photoshop: photoshop)
                // The pass key lives in the group's section divider; with Photoshop's record
                // conventions the record itself says Normal, as Photoshop's groups do.
                #expect(file.layers.contains { $0.sectionDivider?.blendMode == .passThrough || $0.blendMode == .passThrough }, "pass key written")
                let diffs = DocDiff.of(d, back)
                #expect(diffs.isEmpty, "pass-through: \(diffs.prefix(4))")
                try Self.expectCompositeEqual(d, back, "pass-through")
                continue
            }
            let d = Self.blendDoc(mode)
            let (back, _, _) = try Self.exportImport(d, photoshop: photoshop)
            let diffs = DocDiff.of(d, back)
            #expect(diffs.isEmpty, "\(mode.label): \(diffs.prefix(4))")
            try Self.expectCompositeEqual(d, back, mode.label)
        }
    }
}
