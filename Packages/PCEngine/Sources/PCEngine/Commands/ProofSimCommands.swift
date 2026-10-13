// Port of photocraft-engine (crates/engine/src/proof_sim.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// View › Proof Setup simulations beyond a plain profile proof, and View › 32-bit Preview Options.
// Both become the canvas display LUT (`ColorCommands.canvasDisplay`).
//
// * Working Cyan/Magenta/Yellow/Black Plate: the composite is separated into the working CMYK
//   (proof profile, its intent and BPC) and only that plate is printed, shown as gray ink like
//   Photoshop's grayscale plate preview. Working CMY Plate prints cyan, magenta and yellow.
// * Legacy Macintosh RGB: the document's RGB numbers shown on a gamma-1.8 display.
// * Color Blindness (protanopia / deuteranopia): Viénot, Brettel & Mollon (1999), "Digital video
//   colourmaps for checking the legibility of displays by dichromats", Color Research &
//   Application 24(4): linear RGB → LMS, the missing cone response replaced by its projection onto
//   the dichromat's plane, back to RGB (gamut first reduced as in the paper).
// * 32-bit Preview Options: exposure (stops) and gamma applied in linear light before the display
//   transform, for 32-bit documents. Highlight Compression maps the canvas range unchanged.

import Foundation
import PCDocument
import PCFoundation
import PCPlatform

public enum ProofSimCommands: CommandModule {
    public static let name = "proof_sim"
    static let m = "proof_sim"

    /// What a proof simulates (photocraft `ProofKind`).
    public enum Kind: Hashable, Sendable {
        /// The proof profile (Working CMYK, Custom…).
        case profile
        /// One plate of the proof profile (0 cyan, 1 magenta, 2 yellow, 3 black).
        case plate(Int)
        /// Cyan, magenta and yellow plates (no black).
        case cmyPlate
        case legacyMacintoshRgb
        case protanopia
        case deuteranopia

        public var id: String {
            switch self {
            case .profile: "profile"
            case .plate(0): "workingCyanPlate"
            case .plate(1): "workingMagentaPlate"
            case .plate(2): "workingYellowPlate"
            case .plate: "workingBlackPlate"
            case .cmyPlate: "workingCmyPlate"
            case .legacyMacintoshRgb: "legacyMacintoshRgb"
            case .protanopia: "colorBlindnessProtanopia"
            case .deuteranopia: "colorBlindnessDeuteranopia"
            }
        }

        public init?(id: String) {
            switch id {
            case "profile": self = .profile
            case "workingCyanPlate": self = .plate(0)
            case "workingMagentaPlate": self = .plate(1)
            case "workingYellowPlate": self = .plate(2)
            case "workingBlackPlate": self = .plate(3)
            case "workingCmyPlate": self = .cmyPlate
            case "legacyMacintoshRgb": self = .legacyMacintoshRgb
            case "colorBlindnessProtanopia": self = .protanopia
            case "colorBlindnessDeuteranopia": self = .deuteranopia
            default: return nil
            }
        }
    }

    /// View › 32-bit Preview Options (photocraft `HdrPreview`).
    public struct HdrPreview: Hashable, Sendable, CustomStringConvertible {
        /// "exposureGamma" (false) | "highlightCompression" (true).
        public var highlightCompression = false
        /// Stops, −20…20.
        public var exposure: Float = 0
        /// 0.1…9.99.
        public var gamma: Float = 1

        public init(highlightCompression: Bool = false, exposure: Float = 0, gamma: Float = 1) {
            self.highlightCompression = highlightCompression; self.exposure = exposure; self.gamma = gamma
        }

        public var isIdentity: Bool { highlightCompression || (exposure == 0 && gamma == 1) }

        func apply(_ v: Float) -> Float {
            if isIdentity { return v }
            let lin = srgbDecode(v) * powf(2, exposure)
            return srgbEncode(min(powf(max(lin, 0), 1 / gamma), 1))
        }

        public var description: String { "\(highlightCompression)/\(exposure)/\(gamma)" }
    }

