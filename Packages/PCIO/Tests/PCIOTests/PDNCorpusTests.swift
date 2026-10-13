// Port of photocraft-io (crates/io/tests/pdn_corpus.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Local PDN oracles are not bundled: runs only with `PDN_TEST_DIR` set to a directory of PDNs and
// their exported PNGs (photocraft: `#[ignore]` + the same variable).

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Testing
@testable import PCIO

@Suite struct PDNCorpusTests {
    init() { ExportSweep.install() }
    typealias Kit = FlatKit

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PDN_TEST_DIR"] != nil, "requires PDN_TEST_DIR with real Paint.NET files and matching PNG exports"))
    func realPDNLayersAndNativeSaves() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PDN_TEST_DIR"]))
        let paths = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension.lowercased() == "pdn" }.sorted { $0.path < $1.path }
        #expect(!paths.isEmpty, "no PDN files found")
        var worst: Float = 0
        for path in paths {
            let doc = try Kit.importFile(path.path, [UInt8](try Data(contentsOf: path))).document
            let flat = try Kit.flatten(doc)
            let native = try Kit.export(doc, "copy.pcraft")
            let back = try Kit.importFile("copy.pcraft", native.bytes).document
            #expect(doc.layers == back.layers, "\(path.path)")
            #expect(flat == (try Kit.flatten(back)))
            let png = path.deletingPathExtension().appendingPathExtension("png")
            let oracle = try Kit.importFile("oracle.png", [UInt8](try Data(contentsOf: png))).document
            #expect(doc.size == oracle.size)
            let expected = try Kit.flatten(oracle)
            let error = zip(flat, expected).reduce(Float(0)) { max($0, Kit.pixelError($1.0, $1.1)) }
            print("\(path.path): \(doc.layers.count) layers, max PNG error \(String(format: "%.3f", error * 255))/255")
            worst = max(worst, error)
        }
        // Paint.NET 4.x quantized intermediate layers to 8 bits; our compositor keeps floats.
        #expect(worst <= 3 / 255, "max error \(worst)")
    }
}
