// Smart objects of the 36-file Photoshop corpus (`PCPSD_CORPUS`, default the scratch corpus; the
// suite is skipped when it is absent). The block-level part of photocraft-io's
// crates/io/tests/smart_corpus.rs (MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors): its import → export → import round trip needs the PSD importer/exporter and
// stays with the PCIO target.
//
// For every `SoLd`/`SoLE`: it parses, its filter stack maps (and writes back to the same stack),
// and `soldBytes` from the imported descriptor with the parsed placement (an unchanged smart
// object) re-parses to the same placement; `plldBytes` and the new `SoLd` pass PCPSD's strict
// structure check. Every `lnk2`/`lnk3`/`lnkD`/`lnkE` block lists its items (uuids agree with
// PCPSD's reader), and every placed layer's source resolves.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
@testable import PCIOSmart
import PCPSD
import Testing

enum SmartCorpus {
    /// `PCPSD_CORPUS`, default `<fixtures>/psd-corpus` (`Fixtures`); nil when absent.
    static var directory: URL? { Fixtures.psdCorpus }

    static func files() -> [URL] {
        guard let dir = directory, let all = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return all.filter { ["psd", "psb"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

@Suite(.enabled(if: SmartCorpus.directory != nil, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)"))
struct SmartCorpusTests {
    @Test func smartObjectsOfTheCorpus() throws {
        let files = SmartCorpus.files()
        #expect(files.count >= 36)
        var failures: [String] = []
        var (withSmart, sold, parsed, stacks, filters, unsupported, sameDescriptor, quadKept) = (0, 0, 0, 0, 0, 0, 0, 0)
        var (perspective, warped, resolved, linkBlocks, linkItems, embedded, samePlacement) = (0, 0, 0, 0, 0, 0, 0)
        for url in files {
            let name = url.lastPathComponent
            let psd = try PSDFile(contentsOf: url)
            func fail(_ what: String) { failures.append("\(name): \(what)") }
            // The linked-file blocks.
            var meta = Metadata()
            for gb in psd.globalBlocks where ["lnk2", "lnk3", "lnkD", "lnkE"].contains(gb.key) {
                let data = [UInt8](gb.data)
                meta.psdGlobalBlocks.append(PSDGlobalBlock(signature: gb.signature.psdKey, key: gb.key.psdKey, data: data))
                linkBlocks += 1
                let uuids = Linked.blockUuids(data)
                let theirs = (try? PSDLinkedFiles(bytes: gb.data))?.items.compactMap { $0.info?.uniqueID } ?? []
                if uuids != theirs || (uuids.isEmpty && !gb.data.isEmpty) { fail("\(gb.key) lists \(uuids) (PCPSD: \(theirs))") }
                linkItems += uuids.count
                let files = Linked.parseLinkedFiles(data)
                embedded += files.count
                let theirEmbedded = (try? PSDLinkedFiles(bytes: gb.data))?.items.compactMap(\.info).filter { $0.kind == "liFD" } ?? []
                if files.map(\.uuid) != theirEmbedded.map(\.uniqueID) || zip(files, theirEmbedded).contains(where: { $0.bytes != [UInt8]($1.data) }) {
                    fail("\(gb.key): embedded files differ from PCPSD's")
                }
                if Linked.rebuildBlock(data, { _ in true }, []) != nil { fail("\(gb.key): an unchanged rebuild is not nil") }
                if Linked.rebuildBlock(data, { _ in true }, [Linked.LinkedFile(uuid: "x", fileName: "x", bytes: [])]).map({ Array($0.prefix(data.count)) }) != data {
                    fail("\(gb.key): a rebuild does not keep the original items first")
                }
            }
            var fileHasSmart = false
            for rec in psd.layers {
                for key: FourCC in ["SoLd", "SoLE"] {
                    guard let block = rec.block(key) else { continue }
                    fileHasSmart = true
                    sold += 1
                    let data = [UInt8](block.data)
                    let layer = "\(rec.displayName) \(key)"
                    guard let p = SmartMap.parseSold(data) else {
                        fail("\(layer) does not parse")
                        continue
                    }
                    parsed += 1
                    if Linked.findLinkedFile(meta, p.idnt) != nil || meta.psdGlobalBlocks.contains(where: { Linked.blockUuids($0.data).contains(p.idnt) }) {
                        resolved += 1
                    }
                    // The filter stack maps and writes back to itself.
                    if let stack = p.stack {
                        stacks += 1
                        filters += stack.filters.count
                        unsupported += stack.filters.filter { $0.command == SmartMap.unsupportedFilter }.count
                        var w: [String] = []
                        let back = SmartMap.filterStack(SmartMap.filterFX(stack, layer, &w))
                        if !w.isEmpty || back != stack { fail("\(layer): filter stack does not write back (\(w))") }
                    }
                    // An unchanged placement written from the imported descriptor.
                    let warp = Blocks.parsePlacedWarp(key, data)
                    let persp = Blocks.parseSmartPerspective(key, data)
                    if warp != nil { warped += 1 }
                    if persp != nil { perspective += 1 }
                    let spec = SmartMap.PlacedSpec(idnt: p.idnt, placed: p.placed, transform: p.transform, perspective: persp,
                                                   size: SmartMap.storedSize(p.descriptor) ?? SIMD2(1, 1),
                                                   dpi: Blocks.num(p.descriptor["Rslt"]) ?? 72, warp: warp,
                                                   filterFX: SmartMap.getDesc(p.descriptor, "filterFX"))
                    if !SmartMap.quadMoved(p.descriptor, spec) { quadKept += 1 }
                    var w: [String] = []
                    let out = SmartMap.soldBytes(p.descriptor, spec, &w)
                    guard let q = SmartMap.parseSold(out) else {
                        fail("\(layer): regenerated SoLd does not parse")
                        continue
                    }
                    // Only `warp` is always rewritten (Photoshop's identity `warpCustom` reads as no warp and goes out as
                    // `warpNone`, as in photocraft).
                    func noWarp(_ d: PSDDescriptor) -> [PSDDescriptor.Item] { d.items.filter { !$0.key.is("warp") } }
                    if noWarp(q.descriptor) == noWarp(p.descriptor) { sameDescriptor += 1 }
                    let close = zip(q.transform.m, p.transform.m).allSatisfy { abs($0 - $1) <= 1e-9 * (1 + abs($1)) }
                    if q.idnt != p.idnt || q.placed != p.placed || q.stack != p.stack || !close {
                        fail("\(layer): regenerated placement differs: \(q.transform) vs \(p.transform)")
                    } else {
                        samePlacement += 1
                    }
                    if Blocks.parsePlacedWarp(key, out) != warp { fail("\(layer): warp changed") }
                    let persp2 = Blocks.parseSmartPerspective(key, out)
                    if (persp == nil) != (persp2 == nil)
                        || zip(persp ?? [], persp2 ?? []).contains(where: { abs($0 - $1) > 1e-6 * (1 + abs($0)) }) {
                        fail("\(layer): perspective changed")
                    }
                    if !w.isEmpty { fail("\(layer): warnings \(w)") }
                    do {
                        try PSDTaggedBlock(key: "SoLd", bytes: out).checkStructure()
                        try PSDTaggedBlock(key: "PlLd", bytes: SmartMap.plldBytes(spec, &w)).checkStructure()
                    } catch {
                        fail("\(layer): strict structure: \(error)")
                    }
                }
            }
            if fileHasSmart { withSmart += 1 }
        }
        print("""
            PCIOSmart corpus: \(files.count) files, \(withSmart) with smart objects; SoLd/SoLE \(parsed)/\(sold) parse, \
            \(resolved) sources resolve, \(warped) warped, \(perspective) perspective; filter stacks \(stacks) (\(filters) filters, \
            \(unsupported) unsupported); regenerated unchanged: \(samePlacement) same placement, \(quadKept) keep Trnf, \
            \(sameDescriptor) identical descriptors apart from the warp; link blocks \(linkBlocks) (\(linkItems) items, \(embedded) embedded files)
            """)
        for f in failures { print("  FAIL \(f)") }
        #expect(failures.isEmpty, "\(failures.count) failures")
        #expect(parsed == sold && sold > 0)
        #expect(resolved == parsed)
    }
}
