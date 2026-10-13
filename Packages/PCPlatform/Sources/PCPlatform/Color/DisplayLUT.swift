// The GPU display transform: document profile → monitor profile (optionally through a proof profile
// with a gamut warning) baked into a 33³ 3D LUT, and the monitor profiles themselves.
// Replaces photocraft-cms (crates/cms/src/lut3d.rs) and photocraft's monitor-profile helper
// (ui-egui/src/monitor_status.rs, which shells out to `osascript` to read NSScreen) with ColorSync +
// AppKit `NSScreen.colorSpace` read natively. Port of its API shape, MIT OR Apache-2.0, © ArtCraft
// Team and the PhotoCraft contributors.

import AppKit
import Foundation
import Metal

/// A `size³` RGBA lookup table: entry `r + g·size + b·size²` holds the output for input
/// `(r, g, b)/(size − 1)`, alpha 1 — the memory order of a 3D texture whose x axis is red, so it
/// uploads directly (sample at `(c·(size − 1) + 0.5)/size` with linear filtering).
public struct DisplayLUT: Sendable, Equatable {
    public let size: Int
    public let data: [SIMD4<Float>]

    /// photocraft's display LUT size.
    public static let defaultSize = 33

    /// Samples a 3-input transform (1-output transforms are replicated to gray) (photocraft
    /// `Lut3d::from_transform`).
    public init(transform t: ColorTransform, size: Int = DisplayLUT.defaultSize) throws {
        guard t.inputChannels == 3, t.outputChannels == 3 || t.outputChannels == 1 else {
            throw PlatformError.invalidArgument("display LUTs need a 3→3 or 3→1 transform")
        }
        self.size = size
        let pts = GridLUT.nodes(inputs: 3, size: size)
        let n = size * size * size
        let o = t.convert(pts, pixelCount: n)
        var d = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: n)
        for i in 0..<n {
            d[i] = t.outputChannels == 1 ? SIMD4(o[i], o[i], o[i], 1) : SIMD4(o[i * 3], o[i * 3 + 1], o[i * 3 + 2], 1)
        }
        data = d
    }

    public init(size: Int, data: [SIMD4<Float>]) {
        precondition(data.count == size * size * size, "DisplayLUT: data size")
        self.size = size; self.data = data
    }

    /// The canvas display transform (architecture §7.3): `document` → `monitor`, relative
    /// colorimetric with BPC; through `proof` (Proof Colors) when given; with out-of-gamut colours
    /// replaced by `gamutWarningColor` (Gamut Warning; Photoshop's default 50 % gray) when given.
    /// Returns nil when no LUT is needed (the document's colours equal the monitor's and there is
    /// no proof), as photocraft skips the LUT for sRGB on sRGB.
    public static func canvas(document: ICCProfile, monitor: ICCProfile, proof: ProofSettings? = nil,
                              gamutWarningColor: SIMD3<Float>? = nil, size: Int = DisplayLUT.defaultSize) throws -> DisplayLUT? {
        if proof == nil, gamutWarningColor == nil, document.sameColors(as: monitor) { return nil }
        let t: ColorTransform
        if let p = proof {
            t = try ColorTransform.proof(source: document, proof: p.profile, display: monitor, intent: p.intent,
                                         blackPointCompensation: p.blackPointCompensation, simulatePaper: p.simulatePaper)
        } else {
            t = try ColorTransform(source: document, destination: monitor, options: .photoshopDefault)
        }
        var lut = try DisplayLUT(transform: t, size: size)
        if let warn = gamutWarningColor, let p = proof {
            let check = try GamutCheck(source: document, proof: p.profile)
            let pts = GridLUT.nodes(inputs: 3, size: size)
            var d = lut.data
            for i in 0..<d.count where check.isOutOfGamut([pts[i * 3], pts[i * 3 + 1], pts[i * 3 + 2]]) {
                d[i] = SIMD4(warn, 1)
            }
            lut = DisplayLUT(size: size, data: d)
        }
        return lut
    }

    /// Trilinear lookup (what GPU filtering computes).
    public func sample(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let n = size
        func loc(_ v: Float) -> (Int, Float) {
            let p = min(max(v, 0), 1) * Float(n - 1)
            let i = min(Int(p), n - 2)
            return (i, p - Float(i))
        }
        let (r0, fr) = loc(rgb.x), (g0, fg) = loc(rgb.y), (b0, fb) = loc(rgb.z)
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
            let v = data[r + g * n + b * n * n]
            return SIMD3(v.x, v.y, v.z)
        }
        let x00 = at(r0, g0, b0) + (at(r0 + 1, g0, b0) - at(r0, g0, b0)) * fr
        let x10 = at(r0, g0 + 1, b0) + (at(r0 + 1, g0 + 1, b0) - at(r0, g0 + 1, b0)) * fr
        let x01 = at(r0, g0, b0 + 1) + (at(r0 + 1, g0, b0 + 1) - at(r0, g0, b0 + 1)) * fr
        let x11 = at(r0, g0 + 1, b0 + 1) + (at(r0 + 1, g0 + 1, b0 + 1) - at(r0, g0 + 1, b0 + 1)) * fr
        let y0 = x00 + (x10 - x00) * fg, y1 = x01 + (x11 - x01) * fg
        return y0 + (y1 - y0) * fb
    }

    /// Little-endian RGBA16F texels (8 bytes each) for an `rgba16Float` 3D texture.
    public func rgba16fBytes() -> [UInt8] {
        var o = [UInt8]()
        o.reserveCapacity(data.count * 8)
        for px in data {
            for v in [px.x, px.y, px.z, px.w] { withUnsafeBytes(of: Float16(v).bitPattern.littleEndian) { o += $0 } }
        }
        return o
    }

    /// RGBA8 texels (for backends without float 3D textures).
    public func rgba8() -> [UInt8] {
        data.flatMap { px in [px.x, px.y, px.z, px.w].map { UInt8(min(max($0, 0), 1) * 255 + 0.5) } }
    }

    /// A 3D `rgba16Float` texture holding the LUT.
    public func makeTexture(device: any MTLDevice) -> (any MTLTexture)? {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba16Float
        d.width = size; d.height = size; d.depth = size
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        let bytes = rgba16fBytes()
        bytes.withUnsafeBytes { p in
            tex.replace(region: MTLRegionMake3D(0, 0, 0, size, size, size), mipmapLevel: 0, slice: 0,
                        withBytes: p.baseAddress!, bytesPerRow: size * 8, bytesPerImage: size * size * 8)
        }
        return tex
    }

    /// MSL for applying the LUT in a canvas shader's final pass.
    public static let metalSource = """
    // PCPlatform display LUT: document RGB (0…1) → monitor RGB through a size³ rgba16Float 3D texture.
    inline float3 pc_display_lut(texture3d<float> lut, sampler s, float3 rgb) {
        float n = float(lut.get_width());
        float3 uvw = (clamp(rgb, 0.0, 1.0) * (n - 1.0) + 0.5) / n;
        return lut.sample(s, uvw).rgb;
    }
    """
}

