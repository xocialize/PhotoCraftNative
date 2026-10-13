// Auto White Balance and SDR → HDR through ForgeLightKit's LightTier0, and Super Resolution /
// Image Size ▸ Preserve Details 2.0 through the upscale slot (photocraft gap G15: "Generative
// Upscale, Super Zoom"; photocraft's own `image.imageSize` resamplers are classical and stay in
// PCAlgo). White balance edits a layer like the neural filters (selection-limited, alpha kept);
// Super Resolution and SDR → HDR produce a new document, as Photoshop's Enhance and Merge to HDR do.
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import Foundation
import PCDocument
import PCFoundation
import PCHistory

/// SDR → HDR options.
public struct HDRExpansionOptions: Sendable, Equatable {
    /// Where SDR white lands, in cd/m²: 203 is BT.2408 direct mapping, ~1000 BT.2446-A. The standards
    /// disagree, so it is a control (LightTier0's "the anchor is the product").
    public var diffuseWhiteNits: Double
    /// Deband before expanding (on by default: expansion roughly doubles banding).
    public var deband: Bool
    /// Dither once after expanding.
    public var dither: Bool

    public init(diffuseWhiteNits: Double = 203, deband: Bool = true, dither: Bool = true) {
        self.diffuseWhiteNits = diffuseWhiteNits; self.deband = deband; self.dither = dither
    }
}

extension PCIntelligence {

    // MARK: Auto White Balance

    /// Auto White Balance: estimates the scene illuminant of the layer's (selected, opaque) pixels
    /// with LightTier0's shades-of-grey (p = 6) in linear light and adapts to neutral (Bradford), or
    /// runs the injected white-balance provider. The receipt carries the estimate as kelvin and tint.
    /// Assumes an sRGB-like tone curve for the document's encoding.
    public func autoWhiteBalance(_ doc: Document, layer id: LayerId, output: FilterOutput = .currentLayer,
                                 progress: ProgressHandler? = nil) async throws -> PixelEditOutcome {
        guard !doc.mode.isGrayLike else { throw IntelligenceError.refused("Auto White Balance needs a colour document") }
        let stage = Stage(handler: progress)
        try stage.report(0, "Auto White Balance")
        let injected = registry.provider(.whiteBalance, as: (any WhiteBalanceProvider).self)
        let selection = doc.selection
        return try await filterLayer(doc, layer: id, output: output, label: "Auto White Balance", stage: stage) { input in
            if let injected {
                let img = try await run(.whiteBalance) { try await injected.provider.balance(input.image()) }
                return (try input.decode(img), [TierReceipt(capability: .whiteBalance, tier: injected.tier, engine: injected.name)])
            }
            let weight = selection.map { CoverageMask(surface: $0, rect: input.rect).values }
            let r = ClassicalWhiteBalance.balance(input.rgba, weight: weight)
            return (r.rgba, [TierReceipt(capability: .whiteBalance, tier: .classical, engine: BuiltIn.whiteBalance,
                                         metrics: ["kelvin": r.temperature.kelvin, "tint": r.temperature.tint,
                                                   "illuminantR": r.illuminant.red, "illuminantG": r.illuminant.green,
                                                   "illuminantB": r.illuminant.blue])])
        }
    }

    // MARK: SDR → HDR

