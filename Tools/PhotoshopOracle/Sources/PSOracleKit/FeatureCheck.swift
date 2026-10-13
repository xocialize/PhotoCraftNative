// Checks a corpus file's feature tags against Photoshop's own reading of the saved file (the `info`
// JSON), so the manifest says which claimed features Photoshop confirms the file really contains.
// A tag maps to true (confirmed), false (claimed but not seen), or nil (not visible in Photoshop's
// report, e.g. text style runs or a smart object's transform). Photoshop's Action Manager layer
// descriptor does not report knockout, blend-if or the advanced-blending flags at all; for those,
// `verifyInFile` reads the Photoshop-written blocks instead.

import Foundation
import PCPSD

public enum FeatureCheck {
    static let adjustmentClasses: [String: String] = [
        "levels": "levels", "curves": "curves", "brightnessContrast": "brightnessEvent", "hueSaturation": "hueSaturation", "hue2": "hueSaturation",
        "colorBalance": "colorBalance", "blackAndWhite": "blackAndWhite", "channelMixer": "channelMixer", "exposure": "exposure",
        "gradientMap": "gradientMapClass", "invert": "invert", "photoFilter": "photoFilter", "posterize": "posterization",
        "selectiveColor": "selectiveColor", "threshold": "thresholdClassEvent", "vibrance": "vibrance", "colorLookup": "colorLookup",
    ]

    static let effectTypes: [String: [String]] = [
        "dropShadow": ["dropShadow", "dropShadowMulti"], "innerShadow": ["innerShadow", "innerShadowMulti"], "outerGlow": ["outerGlow"],
        "innerGlow": ["innerGlow"], "bevelEmboss": ["bevelEmboss"], "satin": ["chromeFX"], "colorOverlay": ["solidFill", "solidFillMulti"],
        "gradientOverlay": ["gradientFill", "gradientFillMulti"], "patternOverlay": ["patternFill"], "stroke": ["frameFX", "frameFXMulti"],
    ]

