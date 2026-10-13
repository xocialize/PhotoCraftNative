// Port of photocraft-io (crates/io/tests/tiff_corpus.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Layered TIFF against the Photoshop corpus (`PCPSD_CORPUS`; skipped when absent): every PSD
// that imports is written as a layered TIFF and read back, and the result must equal the PSD round
// trip of the same document: the same layer structure (count, names, kinds) and the same render
// (within one 8-bit step). The layers go through the same PSD mapping in both directions, so any
// difference is a bug in the layer-data transcoder or the TIFF glue. Documents a TIFF stores flat
// (a lone Background, Multichannel) only compare the render. photocraft's corpus has more than
// 100 testable files; the 36-file corpus here asserts that at least one is tested.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Testing
@testable import PCIO

@Suite struct TIFFCorpusTests {
    init() { ExportSweep.install() }
    typealias Kit = FlatKit

    static func structure(_ layers: [Layer], _ out: inout [String], _ depth: Int) {
        for l in layers {
            out.append("\(String(repeating: " ", count: depth))\(l.name) [\(l.content.kindName)] \(l.blend) \(String(format: "%.3f", l.opacity)) mask=\(l.mask != nil) fx=\(l.effects.items.count)")
            if let g = l.group { structure(g.children, &out, depth + 1) }
        }
    }

    /// tiff_corpus.rs `max_diff`: premultiplied channels (alpha squared), everywhere.
    static func maxDiff(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Float {
        zip(a, b).reduce(Float(0)) { m, pq in max(m, (0 ..< 4).map { abs(pq.0[$0] * pq.0.w - pq.1[$0] * pq.1.w) }.max() ?? 0) }
    }

    /// Keys the importer reads from layer records or global blocks: dropping one of these loses
    /// something a user can see.
    static let mapped: Set<String> = [
        "lfx2", "lmfx", "lrFX", "TySh", "SoLd", "SoLE", "PlLd", "vmsk", "vsms", "vogk", "vscg", "vstk", "SoCo", "GdFl", "PtFl", "levl", "curv",
        "hue2", "brit", "thrs", "post", "expA", "vibA", "blnc", "mixr", "grdm", "phfl", "selc", "blwh", "clrL", "luni", "lsct", "lyid", "lclr",
        "iOpa", "clbl", "infx", "knko", "lspf", "fxrp", "brst", "shmd", "Patt", "FEid", "FXid", "FMsk", "artb", "artd", "cinf",
    ]

    @Test(.enabled(if: Corpus.available, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)")) func corpusRoundTripsThroughLayeredTIFF() throws {
        var tested = 0
        var failures: [String] = []
        var dropped: [String: Int] = [:]
        for url in Corpus.files {
            let name = url.lastPathComponent
            guard let bytes = try? [UInt8](Data(contentsOf: url)), let imported = try? Kit.importFile(name, bytes) else { continue }
            let doc = imported.document
            // Only modes a TIFF holds; Multichannel documents have no layers at all.
            guard [.grayscale, .rgb, .cmyk].contains(doc.pixelFormat.mode), doc.mode != .multichannel,
                  max(doc.size.width, doc.size.height) <= 4096 else { continue }
            tested += 1
            do {
                let psd = try ExportSweep.$name.withValue(Corpus.sweepName(url, ".reexport.psd")) { try Kit.export(doc, "x.psd") }
                let oracle = try Kit.importFile("x.psd", psd.bytes).document
                let out = try ExportSweep.$name.withValue(Corpus.sweepName(url, ".tiff-reexport.psd")) {
                    try Kit.export(doc, "x.tif", options: Kit.options(tiffLayers: true))
                }
                var mappedDrop: String?
                for w in out.warnings where w.hasPrefix("layer data: ") {
                    let rest = w.dropFirst("layer data: ".count)
                    guard let r = rest.range(of: " block (") else { continue }
                    let key = String(rest[..<r.lowerBound])
                    dropped[key, default: 0] += 1
                    if Self.mapped.contains(key) { mappedDrop = w }
                }
                if let w = mappedDrop { failures.append("\(name): mapped block dropped: \(w)"); continue }
                let back = try Kit.importFile("x.tif", out.bytes).document
                let flat = !TIFFLayers.wouldWriteLayers(doc)
                var (a, b) = ([String](), [String]())
                Self.structure(oracle.layers, &a, 0)
                Self.structure(back.layers, &b, 0)
                if a != b && !flat {
                    failures.append("\(name): layer structure changed:\n  \(a.joined(separator: "\n  "))\n  \(b.joined(separator: "\n  "))")
                    continue
                }
                var expected = oracle
                expected.channels.removeAll()
                let diff = Self.maxDiff(try Kit.flatten(expected), try Kit.flatten(back))
                if diff > 1 / 255 + 1e-5 { failures.append("\(name): render differs by \(diff)") }
            } catch {
                failures.append("\(name): \(error)")
            }
        }
        print("layered TIFF round trips: \(tested) tested, \(failures.count) failed")
        print("blocks dropped on the little-endian path: \(dropped.sorted { $0.key < $1.key })")
        for f in failures { print("FAIL \(f)") }
        #expect(failures.isEmpty, "\(failures.count) failures: \(failures.prefix(4))")
        #expect(tested > 0, "only \(tested) files tested")
    }
}