    /// SDR → HDR: a new 32-bit RGB document in linear light (tagged linear sRGB), where 1.0 is the
    /// BT.2408 HDR reference white (203 cd/m²) and SDR white lands at `diffuseWhiteNits`. Runs
    /// LightTier0's deband → BT.2408 direct mapping → dither chain, or the injected HDR provider.
    public func sdrToHDR(_ doc: Document, source: PixelSource = .composite, options: HDRExpansionOptions = .init(),
                         progress: ProgressHandler? = nil) async throws -> DocumentOutcome {
        guard (80...10_000).contains(options.diffuseWhiteNits) else {
            throw IntelligenceError.badParameter("diffuse white must be 80…10000 cd/m² (203 is BT.2408)")
        }
        let stage = Stage(handler: progress)
        try stage.report(0, "SDR to HDR")
        let rect = doc.bounds
        guard !rect.isEmpty else { throw IntelligenceError.badParameter("the canvas is empty") }
        let surface = try await pixels(source, in: doc, rect: rect)
        let rgba = surface.readRGBA(rect)
        var notes: [String] = []
        if surface.format.sample == .f32, rgba.contains(where: { max($0.x, $0.y, $0.z) > 1 }) {
            notes.append("source values above 1 were clamped to the SDR range")
        }
        let linear: [SIMD4<Float>]
        var receipt: TierReceipt
        let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let p = registry.provider(.hdrExpansion, as: (any HDRExpansionProvider).self) {
            let image = try KitBridge.image(fromRGBA: rgba, width: rect.width, height: rect.height,
                                            sample: surface.format.sample == .u8 ? .u8 : .u16,
                                            colorSpace: KitBridge.colorSpace(for: doc), alpha: .opaque)
            let out = try await run(.hdrExpansion) { try await p.provider.expand(image, diffuseWhiteNits: options.diffuseWhiteNits) }
            var px = try KitBridge.rgba(from: out, colorSpace: linearSpace, sample: .f32, width: rect.width, height: rect.height)
            for i in px.indices { px[i].w = rgba[i].w }
            linear = px
            receipt = TierReceipt(capability: .hdrExpansion, tier: p.tier, engine: p.name, notes: notes,
                                  metrics: ["diffuseWhiteNits": options.diffuseWhiteNits])
        } else {
            let r = ClassicalHDRExpansion.expand(rgba, width: rect.width, height: rect.height, diffuseWhiteNits: options.diffuseWhiteNits,
                                                 deband: options.deband, dither: options.dither)
            linear = r.rgba
            receipt = TierReceipt(capability: .hdrExpansion, tier: .classical, engine: BuiltIn.hdrExpansion, notes: notes,
                                  metrics: ["diffuseWhiteNits": options.diffuseWhiteNits, "peakNits": r.peakNits])
        }
        try stage.report(0.9, "Building document")
        var out = Document(name: "\(doc.name) HDR", size: doc.size, mode: .rgb, depth: .f32)
        out.resolutionDpi = doc.resolutionDpi
        out.iccProfile = (CGColorSpace(name: CGColorSpace.linearSRGB)?.copyICCData() as Data?).map { [UInt8]($0) }
        out.layers = [PCIntelligence.imageLayer(linear, rect: rect, format: out.pixelFormat)]
        receipt.notes.append("linear light, 1.0 = 203 cd/m² (BT.2408 HDR reference white)")
        try stage.report(1, "Done")
        return DocumentOutcome(document: out, receipt: receipt)
    }

    /// A layer holding straight RGBA at `rect`: the Background (locked) when fully opaque, else
    /// "Layer 0".
    static func imageLayer(_ rgba: [SIMD4<Float>], rect: PixelRect, format: PixelFormat) -> Layer {
        var s = Surface(format: format)
        KitBridge.write(rgba: rgba, into: &s, rect: rect)
        let opaque = !rgba.contains { $0.w < 1 }
        var l = Layer.raster(opaque ? "Background" : "Layer 0", surface: s)
        if opaque {
            l.locks.transparency = true
            l.locks.position = true
        }
        return l
    }

    // MARK: Super Resolution

