// Rules for the last PCIO refusal families Photoshop 27.11 was bisected on (oracle RESULTS.md, C′
// bisect; `RefusalVariantTests`): a placed layer with a bare `SoLd` and no linked data, unreadable
// placed-layer data, a linked-file item whose kind does not match its layout, an unreadable
// `SoCo` (errors), and a path-less `vmsk`, which Photoshop opens (warning).

import Foundation
import Testing
@testable import PCPSD

@Suite struct SmartObjectRuleTests {
    static let newRules: Set<PSDCompatibilityRule> = [.placedLayerWithoutLinkedData, .placedLayerDataUnreadable, .linkedFileKindMismatch,
                                                      .fillLayerDataUnreadable, .vectorMaskWithoutPaths]
    static let trnf: PSDDescriptor.Value = .list([0, 0, 10, 0, 10, 5, 0, 5].map { .double($0) })

    /// Photoshop's placement descriptor keys (every `SoLd` in both corpora has them).
    static func fullPlacement(_ uid: String) -> PSDPlacedLayerData {
        PSDPlacedLayerData(descriptor: PSDDescriptor().with("Idnt", .text(PSDUnicodeString(uid))).with("placed", .text("p-1"))
            .with("PgNm", .integer(1)).with("totalPages", .integer(1)).with("Type", .integer(2)).with("Trnf", trnf)
            .with("Sz  ", .descriptor(PSDDescriptor(classID: "Pnt ").with("Wdth", .double(10)).with("Hght", .double(5))))
            .with("Rslt", .unitFloat(unit: "#Rsl", value: 72)))
    }

    static func barePlacement(_ uid: String) -> PSDPlacedLayerData {
        PSDPlacedLayerData(descriptor: PSDDescriptor().with("Idnt", .text(PSDUnicodeString(uid))).with("Trnf", trnf))
    }

    static func embedded(_ uid: String) -> PSDLinkedFile {
        PSDLinkedFile.embedded(uniqueID: uid, fileName: "a.png", fileType: "png ", data: Data([0x89, 0x50, 0x4E, 0x47]))
    }

    /// A one-layer document carrying `blocks` on its layer and `global` as global blocks.
    static func file(blocks: [PSDTaggedBlock], global: [PSDTaggedBlock] = []) throws -> PSDFile {
        var b = PSDBuilder(width: 4, height: 4)
        var s = PSDLayerSpec(name: "layer", left: 0, top: 0, width: 2, height: 2, pixels: .u8([UInt8](repeating: 255, count: 16)))
        s.extraBlocks = blocks.map { PSDTaggedBlock.fourAligned(key: $0.key, data: $0.data) }
        b.pushLayer(s)
        var f = try b.build()
        f.globalBlocks += global
        return try PSDFile(data: f.serialized())
    }

    static func issues(_ f: PSDFile) -> [PSDCompatibilityIssue] { f.compatibilityIssues().filter { $0.rule.map(newRules.contains) ?? false } }

    static func lnk2(_ items: [PSDLinkedFile]) -> PSDTaggedBlock { PSDTaggedBlock(key: "lnk2", data: PSDLinkedFiles(items: items).serialized()) }

    // MARK: Cause 1 — a bare placed layer without linked data

    @Test func barePlacedLayerWithoutLinkedDataIsAnError() throws {
        let uid = "5b0c0b42-0000-4000-8000-000000000001"
        let bare = PSDTaggedBlock(key: "SoLd", data: Self.barePlacement(uid).serialized())
        let issues = Self.issues(try Self.file(blocks: [bare]))
        #expect(issues.count == 1 && issues[0].rule == .placedLayerWithoutLinkedData && issues[0].severity == .error && issues[0].layerIndex == 0, "\(issues)")
        #expect(issues.first?.message.hasPrefix("PHOTOSHOP REFUSES THE FILE") == true)
        // The same bare record with its linked data, a NUL-terminated id included, is not flagged.
        #expect(Self.issues(try Self.file(blocks: [bare], global: [Self.lnk2([Self.embedded(uid)])])).isEmpty)
        let nul = PSDTaggedBlock(key: "SoLd", data: Self.barePlacement(uid + "\u{0}").serialized())
        #expect(Self.issues(try Self.file(blocks: [nul], global: [Self.lnk2([Self.embedded(uid)])])).isEmpty)
        // Photoshop opened a placed layer with its full descriptor and no linked item (a missing link).
        let full = PSDTaggedBlock(key: "SoLd", data: Self.fullPlacement(uid).serialized())
        #expect(Self.issues(try Self.file(blocks: [full])).isEmpty)
        // An item whose kind is wrong still names the source, so only the kind rule fires.
        var relabelled = [UInt8](Self.embedded(uid).raw)
        relabelled.replaceSubrange(0 ..< 4, with: Array("liFE".utf8))
        let kinds = Self.issues(try Self.file(blocks: [bare], global: [Self.lnk2([PSDLinkedFile(raw: Data(relabelled))])]))
        #expect(kinds.map(\.rule) == [.linkedFileKindMismatch])
    }

