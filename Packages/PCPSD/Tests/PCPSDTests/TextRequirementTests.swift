// Type-layer EngineData structures Photoshop requires (Photoshop 27.11 crashes on open without the
// first group and refuses the file without the font-set fields): the public gap report and the
// linter rule, against the Photoshop-authored corpus and synthetic EngineData.

import Foundation
import Testing
@testable import PCPSD

@Suite struct TextRequirementTests {
    /// The smallest EngineData carrying every structure Photoshop requires.
    static let complete = """
    <<
    /EngineDict << /Editor << /Text (abc) >>
      /ParagraphRun << /RunArray [ << /ParagraphSheet << /DefaultStyleSheet 0 /Properties << >> >> >> ] /RunLengthArray [ 4 ] >>
      /AntiAlias 4 /UseFractionalGlyphWidths true
      /Rendered << /Version 1 /Shapes << /WritingDirection 0 /Children [ << /ShapeType 0 /Procession 0
        /Lines << /WritingDirection 0 /Children [ ] >>
        /Cookie << /Photoshop << /ShapeType 0 /Base << /ShapeType 0 /TransformPoint0 [ 1.0 0.0 ] /TransformPoint1 [ 0.0 1.0 ] /TransformPoint2 [ 0.0 0.0 ] >> >> >>
      >> ] >> >>
    >>
    /ResourceDict << /FontSet [ << /Name (Myriad) /Script 0 /FontType 0 /Synthetic 0 >> ] >>
    /DocumentResources << /FontSet [ << /Name (Myriad) /Script 0 /FontType 0 /Synthetic 0 >> ] >>
    >>
    """

    /// What a minimal third-party writer emits: text and a font, nothing Photoshop lays out.
    static let minimal = "<< /EngineDict << /Editor << /Text (abc) >> >> /ResourceDict << /FontSet [ << /Name (Myriad) >> ] >> >>"

    static func engine(_ s: String) throws -> PSDEngineData { try PSDEngineData.parse(Data(s.utf8)) }

    static func typeLayerFile(_ engineText: String) throws -> PSDFile {
        let text = PSDDescriptor(classID: "TxLr")
            .with("Txt ", .text(.nulTerminated("abc")))
            .with("EngineData", .rawData(Data(engineText.utf8)))
        let tysh = PSDTaggedBlock(key: "TySh", data: PSDTypeTool(transform: [1, 0, 0, 1, 0, 0], text: text).serialized())
        var b = PSDBuilder(width: 4, height: 4)
        var spec = PSDLayerSpec(name: "abc", left: 0, top: 0, width: 1, height: 1, pixels: .u8([0, 0, 0, 255]))
        spec.extraBlocks = [tysh]
        b.pushLayer(spec)
        return try PSDFile(data: b.build().serialized())
    }

    @Test func completeEngineDataHasNoGaps() throws {
        #expect(try Self.engine(Self.complete).missingPhotoshopStructures() == [])
    }

