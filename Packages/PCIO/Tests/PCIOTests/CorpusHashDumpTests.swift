// An opt-in hash dump of the format corpus saved as `.pcraft` (PCFormatTests' `SaveHashDumpTests` does `richDoc`):
// with `PCRAFT_HASH_DUMP=<file>`, each PSD/PSB of the two corpora is opened and saved as a single-file `.pcraft` with
// its previews (`DocumentIO.export`) and as a forced-ZIP64 bundle, and `name manifest-sha256 file-sha256` lines are
// appended to the file. Run it at two commits and diff (AB-T-0255). MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

import CryptoKit
import Foundation
import PCDocument
import PCIOCore
@testable import PCFormat
import Testing
@testable import PCIO

@Suite(.serialized) struct CorpusHashDumpTests {
    static let file = ProcessInfo.processInfo.environment["PCRAFT_HASH_DUMP"]

    static func sha(_ bytes: [UInt8]) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    static func record(_ name: String, _ manifest: [UInt8], _ bytes: [UInt8]) throws {
        let url = URL(fileURLWithPath: try #require(file))
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data("\(name) \(sha(manifest)) \(sha(bytes)) \(manifest.count) \(bytes.count)\n".utf8))
        try h.close()
    }

    @Test(.enabled(if: file != nil && (Corpus.available || Corpus.psAvailable), "set PCRAFT_HASH_DUMP (and the fixtures)"))
    func formatCorpus() throws {
        var n = 0
        for url in Corpus.files + Corpus.psFiles {
            let name = Corpus.sweepName(url, "")
            let options = IOOptions(compositor: StoredPixelsCompositor())
            let doc = try DocumentIO.importFile(contentsOf: url, options: options).document
            let bytes = try DocumentIO.export(doc, as: "x.pcraft", options: options).bytes
            let w = PcraftWriter()
            let p = try w.prepare(doc, SaveOptions())
            try Self.record("\(name).export", p.manifest, bytes)
            w.forceZip64 = true
            let (forced, _) = try w.saveZip(doc)
            var model = p.model
            model.formatVersion = max(model.formatVersion, pcraftZip64FormatVersion)
            try Self.record("\(name).zip64", try ManifestJSON.encode(model), forced)
            n += 1
        }
        print("MEASURE corpus hash dump: \(n) files")
    }
}
