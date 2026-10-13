// Photoshop 27.11's blend-mode table (which modes each document mode and depth accepts), the two
// linter rules built on it, the builder's guard, and PSDTestGen's valid-by-default blend modes.

import Foundation
import Testing
@testable import PCPSD

@Suite struct BlendModeTableTests {
    static let measured: [(PSDColorMode, UInt16)] = [(.rgb, 8), (.rgb, 16), (.rgb, 32), (.grayscale, 8), (.grayscale, 16), (.grayscale, 32),
                                                      (.cmyk, 8), (.cmyk, 16), (.lab, 8), (.lab, 16)]
    static let layerModes = PSDBlendMode.all.filter { $0 != .passThrough }

    @Test func tableSizesMatchTheMeasurement() {
        let expected: [String: Int] = ["RGB 8": 27, "RGB 16": 27, "RGB 32": 15, "Grayscale 8": 21, "Grayscale 16": 21, "Grayscale 32": 9,
                                       "CMYK 8": 27, "CMYK 16": 27, "Lab 8": 19, "Lab 16": 19]
        for (mode, depth) in Self.measured {
            let layer = PSDBlendMode.allowedModes(mode: mode, depth: depth)
            let group = PSDBlendMode.allowedModes(mode: mode, depth: depth, isGroup: true)
            #expect(layer.count == expected["\(mode) \(depth)"], "\(mode) \(depth)")
            #expect(!layer.contains(.passThrough))
            #expect(group == [.passThrough] + layer, "groups: the layer set plus pass-through")
            #expect(PSDBlendMode.blendTableIsMeasured(mode: mode, depth: depth))
        }
        #expect(PSDBlendMode.allowedModes(mode: .grayscale, depth: 32) == [.normal, .dissolve, .darken, .multiply, .lighten, .linearDodge, .difference, .subtract, .divide])
        for mode in [PSDColorMode.bitmap, .indexed, .multichannel] {
            #expect(PSDBlendMode.allowedModes(mode: mode, depth: 8, isGroup: true).isEmpty)
        }
        // Unmeasured combinations are unconstrained, except pass-through on layers; unknown keys never pass.
        #expect(!PSDBlendMode.blendTableIsMeasured(mode: .duotone, depth: 8))
        #expect(PSDBlendMode.allowedModes(mode: .duotone, depth: 8) == Self.layerModes)
        #expect(!PSDBlendMode.isAllowed(.passThrough, mode: .duotone, depth: 8, isGroup: false))
        #expect(!PSDBlendMode.isAllowed(.unknown("zzzz"), mode: .rgb, depth: 8, isGroup: false))
    }

    /// The oracle's measurement file: `PCPSD_BLEND_TABLE`, default `<fixtures>/ps-oracle/blend-table.json`.
    static var measurement: URL? { Fixtures.file("PCPSD_BLEND_TABLE", default: "ps-oracle/blend-table.json") }

