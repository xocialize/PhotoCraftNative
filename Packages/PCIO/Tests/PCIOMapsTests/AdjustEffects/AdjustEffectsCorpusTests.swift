// Every adjustment and effects block of the Photoshop corpus (PCPSD_CORPUS; skipped when absent)
// parses, and `write(parse(x))` parses back equal.
// New in the port (photocraft runs the same mapping over its own corpus through whole-file
// import/export), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import Testing
@testable import PCIOMaps

private enum AdjustCorpus {
    /// `PCPSD_CORPUS`, default `<fixtures>/psd-corpus` (`Fixtures`); nil when absent.
    static var directory: URL? { Fixtures.psdCorpus }

    static var files: [URL] {
        guard let dir = directory, let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { ["psd", "psb"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func channels(_ m: PSDColorMode) -> AdjustMap.Channels {
        switch m {
        case .rgb: .rgb
        case .grayscale: .gray
        case .cmyk: .cmyk
        case .lab: .lab
        default: .other
        }
    }
}

@Suite(.enabled(if: AdjustCorpus.directory != nil, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)"))
struct AdjustEffectsCorpusTests {
    @Test func adjustmentAndEffectsBlocksRoundTrip() throws {
        var files = 0
        var adjBlocks = 0, adjTyped = 0, adjExact = 0, adjByteExact = 0
        var kinds: [String: Int] = [:]
        var fxBlocks = 0, fxItems = 0, fxExact = 0, fxFixed = 0
        var fxKeys: [String: Int] = [:]
        var lrfxBlocks = 0, lrfxItems = 0
        for url in AdjustCorpus.files {
            let file = try PSDFile(contentsOf: url)
            files += 1
            let channels = AdjustCorpus.channels(file.header.colorMode)
            for rec in file.layers {
                let cged = rec.blocks.first { $0.key == "CgEd" }.map { [UInt8]($0.data) }
                for block in rec.blocks {
                    let data = [UInt8](block.data)
                    if AdjustMap.adjustmentKeys.contains(block.key) {
                        adjBlocks += 1
                        let a = AdjustMap.parse(block.key, data, cged, channels)
                        #expect(AdjustMap.parse(block.key, data, cged, channels) == a, "\(url.lastPathComponent) \(block.key): deterministic")
                        if case .unsupported = a {} else { adjTyped += 1 }
                        kinds[block.key.string, default: 0] += 1
                        let w = AdjustMap.write(a)
                        guard let first = w.first else {
                            Issue.record("\(url.lastPathComponent) \(block.key): no encoding")
                            continue
                        }
                        let wcged = w.first { $0.key == "CgEd" }?.data
                        let back = AdjustMap.parse(first.key, first.data, wcged, channels)
                        #expect(back == a, "\(url.lastPathComponent) \(block.key): write(parse(x)) parses back equal")
                        if back == a { adjExact += 1 }
                        if first.data == data { adjByteExact += 1 }
                    }
                    if block.key == "lfx2" || block.key == "lfxs" || block.key == "lmfx" {
                        fxBlocks += 1
                        fxKeys[block.key.string, default: 0] += 1
                        guard let (master, items) = EffectsMap.parseLfx2(data) else {
                            Issue.record("\(url.lastPathComponent) \(block.key): unreadable")
                            continue
                        }
                        fxItems += items.count
                        let w = EffectsMap.writeLfx2(master, items)
                        guard let back = EffectsMap.parseLfx2(w) else {
                            Issue.record("\(url.lastPathComponent) \(block.key): written block unreadable")
                            continue
                        }
                        #expect(back.enabled == master && back.items.count == items.count, "\(url.lastPathComponent) \(block.key)")
                        // Colours pass through 0...255 doubles, so equality is checked through the
                        // serialization (as photocraft's own lfx2 round-trip test does).
                        let again = EffectsMap.writeLfx2(back.enabled, back.items)
                        #expect(again == w, "\(url.lastPathComponent) \(block.key): writeLfx2 is a fixed point")
                        if again == w { fxFixed += 1 }
                        if back.items == items { fxExact += 1 }
                    }
                    if block.key == "lrFX" {
                        lrfxBlocks += 1
                        guard let (master, items) = EffectsMap.parseLrfx(data) else {
                            Issue.record("\(url.lastPathComponent) lrFX: unreadable")
                            continue
                        }
                        lrfxItems += items.count
                        // Legacy effects are written back as lfx2.
                        let back = EffectsMap.parseLfx2(EffectsMap.writeLfx2(master, items))
                        #expect(back?.items.count == items.count, "\(url.lastPathComponent) lrFX → lfx2")
                    }
                }
            }
        }
        let k = kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let fk = fxKeys.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        print("""
        AdjustEffects corpus: \(files) files
          adjustment blocks \(adjBlocks) (\(k)): typed \(adjTyped), write→parse equal \(adjExact), byte-identical rewrite \(adjByteExact)
          effects blocks \(fxBlocks) (\(fk)), \(fxItems) effects: reserialization fixed point \(fxFixed), model-equal after write→parse \(fxExact)
          lrFX blocks \(lrfxBlocks), \(lrfxItems) effects
        """)
        #expect(files == AdjustCorpus.files.count)
    }
}
