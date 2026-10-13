// Port of photocraft-engine (crates/engine/src/display_color.rs: `CanvasDisplay`, `canvas_display_for`, monitor resolution), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Colour-managed canvas display: the composite shown through document profile → monitor profile,
// baked into PCPlatform's 33³ `DisplayLUT` (ColorSync) and handed to PCRender's display path
// (`CanvasRenderer.displayLUT`) as its 3D-LUT texture. Proof Colors and Gamut Warning fold into
// the same LUT. When the source and the monitor match (sRGB on sRGB, the common case) no LUT is
// applied. Results are cached per (document profile, mode, monitor, proof); the intent is relative
// colorimetric with black-point compensation, as for Photoshop's monitor display.
//
// ColorSync replaces photocraft-cms here; `ColorManagement.install()` (Session start) makes the
// same engine back PCFoundation's CMYK conversions.

import Foundation
import Metal
import PCDocument
import PCFoundation
import PCPlatform
import PCRender
import Synchronization

/// Installs PCPlatform's ColorSync converter as PCFoundation's managed CMYK path, once per process
/// (photocraft enters its managed CMYK space at start-up).
public enum ColorSetup {
    private static let installed: Bool = {
        (try? ColorManagement.install()) != nil
    }()

    /// Installs the converter if it isn't yet; true when ColorSync backs CMYK conversions.
    @discardableResult
    public static func ensureInstalled() -> Bool { installed }
}

/// How the canvas shows one document (photocraft `CanvasDisplay`).
public struct CanvasDisplay: Sendable {
    /// Profile of the composite's values (the document profile for RGB and Gray, sRGB for CMYK
    /// and Lab, whose composite PCRender returns as sRGB).
    public let source: ICCProfile
    public let monitor: ICCProfile
    /// Composite values → monitor values; nil when that is the identity.
    public let lut: PCPlatform.DisplayLUT?
    /// Changes whenever any of the above changes (UI caches).
    public let key: String

    public var isIdentity: Bool { lut == nil }

    /// The LUT as PCRender's display texture (nil = identity: no LUT pass).
    public func renderLUT(device: any MTLDevice) -> PCRender.DisplayLUT? {
        guard let lut else { return nil }
        return PCRender.DisplayLUT(device: device, size: lut.size, values: lut.data.map { SIMD3($0.x, $0.y, $0.z) })
    }

    /// Applies the display transform to a straight-alpha composite (the CPU canvas path).
    public func apply(_ buf: RGBABuffer) -> RGBABuffer {
        guard let lut else { return buf }
        var out = buf
        for i in out.px.indices {
            let p = out.px[i]
            out.px[i] = SIMD4(lut.sample(SIMD3(p.x, p.y, p.z)), p.w)
        }
        return out
    }
}

/// Proof Colors / Gamut Warning state for one document (View › Proof Setup).
public struct ProofView: Sendable, Equatable {
    public var enabled = false
    public var gamutWarning = false
    /// Proof profile spec (`"working-cmyk"`, a built-in id or an `.icc` path).
    public var profile = "working-cmyk"
    public var intent: RenderingIntent = .relativeColorimetric
    public var blackPointCompensation = true
    public var simulatePaper = false
    /// Gamut warning colour (Preferences › Transparency & Gamut).
    public var warningColor = SIMD3<Float>(0.5, 0.5, 0.5)
    public init() {}
}

/// The display-colour service: resolves monitor profiles and builds (cached) canvas displays.
public final class DisplayColor: Sendable {
    public static let shared = DisplayColor()
    private let cache = Mutex<[String: CanvasDisplay]>([:])

    public init() {}

    /// A profile from a spec: `auto`/empty (nil: let the caller decide), a built-in id, or an
    /// `.icc` path.
    public static func profile(spec: String) -> ICCProfile? {
        if spec.isEmpty || spec == "auto" { return nil }
        if let b = BuiltinProfile.from(id: spec) { return b.profile }
        return try? ICCProfile(contentsOf: URL(fileURLWithPath: spec))
    }

    /// The composite's profile for `doc` (photocraft `composite_profile`).
    public static func compositeProfile(_ doc: Document) -> ICCProfile {
        let embedded = doc.iccProfile.flatMap { try? ICCProfile(data: Data($0)) }
        switch doc.mode {
        case .rgb, .indexed, .multichannel:
            if let p = embedded, p.colorSpace == .rgb { return p }
            return BuiltinProfile.srgb.profile
        case .grayscale, .bitmap, .duotone:
            if let p = embedded, p.colorMode == .grayscale { return p }
            return BuiltinProfile.defaultProfile(for: .grayscale)
        case .cmyk, .lab:
            return BuiltinProfile.srgb.profile
        }
    }

