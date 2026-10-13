// The `typeSizeOutOfRange` rule: type layers whose sizes Photoshop cannot read as type. Photoshop
// 27.11 opened a 1e30 pt layer as an empty pixel layer and raised the modal "type layers … were
// rasterized" for a `Double.greatestFiniteMagnitude` one (oracle RESULTS.md, TS; lesson AB-L-0262).
// Mirrors the oracle's pre-screen 3 (`TypeSizeScreen`): errors for the measured classes
// (non-finite values, sizes of 1e6 pt or more), warnings outside Photoshop's documented limits.

import Foundation
import Testing
@testable import PCPSD

@Suite struct TypeSizeRuleTests {
    /// A type layer with Photoshop's required structures, style runs and `ResourceDict` /
    /// `DocumentResources` style sheets of the given FontSizes, and `transform`.
    static func typeTool(runs: [Double] = [12], resourceSheets: [Double] = [12], documentSheets: [Double] = [12],
                         transform: [Double] = [1, 0, 0, 1, 0, 0]) throws -> PSDTypeTool {
        func sheet(_ s: Double) -> PSDEngineData {
            .dict([.init("StyleSheetData", .dict([.init("FontSize", .real(s))]))])
        }
        var e = try TextRequirementTests.engine(TextRequirementTests.complete)
        var engineDict = try #require(e["EngineDict"])
        engineDict.set("StyleRun", .dict([.init("RunArray", .array(runs.map { .dict([.init("StyleSheet", sheet($0))]) })),
                                          .init("RunLengthArray", .array(runs.map { _ in .int(4) }))]))
        e.set("EngineDict", engineDict)
        for (key, sizes) in [("ResourceDict", resourceSheets), ("DocumentResources", documentSheets)] {
            var res = try #require(e[key])
            res.set("StyleSheetSet", .array(sizes.map { s in .dict([.init("Name", .string("Normal RGB")), .init("StyleSheetData", .dict([.init("FontSize", .real(s))]))]) }))
            e.set(key, res)
        }
        let text = PSDDescriptor(classID: "TxLr")
            .with("Txt ", .text(.nulTerminated("abc")))
            .with("EngineData", .rawData(e.serialized()))
        return PSDTypeTool(transform: transform, text: text)
    }

    /// A file with one pixel layer and `tools` as type layers (layers 1…).
    static func file(_ tools: [PSDTypeTool]) throws -> PSDFile {
        var b = PSDBuilder(width: 4, height: 4)
        b.pushLayer(PSDLayerSpec(name: "pixels", left: 0, top: 0, width: 1, height: 1, pixels: .u8([0, 0, 0, 255])))
        for (i, t) in tools.enumerated() {
            var spec = PSDLayerSpec(name: "type \(i)", left: 0, top: 0, width: 1, height: 1, pixels: .u8([0, 0, 0, 255]))
            spec.extraBlocks = [PSDTaggedBlock.fourAligned(key: "TySh", data: t.serialized())]
            b.pushLayer(spec)
        }
        return try PSDFile(data: b.build().serialized())
    }

    static func rule(_ f: PSDFile) -> [PSDCompatibilityIssue] { f.compatibilityIssues().filter { $0.rule == .typeSizeOutOfRange } }

    /// The single issue for one type layer, or nil.
    static func issue(_ t: PSDTypeTool) throws -> PSDCompatibilityIssue? {
        let issues = Self.rule(try Self.file([t]))
        #expect(issues.count <= 1)
        #expect(issues.allSatisfy { $0.layerIndex == 1 })
        return issues.first
    }

