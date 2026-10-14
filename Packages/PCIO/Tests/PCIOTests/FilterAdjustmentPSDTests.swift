// Filter adjustment layers in a PSD/PSB save (AB-T-0258): Photoshop has no such layer, so each is
// written as an empty pixel layer (its name, mask, opacity, blend mode and clipping kept) with a
// warning naming it, and the merged image still shows the filters. `.pcraft` keeps them.

import Foundation
import PCDocument
import PCFoundation
import PCIOMaps
import PCPSD
import PCRender
import Testing
@testable import PCIO

@Suite struct FilterAdjustmentPSDTests {
    init() { ExportSweep.install() }

    /// A background, Grain (masked, at an opacity, in Overlay), Add Noise, a Gaussian Blur inside a
    /// group, and a Motion Blur clipped to the group.
    static func doc(_ depth: SampleType = .u8) -> Document {
        var d = Document(name: "filters", size: PixelSize(width: 48, height: 32), mode: .rgb, depth: depth)
        let fmt = d.pixelFormat
        d.layers.append(rasterLayer("Background", fmt, d.bounds, 1, false))
        var grain = Layer(name: "Grain", content: .adjustment(.filter(.grain(.init(amount: 60, size: 2, roughness: 40, seed: 3)))))
        grain.opacity = 0.75
        grain.blend = .overlay
        grain.mask = LayerMask(surface: maskSurface(depth, PixelRect(x0: 4, y0: 3, x1: 30, y1: 25), 1, 3), enabled: true, linked: true, density: 1, feather: 0)
        d.layers.append(grain)
        d.layers.append(Layer(name: "Noise", content: .adjustment(.filter(.addNoise(.init(amount: 30, seed: 9))))))
        d.layers.append(Layer.group("Blurs", [rasterLayer("Inside", fmt, PixelRect(x0: 20, y0: 6, x1: 40, y1: 26), 5, true),
                                              Layer(name: "Gaussian", content: .adjustment(.filter(.gaussianBlur(.init(radius: 2)))))]))
        var motion = Layer(name: "Motion", content: .adjustment(.filter(.motionBlur(.init(angle: 30, distance: 8)))))
        motion.clipped = true
        d.layers.append(motion)
        return d
    }

    /// Dropped for the Photoshop oracle (`PCIO_EXPORT_DIR`) as `filter-adjustments-<conventions>-<bits>.psd`.
    @Test(arguments: [false, true], [SampleType.u8, .u16])
    func writtenAsEmptyPixelLayersWithAWarning(_ photoshop: Bool, _ depth: SampleType) throws {
        let d = Self.doc(depth)
        let name = "filter-adjustments-\(photoshop ? "photoshop" : "photocraft")-\(depth.bits).psd"
        let (back, warnings, file) = try ExportSweep.$name.withValue(name) { try AdjustBlendRoundtripTests.exportImport(d, photoshop: photoshop) }
        for name in ["Grain", "Noise", "Gaussian", "Motion"] {
            #expect(warnings.contains { $0.contains("\"\(name)\"") && $0.contains("no PSD equivalent") && $0.contains(".pcraft") }, "\(name): \(warnings)")
        }
        #expect(!warnings.contains { $0.contains("not yet written") })
        // No adjustment block anywhere; the records are all there.
        #expect(!file.layers.contains { l in l.blocks.contains { AdjustMap.adjustmentKeys.contains($0.key) } })
        #expect(back.layers.count == d.layers.count)
        var pairs = Array(zip(d.layers.dropFirst(), back.layers.dropFirst()))
        if let g = pairs.firstIndex(where: { $0.0.isGroup }) {
            let (x, y) = pairs.remove(at: g)
            #expect(y.isGroup && y.children?.count == 2)
            if let xc = x.children?.last, let yc = y.children?.last { pairs.append((xc, yc)) }
        }
        for (x, y) in pairs {
            guard case .raster(let s) = y.content else { Issue.record("\(y.name): \(y.content.kindName)"); continue }
            #expect(ContentBounds.of(s).isEmpty, "\(y.name) holds pixels")
            #expect(x.name == y.name && x.blend == y.blend && abs(x.opacity - y.opacity) <= 0.5 / 255 && x.clipped == y.clipped, "\(x.name)")
            #expect((x.mask != nil) == (y.mask != nil), "\(x.name) mask")
        }
        // The merged image is the document's composite, the filters in it (matted over white, as
        // Photoshop writes a translucent one: the blur thins at the canvas edge).
        let merged = try #require(try PSDCompositeOracle.reference(file, back))
        let composite = try MapsKit.flatten(d)
        let want = merged.flattened.map { composite.over(background: $0) } ?? composite
        #expect(MapsKit.maxDiff(merged.buffer.px, want.px) <= 1.0 / 255 + 1e-6)
        #expect(MapsKit.maxDiff(composite.px, try MapsKit.flatten(back).px) > 2.0 / 255, "the layers alone draw no filter")
    }
}
