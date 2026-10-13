// Port of photocraft-io (crates/io/tests/composite.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Composite oracle: the merged image stored in a PSD must match our compositor's rendering of the
// imported document. photocraft composites with photocraft-compose; here both the export's merged
// image and the reference are PCRender's (`RenderCompositor`), held to photocraft's tolerances.

import Foundation
import PCDocument
import PCFoundation
import PCPSD
import Testing
@testable import PCIO

@Suite struct CompositeTests {
    init() { ExportSweep.install() }
    static let tol: Float = 1 / 255 + 1e-4

    /// The largest difference between the exported merged image and PCRender's composite of the
    /// re-imported document.
    static func exportOracleDiff(_ d: Document, photoshop: Bool = true) throws -> Float {
        let r = try PSDKit.export(d, "x.psd", PSDKit.options(photoshop))
        let f = try PSDFile(bytes: r.bytes)
        let merged = try MergedImage.composite(f)
        let d2 = try PSDKit.importFile("x.psd", r.bytes, photoshop: photoshop).document
        var ours = try PSDKit.flatten(d2)
        if d.mode == .cmyk {
            // The merged CMYK image is the RGB composite separated through the CMYK profile, which
            // gamut-maps colours that blend modes push outside CMYK: project ours the same way.
            let fmt = d.pixelFormat
            ours = PSDKit.toRGBA(fmt, ours.flatMap { fmt.components(fromRGBA: $0) })
        }
        return PSDKit.maxDiff(ours, merged)
    }

    static let oracles: [(name: String, mode: ColorMode, depth: SampleType, features: Features, tol: Float)] = [
        ("rgb8", .rgb, .u8, .all, tol),
        ("rgb16", .rgb, .u16, .all, tol),
        ("rgb32", .rgb, .f32, .all, tol),
        ("gray8", .grayscale, .u8, .all, tol),
        ("gray16", .grayscale, .u16, .all, tol),
        // CMYK/Lab merged data is converted from the RGB composite (CMYK through the built-in
        // profile), so the stored merged image differs by a quantization round trip through the model.
        ("cmyk8", .cmyk, .u8, .pixels, 3 / 255),
        // Lab: one 8-bit Lab quantization step is amplified up to ~15/255 near the sRGB gamut edge
        // (the sRGB toe has slope 12.92), so the tolerance is wider.
        ("lab8", .lab, .u8, .pixels, 16 / 255),
    ]

    @Test(arguments: oracles.indices, PSDKit.conventions) func exportOracle(_ i: Int, _ photoshop: Bool) throws {
        let o = CompositeTests.oracles[i]
        let m = try CompositeTests.exportOracleDiff(genDoc(o.mode, o.depth, o.features), photoshop: photoshop)
        #expect(m <= o.tol, "\(o.name): max diff \(m) > \(o.tol)")
    }

    static func sat8(_ v: Float) -> UInt8 { v.isNaN ? 0 : UInt8(min(max((v * 255).rounded(), 0), 255)) }
    static func sat16(_ v: Float) -> UInt16 { v.isNaN ? 0 : UInt16(min(max((v * 65535).rounded(), 0), 65535)) }

