// Malformed input: every error path returns an error, never traps.
// Port of photocraft-psd (crates/psd/tests/malformed.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors; proptests replaced by seeded randomised loops.

import Foundation
import Testing
@testable import PCPSD

@Suite struct MalformedTests {
    func truncationSweep(_ bytes: Data, _ name: String) {
        let b = [UInt8](bytes)
        for cut in 0 ..< b.count {
            #expect((try? PSDFile(bytes: Array(b[0 ..< cut]))) == nil, "\(name): truncation at \(cut)/\(b.count) parsed")
        }
        #expect((try? PSDFile(bytes: b)) != nil, "\(name): full file must parse")
    }

    @Test(arguments: [PSDVersion.psd, .psb])
    func truncateSmall(version: PSDVersion) throws {
        for c in PSDCompression.all { truncationSweep(try TestGen.small(version, c).serialized(), "small \(version) \(c)") }
    }

    @Test func truncateMergedOnlyAllModes() throws {
        for mode in TestGen.modes {
            for depth in TestGen.modeDepths(mode) {
                truncationSweep(try TestGen.mergedOnly(.psd, mode, depth, .rle, 5, 3).serialized(), "\(mode) \(depth)")
            }
        }
    }

    @Test func truncateBuilder16BitLr16() throws {
        var b = PSDBuilder(width: 3, height: 2, depth: 16)
        b.pushLayer(PSDLayerSpec(name: "x", left: 0, top: 0, width: 3, height: 2, pixels: .u16([UInt16](repeating: 1000, count: 24))))
        truncationSweep(try b.serialized(), "builder 16")
    }

    @Test func emptyInput() {
        #expect(throws: PSDError.unexpectedEOF(offset: 0, needed: 4)) { try PSDFile(bytes: []) }
    }

    @Test func badFileSignature() throws {
        var b = [UInt8](try TestGen.small(.psd, .raw).serialized())
        b[0 ..< 4] = [0x38, 0x42, 0x50, 0x58]
        #expect(throws: PSDError.invalidSignature(expected: "8BPS", found: "8BPX")) { try PSDFile(bytes: b) }
    }

    @Test func badVersion() throws {
        var b = [UInt8](try TestGen.small(.psd, .raw).serialized())
        for v: UInt16 in [0, 3, 0xFFFF] {
            b[4] = UInt8(v >> 8); b[5] = UInt8(v & 0xFF)
            #expect(throws: PSDError.unsupportedVersion(v)) { try PSDFile(bytes: b) }
        }
    }

    @Test func badDepthAndChannels() throws {
        let good = [UInt8](try TestGen.small(.psd, .raw).serialized())
        var b = good; b[22] = 0; b[23] = 7
        #expect(throws: PSDError.self) { try PSDFile(bytes: b) }
        b = good; b[12] = 0; b[13] = 0
        #expect(throws: PSDError.self) { try PSDFile(bytes: b) }
        b = good; b[12] = 0; b[13] = 57
        #expect(throws: PSDError.self) { try PSDFile(bytes: b) }
    }