    @Test func photoshopLikeTypeLayersPass() throws {
        let t = try Self.typeTool()
        #expect(t.photoshopStructureGaps().isEmpty)
        #expect(t.typeSizeViolations().isEmpty)
        #expect(try Self.issue(t) == nil)
        // The limits themselves are inside, and so are Photoshop's own transforms (scale 0.47–1.36).
        for (runs, transform) in [([0.01, 1296.0], [1.0, 0, 0, 1, 0, 0]), ([12.0], [0.47, 0, 0, 0.47, 311, -311]), ([130.0], [1.36, 0.2, -0.2, 1.36, 0, 0])] {
            #expect(try Self.issue(Self.typeTool(runs: runs, transform: transform)) == nil, "\(runs) \(transform)")
        }
    }

    /// The two measured classes: 1e30 pt (opened as an empty pixel layer) and
    /// `Double.greatestFiniteMagnitude` pt and transform (the rasterize modal).
    @Test func measuredClassesAreErrors() throws {
        let huge = Double.greatestFiniteMagnitude
        let cases: [(String, PSDTypeTool)] = [
            ("1e30 pt run", try Self.typeTool(runs: [1e30])),
            ("greatestFiniteMagnitude run and transform", try Self.typeTool(runs: [huge], transform: [huge, 0, 0, huge, 0, 0])),
            ("1e6 pt run", try Self.typeTool(runs: [1e6])),
            ("1e7 pt DocumentResources sheet", try Self.typeTool(documentSheets: [1e7])),
            ("NaN transform", try Self.typeTool(transform: [.nan, 0, 0, 1, 0, 0])),
            ("infinite translation", try Self.typeTool(transform: [1, 0, 0, 1, .infinity, 0])),
            ("12 pt × scale 1e12", try Self.typeTool(transform: [1e12, 0, 0, 1e12, 0, 0])),
        ]
        for (name, t) in cases {
            let i = try #require(try Self.issue(t), "\(name)")
            #expect(i.severity == .error, "\(name)")
            #expect(i.message.hasPrefix("PHOTOSHOP RASTERIZES THE TYPE LAYER"), "\(name): \(i.message)")
            #expect(!i.message.contains("REFUSES"), "\(name)")
            #expect(t.photoshopStructureGaps().isEmpty, "\(name): the structure rules do not see it")
        }
    }

    /// Outside Photoshop's documented limits but not measured: warnings.
    @Test func documentedLimitsAreWarnings() throws {
        let cases: [(String, PSDTypeTool, String)] = [
            ("0 pt run", try Self.typeTool(runs: [0]), "FontSize 0.0 pt (style run 0)"),
            ("0.005 pt run", try Self.typeTool(runs: [0.005]), "FontSize 0.005 pt"),
            ("negative run", try Self.typeTool(runs: [12, -3]), "FontSize -3.0 pt (style run 1)"),
            ("1296.5 pt run", try Self.typeTool(runs: [1296.5]), "FontSize 1296.5 pt"),
            ("999,999 pt run", try Self.typeTool(runs: [999_999]), "FontSize 999999.0 pt"),
            ("2000 pt ResourceDict sheet", try Self.typeTool(resourceSheets: [12, 2000]), "(ResourceDict style sheet 1)"),
            ("12 pt × scale 1100", try Self.typeTool(transform: [1100, 0, 0, 1100, 0, 0]), "effective size 13200.0 pt (style run 0: FontSize 12.0 × transform scale 1100.0)"),
            ("12 pt × scale 0.0001", try Self.typeTool(transform: [0.0001, 0, 0, 0.0001, 0, 0]), "effective size"),
            ("translation 400,000", try Self.typeTool(transform: [1, 0, 0, 1, 400_000, 0]), "transform component 4 is 400000.0"),
        ]
        for (name, t, detail) in cases {
            let i = try #require(try Self.issue(t), "\(name)")
            #expect(i.severity == .warning, "\(name)")
            #expect(i.message.hasPrefix("type layer outside Photoshop's documented limits") && i.message.contains(detail), "\(name): \(i.message)")
        }
        // A run already out of range is not reported a second time through its effective size.
        let both = try Self.typeTool(runs: [0], transform: [2, 0, 0, 2, 0, 0])
        #expect(both.typeSizeViolations().map(\.what) == ["FontSize 0.0 pt (style run 0)"])
    }

