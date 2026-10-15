// Filter adjustment layers in a PSD/PSB save (AB-D-0143): Photoshop has no such layer, so each is
// baked into a pixel layer holding the filter applied to its backdrop, keeping its name, mask,
// opacity, blend mode and clipping, with a warning that it won't update. Composited with those, the
// pixels give the live layer's result, so the layers draw what PCRender draws live; the merged
// image is the live composite. `.pcraft` keeps the layers live.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCIOMaps
import PCPSD
import PCRender
import Testing
@testable import PCIO

@Suite struct FilterAdjustmentPSDTests {
    init() { ExportSweep.install() }

    static let canvas = PixelSize(width: 96, height: 64)

    /// A mask hiding everything but `r`.
    static func reveal(_ depth: SampleType, _ r: PixelRect) -> LayerMask {
        var s = Surface(format: PixelFormat(mode: .grayscale, sample: depth, alpha: false), defaultPixel: [0])
        s.writeRegion(r, [Float](repeating: 1, count: r.area))
        s.prune()
        return LayerMask(surface: s)
    }

    static func filter(_ name: String, _ f: FilterAdjustment, blend: BlendMode = .normal, opacity: Float = 1) -> Layer {
        var l = Layer(name: name, content: .adjustment(.filter(f)))
        l.blend = blend
        l.opacity = opacity
        return l
    }

    /// Every kind; a mask, opacities under 100 % and non-Normal blend modes; a clipped layer; one in a
    /// pass-through group and one in an isolated group; two stacked. Normal blurs are masked off the
    /// canvas edge, where a live blur thins the composite and a pixel layer can't (`limits`).
    static func doc(_ depth: SampleType = .u8) -> Document {
        var d = Document(name: "filter-bake", size: canvas, mode: .rgb, depth: depth)
        let fmt = d.pixelFormat
        let inner = PixelRect(x0: 10, y0: 9, x1: 86, y1: 55)
        d.layers.append(rasterLayer("Background", fmt, d.bounds, 1, false))
        var grain = filter("Grain", .grain(.init(amount: 60, size: 2, roughness: 40, seed: 3)), blend: .overlay, opacity: 0.75)
        grain.mask = LayerMask(surface: maskSurface(depth, PixelRect(x0: 4, y0: 3, x1: 60, y1: 40), 1, 3))
        d.layers.append(grain)
        d.layers.append(filter("Noise", .addNoise(.init(amount: 30, gaussian: true, seed: 9))))
        var gaussian = filter("Gaussian", .gaussianBlur(.init(radius: 2)))
        gaussian.mask = reveal(depth, inner)
        d.layers.append(Layer.group("Pass", [rasterLayer("Stripe", fmt, PixelRect(x0: 30, y0: 0, x1: 50, y1: 64), 5, false), gaussian]))
        var isolated = Layer.group("Isolated", [rasterLayer("Card", fmt, PixelRect(x0: 6, y0: 30, x1: 44, y1: 60), 7, false),
                                                filter("Motion", .motionBlur(.init(angle: 30, distance: 8)), blend: .screen)])
        isolated.blend = .normal
        isolated.opacity = 0.8
        d.layers.append(isolated)
        d.layers.append(rasterLayer("Base", fmt, PixelRect(x0: 54, y0: 18, x1: 92, y1: 60), 11, false))
        var clipped = filter("Clipped Motion", .motionBlur(.init(angle: 0, distance: 12)))
        clipped.clipped = true
        d.layers.append(clipped)
        var first = filter("Blur 1", .gaussianBlur(.init(radius: 1.5)), opacity: 0.8)
        first.mask = reveal(depth, inner)
        d.layers.append(first)
        d.layers.append(filter("Blur 2", .motionBlur(.init(angle: 90, distance: 6)), blend: .softLight))
        return d
    }

    /// Where a pixel layer can't follow the live layer: a Normal blur thins coverage at the canvas
    /// edge (past which the backdrop counts as clear) and inside the edge of the card in its
    /// isolated group, and a pixel layer only adds coverage.
    static func limits(_ depth: SampleType = .u8) -> Document {
        var d = Document(name: "filter-bake-limits", size: canvas, mode: .rgb, depth: depth)
        let fmt = d.pixelFormat
        d.layers.append(rasterLayer("Background", fmt, d.bounds, 1, false))
        d.layers.append(filter("Edge Blur", .gaussianBlur(.init(radius: 3))))
        var group = Layer.group("Glow", [rasterLayer("Card", fmt, PixelRect(x0: 30, y0: 16, x1: 66, y1: 48), 7, false),
                                         filter("Glow Blur", .gaussianBlur(.init(radius: 3)))])
        group.blend = .normal
        d.layers.append(group)
        return d
    }

