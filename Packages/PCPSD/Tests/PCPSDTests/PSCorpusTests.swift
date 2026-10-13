// The Photoshop-authored oracle corpus (155 files written by Photoshop 27.11 for this port, with a
// feature manifest), read from PCPSD_PS_CORPUS (opt-in; skipped when absent): byte identity, and
// the four reader/writer bugs the Photoshop oracle found (RESULTS.md F1, B1, B2, B3).

import Foundation
import Testing
@testable import PCPSD

@Suite(.enabled(if: PSCorpus.directory != nil, "Photoshop oracle corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_PS_CORPUS)"))
struct PSCorpusTests {
    @Test func everyFileRewritesByteForByte() throws {
        var ok = 0
        var failures: [String] = []
        for url in PSCorpus.files {
            let data = try Data(contentsOf: url)
            let f = try PSDFile(data: data)
            if try f.serialized() == data { ok += 1 } else { failures.append(url.lastPathComponent) }
        }
        #expect(PSCorpus.files.count >= 155) // grows as the oracle adds references; 155 on 2026-10-12
        #expect(failures.isEmpty, "\(failures)")
        print("PS-CORPUS byte-stable rewrite: \(ok)/\(PSCorpus.files.count)")
    }

    /// The new rules the oracle measured (EngineData, blend table, 4-alignment, matte order) never
    /// fire on files Photoshop wrote.
    @Test func measuredRulesHaveNoFalsePositives() throws {
        let rules: Set<PSDCompatibilityRule> = [.typeLayerEngineDataCrashesPhotoshop, .typeLayerEngineDataBlocksPhotoshop, .typeLayerUnreadable,
                                                .blendModeInvalidForDocument, .passThroughOnNonGroup, .layerBlockNotFourAligned, .layerInfoBeforeMatteBlock,
                                                .hdrToningMissingAt32Bit, .patternTransparencyInUserMask, .patternDataUnreadable, .typeSizeOutOfRange,
                                                .placedLayerWithoutLinkedData, .placedLayerDataUnreadable, .linkedFileKindMismatch,
                                                .fillLayerDataUnreadable, .vectorMaskWithoutPaths]
        var hits: [String] = []
        var patternBlocks = 0, patterns = 0
        for url in PSCorpus.files {
            let f = try PSDFile(contentsOf: url)
            for i in f.compatibilityIssues() where i.rule.map(rules.contains) ?? false { hits.append("\(url.lastPathComponent): \(i)") }
            for b in f.globalBlocks where PSDPattern.blockKeys.contains(b.key) {
                patternBlocks += 1
                patterns += try PSDPattern.parseBlock(b.data).count
            }
        }
        #expect(hits.isEmpty, "\(hits.prefix(10))")
        // Every file with layers has one (the 8 flat or layerless files have none): all empty
        // (Patt, Pat2, Pat3) but 2 holding Photoshop's "Tree Tile 4" (147 blocks in 155 files).
        #expect(patternBlocks == PSCorpus.files.count - 8 && patterns == 2)
        print("PS-CORPUS measured rules: \(PSCorpus.files.count) files, \(patternBlocks) pattern blocks (\(patterns) patterns), \(hits.count) hits")
    }

    // MARK: Patterns — Photoshop's own pattern data rewrites byte for byte

    /// Photoshop's "Tree Tile 4" (indexed, 946², RLE in Photoshop's own PackBits runs, `01 00 00 ff`
    /// after the palette) parses and re-serialises through the typed model byte for byte, alone
    /// and as part of the file.
    @Test func photoshopPatternsRewriteByteForByte() throws {
        for name in ["fill-pattern.psd", "fx-pattern-overlay.psd"] {
            let url = try #require(PSCorpus.url(name))
            let data = try Data(contentsOf: url)
            var f = try PSDFile(data: data)
            let index = try #require(f.globalBlocks.firstIndex { $0.key == "Patt" && !$0.data.isEmpty })
            let block = f.globalBlocks[index]
            let patterns = try PSDPattern.parseBlock(block.data)
            #expect(patterns.count == 1)
            let p = try #require(patterns.first)
            #expect(p.name == "Tree Tile 4" && p.mode == 2 && p.width == 946 && p.height == 946 && p.depth == 8 && p.alpha == nil)
            #expect(p.paletteTrailer == [0x01, 0x00, 0x00, 0xFF])
            #expect(p.stored?.slotCount == 24 && p.stored?.writtenSlots == [0] && p.stored?.writesUserMask == false)
            let rewritten = try PSDPattern.writeBlock(patterns)
            #expect(rewritten == block.data, "\(name): \(rewritten.count) vs \(block.data.count) bytes")
            f.globalBlocks[index] = PSDTaggedBlock(key: "Patt", data: rewritten)
            #expect(try f.serialized() == data, "\(name)")
            // An edited pixel is re-encoded and reads back.
            var edited = p
            edited.channels[0][0] ^= 1
            let back = try PSDPattern.parseBlock(PSDPattern.writeBlock([edited]))
            #expect(back == [edited])
            #expect(back != patterns)
        }
    }