    @Test func oversizedDimensionsRejected() throws {
        var b = [UInt8](try TestGen.small(.psb, .raw).serialized())
        let v: UInt32 = 300_001
        b[14 ..< 18] = [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        #expect(throws: PSDError.limitExceeded("image dimensions exceed 300000")) { try PSDFile(bytes: b) }
    }

    @Test func zeroDimensionsRejected() throws {
        let good = [UInt8](try TestGen.small(.psd, .raw).serialized())
        for range in [14 ..< 18, 18 ..< 22, 14 ..< 22] {
            var b = good
            for i in range { b[i] = 0 }
            do {
                _ = try PSDFile(bytes: b)
                Issue.record("zero dimensions parsed")
            } catch {
                #expect("\(error)".contains("at least 1x1"))
            }
        }
        var f = TestGen.small(.psd, .raw)
        f.header.width = 0
        #expect(throws: PSDError.self) { try f.validate() }
    }

    @Test func hugeDeclaredDimensionsSmallData() throws {
        var f = TestGen.mergedOnly(.psb, .grayscale, 8, .rle, 1, 1)
        f.header.width = 300_000
        f.header.height = 300_000
        #expect(throws: PSDError.self) { try PSDFile(data: try f.serialized()) }
        f.imageData = PSDImageData(compression: .zip, data: Data(Zlib.compress([UInt8](repeating: 0, count: 100))))
        let g = try PSDFile(data: try f.serialized())
        #expect(throws: PSDError.self) { try g.decodeMerged() }
    }

    /// PhotoDemon errata: a resource section that stops parsing keeps its bytes (and warns) instead of
    /// failing the file (photocraft errors here).
    @Test func badResourceSignatureKeptRaw() throws {
        let f = TestGen.small(.psd, .raw)
        var b = [UInt8](try f.serialized())
        b[34 ..< 38] = [0x58, 0x58, 0x58, 0x58]
        let g = try PSDFile(bytes: b)
        #expect(g.resources.isEmpty)
        #expect(!g.resourcesTrailing.isEmpty)
        #expect(!g.warnings.isEmpty)
        #expect(try g.serialized() == Data(b), "kept byte for byte")
    }

    @Test func zeroLengthResourcesAccepted() throws {
        var f = TestGen.small(.psd, .raw)
        f.resources.append(PSDImageResource(id: 1060, data: Data()))
        f.resources.append(PSDImageResource(id: 1039, data: Data()))
        try assertStable(f, "zero-length resources (Photopea)")
    }

    @Test func badLayerBlendSignature() throws {
        let b = [UInt8](try TestGen.small(.psd, .raw).serialized())
        let pos = find(b, Array("8BIMnorm".utf8))!
        var b2 = b
        b2[pos] = UInt8(ascii: "X")
        #expect(throws: PSDError.self) { try PSDFile(bytes: b2) }
    }

    @Test func oversizedSectionLengths() throws {
        let b = [UInt8](try TestGen.small(.psd, .raw).serialized())
        var b2 = b; b2[26 ..< 30] = [0xFF, 0xFF, 0xFF, 0xFF]
        #expect(throws: PSDError.self) { try PSDFile(bytes: b2) }
        var b3 = b; b3[30 ..< 34] = [0xFF, 0xFF, 0xFF, 0xFF]
        #expect(throws: PSDError.self) { try PSDFile(bytes: b3) }
    }

    @Test func corruptZipMergedRejected() throws {
        var f = TestGen.small(.psd, .zip)
        var d = [UInt8](f.imageData.data)
        d[d.count / 2] ^= 0xFF
        d[d.count / 2 + 1] ^= 0x55
        f.imageData.data = Data(d)
        #expect(throws: PSDError.self) { try PSDFile(data: try f.serialized()) }
    }

    @Test func corruptLayerChannelIsLazyError() throws {
        var f = TestGen.small(.psd, .rle)
        let id = f.layers[0].channels[1].id
        f.layers[0].channels[1].data = Data(repeating: 0x7F, count: f.layers[0].channels[1].data.count)
        let p = try PSDFile(data: try f.serialized())
        #expect(throws: PSDError.self) { try p.layers[0].decodeChannel(id, depth: 8, version: .psd) }
        #expect(throws: PSDError.self) { try p.layer(0)!.rgba8() }
    }

    @Test func negativeLayerRectDecodeErrors() throws {
        var f = TestGen.small(.psd, .raw)
        f.layers[0].rect = PSDRect(top: 10, left: 0, bottom: 0, right: 4)
        let p = try PSDFile(data: try f.serialized())
        #expect(throws: PSDError.self) { try p.layers[0].decodeChannel(0, depth: 8, version: .psd) }
        #expect(throws: PSDError.self) { try p.layer(0)!.rgba8() }
    }

    @Test func tooManyLayerChannels() throws {
        let f2 = TestGen.mergedOnly(.psd, .rgb, 8, .raw, 1, 1)
        let b2 = [UInt8](try f2.serialized())
        let resLen = Int(UInt32(b2[30]) << 24 | UInt32(b2[31]) << 16 | UInt32(b2[32]) << 8 | UInt32(b2[33]))
        let lm = 34 + resLen
        var rec: [UInt8] = [0, 1] + [UInt8](repeating: 0, count: 16) + [0xFF, 0xFF]
        let section = [UInt8(rec.count >> 24), UInt8(rec.count >> 16 & 0xFF), UInt8(rec.count >> 8 & 0xFF), UInt8(rec.count & 0xFF)] + rec
        rec = section
        var out = Array(b2[0 ..< lm])
        out += [UInt8(rec.count >> 24), UInt8(rec.count >> 16 & 0xFF), UInt8(rec.count >> 8 & 0xFF), UInt8(rec.count & 0xFF)] + rec
        let oldLen = Int(UInt32(b2[lm]) << 24 | UInt32(b2[lm + 1]) << 16 | UInt32(b2[lm + 2]) << 8 | UInt32(b2[lm + 3]))
        out += b2[(lm + 4 + oldLen)...]
        #expect(throws: PSDError.self) { try PSDFile(bytes: out) }
    }

    /// PhotoDemon errata: a channel whose stored length is 1 is kept raw instead of failing the file.
    @Test func channelLengthOneKeptRaw() throws {
        var f = TestGen.small(.psd, .raw)
        f.layers[1].channels[0] = PSDChannel(id: f.layers[1].channels[0].id, compression: nil, data: Data([42]))
        try assertStable(f, "length-1 channel")
    }

    @Test func randomBytesNeverTrap() {
        var rng = SeededRandom(0xFEED)
        for _ in 0 ..< 400 { _ = try? PSDFile(bytes: rng.bytes(rng.int(0 ..< 512))) }
        let header = Array([UInt8](try! TestGen.small(.psd, .raw).serialized())[0 ..< 26])
        for _ in 0 ..< 400 { _ = try? PSDFile(bytes: header + rng.bytes(rng.int(0 ..< 512))) }
    }

    @Test func mutationsNeverTrap() throws {
        var rng = SeededRandom(0xC0FFEE)
        for iter in 0 ..< 600 {
            let v: PSDVersion = iter % 2 == 0 ? .psd : .psb
            var b = [UInt8](try TestGen.small(v, PSDCompression.all[iter % 4]).serialized())
            for _ in 0 ..< rng.int(1 ..< 8) { b[rng.int(0 ..< b.count)] = rng.byte() }
            guard let f = try? PSDFile(bytes: b) else { continue }
            _ = try? f.serialized()
            _ = try? f.decodeMerged()
            _ = try? f.compositeRGBA8()
            _ = f.layerTree()
            for l in f.layerViews {
                _ = try? l.rgba8()
                _ = l.userMask()
                _ = l.name
                for bl in l.record.blocks { _ = try? bl.parsed(); _ = try? bl.checkStructure() }
            }
            for r in f.resources { _ = try? r.parsed() }
        }
    }

    @Test func parsedMutantsAreModelStable() throws {
        var rng = SeededRandom(0xABCD)
        let base = [UInt8](try TestGen.small(.psd, .rle).serialized())
        for _ in 0 ..< 600 {
            var b = base
            b[rng.int(0 ..< b.count)] = rng.byte()
            guard let f = try? PSDFile(bytes: b) else { continue }
            let out = try f.serialized()
            #expect(try PSDFile(data: out) == f)
        }
    }
}