    /// Per-document 32-bit preview options.
    public enum HdrKey: StateKey { public static let defaultValue: HdrPreview? = nil }

    /// The 32-bit preview of `st`'s document when it changes the display (a 32-bit document with
    /// non-default options; photocraft `hdr_active` / `ColorState::hdr_preview`).
    public static func hdrPreview(_ st: DocState) -> HdrPreview? {
        guard st.doc.depth == .f32, let h = st.view[HdrKey.self], !h.isIdentity else { return nil }
        return h
    }

    static func srgbDecode(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4) }

    static func srgbEncode(_ v0: Float) -> Float {
        let v = min(max(v0, 0), 1)
        return v <= 0.003_130_8 ? v * 12.92 : 1.055 * powf(v, 1 / 2.4) - 0.055
    }

    /// Viénot et al. (1999): linear RGB → LMS.
    static let rgbLMS: [SIMD3<Float>] = [SIMD3(17.8824, 43.5161, 4.11935), SIMD3(3.45565, 27.1554, 3.86714), SIMD3(0.0299566, 0.184309, 1.46709)]
    /// LMS → linear RGB (the paper's values, kept verbatim).
    static let lmsRGB: [SIMD3<Float>] = [SIMD3(0.080_944_45, -0.130_504_41, 0.116_721_07), SIMD3(-0.010_248_533, 0.054_019_327, -0.113_614_71),
                                          SIMD3(-0.000_365_297, -0.004_121_614_7, 0.693_511_4)]

    static func mul(_ m: [SIMD3<Float>], _ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3((m[0] * v).sum(), (m[1] * v).sum(), (m[2] * v).sum())
    }

    /// A dichromat's view of a linear-RGB colour.
    public static func dichromat(_ rgbLin: SIMD3<Float>, protan: Bool) -> SIMD3<Float> {
        // Gamut reduction so the simulated colours stay displayable.
        let v = rgbLin * 0.992_052 + 0.003_974
        let lms = mul(rgbLMS, v)
        let (l, m, s) = (lms.x, lms.y, lms.z)
        let sim = protan ? SIMD3(2.02344 * m - 2.52581 * s, m, s) : SIMD3(l, 0.494_207 * l + 1.24827 * s, s)
        let o = mul(lmsRGB, sim)
        return SIMD3(min(max(o.x, 0), 1), min(max(o.y, 0), 1), min(max(o.z, 0), 1))
    }

    /// Batched conversion through `t` returning 3 values per pixel (1-output transforms replicated).
    static func eval3(_ t: ColorTransform, _ pts: [Float], _ count: Int) -> [Float] {
        let src: [Float]
        if t.inputChannels == 3 {
            src = pts
        } else {
            src = (0..<count).flatMap { i in Array(pts[(i * 3)..<(i * 3 + min(t.inputChannels, 3))]) + [Float](repeating: 0, count: max(t.inputChannels - 3, 0)) }
        }
        let o = t.convert(src, pixelCount: count)
        if t.outputChannels == 3 { return o }
        let oc = t.outputChannels
        return (0..<count).flatMap { i in oc == 1 ? [o[i], o[i], o[i]] : Array(o[(i * oc)..<(i * oc + 3)]) }
    }

    /// The display LUT when a simulation or the 32-bit preview applies (nil = the plain or profile
    /// proof path), `size`³ nodes, red fastest (photocraft `display_lut_with`). `includeHDR` false
    /// leaves the 32-bit preview out (the GPU canvas applies it in its shader).
    public static func displayLUT(_ s: Session, _ st: DocState, size: Int = PCPlatform.DisplayLUT.defaultSize, includeHDR: Bool = true,
                                  display: UInt32? = nil) throws -> PCPlatform.DisplayLUT? {
        let pv = st.view[ColorCommands.ProofKey.self]
        let kind = pv.view.enabled ? pv.kind : .profile
        let hdr = includeHDR ? hdrPreview(st) : nil
        if kind == .profile && hdr == nil { return nil }
        let src = ColorCommands.compositeProfile(st.doc)
        let mon = ColorCommands.monitorProfile(s, display: display)
        let srgb = BuiltinProfile.srgb.profile
        let n = max(size, 2), sc = Float(n - 1), count = n * n * n
        var pts = [Float](repeating: 0, count: count * 3)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let i = (r + g * n + b * n * n) * 3
            var v = SIMD3(Float(r) / sc, Float(g) / sc, Float(b) / sc)
            if let h = hdr { v = SIMD3(h.apply(v.x), h.apply(v.y), h.apply(v.z)) }
            pts[i] = v.x; pts[i + 1] = v.y; pts[i + 2] = v.z
        } } }
        func make(_ a: ICCProfile, _ b: ICCProfile, _ intent: RenderingIntent = .relativeColorimetric, _ bpc: Bool = true) throws -> ColorTransform {
            do { return try ColorTransform(source: a, destination: b, options: TransformOptions(intent: intent, blackPointCompensation: bpc)) } catch {
                throw ColorCommands.cmsError(error)
            }
        }
        let out: [Float]
        switch kind {
        case .profile:
            let t: ColorTransform
            if pv.view.enabled {
                do {
                    t = try ColorTransform.proof(source: src, proof: pv.profile, display: mon, intent: pv.view.intent,
                                                 blackPointCompensation: pv.view.blackPointCompensation, simulatePaper: pv.view.simulatePaper)
                } catch { throw ColorCommands.cmsError(error) }
            } else {
                t = try make(src, mon)
            }
            out = eval3(t, pts, count)
        case .plate, .cmyPlate:
            guard pv.profile.channels == 4 else { throw EngineError.other("plate previews need a CMYK proof profile") }
            let sep = try make(src, pv.profile, pv.view.intent, pv.view.blackPointCompensation)
            let print = try make(pv.profile, mon)
            let srcPts = src.channels == 3 ? pts : (0..<count).map { pts[$0 * 3] }
            let ink = sep.convert(srcPts, pixelCount: count)
            var shown = [Float](repeating: 0, count: count * 4)
            for i in 0..<count {
                if case .plate(let p) = kind {
                    shown[i * 4 + 3] = ink[i * 4 + min(max(p, 0), 3)]
                } else {
                    shown[i * 4] = ink[i * 4]; shown[i * 4 + 1] = ink[i * 4 + 1]; shown[i * 4 + 2] = ink[i * 4 + 2]
                }
            }
            out = eval3FromCMYK(print, shown, count)
        case .legacyMacintoshRgb:
            // Numbers preserved, shown with a 1.8 gamma instead of the sRGB curve.
            let t = try make(srgb, mon)
            out = eval3(t, pts.map { srgbEncode(powf(max($0, 0), 1.8)) }, count)
        case .protanopia, .deuteranopia:
            let toSRGB = try make(src, srgb)
            let toMon = try make(srgb, mon)
            let protan = kind == .protanopia
            let sr = eval3(toSRGB, pts, count)
            var sim = [Float](repeating: 0, count: count * 3)
            for i in 0..<count {
                let lin = SIMD3(srgbDecode(sr[i * 3]), srgbDecode(sr[i * 3 + 1]), srgbDecode(sr[i * 3 + 2]))
                let d = dichromat(lin, protan: protan)
                sim[i * 3] = srgbEncode(d.x); sim[i * 3 + 1] = srgbEncode(d.y); sim[i * 3 + 2] = srgbEncode(d.z)
            }
            out = eval3(toMon, sim, count)
        }
        var data = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: count)
        for i in 0..<count where i * 3 + 2 < out.count { data[i] = SIMD4(out[i * 3], out[i * 3 + 1], out[i * 3 + 2], 1) }
        return PCPlatform.DisplayLUT(size: n, data: data)
    }

    /// CMYK values (4 per pixel) through `t` to 3 values per pixel.
    static func eval3FromCMYK(_ t: ColorTransform, _ cmyk: [Float], _ count: Int) -> [Float] {
        let o = t.convert(cmyk, pixelCount: count)
        let oc = t.outputChannels
        if oc == 3 { return o }
        return (0..<count).flatMap { i in oc == 1 ? [o[i], o[i], o[i]] : Array(o[(i * oc)..<(i * oc + 3)]) }
    }

    // MARK: Commands

    static let is32: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return d.doc.depth == .f32 ? nil : "32-bit Preview Options apply to 32-bit documents"
    }

    /// Selects a simulated proof and turns Proof Colors on; plates use the working CMYK
    /// (photocraft `set_kind`).
    public static func setKind(_ s: Session, _ kind: Kind) throws -> JSONValue {
        guard let st = s.active else { throw EngineError.noDocument }
        let plates: Bool
        switch kind {
        case .plate, .cmyPlate: plates = true
        default: plates = false
        }
        let working = plates ? try ColorCommands.resolve(s, "working-cmyk", doc: st.doc, mode: .cmyk) : nil
        let pv: ColorCommands.ProofState = try s.updateActive { st in
            var pv = st.view[ColorCommands.ProofKey.self]
            if let w = working {
                pv.profile = w
                pv.view.profile = "working-cmyk"
            }
            pv.kind = kind
            pv.view.enabled = true
            st.view[ColorCommands.ProofKey.self] = pv
            return pv
        }
        return ["proof": .string(kind.id), "profile": .string(pv.profile.profileDescription), "proofColors": true]
    }

    static func preview32(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "view.thirtyTwoBitPreviewOptions"
        guard let st = s.active else { throw EngineError.noDocument }
        var h = st.view[HdrKey.self] ?? HdrPreview()
        if let mth = p["method"]?.stringValue {
            switch mth {
            case "exposureGamma", "exposureAndGamma": h.highlightCompression = false
            case "highlightCompression": h.highlightCompression = true
            default: throw EngineError.bad(cmd, "method `\(mth)` (exposureGamma|highlightCompression)")
            }
        }
        if let e = p["exposure"]?.doubleValue { h.exposure = min(max(Float(e), -20), 20) }
        if let g = p["gamma"]?.doubleValue { h.gamma = min(max(Float(g), 0.1), 9.99) }
        let set = h
        try s.updateActive { $0.view[HdrKey.self] = set }
        return ["method": .string(h.highlightCompression ? "highlightCompression" : "exposureGamma"), "exposure": .float(h.exposure), "gamma": .float(h.gamma)]
    }

    public static func register(into r: inout CommandRegistry) {
        let kinds: [(String, String)] = [
            ("view.proofSetup.workingCyanPlate", "Working Cyan Plate"),
            ("view.proofSetup.workingMagentaPlate", "Working Magenta Plate"),
            ("view.proofSetup.workingYellowPlate", "Working Yellow Plate"),
            ("view.proofSetup.workingBlackPlate", "Working Black Plate"),
            ("view.proofSetup.workingCmyPlate", "Working CMY Plate"),
            ("view.proofSetup.legacyMacintoshRgb", "Legacy Macintosh RGB"),
            ("view.proofSetup.colorBlindnessProtanopia", "Color Blindness — Protanopia-type"),
            ("view.proofSetup.colorBlindnessDeuteranopia", "Color Blindness — Deuteranopia-type"),
        ]
        for (id, label) in kinds {
            r.add(CommandSpec(id, label, menu: ["View", "Proof Setup"], params: "{} (sets the proof and turns Proof Colors on)",
                              module: m, journal: false, enabled: Pre.hasDoc) { s, _ in
                guard let kind = Kind(id: String(id.dropFirst("view.proofSetup.".count))) else { throw EngineError.unknownCommand(id) }
                return try setKind(s, kind)
            })
        }
        r.add(CommandSpec("view.thirtyTwoBitPreviewOptions", "32-bit Preview Options…", menu: ["View"],
                          params: #"{"method":"exposureGamma|highlightCompression"="exposureGamma","exposure":-20..20=0,"gamma":0.1..9.99=1}"#,
                          module: m, journal: false, enabled: is32, run: preview32))
    }
}