    // MARK: F1 — matte block before the layer info

    /// Photoshop writes `Mt16`/`Mt32` first, then `Lr16`/`Lr32` with a positive count; the builder
    /// now writes the same, and the linter flags the reverse.
    @Test func matteBlockPrecedesLayerInfo() throws {
        var checked = 0
        for url in PSCorpus.files {
            let f = try PSDFile(contentsOf: url)
            guard let matte = f.globalBlocks.firstIndex(where: { ["Mt16", "Mt32"].contains($0.key) }),
                  case let .globalBlock(index, _, key, _, _) = f.layerInfoPlacement else { continue }
            checked += 1
            #expect(matte < index, "\(url.lastPathComponent): \(key) at \(index), matte at \(matte)")
            #expect(f.layerInfo?.mergedAlpha == false, "Photoshop keeps the count positive")
            #expect(f.mergedHasAlpha)
            // The order PCPSD wrote before the fix is flagged.
            var swapped = f
            swapped.layerInfoPlacement = .globalBlock(index: 0, signature: "8BIM", key: key, padding: nil, longLengthOverride: nil)
            #expect(swapped.compatibilityIssues().contains { $0.rule == .layerInfoBeforeMatteBlock && $0.severity == .error })
            #expect(!f.compatibilityIssues().contains { $0.rule == .layerInfoBeforeMatteBlock })
        }
        #expect(checked == 3) // transparent-grayscale-16, transparent-rgb-16, transparent-rgb-32

        for depth: UInt16 in [16, 32] {
            for mode in [PSDColorMode.rgb, .grayscale] {
                var b = PSDBuilder(width: 2, height: 2, colorMode: mode, depth: depth)
                let cc = mode == .rgb ? 3 : 1
                b.pushLayer(PSDLayerSpec(name: "half", left: 0, top: 0, width: 2, height: 1,
                                         pixels: depth == 16 ? .u16([UInt16](repeating: 30000, count: 2 * (cc + 1))) : .f32([Float](repeating: 0.5, count: 2 * (cc + 1)))))
                // A composite with transparency (the merged image gets an alpha channel).
                let n = 4 * (cc + 1)
                b.setComposite(depth == 16 ? .u16((0 ..< n).map { $0 % (cc + 1) == cc && $0 >= n / 2 ? 0 : 30000 })
                                           : .f32((0 ..< n).map { $0 % (cc + 1) == cc && $0 >= n / 2 ? 0 : 0.5 }))
                let f = try PSDFile(data: b.serialized())
                let mt: FourCC = depth == 16 ? "Mt16" : "Mt32"
                #expect(f.globalBlocks.first?.key == mt, "\(mode) \(depth)")
                guard case let .globalBlock(index, _, key, _, _) = f.layerInfoPlacement else { Issue.record("no layer block"); continue }
                #expect(index == 1 && key == (depth == 16 ? "Lr16" : "Lr32"))
                #expect(f.layerInfo?.mergedAlpha == false && f.mergedHasAlpha)
                #expect(f.compatibilityIssues().isEmpty, "\(f.compatibilityIssues())")
            }
        }
    }

    // MARK: B1 — colour overlays (`SoFi`)

    @Test func colorOverlaysAreRead() throws {
        let features = PSCorpus.features
        var overlayFiles = 0
        var filesWithOverlays: [String] = []
        for url in PSCorpus.files {
            let f = try PSDFile(contentsOf: url)
            let fx = f.layers.compactMap { $0.objectEffects }
            // Every effect key Photoshop wrote is one the reader knows.
            for e in fx {
                for item in e.descriptor.descriptor.items {
                    let k = item.key.name
                    if ["Scl ", "masterFXSwitch", "numModifyingFX"].contains(k) { continue }
                    #expect(PSDObjectEffects.effectKeys.contains(k) || PSDObjectEffects.multiKeys.contains(k), "\(url.lastPathComponent): unknown effect key \(k)")
                }
            }
            if fx.flatMap(\.effects).contains(where: { $0.key == "SoFi" && $0.isEnabled }) { filesWithOverlays.append(url.lastPathComponent) }
            guard features[url.lastPathComponent]?.contains("effect:colorOverlay") == true else { continue }
            overlayFiles += 1
            let overlays = fx.flatMap(\.effects).filter { ($0.key == "SoFi" || $0.key == "solidFillMulti") && $0.isEnabled }
            #expect(!overlays.isEmpty, "\(url.lastPathComponent): colour overlay not read")
            #expect(overlays.allSatisfy { $0.color != nil })
        }
        #expect(overlayFiles == 3)
        // The four files whose layer trees differed from Photoshop's reading (RESULTS.md B1).
        #expect(filesWithOverlays == ["advanced-flags.psd", "fx-all.psd", "fx-color-overlay.psd", "fx-multi.psd"], "\(filesWithOverlays)")
    }