    @Test func oneIssuePerTypeLayer() throws {
        let f = try Self.file([try Self.typeTool(), try Self.typeTool(runs: [1e30, 0], resourceSheets: [0]), try Self.typeTool(runs: [0])])
        let issues = Self.rule(f)
        #expect(issues.map(\.layerIndex) == [2, 3])
        #expect(issues.map(\.severity) == [.error, .warning])
        // Each issue names every value out of range in its layer (the error lists the 0 pt ones too).
        #expect(issues[0].message.contains("1e+30") && issues[0].message.contains("style run 1") && issues[0].message.contains("ResourceDict style sheet 0"))
    }

    // MARK: Calibration

    @Test(.enabled(if: Corpus.directory != nil, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)"))
    func silentOnTheCorpus() throws {
        var typeLayers = 0, hits: [String] = []
        for url in Corpus.files {
            let f = try PSDFile(contentsOf: url)
            typeLayers += f.layers.filter { $0.block("TySh") != nil }.count
            hits += Self.rule(f).map { "\(url.lastPathComponent): \($0)" }
        }
        #expect(typeLayers == 64)
        #expect(hits.isEmpty, "\(hits.prefix(10))")
        print("TYPE-SIZE rule, Unity corpus: \(Corpus.files.count) files, \(typeLayers) type layers, \(hits.count) hits")
    }

    /// The oracle's pre-screen 3 flags exactly 5 of PCIO's exports in `pcio-snapshot-c2`; the rule
    /// flags the same 5 (and the same layer), with errors for the measured classes.
    static var snapshot: URL? {
        guard let dir = Corpus.psOracle?.appendingPathComponent("pcio-snapshot-c2") else { return nil }
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    @Test(.enabled(if: TypeSizeRuleTests.snapshot != nil, "oracle snapshot pcio-snapshot-c2 not present (set PHOTOCRAFT_FIXTURES or PCPSD_PS_ORACLE)"))
    func agreesWithTheOraclesPreScreen() throws {
        let dir = try #require(Self.snapshot)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".psd") || $0.hasSuffix(".psb") }.sorted()
        var found: [String: [PSDCompatibilityIssue]] = [:], typeLayers = 0
        for name in names {
            guard let f = try? PSDFile(contentsOf: dir.appendingPathComponent(name)) else { continue }
            typeLayers += f.layers.filter { $0.block("TySh") != nil }.count
            let issues = Self.rule(f)
            if !issues.isEmpty { found[name] = issues }
        }
        let hostile = "synthetic-hostileTypeSizesWithoutPixelsImportWithoutAHugeRender-"
        let expected: [String: PSDCompatibilityIssue.Severity] = [
            hostile + "08e3aaeee0.psd": .error,   // 1e30 pt: opened as an empty pixel layer
            hostile + "6639470508.psd": .error,   // greatestFiniteMagnitude: the modal
            hostile + "e3a378b9c9.psd": .error,   // 12 pt × scale 1e12 (never opened)
            hostile + "7eca2591d2.psd": .warning, // 12 pt × scale 1100 (never opened)
            "synthetic-textLayerRoundtripWithTySh-7f7ce94a65.psd": .warning, // layer #41 at 0 pt
        ]
        #expect(Set(found.keys) == Set(expected.keys), "\(found.keys.sorted())")
        for (name, severity) in expected {
            #expect(found[name]?.map(\.severity) == [severity], "\(name)")
        }
        #expect(found["synthetic-textLayerRoundtripWithTySh-7f7ce94a65.psd"]?.first?.layerIndex == 41)
        print("TYPE-SIZE rule, pcio-snapshot-c2: \(names.count) files, \(typeLayers) type layers, \(found.count) flagged (\(found.values.joined().filter { $0.severity == .error }.count) errors)")
    }
}