    /// Builds a PSD with the *builder* (an independent writer) whose merged image is PCRender's
    /// composite, then checks import + composite against it.
    static func builderOracleDiff(_ depth: UInt16, _ mode: ColorMode) throws -> Float {
        let sample: SampleType = depth == 16 ? .u16 : .u8
        let d = genDoc(mode, sample, Features(groups: false, masks: true, adjustments: false, fills: false, allBlends: true, extras: false))
        let flat = try PSDKit.flatten(d)
        let fmt = d.pixelFormat
        func toPixels(_ px: [SIMD4<Float>]) -> PCPSD.PSDPixels {
            let vals = px.flatMap { fmt.components(fromRGBA: $0) }
            return depth == 8 ? .u8(vals.map(sat8)) : .u16(vals.map(sat16))
        }
        var b = PSDKit.builder(d.size.width, d.size.height, mode: mode == .grayscale ? .grayscale : .rgb, depth: depth)
        for l in d.layers {
            let s = try #require(l.surface)
            let r = s.contentBounds
            let buf = r.isEmpty ? [] : PSDKit.toRGBA(s.format, s.readRegion(r))
            var spec = PSDLayerSpec(name: l.name, left: r.x0, top: r.y0, width: r.width, height: r.height, pixels: toPixels(buf))
            spec.blendMode = PSDBlendMode(key: FourCC(l.blend.psdKey))
            spec.opacity = sat8(l.opacity)
            spec.fillOpacity = sat8(l.fillOpacity)
            spec.visible = l.visible
            spec.clipping = l.clipped
            if let m = l.mask {
                let mr = m.surface.contentBounds
                spec.mask = PSDMaskSpec(rect: PSDRect(top: mr.y0, left: mr.x0, bottom: mr.y1, right: mr.x1), data: m.surface.readRegion(mr).map(sat8),
                                        defaultColor: sat8(m.surface.defaultPixelValue[0]), disabled: !m.enabled)
            }
            b.pushLayer(spec)
        }
        b.setComposite(toPixels(flat))
        let bytes = [UInt8](try b.serialized())
        let f = try PSDFile(bytes: bytes)
        let merged = try MergedImage.composite(f)
        let d2 = try PSDKit.importFile("b.psd", bytes).document
        return PSDKit.maxDiff(try PSDKit.flatten(d2), merged)
    }

    // Density/feather of masks are not written by the builder; the generated doc uses them only
    // on a disabled mask, so results must match.
    @Test(arguments: [(UInt16(8), ColorMode.rgb), (16, .rgb), (8, .grayscale), (16, .grayscale)])
    func builderOracle(_ depth: UInt16, _ mode: ColorMode) throws {
        let m = try CompositeTests.builderOracleDiff(depth, mode)
        #expect(m <= 2 / 255, "builder oracle \(mode) \(depth): max diff \(m)")
    }

    @Test func everyBlendModeSingleLayerOracle() throws {
        for m in BlendMode.layerModes where m != .dissolve {
            var d = Document(name: "b", size: PixelSize(width: 8, height: 8), mode: .rgb, depth: .u8)
            let fmt = d.pixelFormat
            d.layers.append(rasterLayer("bg", fmt, d.bounds, 1, false))
            var top = rasterLayer("top", fmt, rect(2, 2, 7, 7), 9, true)
            top.blend = m
            top.opacity = g(190)
            d.layers.append(top)
            let diff = try CompositeTests.exportOracleDiff(d)
            #expect(diff <= CompositeTests.tol, "\(m): max diff \(diff)")
        }
    }

    @Test func hiddenAndClippedAffectComposite() throws {
        let d = genDoc(.rgb, .u8, .pixels)
        let merged = try MergedImage.composite(PSDKit.documentToPSD(d))
        var d2 = d
        for i in d2.layers.indices { d2.updateLayer(at: [i]) { $0.visible = true } }
        #expect(PSDKit.maxDiff(try PSDKit.flatten(d2), merged) > 0, "unhiding a layer must change the composite")
    }

    @Test func mergedAlphaWrittenWhenTransparent() throws {
        var d = Document(name: "t", size: PixelSize(width: 4, height: 4), mode: .rgb, depth: .u8)
        d.layers.append(rasterLayer("half", d.pixelFormat, rect(0, 0, 2, 4), 3, true))
        let f = PSDKit.documentToPSD(d)
        #expect(f.header.channels == 4)
        #expect(f.mergedHasAlpha)
        #expect(try MergedImage.composite(f)[3].w == 0)

        // U8 rounding must not erase transparency that is representable in the exported U16 plane.
        var near = Document(name: "near opaque", size: PixelSize(width: 1, height: 1), mode: .rgb, depth: .u16)
        var layer = Layer.raster("pixel", format: near.pixelFormat)
        let bounds = near.bounds
        layer.withRaster { $0.fill(bounds, with: [1, 0, 0, 65500 / 65535]) }
        near.layers.append(layer)
        let out = try PSDKit.export(near, "near.psd")
        let file = try PSDFile(bytes: out.bytes)
        #expect(file.header.channels == 4)
        #expect(file.mergedHasAlpha)
        let samples = try file.decodeMerged()
        #expect(PSDKit.be16(samples, 3) == 65500)
    }
}