    public static func verify(_ features: [String], info: [String: Any], fileExtension: String) -> [String: Bool?] {
        let layers = (info["layers"] as? [[String: Any]]) ?? []
        let groups = layers.filter { $0["kind"] as? String == "group" }
        let groupIDs = Set(groups.compactMap { $0["id"] as? Int })
        func any(_ p: ([String: Any]) -> Bool) -> Bool { layers.contains(where: p) }
        func effects(_ l: [String: Any]) -> [[String: Any]] { ((l["effects"] as? [[String: Any]]) ?? []).filter { $0["present"] as? Bool ?? true } }
        func mask(_ l: [String: Any], _ k: String) -> [String: Any]? { l[k] as? [String: Any] }
        let channels = (info["channels"] as? [[String: Any]]) ?? []
        var out: [String: Bool?] = [:]
        for f in features {
            let parts = f.split(separator: ":", maxSplits: 1).map(String.init)
            let key = parts[0], value = parts.count > 1 ? parts[1] : ""
            var r: Bool?
            switch key {
            case "mode": r = info["mode"] as? String == value
            case "depth": r = "\(info["bits"] ?? "")" == value
            case "format": r = fileExtension.lowercased() == value
            case "layers": r = layers.count > 1
            case "background-only": r = layers.count == 1 && (layers.first?["background"] as? Bool ?? false)
            case "no-background": r = !(info["hasBackground"] as? Bool ?? true)
            case "opacity": r = any { ($0["opacity"] as? Int ?? 255) < 255 }
            case "fill-opacity": r = any { ($0["fillOpacity"] as? Int ?? 255) < 255 }
            case "visibility": r = any { !($0["visible"] as? Bool ?? true) }
            case "clipping": r = any { $0["clipped"] as? Bool ?? false }
            case "blend":
                if value == "all" { r = Set(layers.compactMap { $0["blendMode"] as? String }).count >= 10 } else { r = any { $0["blendMode"] as? String == value } }
            case "group":
                switch value {
                case "": r = !groups.isEmpty
                case "pass-through": r = groups.contains { $0["blendMode"] as? String == "passThrough" }
                case "normal": r = groups.contains { $0["blendMode"] as? String != "passThrough" }
                case "nested": r = groups.contains { groupIDs.contains($0["parentLayerID"] as? Int ?? -1) }
                case "opacity": r = groups.contains { ($0["opacity"] as? Int ?? 255) < 255 }
                case "hidden-child": r = any { !($0["visible"] as? Bool ?? true) }
                default: r = nil
                }
            case "mask":
                switch value {
                case "raster": r = any { mask($0, "userMask") != nil }
                case "vector": r = any { mask($0, "vectorMask") != nil }
                case "density": r = any { (mask($0, "userMask")?["density"] as? Int ?? 255) < 255 || (mask($0, "vectorMask")?["density"] as? Int ?? 255) < 255 }
                case "feather": r = any { (mask($0, "userMask")?["feather"] as? Double ?? 0) > 0 || (mask($0, "vectorMask")?["feather"] as? Double ?? 0) > 0 }
                case "disabled": r = any { mask($0, "userMask")?["enabled"] as? Bool == false }
                case "on-group": r = groups.contains { mask($0, "userMask") != nil }
                default: r = nil
                }
            case "adjustment":
                if value == "stack" { r = layers.filter { $0["kind"] as? String == "adjustment" }.count >= 2 } else {
                    let cls = adjustmentClasses[value] ?? value
                    r = any { $0["adjustment"] as? String == cls }
                }
            case "fill":
                let k = ["solid": "solidFill", "gradient": "gradientFill", "pattern": "patternFill"][value] ?? value
                r = any { $0["kind"] as? String == k }
            case "effect":
                switch value {
                case "disabled": r = any { effects($0).contains { $0["enabled"] as? Bool == false } }
                case "hidden-all": r = any { $0["effects"] != nil && $0["effectsVisible"] as? Bool == false }
                case "on-group": r = groups.contains { !effects($0).isEmpty }
                case "multi": r = any { l in Dictionary(grouping: effects(l), by: { $0["type"] as? String ?? "" }).values.contains { $0.count > 1 } }
                default:
                    let types = effectTypes[value] ?? [value]
                    r = any { effects($0).contains { types.contains($0["type"] as? String ?? "") && ($0["enabled"] as? Bool ?? true) } }
                }
            case "knockout":
                r = any { $0["knockout"] != nil } ? any { ($0["knockout"] as? String).map { $0.lowercased().contains(value == "shallow" ? "sh" : "deep") } ?? false } : nil
            case "blend-if":
                func nonDefault(_ l: [String: Any]) -> [[Int]] {
                    ((l["blendIf"] as? [[Int]]) ?? []).filter { $0 != [0, 0, 255, 255, 0, 0, 255, 255] }
                }
                guard any({ $0["blendIf"] != nil }) else { r = nil; break }
                switch value {
                case "", "gray": r = any { !nonDefault($0).isEmpty }
                case "channels": r = any { nonDefault($0).count >= 2 || ((($0["blendIf"] as? [[Int]]) ?? []).dropFirst().contains { $0 != [0, 0, 255, 255, 0, 0, 255, 255] }) }
                case "split": r = any { nonDefault($0).contains { $0[0] != $0[1] || $0[2] != $0[3] || $0[4] != $0[5] || $0[6] != $0[7] } }
                default: r = nil
                }
            case "advanced" where !["channels"].contains(value) && !any({ $0["blendInterior"] != nil || $0["blendClipped"] != nil }):
                r = nil
            case "advanced":
                switch value {
                case "channels": r = any { ($0["channelRestrictions"] as? Int ?? 99) < channels.filter { $0["kind"] as? String == "COMPONENT" }.count }
                case "blendClipped": r = any { $0["blendClipped"] as? Bool == false }
                case "blendInterior": r = any { $0["blendInterior"] as? Bool == true }
                case "transparencyShapes": r = any { $0["transparencyShapesLayer"] as? Bool == false }
                case "layerMaskAsGlobal": r = any { $0["layerMaskAsGlobalMask"] as? Bool == true }
                default: r = nil
                }
            case "brst": r = any { ($0["channelRestrictions"] as? Int ?? 99) < channels.filter { $0["kind"] as? String == "COMPONENT" }.count }
            case "text":
                func text(_ l: [String: Any]) -> [String: Any]? { l["text"] as? [String: Any] }
                switch value {
                case "point": r = any { text($0)?["shape"] as? String == "paint" }
                case "paragraph": r = any { text($0)?["shape"] as? String == "box" }
                case "warp": r = any { (text($0)?["warp"] as? String).map { $0 != "warpNone" } ?? false }
                default: r = nil
                }
            case "shape":
                r = value.isEmpty ? any { $0["kind"] as? String == "shape" } : nil
            case "smart-object":
                r = value == "embedded" ? any { (($0["smartObject"] as? [String: Any])?["linked"] as? Bool) == false } : nil
            case "smart-filter":
                if value == "mask" { r = any { $0["filterMask"] as? Bool == true } } else {
                    r = any { ((($0["smartObject"] as? [String: Any])?["filters"] as? [[String: Any]]) ?? []).contains { $0["filter"] as? String == value } }
                }
            case "channel":
                let kind = value == "spot" ? "SPOTCOLOR" : "MASKEDAREA|SELECTEDAREA"
                r = channels.contains { kind.split(separator: "|").contains(Substring($0["kind"] as? String ?? "")) }
            default: r = nil
            }
            out[f] = r
        }
        return out
    }

