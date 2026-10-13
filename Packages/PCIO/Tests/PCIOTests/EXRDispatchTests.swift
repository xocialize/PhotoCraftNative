// Opening a multi-part OpenEXR as a flat image: the part with the most colour, as
// photocraft-codecs' EXR decoder does (crates/codecs/src/codecs/exr.rs `pick_part`, `decode`).
// Port of photocraft-io's flat import behaviour, MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Testing
@testable import PCIO

enum EXRDispatchKit {
    /// A scan-line, uncompressed, 32-bit float multi-part OpenEXR: each part is (name, channel
    /// names, value of channel k at pixel i = values(k, i)).
    static func multipart(width: Int, height: Int, _ parts: [(name: String, channels: [String])], value: (Int, Int, Int) -> Float) -> [UInt8] {
        var b: [UInt8] = [0x76, 0x2F, 0x31, 0x01]
        func u32(_ v: UInt32) { b += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
        func i32(_ v: Int) { u32(UInt32(bitPattern: Int32(v))) }
        func attr(_ name: String, _ type: String, _ value: [UInt8]) {
            b += Array(name.utf8) + [0] + Array(type.utf8) + [0]
            u32(UInt32(value.count))
            b += value
        }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
        func box() -> [UInt8] { le32(0) + le32(0) + le32(UInt32(width - 1)) + le32(UInt32(height - 1)) }
        u32(2 | 0x1000)
        for p in parts {
            var chlist: [UInt8] = []
            for c in p.channels.sorted() { chlist += Array(c.utf8) + [0] + le32(2) + [0, 0, 0, 0] + le32(1) + le32(1) }
            chlist.append(0)
            attr("channels", "chlist", chlist)
            attr("compression", "compression", [0])
            attr("dataWindow", "box2i", box())
            attr("displayWindow", "box2i", box())
            attr("lineOrder", "lineOrder", [0])
            attr("pixelAspectRatio", "float", le32(Float(1).bitPattern))
            attr("screenWindowCenter", "v2f", le32(0) + le32(0))
            attr("screenWindowWidth", "float", le32(Float(1).bitPattern))
            attr("name", "string", Array(p.name.utf8))
            attr("type", "string", Array("scanlineimage".utf8))
            attr("chunkCount", "int", le32(UInt32(height)))
            b.append(0)
        }
        b.append(0)
        // Offset tables, then one chunk per scan line: part, y, size, each channel's row.
        let tableStart = b.count
        b += [UInt8](repeating: 0, count: parts.count * height * 8)
        var offsets: [UInt64] = []
        for (pi, p) in parts.enumerated() {
            let sorted = p.channels.sorted()
            for y in 0 ..< height {
                offsets.append(UInt64(b.count))
                u32(UInt32(pi))
                i32(y)
                i32(sorted.count * width * 4)
                for c in sorted {
                    let k = p.channels.firstIndex(of: c) ?? 0
                    for x in 0 ..< width { u32(value(pi, k, y * width + x).bitPattern) }
                }
            }
        }
        for (i, o) in offsets.enumerated() {
            for j in 0 ..< 8 { b[tableStart + i * 8 + j] = UInt8(o >> (8 * UInt64(j)) & 0xFF) }
        }
        return b
    }
}

@Suite struct EXRDispatchTests {
    init() { ExportSweep.install() }
    @Test func multiPartEXROpensTheMostColourfulPart() throws {
        // Part 0: a depth AOV (one channel); part 1: RGB; part 2: RGBA (the one opened).
        let parts: [(name: String, channels: [String])] = [("depth", ["Z"]), ("beauty", ["R", "G", "B"]), ("rgba", ["R", "G", "B", "A"])]
        let bytes = EXRDispatchKit.multipart(width: 3, height: 2, parts) { part, k, i in Float(part * 10 + k) + Float(i) / 100 }
        let r = try DocumentIO.importFile(name: "render.exr", bytes: bytes)
        let d = r.document
        #expect(d.mode == .rgb && d.depth == .f32 && d.size == PixelSize(width: 3, height: 2))
        #expect(r.warnings.first == "only one of 3 EXR parts was imported", "\(r.warnings)")
        let px = try #require(d.layers.first?.surface).readRegion(d.bounds)
        // R, G, B, A of part 2 are channels 0…3 of its declared order.
        for i in 0 ..< 6 {
            for c in 0 ..< 4 { #expect(abs(px[i * 4 + c] - (Float(20 + c) + Float(i) / 100)) < 1e-6, "pixel \(i) channel \(c)") }
        }
        #expect(d.layers.first?.name == "Layer 0")
        // Linear light, tagged as such.
        #expect(d.iccProfile != nil)
    }

    @Test func earliestPartWinsATie() throws {
        let parts: [(name: String, channels: [String])] = [("a", ["R", "G", "B"]), ("b", ["R", "G", "B"])]
        let bytes = EXRDispatchKit.multipart(width: 1, height: 1, parts) { part, _, _ in Float(part) + 0.5 }
        let d = try DocumentIO.importFile(name: "two.exr", bytes: bytes).document
        #expect(try #require(d.layers.first?.surface).readRegion(d.bounds)[0] == 0.5)
        #expect(d.layers.first?.name == "Background")
    }
}
