// Image Size's enlarger slot (AB-T-0292): a host-injected whole-image ×2 — anime4k-metal's Anime4K in
// PixelAgencyEditor's Line art method — which PCEngine's `image.imageSize` runs as many times as the
// target needs before its chosen Resample fits the result to the exact size (AB-D-0119's chain). Not a
// per-axis filter, so it isn't one of PCAlgo's `Resample` kernels, and nothing here depends on it: the
// host registers it as it registers ForgeCore's providers. MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

import CoreGraphics
import PCDocument
import PCFoundation

/// Whether an enlarger can run on this machine.
public enum EnlargerAvailability: Sendable, Equatable {
    case available
    /// It can't run (anime4k-metal's `Anime4KUpscaler.unavailableReason`: no Metal device); `reason` says why.
    case unavailable(reason: String)
}

/// Enlarges pixels by exactly ×2 on both axes (Anime4K). Registered with `ProviderRegistry.register(enlarger:)`.
public protocol ImageEnlarger: Sendable {
    /// The name receipts print ("Anime4K (VL)").
    var name: String { get }
    /// Whether it can run now. An unavailable enlarger reports the slot unavailable, and Image Size uses its
    /// Resample alone. Defaults to `.available`.
    var availability: EnlargerAvailability { get }
    /// The pixels of `rect` of `surface` enlarged ×2: a surface in `surface.format` (same model, depth and
    /// alpha) holding them over `rect` doubled — top-left (2·x0, 2·y0), 2·width × 2·height. Pixels outside
    /// `rect` are neither read nor written. Called once per pixel layer and pass, never on a mask or a smart
    /// object's source.
    func enlarge(_ surface: Surface, rect: PixelRect) async throws -> Surface
}

extension ImageEnlarger {
    public var availability: EnlargerAvailability { .available }
}

/// An `ImageEnlarger` from a closure over surfaces.
public struct ImageEnlargerClosure: ImageEnlarger {
    public let name: String
    let check: @Sendable () -> EnlargerAvailability
    let body: @Sendable (Surface, PixelRect) async throws -> Surface
    public init(_ name: String, availability: @escaping @Sendable () -> EnlargerAvailability = { .available },
                _ body: @escaping @Sendable (_ surface: Surface, _ rect: PixelRect) async throws -> Surface) {
        self.name = name; self.check = availability; self.body = body
    }
    public var availability: EnlargerAvailability { check() }
    public func enlarge(_ surface: Surface, rect: PixelRect) async throws -> Surface { try await body(surface, rect) }
}

/// An `ImageEnlarger` from a CGImage ×2 (anime4k-metal's `Anime4KUpscaler.upscale(_:)`), so a host registers
/// one in one statement:
///
///     registry.register(enlarger: CGImageEnlarger("Anime4K (VL)", availability: {
///         Anime4KUpscaler.unavailableReason.map { .unavailable(reason: $0) } ?? .available
///     }) { try upscaler.upscale($0) })
///
/// The pixels cross through `KitBridge` at the surface's depth (8-bit, 16-bit or 32-bit float components),
/// tagged sRGB (extended sRGB at 32 bits); the same space both ways, so the stored values reach the
/// closure untransformed. Straight alpha travels with the image when the region has any transparency;
/// an opaque region goes out opaque and comes back opaque. RGB and grayscale round-trip exactly; CMYK and
/// Lab go through sRGB (`Surface.readRGBA`). The closure must return exactly twice the size.
public struct CGImageEnlarger: ImageEnlarger {
    public let name: String
    let check: @Sendable () -> EnlargerAvailability
    let body: @Sendable (CGImage) async throws -> CGImage
    public init(_ name: String, availability: @escaping @Sendable () -> EnlargerAvailability = { .available },
                _ body: @escaping @Sendable (_ image: CGImage) async throws -> CGImage) {
        self.name = name; self.check = availability; self.body = body
    }
    public var availability: EnlargerAvailability { check() }