    /// The table matches the oracle's measurement file when it is present.
    @Test(.enabled(if: BlendModeTableTests.measurement != nil, "oracle blend-table.json not present (set PHOTOCRAFT_FIXTURES or PCPSD_BLEND_TABLE)"))
    func tableMatchesTheOracleMeasurement() throws {
        let data = try Data(contentsOf: try #require(Self.measurement))
        let names: [String: PSDBlendMode] = [
            "passThrough": .passThrough, "normal": .normal, "dissolve": .dissolve, "darken": .darken, "multiply": .multiply,
            "colorBurn": .colorBurn, "linearBurn": .linearBurn, "darkerColor": .darkerColor, "lighten": .lighten, "screen": .screen,
            "colorDodge": .colorDodge, "linearDodge": .linearDodge, "lighterColor": .lighterColor, "overlay": .overlay,
            "softLight": .softLight, "hardLight": .hardLight, "vividLight": .vividLight, "linearLight": .linearLight,
            "pinLight": .pinLight, "hardMix": .hardMix, "difference": .difference, "exclusion": .exclusion,
            "blendSubtraction": .subtract, "blendDivide": .divide, "hue": .hue, "saturation": .saturation, "color": .color,
            "luminosity": .luminosity,
        ]
        let modes: [String: PSDColorMode] = ["RGB": .rgb, "Grayscale": .grayscale, "CMYK": .cmyk, "Lab": .lab]
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let table = try #require(json["table"] as? [[String: Any]])
        var checked = 0
        for row in table {
            let mode = try #require(modes[row["mode"] as? String ?? ""])
            let depth = UInt16(try #require(row["bits"] as? Int))
            for (kind, isGroup) in [("layer", false), ("group", true)] {
                let entries = try #require(row[kind] as? [String: Bool])
                for (name, allowed) in entries {
                    let blend = try #require(names[name], "unknown name \(name)")
                    #expect(PSDBlendMode.isAllowed(blend, mode: mode, depth: depth, isGroup: isGroup) == allowed, "\(mode) \(depth) \(kind) \(name)")
                    checked += 1
                }
            }
        }
        #expect(checked == 10 * 2 * 28)
        let layerless = try #require(json["layerless"] as? [String: Any])
        #expect(Set(layerless.keys) == ["Bitmap", "Indexed", "Multichannel"])
        print("BLEND TABLE: \(checked) measured combinations match")
    }

    /// One document per mode and depth with a layer and a group per blend mode (written as given):
    /// exactly the excluded combinations are flagged, pass-through on a layer with its own rule.
    @Test func linterFlagsEachExcludedCombination() throws {
        var flagged = 0
        for (mode, depth) in Self.measured {
            var b = PSDBuilder(width: 2, height: 2, colorMode: mode, depth: depth)
            b.blendModePolicy = .keep
            let cc = mode.colorChannels ?? 3
            for m in PSDBlendMode.all {
                var s = PSDLayerSpec(name: "layer \(m)", left: 0, top: 0, width: 1, height: 1,
                                     pixels: depth == 8 ? .u8([UInt8](repeating: 9, count: cc + 1)) : depth == 16 ? .u16([UInt16](repeating: 9, count: cc + 1)) : .f32([Float](repeating: 0.5, count: cc + 1)))
                s.blendMode = m
                b.pushLayer(s)
                var g = PSDGroupSpec(name: "group \(m)")
                g.blendMode = m
                b.beginGroup(g)
                try b.endGroup()
            }
            let f = try PSDFile(data: b.build().serialized())
            let issues = f.compatibilityIssues()
            for (i, rec) in f.layers.enumerated() where rec.sectionType != .boundingDivider {
                let isGroup = rec.sectionType != .other
                let rules = issues.filter { $0.layerIndex == i }.compactMap(\.rule)
                let blend = rec.sectionDivider?.blendMode ?? rec.blendMode
                if blend == .passThrough, !isGroup {
                    #expect(rules == [.passThroughOnNonGroup], "\(mode) \(depth) \(rec.displayName)")
                } else if PSDBlendMode.isAllowed(blend, mode: mode, depth: depth, isGroup: isGroup) {
                    #expect(rules.isEmpty, "\(mode) \(depth) \(rec.displayName): \(rules)")
                } else {
                    #expect(rules == [.blendModeInvalidForDocument], "\(mode) \(depth) \(rec.displayName): \(rules)")
                }
                flagged += rules.count
            }
            #expect(issues.contains { $0.rule == .passThroughOnNonGroup && $0.message.hasPrefix("PHOTOSHOP RAISES A MODAL") })
            if mode == .rgb && depth != 32 || mode == .cmyk {
                #expect(!issues.contains { $0.rule == .blendModeInvalidForDocument })
            } else {
                #expect(issues.contains { $0.rule == .blendModeInvalidForDocument && $0.message.hasPrefix("PHOTOSHOP REFUSES THE FILE") })
            }
        }
        // Excluded layer combinations: 12 + 6 + 6 + 18 + 8 + 8, groups the same, plus one pass-through layer per document.
        #expect(flagged == 2 * (12 + 6 + 6 + 18 + 8 + 8) + 10)
    }

    @Test func passThroughOnPixelLayerIsFlagged() throws {
        var f = try PSDFile(data: {
            var b = PSDBuilder(width: 2, height: 2)
            b.pushLayer(PSDLayerSpec(name: "px", left: 0, top: 0, width: 1, height: 1, pixels: .u8([1, 2, 3, 255])))
            return try b.serialized()
        }())
        #expect(f.compatibilityIssues().isEmpty)
        f.layers[0].blendMode = .passThrough
        let issues = f.compatibilityIssues()
        #expect(issues.count == 1 && issues[0].rule == .passThroughOnNonGroup && issues[0].layerIndex == 0 && issues[0].severity == .error)
    }

    @Test func builderSubstitutesRefusesOrKeeps() throws {
        func doc(_ policy: PSDBuilder.BlendModePolicy) -> PSDBuilder {
            var b = PSDBuilder(width: 2, height: 2, depth: 32)
            b.blendModePolicy = policy
            for m in [PSDBlendMode.screen, .overlay, .passThrough, .multiply] {
                var s = PSDLayerSpec(name: "\(m)", left: 0, top: 0, width: 1, height: 1, pixels: .f32([0.5, 0.5, 0.5, 1]))
                s.blendMode = m
                b.pushLayer(s)
            }
            var g = PSDGroupSpec(name: "g")
            g.blendMode = .colorDodge
            b.beginGroup(g)
            try? b.endGroup()
            return b
        }
        let built = try doc(.substituteNearest).build()
        #expect(built.layers.map(\.blendMode) == [.linearDodge, .normal, .normal, .multiply, .normal, .linearDodge])
        #expect(built.layers.last?.sectionDivider?.blendMode == .linearDodge)
        #expect(built.warnings.count == 4)
        #expect(built.warnings.first?.contains("wrote lddg") == true)
        #expect(built.compatibilityIssues().isEmpty)
        #expect(throws: PSDError.self) { try doc(.refuse).build() }
        let kept = try doc(.keep).build()
        #expect(kept.layers.prefix(4).map(\.blendMode) == [.screen, .overlay, .passThrough, .multiply])
        #expect(kept.warnings.isEmpty)
        #expect(kept.compatibilityIssues().filter { $0.rule != nil }.count == 4)
    }

    @Test func nearestAllowedIsAlwaysAllowed() {
        for (mode, depth) in Self.measured {
            for isGroup in [false, true] {
                for m in PSDBlendMode.all + [.unknown("zzzz")] {
                    let n = PSDBlendMode.nearestAllowed(m, mode: mode, depth: depth, isGroup: isGroup)
                    #expect(PSDBlendMode.isAllowed(n, mode: mode, depth: depth, isGroup: isGroup), "\(m) → \(n) in \(mode) \(depth)")
                    if PSDBlendMode.isAllowed(m, mode: mode, depth: depth, isGroup: isGroup) { #expect(n == m) }
                }
            }
        }
        #expect(PSDBlendMode.nearestAllowed(.darken, mode: .lab, depth: 8, isGroup: false) == .darkerColor)
        #expect(PSDBlendMode.nearestAllowed(.exclusion, mode: .grayscale, depth: 32, isGroup: false) == .difference)
        #expect(PSDBlendMode.nearestAllowed(.hue, mode: .grayscale, depth: 8, isGroup: false) == .normal)
    }

    @Test func testGenIsValidByDefaultAndFuzzesOnRequest() throws {
        var fuzzFlagged = 0
        for (valid, fuzz) in zip(PSDTestGen.allCases(), PSDTestGen.allCases(invalidBlendModes: true)) {
            let blendRules: Set<PSDCompatibilityRule> = [.blendModeInvalidForDocument, .passThroughOnNonGroup]
            #expect(!valid.file.compatibilityIssues().contains { $0.rule.map(blendRules.contains) ?? false }, "\(valid.name)")
            #expect(valid.file.layers.count == fuzz.file.layers.count)
            fuzzFlagged += fuzz.file.compatibilityIssues().filter { $0.rule.map(blendRules.contains) ?? false }.count
            let bytes = try fuzz.file.serialized()
            #expect(try PSDFile(data: bytes).serialized() == bytes, "\(fuzz.name)")
            #expect(try PSDFile(data: bytes) == fuzz.file)
        }
        #expect(fuzzFlagged > 0)
    }

    @Test(.enabled(if: Corpus.directory != nil, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)"))
    func corpusHasNoFalsePositives() throws {
        var records = 0
        for url in Corpus.files {
            let f = try PSDFile(contentsOf: url)
            records += f.layers.count
            let rules = f.compatibilityIssues().compactMap(\.rule).filter { $0 == .blendModeInvalidForDocument || $0 == .passThroughOnNonGroup }
            #expect(rules.isEmpty, "\(url.lastPathComponent): \(rules)")
        }
        print("BLEND corpus: \(Corpus.files.count) files, \(records) records, 0 blend-mode issues")
    }
}