    // MARK: Cause 3 — placed-layer data that does not parse

    @Test func unreadablePlacedLayerDataIsAnError() throws {
        for (key, bytes) in [("PlLd", [UInt8]([1, 2, 3, 4])), ("SoLd", [0x73, 0x6F, 0x4C, 0x44, 0, 0, 0, 4]), ("SoLE", [1, 2, 3, 4, 5, 6, 7, 8])] {
            let all = try Self.file(blocks: [PSDTaggedBlock(key: FourCC(stringLiteral: key), data: Data(bytes))]).compatibilityIssues()
            let named = all.filter { $0.rule == .placedLayerDataUnreadable }
            #expect(named.count == 1 && named[0].severity == .error && named[0].layerIndex == 0, "\(key): \(all)")
            #expect(named.first?.message.hasPrefix("PHOTOSHOP REFUSES THE FILE: \(key) placed-layer data does not parse") == true, "\(key)")
            // It replaces the generic structure error for the block.
            #expect(!all.contains { $0.rule == nil && $0.message.hasPrefix("block \(key)") }, "\(key): \(all)")
        }
        // Well-formed placed-layer blocks pass.
        let uid = "abc-123"
        let pl = PSDPlacedLayer(uniqueID: uid, transform: [0, 0, 10, 0, 10, 5, 0, 5], warp: PSDVersionedDescriptor(PSDTypeTool.defaultWarp()))
        let good = [PSDTaggedBlock(key: "PlLd", data: pl.serialized()), PSDTaggedBlock(key: "SoLd", data: Self.fullPlacement(uid).serialized())]
        #expect(Self.issues(try Self.file(blocks: good, global: [Self.lnk2([Self.embedded(uid)])])).isEmpty)
    }

    // MARK: Cause 4 — a linked-file item whose kind does not match its layout

    @Test func linkedItemKindMismatchIsAnError() throws {
        let items = [Self.embedded("one"), Self.embedded("two")]
        #expect(Self.issues(try Self.file(blocks: [], global: [Self.lnk2(items)])).isEmpty)
        for key: FourCC in ["lnk2", "lnk3", "lnkD", "lnkE"] {
            var second = [UInt8](items[1].raw)
            second.replaceSubrange(0 ..< 4, with: Array("liFE".utf8))
            let block = PSDTaggedBlock(key: key, data: PSDLinkedFiles(items: [items[0], PSDLinkedFile(raw: Data(second))]).serialized())
            let issues = Self.issues(try Self.file(blocks: [], global: [block]))
            #expect(issues.count == 1 && issues[0].rule == .linkedFileKindMismatch && issues[0].severity == .error, "\(key): \(issues)")
            #expect(issues.first?.message == "PHOTOSHOP REFUSES THE FILE: \(key) item 1 (\"a.png\") is labelled liFE but laid out as liFD")
        }
        // An item that reads as no kind at all is not this rule's.
        var junk = [UInt8](items[0].raw)
        junk.replaceSubrange(4 ..< junk.count, with: [UInt8](repeating: 0xFF, count: junk.count - 4))
        #expect(Self.issues(try Self.file(blocks: [], global: [Self.lnk2([PSDLinkedFile(raw: Data(junk))])])).isEmpty)
    }

    // MARK: Cause 2 — an unreadable SoCo (error); a path-less vmsk (warning)

