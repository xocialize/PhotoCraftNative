// The TIFF / Photoshop Raw reader and the stored-domain mapping, on synthetic files written here.

import Foundation
import Testing
import PCPSD
@testable import PSOracleKit

/// Writes minimal uncompressed TIFFs.
enum TIFFWriter {
    static func make(width: Int, height: Int, bits: Int, samples: [[Double]], photometric: Int, bigEndian: Bool, planar: Bool = false,
                     float: Bool = false, extraSamples: [Int] = []) -> Data {
        var body = [UInt8]()
        func put16(_ v: Int, into b: inout [UInt8]) { bigEndian ? b.append(contentsOf: [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) : b.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
        func put32(_ v: UInt32, into b: inout [UInt8]) {
            let bytes = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
            b.append(contentsOf: bigEndian ? bytes : bytes.reversed())
        }
        let spp = samples.count
        func sample(_ v: Double, into b: inout [UInt8]) {
            switch bits {
            case 8: b.append(UInt8(v))
            case 16: put16(Int(v), into: &b)
            default: put32(Float(v).bitPattern, into: &b)
            }
        }
        if bits == 1 {
            let rb = (width + 7) / 8
            for y in 0 ..< height {
                var row = [UInt8](repeating: 0, count: rb)
                for x in 0 ..< width where samples[0][y * width + x] != 0 { row[x / 8] |= 0x80 >> UInt8(x % 8) }
                body += row
            }
        } else if planar {
            for s in 0 ..< spp { for v in samples[s] { sample(v, into: &body) } }
        } else {
            for i in 0 ..< width * height { for s in 0 ..< spp { sample(samples[s][i], into: &body) } }
        }
        var tags: [(Int, Int, [Int])] = [(256, 4, [width]), (257, 4, [height]), (258, 3, [Int](repeating: bits, count: spp)), (259, 3, [1]),
                                         (262, 3, [photometric]), (273, 4, [0]), (277, 3, [spp]), (278, 4, [height]), (279, 4, [body.count]),
                                         (284, 3, [planar ? 2 : 1])]
        if !extraSamples.isEmpty { tags.append((338, 3, extraSamples)) }
        if float { tags.append((339, 3, [Int](repeating: 3, count: spp))) }
        tags.sort { $0.0 < $1.0 }
        var out = [UInt8]()
        out += bigEndian ? [0x4D, 0x4D] : [0x49, 0x49]
        put16(42, into: &out)
        let ifdOffset = 8
        put32(UInt32(ifdOffset), into: &out)
        let ifdSize = 2 + 12 * tags.count + 4
        var extra = [UInt8]()
        let extraStart = ifdOffset + ifdSize
        let dataStart = extraStart + 64
        var ifd = [UInt8]()
        put16(tags.count, into: &ifd)
        for (tag, type, values) in tags {
            put16(tag, into: &ifd)
            put16(type, into: &ifd)
            put32(UInt32(values.count), into: &ifd)
            var vals = [UInt8]()
            for v in values { type == 3 ? put16(tag == 273 ? dataStart : v, into: &vals) : put32(UInt32(tag == 273 ? dataStart : v), into: &vals) }
            if vals.count <= 4 {
                ifd += vals + [UInt8](repeating: 0, count: 4 - vals.count)
            } else {
                put32(UInt32(extraStart + extra.count), into: &ifd)
                extra += vals
            }
        }
        put32(0, into: &ifd)
        out += ifd
        out += extra + [UInt8](repeating: 0, count: 64 - extra.count)
        out += body
        return Data(out)
    }
}

@Suite struct ReferenceImageTests {
    @Test(arguments: [true, false]) func readsEightAndSixteenBitChunkyAndPlanar(bigEndian: Bool) throws {
        let w = 5, h = 3
        let planes8 = (0 ..< 3).map { c in (0 ..< w * h).map { Double(($0 * 17 + c * 40) % 256) } }
        for planar in [false, true] {
            let img = try ReferenceImageReader.readTIFF(TIFFWriter.make(width: w, height: h, bits: 8, samples: planes8, photometric: 2, bigEndian: bigEndian, planar: planar))
            #expect(img.planes == planes8 && img.bits == 8 && img.colorSamples == 3)
        }
        let planes16 = (0 ..< 4).map { c in (0 ..< w * h).map { Double(($0 * 4099 + c * 811) % 65536) } }
        let img16 = try ReferenceImageReader.readTIFF(TIFFWriter.make(width: w, height: h, bits: 16, samples: planes16, photometric: 2, bigEndian: bigEndian, extraSamples: [1]))
        #expect(img16.planes == planes16 && img16.extraSamples == [1] && img16.colorSamples == 3)
        #expect(PixelCompare.referenceAlpha(img16) == planes16[3])
    }

    @Test func readsFloatAndBitmap() throws {
        let w = 9, h = 2
        let f = [(0 ..< w * h).map { Double(Float($0) * 0.37 - 1.5) }]
        let img = try ReferenceImageReader.readTIFF(TIFFWriter.make(width: w, height: h, bits: 32, samples: f, photometric: 1, bigEndian: true, float: true))
        #expect(img.isFloat && img.planes == f)
        let bitsPlane = [(0 ..< w * h).map { Double(($0 * 7) % 3 == 0 ? 1 : 0) }]
        let b = try ReferenceImageReader.readTIFF(TIFFWriter.make(width: w, height: h, bits: 1, samples: bitsPlane, photometric: 0, bigEndian: true))
        #expect(b.planes == bitsPlane)
    }

    @Test func mapsCMYKAndLabToStoredValues() throws {
        // CMYK ink 0 = no ink → PSD stores 255; Lab a* = −28 (signed byte 228) → PSD 100.
        let cmyk = try ReferenceImageReader.readTIFF(TIFFWriter.make(width: 1, height: 1, bits: 8, samples: [[0], [255], [10], [128]], photometric: 5, bigEndian: true))
        #expect(PixelCompare.referenceColorPlanes(cmyk).map(\.[0]) == [255, 0, 245, 127])
        let lab = try ReferenceImageReader.readTIFF(TIFFWriter.make(width: 1, height: 1, bits: 8, samples: [[200], [228], [30]], photometric: 8, bigEndian: true))
        #expect(PixelCompare.referenceColorPlanes(lab).map(\.[0]) == [200, 100, 158])
        let lab16 = try ReferenceImageReader.readTIFF(TIFFWriter.make(width: 1, height: 1, bits: 16, samples: [[40000], [65535], [1]], photometric: 8, bigEndian: true))
        #expect(PixelCompare.referenceColorPlanes(lab16).map(\.[0]) == [40000, 32767, 32769])
    }

    @Test func readsPhotoshopRaw() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pso-raw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.raw")
        try Data([0x12, 0x34, 0xAB, 0xCD, 0x00, 0x01, 0xFF, 0xFF]).write(to: url)
        let img = try ReferenceImageReader.readRaw(contentsOf: url, width: 2, height: 1, channels: 2, bits: 16)
        #expect(img.planes == [[0x1234, 0x0001], [0xABCD, 0xFFFF]])
    }

    @Test func storedValuesDecodeEveryDepth() {
        #expect(PixelCompare.storedValues([0b1010_0000], depth: 1, width: 3, height: 1) == [1, 0, 1])
        #expect(PixelCompare.storedValues([0x01, 0x02], depth: 16, width: 1, height: 1) == [258])
        let half = Float(0.5).bitPattern
        #expect(PixelCompare.storedValues([UInt8(half >> 24), UInt8(half >> 16 & 0xFF), UInt8(half >> 8 & 0xFF), UInt8(half & 0xFF)], depth: 32, width: 1, height: 1) == [0.5])
    }

    @Test func mergedComparisonIsExactForAnIdenticalComposite() throws {
        // A PCPSD-built RGB file against a TIFF holding its own merged planes.
        var b = PSDBuilder(width: 4, height: 2)
        var px: [UInt8] = []
        for i in 0 ..< 8 {
            let r = UInt8(i * 30), g = UInt8(255 - i * 20), b = UInt8(i * 7)
            px += [r, g, b, 255]
        }
        b.pushLayer(PSDLayerSpec(name: "L", left: 0, top: 0, width: 4, height: 2, pixels: .u8(px)))
        b.setComposite(.u8(px))
        let f = try PSDFile(data: b.build().serialized())
        let planes = try PixelCompare.mergedPlanes(f)
        let tif = try ReferenceImageReader.readTIFF(TIFFWriter.make(width: 4, height: 2, bits: 8, samples: Array(planes.prefix(3)), photometric: 2, bigEndian: true))
        let d = try PixelCompare.merged(f, against: tif)
        #expect(d.exact && d.channels.count == 3)
        let lc = try PixelCompare.layerCanvas(f, record: 0, masked: false)
        #expect(lc.color[0] == planes[0] && lc.alpha.allSatisfy { $0 == 255 })
    }

    @Test func factsMapBlendModesAndAdjustments() {
        let l = PhotoshopFacts.layer(["name": "x", "kind": "adjustment", "adjustment": "hueSaturation", "blendMode": "blendSubtraction", "opacity": 128,
                                      "fillOpacity": 255, "visible": true, "clipped": true, "effects": [["type": "solidFill", "enabled": true, "present": true]]])
        #expect(l.kind == "adjustment:hue2" && l.blendMode == "fsub" && l.clipped && l.effects == ["colorOverlay"])
    }
}