    /// The filter layers of `d`, bottom to top.
    static func filterLayers(_ d: Document) -> [Layer] {
        var out: [Layer] = []
        d.forEachLayer { _, _, l in
            if case .adjustment(let a) = l.content, a.asFilter != nil { out.append(l) }
        }
        return out
    }

    /// PCRender's bake of every filter layer, bottom to top, each over the ones baked beneath it.
    static func baked(_ d: Document) throws -> Document {
        var w = d
        for l in filterLayers(d) {
            guard let s = try MapsKit.compositor.bakeFilterLayer(w, layer: l.id) else { throw PCIOError.codec("\(l.name) not baked") }
            w.updateLayer(l.id) { $0.content = .raster(s) }
        }
        return w
    }

    /// The largest difference in 8-bit levels between two composites over `rect`, premultiplied.
    static func levels(_ a: RGBABuffer, _ b: RGBABuffer, in rect: PixelRect? = nil) -> Float {
        var m: Float = 0
        for (i, (p, q)) in zip(a.px, b.px).enumerated() {
            let x = a.rect.x0 + Int32(i % a.rect.width), y = a.rect.y0 + Int32(i / a.rect.width)
            if let rect, !rect.contains(x: x, y: y) { continue }
            for c in 0 ..< 4 {
                let (u, v) = c < 3 ? (p[c] * p.w, q[c] * q.w) : (p[c], q[c])
                m = max(m, abs(u - v) * 255)
            }
        }
        return m
    }

    /// Dropped for the Photoshop oracle (`PCIO_EXPORT_DIR`) as `filter-bake-<conventions>-<bits>.psd`.
    @Test(arguments: [false, true], [SampleType.u8, .u16])
    func bakedIntoPixelLayers(_ photoshop: Bool, _ depth: SampleType) throws {
        let d = Self.doc(depth)
        let name = "filter-bake-\(photoshop ? "photoshop" : "photocraft")-\(depth.bits).psd"
        let (back, warnings, file) = try ExportSweep.$name.withValue(name) { try AdjustBlendRoundtripTests.exportImport(d, photoshop: photoshop) }
        let filters = Self.filterLayers(d)
        for l in filters {
            #expect(warnings.contains { $0.contains("\"\(l.name)\"") && $0.contains("baked to pixels") && $0.contains(".pcraft") }, "\(l.name): \(warnings)")
        }
        #expect(!warnings.contains { $0.contains("no PSD equivalent") || $0.contains("not yet written") || $0.contains("could not be baked") }, "\(warnings)")
        #expect(!file.layers.contains { l in l.blocks.contains { AdjustMap.adjustmentKeys.contains($0.key) } })
        // The tree comes back as written: the filter layers as pixel layers holding PCRender's bake,
        // with their name, blend mode, opacity, clipping and mask.
        let want = try Self.baked(d)
        var pairs: [(Layer, Layer)] = []
        func walk(_ a: [Layer], _ b: [Layer]) {
            #expect(a.count == b.count, "\(a.map(\.name)) vs \(b.map(\.name))")
            for (x, y) in zip(a, b) {
                pairs.append((x, y))
                if let xc = x.children, let yc = y.children { walk(xc, yc) }
            }
        }
        walk(want.layers, back.layers)
        for (x, y) in pairs {
            #expect(x.name == y.name && x.blend == y.blend && abs(x.opacity - y.opacity) <= 0.5 / 255 && x.clipped == y.clipped, "\(x.name)")
            #expect((x.mask != nil) == (y.mask != nil), "\(x.name) mask")
        }
        for l in filters {
            let x = try #require(want.layer(l.id)), y = try #require(pairs.first { $0.0.id == l.id }?.1)
            guard case .raster(let s) = x.content, case .raster(let t) = y.content else { Issue.record("\(y.name): \(y.content.kindName)"); continue }
            #expect(!ContentBounds.of(t).isEmpty, "\(l.name) holds no pixels")
            #expect(s.readRegion(d.bounds) == t.readRegion(d.bounds), "\(l.name): the pixels differ from PCRender's bake")
        }
        // The layers alone draw the live composite. At 8 bits each stamp is rounded to whole levels
        // where the live layer is rounded to the adjustment quantum: under a level per layer, 1.80
        // with all seven; 0.012 at 16 bits.
        let live = try MapsKit.flatten(d), layers = try MapsKit.flatten(back)
        let diff = Self.levels(live, layers)
        #expect(diff <= (depth == .u8 ? 2 : 0.05), "the layers draw \(diff) levels off the live composite")
        // The merged image is the live composite (matted over white, as Photoshop writes one).
        let merged = try #require(try PSDCompositeOracle.reference(file, back))
        let wantMerged = merged.flattened.map { live.over(background: $0) } ?? live
        #expect(MapsKit.maxDiff(merged.buffer.px, wantMerged.px) <= 1.0 / 255 + 1e-6)
    }

