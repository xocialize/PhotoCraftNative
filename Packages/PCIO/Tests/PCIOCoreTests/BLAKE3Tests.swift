// BLAKE3 against published vectors (BLAKE3 specification / reference `test_vectors.json`).
// New in the port (photocraft-format hashes with the `blake3` crate); MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCIOCore

@Suite struct BLAKE3Tests {
    @Test func knownVectors() {
        #expect(BLAKE3.hex([]) == "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262")
        #expect(BLAKE3.hex(Array("abc".utf8)) == "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85")
    }

    @Test func incrementalEqualsOneShot() {
        let data: [UInt8] = (0 ..< 10_000).map { UInt8($0 % 251) }
        for split in [0, 1, 63, 64, 65, 1023, 1024, 1025, 3000, 9999] {
            var h = BLAKE3()
            h.update(Array(data[..<split]))
            h.update(Array(data[split...]))
            #expect(h.finalize() == BLAKE3.hash(data))
        }
    }
}

@Suite struct BLAKE3Speed {
    @Test func throughput() {
        let data = [UInt8](repeating: 7, count: 16 << 20)
        let t0 = Date()
        _ = BLAKE3.hash(data)
        let dt = Date().timeIntervalSince(t0)
        print("MEASURE blake3 16 MiB: \(String(format: "%.3f", dt)) s (\(String(format: "%.0f", 16 / dt)) MiB/s)")
    }
}
