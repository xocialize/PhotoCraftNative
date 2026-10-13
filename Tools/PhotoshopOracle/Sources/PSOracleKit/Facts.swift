// One vocabulary for "what a reader sees in a PSD": document facts and per-record layer facts, built
// either from Photoshop's report (the `info` JSON) or from PCPSD, and compared field by field.
// Records are listed bottom to top including group-end markers — the order of both the PSD layer
// records and Photoshop's Action Manager layer indices.

import ColorSync
import Foundation
import PCPSD

public struct DocFacts: Codable, Equatable, Sendable {
    public var mode: String
    public var bits: Int
    public var width: Int
    public var height: Int
    public var resolution: Double?
    public var profile: String?
    public var layerCount: Int
}

public struct LayerFacts: Codable, Equatable, Sendable {
    public var name: String
    /// pixel, group, groupEnd, text, smartObject, shape, fill:solid|gradient|pattern,
    /// adjustment:<PSD key>, video, 3d, artboard.
    public var kind: String
    public var visible: Bool
    /// The PSD blend-mode key (`norm`, `mul `, `pass`, …).
    public var blendMode: String
    public var opacity: Int
    public var fillOpacity: Int
    public var clipped: Bool
    public var userMask: Bool
    public var vectorMask: Bool
    /// Present effects as `type` or `type(off)`, sorted.
    public var effects: [String]
    public var text: String?
    public var smartFilters: Int?
    /// Photoshop's Background layer (Photoshop's side only).
    public var isBackground = false
}

// MARK: - Photoshop's report

public enum PhotoshopFacts {
    static let blendKeys: [String: String] = [
        "normal": "norm", "dissolve": "diss", "darken": "dark", "multiply": "mul ", "colorBurn": "idiv", "linearBurn": "lbrn",
        "darkerColor": "dkCl", "lighten": "lite", "screen": "scrn", "colorDodge": "div ", "linearDodge": "lddg", "lighterColor": "lgCl",
        "overlay": "over", "softLight": "sLit", "hardLight": "hLit", "vividLight": "vLit", "linearLight": "lLit", "pinLight": "pLit",
        "hardMix": "hMix", "difference": "diff", "exclusion": "smud", "blendSubtraction": "fsub", "blendDivide": "fdiv", "hue": "hue ",
        "saturation": "sat ", "color": "colr", "luminosity": "lum ", "passThrough": "pass",
    ]

    /// Photoshop adjustment class (stringID) → the PSD block key.
    public static let adjustmentKeys: [String: String] = [
        "levels": "levl", "curves": "curv", "hueSaturation": "hue2", "colorBalance": "blnc", "brightnessEvent": "brit",
        "blackAndWhite": "blwh", "channelMixer": "mixr", "exposure": "expA", "gradientMapClass": "grdm", "invert": "nvrt",
        "photoFilter": "phfl", "posterization": "post", "selectiveColor": "selc", "thresholdClassEvent": "thrs", "vibrance": "vibA",
        "colorLookup": "clrL",
    ]

    static let effectNames: [String: String] = [
        "dropShadow": "dropShadow", "dropShadowMulti": "dropShadow", "innerShadow": "innerShadow", "innerShadowMulti": "innerShadow",
        "outerGlow": "outerGlow", "innerGlow": "innerGlow", "bevelEmboss": "bevelEmboss", "chromeFX": "satin",
        "solidFill": "colorOverlay", "solidFillMulti": "colorOverlay", "gradientFill": "gradientOverlay", "gradientFillMulti": "gradientOverlay",
        "patternFill": "patternOverlay", "frameFX": "stroke", "frameFXMulti": "stroke",
    ]

    public static func doc(_ j: [String: Any]) -> DocFacts {
        DocFacts(mode: j["mode"] as? String ?? "?", bits: j["bits"] as? Int ?? 0, width: Int(j["width"] as? Double ?? 0),
                 height: Int(j["height"] as? Double ?? 0), resolution: j["resolution"] as? Double, profile: j["profile"] as? String,
                 layerCount: (j["layers"] as? [Any])?.count ?? 0)
    }

    public static func layers(_ j: [String: Any]) -> [LayerFacts] {
        ((j["layers"] as? [[String: Any]]) ?? []).map(layer)
    }