    public func enlarge(_ surface: Surface, rect: PixelRect) async throws -> Surface {
        let sample = surface.format.sample
        let cs = KitBridge.defaultColorSpace(sample: sample)
        let rgba = surface.readRGBA(rect)
        let opaque = !rgba.contains { $0.w < 1 }
        let image = try KitBridge.image(fromRGBA: rgba, width: rect.width, height: rect.height, sample: sample,
                                        colorSpace: cs, alpha: opaque ? .opaque : .keep)
        let out = try await body(image)
        guard out.width == rect.width * 2, out.height == rect.height * 2 else {
            throw KitBridgeError("\(name) returned \(out.width)×\(out.height) for a \(rect.width)×\(rect.height) input; an enlarger doubles it")
        }
        var px = try KitBridge.rgba(from: out, colorSpace: cs, sample: sample)
        if opaque { for i in px.indices { px[i].w = 1 } }
        var s = Surface(format: surface.format, defaultPixel: surface.defaultPixelValue)
        KitBridge.write(rgba: px, into: &s, rect: rect.doubled)
        return s
    }
}

/// Pixels enlarged through the enlarger slot.
public struct EnlargeOutcome: Sendable {
    /// The enlarged pixels, `rect` of the input doubled `passes` times.
    public var surface: Surface
    /// Where they are: the input rect's corners times 2^passes.
    public var rect: PixelRect
    public var passes: Int
    public var receipt: TierReceipt
}

extension PixelRect {
    /// The rect at twice the scale about the origin.
    var doubled: PixelRect { PixelRect(x0: x0 &* 2, y0: y0 &* 2, x1: x1 &* 2, y1: y1 &* 2) }
}

extension PCIntelligence {

    /// The registered enlarger when it can run; nil when the slot is empty or its enlarger is unavailable
    /// (Image Size then uses its Resample alone).
    public var enlarger: (any ImageEnlarger)? {
        guard registry.status(of: .enlarge).isAvailable else { return nil }
        return registry.provider(.enlarge, as: (any ImageEnlarger).self)?.provider
    }

    /// `rect` of `surface` through the enlarger `passes` times (×2^passes), each result checked: the input's
    /// format, and nothing outside its rect. Cancellable between passes. Unavailable while the slot is empty.
    public func enlarge(_ surface: Surface, rect: PixelRect, passes: Int, progress: ProgressHandler? = nil) async throws -> EnlargeOutcome {
        guard let e = registry.provider(.enlarge, as: (any ImageEnlarger).self), registry.status(of: .enlarge).isAvailable else {
            throw IntelligenceError.unavailable(.enlarge, registry.status(of: .enlarge).reason ?? "")
        }
        guard (1...8).contains(passes) else { throw IntelligenceError.badParameter("an enlargement takes 1…8 passes of ×2") }
        guard !rect.isEmpty else { throw IntelligenceError.badParameter("nothing to enlarge") }
        let limit = Int64(Int32.max / 2) >> passes
        guard [rect.x0, rect.y0, rect.x1, rect.y1].allSatisfy({ abs(Int64($0)) <= limit }) else {
            throw IntelligenceError.badParameter("×\(1 << passes) puts the pixels outside the 32-bit coordinate range")
        }
        let stage = Stage(handler: progress)
        var cur = surface, r = rect
        for i in 0..<passes {
            try stage.report(Double(i) / Double(passes), "\(e.name) ×2 (pass \(i + 1) of \(passes))")
            let input = cur, at = r
            let out = try await run(.enlarge) { try await e.provider.enlarge(input, rect: at) }
            guard out.format == input.format else {
                throw IntelligenceError.providerFailed(.enlarge, "\(e.name) returned \(out.format) pixels for \(input.format) ones")
            }
            r = at.doubled
            let spill = out.contentBounds
            guard spill.isEmpty || r.contains(spill) else {
                throw IntelligenceError.providerFailed(.enlarge, "\(e.name) wrote outside the doubled rect")
            }
            cur = out
        }
        try stage.report(1, "Done")
        return EnlargeOutcome(surface: cur, rect: r, passes: passes,
                              receipt: TierReceipt(capability: .enlarge, tier: e.tier, engine: e.name,
                                                   metrics: ["passes": Double(passes), "appliedScale": Double(1 << passes)]))
    }
}
