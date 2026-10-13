// Port of photocraft-io (crates/io/tests/psd_type_photoshop_bytes.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Type-layer bytes we write match what Photoshop writes for the same settings, checked against the
// Photoshop-authored files of the Photoshop corpus (PCPSD_CORPUS; skipped when absent) instead of
// photocraft's Photoshop 2026 oracles (photoshop/text/antialias-*.psd, warp-arc-50.psd): every type
// layer of the corpus is read, rebuilt by our TySh writer, and compared field by field:
// - EngineData `AntiAlias` numbers;
// - the four f32 values that end a `TySh` block (zeros unwarped, text-space bounds warped).
// Synthetic versions of both are PCIOTextTests' PSDTextTests (engineDataAntialiasNumbersMatchPhotoshop,
// tyShTrailingBoundsAreF32). Not ported: `version_info_matches_photoshop` (resource 1057 of
// Photoshop 2026; the corpus files were written by Photoshop CS6 to CC 2018, whose reader names
// differ).

import Foundation
import PCDocument
import PCFoundation
@testable import PCIOText
import PCPSD
import Testing
@testable import PCIO

@Suite(.enabled(if: Corpus.available, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)")) struct PSDTypePhotoshopBytesTests {
    init() { ExportSweep.install() }
    /// Every `TySh` of the corpus, with its file and layer names.
    static func corpusTySh() throws -> [(String, [UInt8])] {
        var out: [(String, [UInt8])] = []
        for url in Corpus.files {
            for r in try PSDFile(contentsOf: url).layers {
                if let b = r.block("TySh") { out.append(("\(url.lastPathComponent)/\(r.displayName)", [UInt8](b.data))) }
            }
        }
        return out
    }

    static func engineAntialias(_ tysh: [UInt8]) -> Double? {
        PSDText.parseTySh(tysh).flatMap { PSDText.engineData($0.text) }?.at("EngineDict", "AntiAlias")?.f64
    }

    static func rect(_ t: PSDText.TySh, _ key: String) -> SIMD4<Float>? {
        guard case let .descriptor(d)? = t.text[key] else { return nil }
        var v = SIMD4<Float>.zero
        for (i, k) in ["Left", "Top ", "Rght", "Btom"].enumerated() {
            guard case let .unitFloat(_, value)? = d[k] else { return nil }
            v[i] = Float(value)
        }
        return v
    }

    @Test func engineDataAntialiasMatchesPhotoshop() throws {
        let all = try Self.corpusTySh()
        #expect(!all.isEmpty)
        for (name, raw) in all {
            var layer = try #require(PSDText.textLayer(fromTySh: raw, dpi: 72), "\(name)")
            layer.psdRaw = nil
            let ours = PSDText.buildTySh(layer, dpi: 72, ink: nil)
            #expect(Self.engineAntialias(ours) == Self.engineAntialias(raw), "\(name)")
        }
    }

    @Test func tyShTrailingBoundsMatchPhotoshop() throws {
        for (name, raw) in try Self.corpusTySh() {
            let theirs = try #require(PSDText.parseTySh(raw), "\(name)")
            var layer = try #require(PSDText.textLayer(fromTySh: raw, dpi: 72), "\(name)")
            let warped = layer.warp != nil
            layer.psdRaw = nil
            let bounds = try #require(Self.rect(theirs, "bounds"), "\(name): bounds")
            let ours = try #require(PSDText.parseTySh(PSDText.buildTySh(layer, dpi: 72, ink: bounds)), "\(name)")
            #expect(ours.bounds == theirs.bounds, "\(name)")
            if warped { #expect(theirs.bounds == bounds, "\(name)") } else { #expect(theirs.bounds == .zero, "\(name)") }
        }
    }
}