    /// Normal blurs thinning coverage: the layers draw the live composite everywhere except within
    /// the blurs' reach of the canvas edge and inside the card's edge.
    @Test(arguments: [SampleType.u8, .u16])
    func normalBlursThinningCoverage(_ depth: SampleType) throws {
        let d = Self.limits(depth)
        let (back, _, _) = try ExportSweep.$name.withValue("filter-bake-limits-\(depth.bits).psd") {
            try AdjustBlendRoundtripTests.exportImport(d, photoshop: true)
        }
        let live = try MapsKit.flatten(d), layers = try MapsKit.flatten(back)
        let reach: Int32 = 9
        let interior = d.bounds.outset(by: -reach)
        let card = PixelRect(x0: 30, y0: 16, x1: 66, y1: 48)
        var outside: Float = 0, rim: Float = 0, cardEdge: Float = 0
        for (i, (p, q)) in zip(live.px, layers.px).enumerated() {
            let x = Int32(i % live.rect.width), y = Int32(i / live.rect.width)
            var m: Float = 0
            for c in 0 ..< 4 { m = max(m, abs((c < 3 ? p[c] * p.w : p[c]) - (c < 3 ? q[c] * q.w : q[c])) * 255) }
            if !interior.contains(x: x, y: y) {
                rim = max(rim, m)
            } else if card.outset(by: reach).contains(x: x, y: y) && !card.outset(by: -reach).contains(x: x, y: y) {
                cardEdge = max(cardEdge, m)
            } else {
                outside = max(outside, m)
            }
        }
        #expect(outside <= 1, "\(outside) levels away from the thinned areas")
        #expect(rim > 2 && cardEdge > 2, "rim \(rim), card edge \(cardEdge): the thinning should show")
        print("filter-bake limits \(depth.bits)-bit: canvas rim \(rim) levels, card edge \(cardEdge), elsewhere \(outside)")
    }

    /// A compositor that can't bake leaves the layer empty, with the warning saying so.
    @Test func aCompositorThatCantBakeWritesItEmpty() throws {
        var d = Document(name: "f", size: PixelSize(width: 16, height: 12), mode: .rgb, depth: .u8)
        d.layers.append(rasterLayer("Background", d.pixelFormat, d.bounds, 1, false))
        d.layers.append(Self.filter("Blur", .gaussianBlur(.init(radius: 2))))
        var o = MapsKit.options()
        o.compositor = StoredPixelsCompositor()
        let r = try ExportSweep.excluded { try MapsKit.export(d, "x.psd", options: o) }
        #expect(r.warnings.contains { $0.contains("\"Blur\"") && $0.contains("empty pixel layer") }, "\(r.warnings)")
        let back = try MapsKit.importFile(r.bytes, "x.psd", options: o).document
        guard case .raster(let s) = back.layers[1].content else { Issue.record("\(back.layers[1].content.kindName)"); return }
        #expect(ContentBounds.of(s).isEmpty)
    }

    /// A hidden filter layer, and one inside a hidden group, are baked too (for when they're shown);
    /// a masked one only within its mask.
    @Test func hiddenAndMaskedLayers() throws {
        var d = Document(name: "f", size: PixelSize(width: 40, height: 30), mode: .rgb, depth: .u8)
        let fmt = d.pixelFormat
        d.layers.append(rasterLayer("Background", fmt, d.bounds, 1, false))
        var hidden = Self.filter("Hidden", .grain(.init(amount: 80, seed: 5)))
        hidden.visible = false
        d.layers.append(hidden)
        var group = Layer.group("Off", [rasterLayer("Inside", fmt, PixelRect(x0: 4, y0: 4, x1: 30, y1: 20), 3, false),
                                        Self.filter("In Hidden", .addNoise(.init(amount: 50, seed: 2)))])
        group.blend = .normal
        group.visible = false
        d.layers.append(group)
        var masked = Self.filter("Masked", .gaussianBlur(.init(radius: 1)))
        let window = PixelRect(x0: 12, y0: 10, x1: 28, y1: 22)
        masked.mask = Self.reveal(.u8, window)
        d.layers.append(masked)
        let back = try ExportSweep.excluded { try MapsKit.roundtrip(d) }
        for (name, bounds) in [("Hidden", d.bounds), ("In Hidden", PixelRect(x0: 4, y0: 4, x1: 30, y1: 20)), ("Masked", window)] {
            var found: Layer?
            back.forEachLayer { _, _, l in if l.name == name { found = l } }
            let l = try #require(found)
            guard case .raster(let s) = l.content else { Issue.record("\(name): \(l.content.kindName)"); continue }
            #expect(ContentBounds.of(s) == bounds, "\(name): \(ContentBounds.of(s))")
        }
        #expect(try MapsKit.flatten(d).px == MapsKit.flatten(back).px || Self.levels(try MapsKit.flatten(d), try MapsKit.flatten(back)) <= 1)
    }
}