    /// Photoshop 27.11 on `vectorRenderedMaskNotDoubledOnShapes`: B2 (a real `SoCo`, the 8-byte
    /// version-0 `vmsk` kept) opened; B3 (the 0-byte `SoCo` kept, a real `vmsk`) was refused.
    @Test func unreadableSolidColorIsAnErrorAndPathlessVectorMaskWarns() throws {
        let both = Self.issues(try Self.file(blocks: [PSDTaggedBlock(key: "SoCo", data: Data()), PSDTaggedBlock(key: "vmsk", data: Data(count: 8))]))
        #expect(both.map(\.rule) == [.fillLayerDataUnreadable, .vectorMaskWithoutPaths], "\(both)")
        #expect(both.map(\.severity) == [.error, .warning])
        #expect(both.first?.message == "PHOTOSHOP REFUSES THE FILE: SoCo fill-layer block is empty")
        #expect(both.last?.message.hasPrefix("vmsk (version 0, 8 bytes) has no path records; Photoshop opens it") == true)
        // A SoCo that does not parse is the same error.
        let garbled = Self.issues(try Self.file(blocks: [PSDTaggedBlock(key: "SoCo", data: Data([0, 0, 0, 16, 1, 2, 3, 4]))]))
        #expect(garbled.map(\.severity) == [.error] && garbled.first?.message == "PHOTOSHOP REFUSES THE FILE: SoCo fill-layer block does not parse")
        // B2: a real SoCo beside the path-less vmsk leaves only the warning; so do the 12-byte form and vsms.
        let b2 = Self.issues(try Self.file(blocks: [PSDFillSetting.solid(.rgb(red: 10, green: 20, blue: 30)), PSDTaggedBlock(key: "vmsk", data: Data(count: 8))]))
        #expect(b2.map(\.severity) == [.warning] && b2.first?.rule == .vectorMaskWithoutPaths)
        #expect(Self.issues(try Self.file(blocks: [PSDTaggedBlock(key: "vsms", data: Data(count: 12))])).map(\.severity) == [.warning])
        // GdFl/PtFl are not measured: warnings.
        for key: FourCC in ["GdFl", "PtFl"] {
            for bytes in [Data(), Data([0, 0, 0, 16, 1, 2, 3, 4])] {
                let i = Self.issues(try Self.file(blocks: [PSDTaggedBlock(key: key, data: bytes)]))
                #expect(i.map(\.rule) == [.fillLayerDataUnreadable] && i.map(\.severity) == [.warning] && !(i.first?.message.contains("REFUSES THE FILE:") ?? true), "\(key) \(bytes.count): \(i)")
            }
        }
        // A real SoCo and a vmsk with path records pass.
        var vmsk = ByteWriter()
        vmsk.u32(3); vmsk.u32(0); vmsk.u16(6); vmsk.zeros(24) // path fill rule record
        let fine = [PSDFillSetting.solid(.rgb(red: 10, green: 20, blue: 30)), PSDTaggedBlock(key: "vmsk", data: vmsk.data)]
        #expect(Self.issues(try Self.file(blocks: fine)).isEmpty)
    }

    // MARK: Calibration

    @Test(.enabled(if: Corpus.directory != nil, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)"))
    func silentOnTheCorpus() throws {
        var hits: [String] = [], placed = 0
        for url in Corpus.files {
            let f = try PSDFile(contentsOf: url)
            placed += f.layers.filter { $0.block("SoLd") != nil }.count
            hits += Self.issues(f).map { "\(url.lastPathComponent): \($0)" }
        }
        #expect(hits.isEmpty, "\(hits.prefix(10))")
        print("SMART rules, Unity corpus: \(Corpus.files.count) files, \(placed) placed layers, \(hits.count) hits")
    }

    /// The oracle's C″ sweep (`ps-oracle/pcio-c3/pcio-c3.json` over `pcio-snapshot-c3`): the error
    /// rules flag all 6 refusals, and none of these rules (errors or warnings) fires on a file
    /// Photoshop opened.
    static var sweep: (json: URL, files: URL)? {
        guard let root = Corpus.psOracle else { return nil }
        let json = root.appendingPathComponent("pcio-c3/pcio-c3.json"), files = root.appendingPathComponent("pcio-snapshot-c3")
        return FileManager.default.fileExists(atPath: json.path) && FileManager.default.fileExists(atPath: files.path) ? (json, files) : nil
    }

    @Test(.enabled(if: SmartObjectRuleTests.sweep != nil, "oracle sweep pcio-c3 not present (set PHOTOCRAFT_FIXTURES or PCPSD_PS_ORACLE)"))
    func agreesWithPhotoshopsVerdicts() throws {
        let sweep = try #require(Self.sweep)
        let rows = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: sweep.json)) as? [[String: Any]])
        var refusedErrors: [String] = [], refusedUnflagged: [String] = [], openedFlagged: [String] = []
        var opened = 0
        for row in rows {
            guard let path = row["file"] as? String, let ok = row["opened"] as? Bool else { continue }
            let name = (path as NSString).lastPathComponent
            guard let f = try? PSDFile(contentsOf: sweep.files.appendingPathComponent(name)) else { continue }
            let issues = Self.issues(f)
            if ok {
                opened += 1
                if !issues.isEmpty { openedFlagged.append(name) }
            } else if issues.contains(where: { $0.severity == .error }) {
                refusedErrors.append(name)
            } else {
                refusedUnflagged.append(name)
            }
        }
        #expect(openedFlagged.isEmpty, "\(openedFlagged.prefix(10))")
        #expect(refusedUnflagged.isEmpty, "\(refusedUnflagged)")
        func family(_ names: [String]) -> [String] { names.map { $0.split(separator: "-")[1].description }.sorted() }
        #expect(family(refusedErrors) == ["independentUnavailableLinkRetainsSeparatePreservedRecord", "placedLayerBlocksKeepTheirKeys",
                                          "placedLayerBlocksKeepTheirKeys", "textShapeSmartRawBlocksSurvive",
                                          "vectorRenderedMaskNotDoubledOnShapes", "vectorRenderedMaskNotDoubledOnShapes"], "\(refusedErrors)")
        print("SMART rules vs Photoshop (pcio-c3): \(refusedErrors.count) refused files with an error, \(refusedUnflagged.count) unflagged; \(openedFlagged.count) of \(opened) opened files flagged")
    }
}