    // MARK: B2 — `Txt2` literal encodings

    @Test func txt2RoundTripsByteForByte() throws {
        var total = 0, exact = 0
        for url in PSCorpus.files {
            let f = try PSDFile(contentsOf: url)
            guard let b = f.globalBlock("Txt2") else { continue }
            total += 1
            let doc = try PSDEngineData.parseBare(b.data)
            if doc.serializedCompactBare() == b.data { exact += 1 } else { Issue.record("\(url.lastPathComponent): Txt2 differs") }
            #expect(try PSDEngineData.parseBare(doc.serializedCompactBare()) == doc)
        }
        #expect(total == 10 && exact == total)
        print("PS-CORPUS Txt2: \(exact)/\(total) byte for byte")
    }

    @Test func eightBitLiteralsKeepTheirEncoding() throws {
        var bytes = Array(" /0 << /2 (0100) /3 (".utf8) + [0xFE, 0xFF, 0x00, 0x41] + Array(") >>".utf8)
        let doc = try PSDEngineData.parseBare(Data(bytes))
        #expect(doc.path("0", "2")?.string == "0100" && doc.path("0", "3")?.string == "A")
        #expect(doc.serializedCompactBare() == Data(bytes))
        #expect(doc.path("0")?.entries?.map(\.stringEncoding) == [.eightBit, nil])
        // A replaced value keeps the entry's encoding when it fits in 8 bits, else falls back to UTF-16.
        var d = doc
        if case var .dict(top) = d, case var .dict(inner) = top[0].value {
            inner[0].value = .string("1111")
            top[0].value = .dict(inner)
            d = .dict(top)
        }
        #expect(String(decoding: d.serializedCompactBare(), as: UTF8.self).contains("/2 (1111)"))
        if case var .dict(top) = d, case var .dict(inner) = top[0].value {
            inner[0].value = .string("\u{263A}")
            top[0].value = .dict(inner)
            d = .dict(top)
        }
        bytes = [UInt8](d.serializedCompactBare())
        #expect(bytes.starts(with: Array(" /0 << /2 (".utf8) + [0xFE, 0xFF, 0x26, 0x3A]))
        // Equality ignores the literal encoding.
        #expect(PSDEngineData.Entry("a", .string("x"), stringEncoding: .eightBit) == PSDEngineData.Entry("a", .string("x")))
    }

    // MARK: B3 — user mask vs vector-mask rendering

    @Test func userMaskIsNeverTheVectorMaskRendering() throws {
        var vectorOnly = 0, both = 0, raster = 0
        for url in PSCorpus.files {
            let f = try PSDFile(contentsOf: url)
            for (i, rec) in f.layers.enumerated() where rec.channel(PSDChannelID.userMask) != nil {
                let view = try #require(f.layer(i))
                let rendered = (rec.layerMask?.flags ?? 0) & PSDLayerMask.flagFromRendering != 0
                let hasReal = rec.channel(PSDChannelID.realUserMask) != nil
                let user = try view.userMask()?.get()
                let vector = try view.vectorMaskRendering()?.get()
                switch (rendered, hasReal) {
                case (true, false):
                    vectorOnly += 1
                    #expect(user == nil, "\(url.lastPathComponent) \(rec.displayName): vector rendering returned as user mask")
                    #expect(vector != nil)
                case (true, true):
                    both += 1
                    #expect(user != nil && vector != nil)
                    #expect(user?.width == Int(rec.layerMask?.real?.rect.width ?? -1))
                default:
                    raster += 1
                    #expect(user != nil && vector == nil)
                }
            }
        }
        #expect(vectorOnly == 2 && both == 2 && raster > 90)
        print("PS-CORPUS masks: \(raster) raster, \(vectorOnly) vector-only, \(both) both")
    }
}