    /// Upscales `rect` of `surface` by `factor` through the upscale slot (the Image Size ▸ Preserve
    /// Details 2.0 primitive). Colour goes through the provider; alpha, when the region has any
    /// transparency, is resampled bilinearly. The result keeps `surface`'s format, with the region's
    /// top-left at (x0·f, y0·f). Unavailable until an `UpscaleProvider` is registered.
    public func upscale(_ surface: Surface, rect: PixelRect, factor: Int, colorSpace: CGColorSpace? = nil,
                        progress: ProgressHandler? = nil) async throws -> UpscaleOutcome {
        guard let p = registry.provider(.upscale, as: (any UpscaleProvider).self) else {
            throw IntelligenceError.unavailable(.upscale, registry.status(of: .upscale).reason ?? "")
        }
        guard (2...8).contains(factor) else { throw IntelligenceError.badParameter("the upscale factor must be 2…8") }
        guard !rect.isEmpty else { throw IntelligenceError.badParameter("nothing to upscale") }
        let stage = Stage(handler: progress)
        try stage.report(0, "Super Resolution")
        let cs = colorSpace ?? KitBridge.defaultColorSpace(sample: surface.format.sample)
        let rgba = surface.readRGBA(rect)
        let image = try KitBridge.image(fromRGBA: rgba, width: rect.width, height: rect.height, sample: surface.format.sample,
                                        colorSpace: cs, alpha: .opaque)
        let out = try await run(.upscale) { try await p.provider.upscale(image, factor: factor) }
        let applied = out.width / rect.width
        guard applied >= 1, out.width == rect.width * applied, out.height == rect.height * applied else {
            throw IntelligenceError.providerFailed(.upscale, "\(p.name) returned \(out.width)×\(out.height) for a \(rect.width)×\(rect.height) input at ×\(factor)")
        }
        try stage.report(0.8, "Applying")
        let (W, H) = (rect.width * applied, rect.height * applied)
        var px = try KitBridge.rgba(from: out, colorSpace: cs, sample: surface.format.sample)
        if rgba.contains(where: { $0.w < 1 }) {
            let alpha = KitBridge.resampleBilinear(rgba.map { $0.w }, from: (rect.width, rect.height), to: (W, H))
            for i in px.indices { px[i].w = alpha[i] }
        } else {
            for i in px.indices { px[i].w = 1 }
        }
        let outRect = PixelRect(x: Int(rect.x0) * applied, y: Int(rect.y0) * applied, width: W, height: H)
        var s = Surface(format: surface.format)
        KitBridge.write(rgba: px, into: &s, rect: outRect)
        var notes: [String] = []
        if applied != factor { notes.append("requested ×\(factor), the provider applied ×\(applied)") }
        try stage.report(1, "Done")
        return UpscaleOutcome(surface: s, rect: outRect, appliedFactor: applied,
                              receipt: TierReceipt(capability: .upscale, tier: p.tier, engine: p.name, notes: notes,
                                                   metrics: ["appliedScale": Double(applied), "requestedScale": Double(factor)]))
    }

    /// Super Resolution: the canvas (or `source`) upscaled by `factor` into a new document with the
    /// same mode, depth and profile; resolution scales with it, so the print size is unchanged.
    public func superResolution(_ doc: Document, source: PixelSource = .composite, factor: Int = 2,
                                progress: ProgressHandler? = nil) async throws -> DocumentOutcome {
        let rect = doc.bounds
        let surface = try await pixels(source, in: doc, rect: rect)
        let up = try await upscale(surface, rect: rect, factor: factor, colorSpace: KitBridge.colorSpace(for: doc), progress: progress)
        let f = up.appliedFactor
        var out = Document(name: "\(doc.name) (Super Resolution)", size: PixelSize(width: doc.size.width * f, height: doc.size.height * f),
                           mode: doc.mode, depth: doc.depth)
        out.resolutionDpi = doc.resolutionDpi * Float(f)
        out.iccProfile = doc.iccProfile
        out.colorTable = doc.colorTable
        out.duotone = doc.duotone
        let rgba = up.surface.readRGBA(up.rect)
        out.layers = [PCIntelligence.imageLayer(rgba, rect: up.rect, format: out.pixelFormat)]
        return DocumentOutcome(document: out, receipt: up.receipt)
    }
}