    public static func layer(_ l: [String: Any]) -> LayerFacts {
        var kind = l["kind"] as? String ?? "?"
        switch kind {
        case "adjustment":
            let cls = l["adjustment"] as? String ?? "?"
            kind = "adjustment:" + (adjustmentKeys[cls] ?? cls)
        case "solidFill": kind = "fill:solid"
        case "gradientFill": kind = "fill:gradient"
        case "patternFill": kind = "fill:pattern"
        default: break
        }
        let effects = ((l["effects"] as? [[String: Any]]) ?? []).filter { $0["present"] as? Bool ?? true }.map { e -> String in
            let t = effectNames[e["type"] as? String ?? ""] ?? (e["type"] as? String ?? "?")
            return (e["enabled"] as? Bool ?? true) ? t : t + "(off)"
        }.sorted()
        let text = (l["text"] as? [String: Any])?["contents"] as? String
        let filters = ((l["smartObject"] as? [String: Any])?["filters"] as? [Any])?.count
        return LayerFacts(name: l["name"] as? String ?? "", kind: kind, visible: l["visible"] as? Bool ?? true,
                          blendMode: blendKeys[l["blendMode"] as? String ?? ""] ?? (l["blendMode"] as? String ?? "?"),
                          opacity: l["opacity"] as? Int ?? -1, fillOpacity: l["fillOpacity"] as? Int ?? -1, clipped: l["clipped"] as? Bool ?? false,
                          userMask: l["userMask"] is [String: Any], vectorMask: l["vectorMask"] is [String: Any], effects: effects,
                          text: text.map(normalizeText), smartFilters: filters, isBackground: l["background"] as? Bool ?? false)
    }

    static func normalizeText(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{3}", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0\n"))
    }
}

// MARK: - PCPSD

public enum PCPSDFacts {
    public static func modeName(_ m: PSDColorMode) -> String {
        switch m {
        case .bitmap: "Bitmap"
        case .grayscale: "Grayscale"
        case .indexed: "Indexed"
        case .rgb: "RGB"
        case .cmyk: "CMYK"
        case .multichannel: "Multichannel"
        case .duotone: "Duotone"
        case .lab: "Lab"
        case let .unknown(c): "mode\(c)"
        }
    }

    public static func profileName(_ icc: Data?) -> String? {
        guard let icc, !icc.isEmpty, let p = ColorSyncProfileCreate(icc as CFData, nil)?.takeRetainedValue() else { return nil }
        return ColorSyncProfileCopyDescriptionString(p)?.takeRetainedValue() as String?
    }

    public static func doc(_ f: PSDFile) -> DocFacts {
        DocFacts(mode: modeName(f.header.colorMode), bits: Int(f.header.depth), width: Int(f.header.width), height: Int(f.header.height),
                 resolution: f.resolution.map(\.hRes), profile: profileName(f.iccProfile), layerCount: f.layers.count)
    }

    static let effectNames: [String: String] = [
        "DrSh": "dropShadow", "dropShadowMulti": "dropShadow", "IrSh": "innerShadow", "innerShadowMulti": "innerShadow",
        "OrGl": "outerGlow", "IrGl": "innerGlow", "ebbl": "bevelEmboss", "ChFX": "satin", "SoFi": "colorOverlay", "Sofi": "colorOverlay",
        "solidFillMulti": "colorOverlay", "GrFl": "gradientOverlay", "gradientFillMulti": "gradientOverlay", "patternFill": "patternOverlay",
        "FrFX": "stroke", "frameFXMulti": "stroke",
    ]

    public static func layers(_ f: PSDFile) -> [LayerFacts] { f.layers.map(layer) }