/// Proof Colors settings (View ▸ Proof Setup).
public struct ProofSettings: Sendable {
    public var profile: ICCProfile
    public var intent: RenderingIntent
    public var blackPointCompensation: Bool
    /// Simulate Paper Color (absolute colorimetric display leg, which also simulates black ink).
    public var simulatePaper: Bool

    public init(profile: ICCProfile, intent: RenderingIntent = .relativeColorimetric, blackPointCompensation: Bool = true,
                simulatePaper: Bool = false) {
        self.profile = profile; self.intent = intent; self.blackPointCompensation = blackPointCompensation; self.simulatePaper = simulatePaper
    }
}

/// One display and its colour profile.
public struct DisplayInfo: Sendable {
    public let displayID: UInt32
    public let name: String
    public let frame: CGRect
    public let profile: ICCProfile?
    /// Extended dynamic range headroom (1 = SDR).
    public let maximumEDRValue: Double
}

/// The monitor profiles, read from AppKit (photocraft reads them by running `osascript`).
@MainActor
public enum DisplayProfiles {
    /// The profile of `screen` (its `NSColorSpace`'s ICC data).
    public static func profile(of screen: NSScreen) -> ICCProfile? {
        if let d = screen.colorSpace?.iccProfileData { return try? ICCProfile(data: d) }
        if let cs = screen.colorSpace?.cgColorSpace { return ICCProfile(colorSpace: cs) }
        return nil
    }

    /// The main screen's profile; nil without a window server.
    public static var main: ICCProfile? { NSScreen.main.flatMap(profile(of:)) }

    /// Every display (photocraft `monitor_status` reading).
    public static func all() -> [DisplayInfo] {
        NSScreen.screens.map { s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return DisplayInfo(displayID: id, name: s.localizedName, frame: s.frame, profile: profile(of: s),
                               maximumEDRValue: Double(s.maximumPotentialExtendedDynamicRangeColorComponentValue))
        }
    }

    /// The profile of the screen a window is on (photocraft follows `NSWindow.screen`), else sRGB.
    public static func profile(for window: NSWindow) -> ICCProfile {
        window.screen.flatMap(profile(of:)) ?? BuiltinProfile.srgb.profile
    }
}