    /// Evidence in the file itself (Photoshop-written blocks read by PCPSD) for the tags Photoshop's
    /// report cannot show.
    public static func verifyInFile(_ features: [String], file f: PSDFile) -> [String: Bool] {
        func isFull(_ r: PSDBlendingRanges.Range) -> Bool { r.source == [0, 0, 255, 255] && r.destination == [0, 0, 255, 255] }
        func typed(_ r: PSDLayerRecord, _ k: FourCC) -> PSDBlockData? { (try? r.block(k)?.parsed()) ?? nil }
        func anyRecord(_ p: (PSDLayerRecord) -> Bool) -> Bool { f.layers.contains(where: p) }
        var out: [String: Bool] = [:]
        for t in features {
            let parts = t.split(separator: ":", maxSplits: 1).map(String.init)
            let key = parts[0], value = parts.count > 1 ? parts[1] : ""
            switch (key, value) {
            case ("knockout", _):
                let want: UInt8 = value == "deep" ? 2 : 1
                out[t] = anyRecord { if case let .knockout(k)? = typed($0, "knko") { k == want } else { false } }
            case ("blend-if", ""):
                out[t] = anyRecord { $0.blendingRanges.ranges.contains { !isFull($0) } }
            case ("blend-if", "gray"):
                out[t] = anyRecord { $0.blendingRanges.ranges.first.map { !isFull($0) } ?? false }
            case ("blend-if", "channels"):
                out[t] = anyRecord { $0.blendingRanges.ranges.dropFirst().contains { !isFull($0) } }
            case ("blend-if", "split"):
                out[t] = anyRecord { $0.blendingRanges.ranges.contains { $0.source[0] != $0.source[1] || $0.source[2] != $0.source[3] || $0.destination[0] != $0.destination[1] || $0.destination[2] != $0.destination[3] } }
            case ("advanced", "blendClipped"):
                out[t] = anyRecord { typed($0, "clbl") == .blendClippedAsGroup(false) }
            case ("advanced", "blendInterior"):
                out[t] = anyRecord { typed($0, "infx") == .blendInteriorElements(true) }
            case ("advanced", "transparencyShapes"):
                out[t] = anyRecord { typed($0, "tsly") == .transparencyShapes(false) }
            case ("advanced", "layerMaskAsGlobal"):
                out[t] = anyRecord { typed($0, "lmgm") == .layerMaskHidesEffects(true) }
            case ("advanced", "channels"), ("brst", _):
                out[t] = anyRecord { !$0.blendingRestrictions.isEmpty }
            case ("mask", "feather"):
                out[t] = anyRecord { r in r.layerMask?.parameters.map { ($0.userFeather ?? 0) > 0 || ($0.vectorFeather ?? 0) > 0 } ?? false }
            case ("effect", "hidden-all"):
                out[t] = anyRecord { $0.objectEffects.map { !$0.isEnabled } ?? false }
            default: break
            }
        }
        return out
    }
}