    public static func layer(_ r: PSDLayerRecord) -> LayerFacts {
        var kind: String
        switch r.kind {
        case .pixel: kind = "pixel"
        case .group: kind = "group"
        case .groupEnd: kind = "groupEnd"
        case .text: kind = "text"
        case .smartObject: kind = "smartObject"
        case .shape: kind = "shape"
        case .artboard: kind = "artboard"
        case .fill:
            kind = r.block("SoCo") != nil ? "fill:solid" : r.block("GdFl") != nil ? "fill:gradient" : "fill:pattern"
        case .adjustment:
            let key = r.blocks.first { PSDAdjustment.keys.contains($0.key) }?.key.string ?? "?"
            kind = "adjustment:" + (key == "hue " ? "hue2" : key)
        }
        var blend = r.blendMode.key.string
        if r.kind == .group, let b = r.sectionDivider?.blendMode { blend = b.key.string }
        var effects: [String] = []
        if let fx = r.objectEffects {
            effects = fx.effects.filter(\.isPresent).map { e in
                let t = effectNames[e.key] ?? e.key
                return e.isEnabled ? t : t + "(off)"
            }.sorted()
        }
        // A -2 channel whose mask record "came from rendering" is the vector mask's rasterisation, not a
        // user mask; with both masks the user mask is the real (-3) one.
        let mask = r.layerMask
        let userMask = mask.map { m in r.channel(PSDChannelID.realUserMask) != nil || (r.channel(PSDChannelID.userMask) != nil && !m.cameFromRendering) } ?? false
        // A `vmsk` with no path records is no vector mask to Photoshop (C′: a 12-byte, path-less
        // block reads back without one).
        let vectorMask = r.vectorMask.map { !$0.path.records.isEmpty } ?? false
        return LayerFacts(name: r.displayName, kind: kind, visible: r.isVisible, blendMode: blend, opacity: Int(r.opacity),
                          fillOpacity: Int(r.fillOpacity), clipped: r.clipping != 0, userMask: userMask, vectorMask: vectorMask,
                          effects: effects, text: r.typeTool?.string.map(PhotoshopFacts.normalizeText), smartFilters: nil)
    }
}

// MARK: - Comparison

public struct FactMismatch: Codable, Sendable, CustomStringConvertible {
    public var record: Int?
    public var field: String
    public var photoshop: String
    public var pcpsd: String

    public var description: String {
        (record.map { "#\($0) " } ?? "") + "\(field): Photoshop \(photoshop) vs PCPSD \(pcpsd)"
    }
}

public enum FactComparison {
    public static func compare(docPS: DocFacts, docOurs: DocFacts, layersPS: [LayerFacts], layersOurs: [LayerFacts]) -> [FactMismatch] {
        var out: [FactMismatch] = []
        func doc(_ f: String, _ a: String, _ b: String) { if a != b { out.append(FactMismatch(record: nil, field: f, photoshop: a, pcpsd: b)) } }
        doc("mode", docPS.mode, docOurs.mode)
        doc("bits", "\(docPS.bits)", "\(docOurs.bits)")
        doc("size", "\(docPS.width)x\(docPS.height)", "\(docOurs.width)x\(docOurs.height)")
        if let a = docPS.resolution, let b = docOurs.resolution, abs(a - b) > 0.01 { doc("resolution", "\(a)", "\(b)") }
        // Photoshop names an untagged document's working profile only when it has one; compare when
        // both sides name a profile.
        if let a = docPS.profile, let b = docOurs.profile { doc("profile", a, b) }
        // A file without layer records opens as a single Background made from the merged image.
        if layersOurs.isEmpty, layersPS.count == 1, layersPS[0].kind == "pixel", layersPS[0].isBackground { return out }
        doc("layer records", "\(layersPS.count)", "\(layersOurs.count)")
        guard layersPS.count == layersOurs.count else { return out }
        for (i, (p, o)) in zip(layersPS, layersOurs).enumerated() {
            func f(_ name: String, _ a: String, _ b: String) { if a != b { out.append(FactMismatch(record: i, field: name, photoshop: a, pcpsd: b)) } }
            f("kind", p.kind, o.kind)
            f("name", p.name, o.name)
            if p.kind == "groupEnd" || o.kind == "groupEnd" { continue }
            f("visible", "\(p.visible)", "\(o.visible)")
            f("blendMode", p.blendMode, o.blendMode)
            f("opacity", "\(p.opacity)", "\(o.opacity)")
            f("fillOpacity", "\(p.fillOpacity)", "\(o.fillOpacity)")
            f("clipped", "\(p.clipped)", "\(o.clipped)")
            f("userMask", "\(p.userMask)", "\(o.userMask)")
            f("vectorMask", "\(p.vectorMask)", "\(o.vectorMask)")
            f("effects", p.effects.joined(separator: ","), o.effects.joined(separator: ","))
            f("text", p.text ?? "-", o.text ?? "-")
        }
        return out
    }
}
