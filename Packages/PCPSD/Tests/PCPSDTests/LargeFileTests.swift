// Large PSB behaviour: lazy decode and > 4 GB files (photocraft #375). The big test is opt-in
// (PCPSD_BIG_EDGE=<pixels>, e.g. 40000 for a ~6.5 GB file); run it in release:
// `swift test -c release -Xswiftc -enable-testing --filter LargeFileTests`.

import Foundation
import Testing
@testable import PCPSD

@Suite struct LargeFileTests {
    /// Opening never decodes layer channels: a corrupt channel only fails when it is decoded.
    @Test func openIsLazy() throws {
        var f = TestGen.small(.psb, .rle)
        f.layers[0].channels[1].data = Data(repeating: 0x7F, count: f.layers[0].channels[1].data.count)
        let parsed = try PSDFile(data: try f.serialized())
        #expect(parsed.layers.count == 4)
        #expect(throws: PSDError.self) { try parsed.layers[0].decodeChannel(parsed.layers[0].channels[1].id, depth: 8, version: .psb) }
    }

    /// Payloads are slices of the file buffer, not copies.
    @Test func payloadsShareTheFileBuffer() throws {
        let bytes = try TestGen.small(.psd, .raw).serialized()
        let f = try PSDFile(data: bytes)
        let ch = f.layers[0].channels[1].data
        #expect(ch.startIndex > 0, "a slice of the file data")
        #expect(f.imageData.data.endIndex == bytes.endIndex)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PCPSD_BIG_EDGE"] != nil, "set PCPSD_BIG_EDGE to run"))
    func bigPSBStreamsOpensLazilyAndDecodes() throws {
        let edge = Int(ProcessInfo.processInfo.environment["PCPSD_BIG_EDGE"] ?? "") ?? 40000
        let header = PSDHeader(version: .psb, width: UInt32(edge), height: UInt32(edge), channels: 3, depth: 8, colorMode: .rgb)
        let plane = edge * edge
        // A full-canvas raw layer: four planes of zeros (calloc'd lazily, so cheap to build).
        let channels = [Int16(-1), 0, 1, 2].map { PSDChannel(id: $0, compression: .raw, data: Data(count: plane)) }
        var rec = PSDLayerRecord(rect: PSDRect(x: 0, y: 0, width: UInt32(edge), height: UInt32(edge)), channels: channels,
                                 blendingRanges: .full(channels: 3), name: Array("big".utf8), blocks: [.unicodeName("big"), .layerID(1)])
        rec.channels[0].data = Data(repeating: 255, count: plane)
        // Merged RLE of zero rows, assembled row by row.
        let row = PackBits.encode([UInt8](repeating: 0, count: edge))
        var merged = Data(capacity: 3 * edge * (4 + row.count))
        for _ in 0 ..< 3 * edge { withUnsafeBytes(of: UInt32(row.count).bigEndian) { merged.append(contentsOf: $0) } }
        for _ in 0 ..< 3 * edge { merged.append(contentsOf: row) }
        var info = PSDLayerInfo(layers: [rec])
        try info.pad(to: 4, version: .psb)
        let file = PSDFile(header: header, resources: [PSDVersionInfo.resource(hasRealMergedData: true)], layerInfo: info,
                           globalLayerMask: PSDGlobalLayerMask(), imageData: PSDImageData(compression: .rle, data: merged))
        let url = Corpus.workDirectory.appendingPathComponent("big-\(edge).psb")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = ContinuousClock()
        let writeTime = try clock.measure { try file.write(to: url) }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        var opened: PSDFile?
        let openTime = try clock.measure { opened = try PSDFile(contentsOf: url) }
        let f = try #require(opened)
        #expect(f.layers.count == 1 && f.layers[0].channels.allSatisfy { $0.data.count == plane })
        var alpha: [UInt8] = []
        let decodeTime = try clock.measure { alpha = try f.layers[0].decodeChannel(-1, depth: 8, version: .psb) }
        #expect(alpha.count == plane && alpha.first == 255 && alpha.last == 255)
        let mergedTime = try clock.measure { _ = try f.imageData.decodeChannel(f.header, index: 2) }
        print("BIG PSB \(edge)×\(edge): \(size) bytes; write \(writeTime), open \(openTime), decode one 1-channel plane \(decodeTime), merged decode \(mergedTime)")
        #expect(size > 4 << 30 || edge < 33000)
    }
}