    @Test func minimalEngineDataIsFlagged() throws {
        let gaps = try Self.engine(Self.minimal).photoshopStructureGaps()
        let crashing = gaps.filter { $0.consequence == .crashesPhotoshop }.map(\.path)
        #expect(crashing == [
            "DocumentResources", "EngineDict.Rendered.Version", "EngineDict.Rendered.Shapes.WritingDirection",
            "EngineDict.Rendered.Shapes.Children", "EngineDict.AntiAlias", "EngineDict.UseFractionalGlyphWidths",
            "EngineDict.ParagraphRun.RunArray[].ParagraphSheet.DefaultStyleSheet",
        ])
        #expect(gaps.filter { $0.consequence == .photoshopRefusesFile }.map(\.path) == ["ResourceDict.FontSet[0].FontType", "ResourceDict.FontSet[0].Synthetic"])
    }

    /// Removing any one required structure from the complete document is reported at its path.
    @Test func eachStructureIsRequired() throws {
        let cases: [(String, String, PSDEngineDataGap.Consequence)] = [
            ("/DocumentResources << /FontSet [ << /Name (Myriad) /Script 0 /FontType 0 /Synthetic 0 >> ] >>", "DocumentResources", .crashesPhotoshop),
            ("/Version 1 ", "EngineDict.Rendered.Version", .crashesPhotoshop),
            ("/Shapes << /WritingDirection 0 /Children|/Shapes << /Children", "EngineDict.Rendered.Shapes.WritingDirection", .crashesPhotoshop),
            ("/Lines << /WritingDirection 0 /Children [ ] >>", "EngineDict.Rendered.Shapes.Children[0].Lines", .crashesPhotoshop),
            ("/Lines << /WritingDirection 0 /Children [ ] >>|/Lines << /Children [ ] >>", "EngineDict.Rendered.Shapes.Children[0].Lines.WritingDirection", .crashesPhotoshop),
            ("/Lines << /WritingDirection 0 /Children [ ] >>|/Lines << /WritingDirection 0 >>", "EngineDict.Rendered.Shapes.Children[0].Lines.Children", .crashesPhotoshop),
            ("/Procession 0", "EngineDict.Rendered.Shapes.Children[0].Procession", .crashesPhotoshop),
            ("/TransformPoint1 [ 0.0 1.0 ] ", "EngineDict.Rendered.Shapes.Children[0].Cookie.Photoshop.Base.TransformPoint1", .crashesPhotoshop),
            ("/AntiAlias 4 ", "EngineDict.AntiAlias", .crashesPhotoshop),
            ("/UseFractionalGlyphWidths true", "EngineDict.UseFractionalGlyphWidths", .crashesPhotoshop),
            ("/DefaultStyleSheet 0 ", "EngineDict.ParagraphRun.RunArray[0].ParagraphSheet.DefaultStyleSheet", .crashesPhotoshop),
            ("/ResourceDict << /FontSet [ << /Name (Myriad) /Script 0 /FontType 0 /Synthetic 0 >> ] >>|/ResourceDict << /FontSet [ << /Name (Myriad) /Script 0 /Synthetic 0 >> ] >>",
             "ResourceDict.FontSet[0].FontType", .photoshopRefusesFile),
            ("/ResourceDict << /FontSet [ << /Name (Myriad) /Script 0 /FontType 0 /Synthetic 0 >> ] >>|/ResourceDict << /FontSet [ << /Name (Myriad) /Script 0 /FontType 0 >> ] >>",
             "ResourceDict.FontSet[0].Synthetic", .photoshopRefusesFile),
            ("/ResourceDict << /FontSet [ << /Name (Myriad) /Script 0 /FontType 0 /Synthetic 0 >> ] >>", "ResourceDict.FontSet", .photoshopRefusesFile),
        ]
        for (edit, path, consequence) in cases {
            let parts = edit.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let text = Self.complete.replacingOccurrences(of: parts[0], with: parts.count > 1 ? parts[1] : "")
            #expect(text != Self.complete, "edit \(edit) applies")
            let gaps = try Self.engine(text).photoshopStructureGaps()
            #expect(gaps == [PSDEngineDataGap(path: path, consequence: consequence)], "\(path): \(gaps)")
        }
    }

    @Test func linterFlagsTypeLayersPhotoshopCannotOpen() throws {
        let bad = try Self.typeLayerFile(Self.minimal).compatibilityIssues()
        let crash = bad.filter { $0.rule == .typeLayerEngineDataCrashesPhotoshop }
        #expect(crash.count == 1 && crash[0].severity == .error && crash[0].layerIndex == 0)
        #expect(crash.first?.message.contains("CRASHES") == true)
        #expect(bad.contains { $0.rule == .typeLayerEngineDataBlocksPhotoshop })

        let noFontType = Self.complete.replacingOccurrences(of: "/FontType 0 /Synthetic 0 >> ] >>\n/DocumentResources", with: "/Synthetic 0 >> ] >>\n/DocumentResources")
        #expect(noFontType != Self.complete)
        let refused = try Self.typeLayerFile(noFontType).compatibilityIssues()
        #expect(refused.map(\.rule) == [.typeLayerEngineDataBlocksPhotoshop])

        #expect(try Self.typeLayerFile(Self.complete).compatibilityIssues().isEmpty)
    }

    @Test func linterFlagsTypeLayerWithoutEngineData() throws {
        let text = PSDDescriptor(classID: "TxLr").with("Txt ", .text(.nulTerminated("abc")))
        #expect(PSDTypeTool(transform: [1, 0, 0, 1, 0, 0], text: text).missingPhotoshopStructures() == ["EngineData"])
    }

    @Test(.enabled(if: Corpus.directory != nil, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)"))
    func photoshopTypeLayersHaveEveryStructure() throws {
        var typeLayers = 0
        var gaps: [String] = []
        for url in Corpus.files {
            let f = try PSDFile(contentsOf: url)
            for (i, rec) in f.layers.enumerated() {
                guard let t = rec.typeTool else { continue }
                typeLayers += 1
                gaps += t.missingPhotoshopStructures().map { "\(url.lastPathComponent) layer \(i): \($0)" }
            }
            let rules = f.compatibilityIssues().compactMap(\.rule)
            #expect(rules.isEmpty, "\(url.lastPathComponent): \(rules)")
        }
        #expect(typeLayers == 64)
        #expect(gaps.isEmpty, "\(gaps.prefix(10))")
        print("TEXT REQUIREMENTS: \(typeLayers) Photoshop type layers, \(gaps.count) gaps")
    }
}