    /// The monitor profile for Color Settings › Monitor Profile `spec` (`auto`: the main
    /// display's, else sRGB). Profiles that aren't RGB or can't be a destination fall back to sRGB.
    public static func monitorProfile(spec: String, display: ICCProfile? = nil) -> ICCProfile {
        let p = profile(spec: spec) ?? display ?? BuiltinProfile.srgb.profile
        guard p.colorSpace == .rgb, p.canBeDestination else { return BuiltinProfile.srgb.profile }
        return p
    }

    /// How the canvas shows `doc` on a display with `monitor`'s profile, through `proof` when
    /// Proof Colors or Gamut Warning is on.
    public func canvasDisplay(for doc: Document, monitor: ICCProfile, proof: ProofView? = nil, proofProfile: ICCProfile? = nil) throws -> CanvasDisplay {
        let source = DisplayColor.compositeProfile(doc)
        let proofOn = proof.map { $0.enabled || $0.gamutWarning } ?? false
        let pp = proofOn ? (proofProfile ?? BuiltinProfile.coatedCMYK.profile) : nil
        var key = "\(source.md5.base64EncodedString())|\(doc.mode)|\(monitor.md5.base64EncodedString())"
        if let p = proof, proofOn, let pp {
            key += "|proof:\(p.enabled):\(p.gamutWarning):\(pp.md5.base64EncodedString()):\(p.intent.rawValue):\(p.blackPointCompensation):\(p.simulatePaper):\(p.warningColor)"
        }
        if let d = cache.withLock({ $0[key] }) { return d }
        let lut: PCPlatform.DisplayLUT?
        do {
            if source.colorSpace == .rgb {
                let ps = proof.flatMap { p -> ProofSettings? in
                    guard p.enabled, let pp else { return nil }
                    return ProofSettings(profile: pp, intent: p.intent, blackPointCompensation: p.blackPointCompensation, simulatePaper: p.simulatePaper)
                }
                let warn: SIMD3<Float>? = (proof?.gamutWarning ?? false) ? proof?.warningColor : nil
                let gamutProof = ps ?? pp.map { ProofSettings(profile: $0) }
                lut = try PCPlatform.DisplayLUT.canvas(document: source, monitor: monitor, proof: warn != nil ? gamutProof : ps,
                                                       gamutWarningColor: warn)
            } else {
                // Gray documents: the composite repeats the gray value in R, G and B; the LUT maps
                // it through the gray profile to the monitor.
                let t = try ColorTransform(source: source, destination: monitor, options: .photoshopDefault)
                let n = PCPlatform.DisplayLUT.defaultSize
                var data = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: n * n * n)
                var grays = [Float](repeating: 0, count: n * n * n)
                for b in 0..<n { for g in 0..<n { for r in 0..<n {
                    grays[r + g * n + b * n * n] = (Float(r) + Float(g) + Float(b)) / Float(3 * (n - 1))
                } } }
                let o = t.convert(grays, pixelCount: grays.count)
                let identity = zip(grays, stride(from: 0, to: o.count, by: 3)).allSatisfy { v, i in
                    abs(o[i] - v) <= 0.5 / 255 && abs(o[i + 1] - v) <= 0.5 / 255 && abs(o[i + 2] - v) <= 0.5 / 255
                }
                if identity {
                    lut = nil
                } else {
                    for i in data.indices { data[i] = SIMD4(o[i * 3], o[i * 3 + 1], o[i * 3 + 2], 1) }
                    lut = PCPlatform.DisplayLUT(size: n, data: data)
                }
            }
        } catch {
            throw EngineError.other("colour management: \(error)")
        }
        let d = CanvasDisplay(source: source, monitor: monitor, lut: lut, key: key)
        cache.withLock { c in
            if c.count > 32 { c.removeAll() }
            c[key] = d
        }
        return d
    }

    /// Points PCRender's canvas at the right display LUT for `doc` (nil LUT = identity).
    public func install(on renderer: CanvasRenderer, doc: Document, monitor: ICCProfile, proof: ProofView? = nil, device: any MTLDevice) throws {
        renderer.displayLUT = try canvasDisplay(for: doc, monitor: monitor, proof: proof).renderLUT(device: device)
    }
}
