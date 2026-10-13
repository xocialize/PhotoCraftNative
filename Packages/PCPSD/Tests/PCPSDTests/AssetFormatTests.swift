// Adobe asset formats: .aco, .ase, .grd, .shc, patterns (.pat / Patt blocks), .abr.
// Port of the inline tests of photocraft-psd (crates/psd/src/aco.rs, ase.rs, grd.rs, shc.rs,
// patterns.rs, abr.rs) and of tests/swatch_malformed.rs (bit-flip sweeps as seeded loops),
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCPSD

@Suite struct SwatchTests {
    static func acoSample() -> [PSDAco.Swatch] {
        [
            .init(name: "Pure Red", color: .rgb(65535, 0, 0)), .init(name: "Hue", color: .hsb(12000, 65535, 40000)),
            .init(name: "Cyan ink", color: .cmyk(65535, 0, 0, 1234)), .init(name: "Lab −", color: .lab(l: 5321, a: -12800, b: 12700)),
            .init(name: "Gray", color: .gray(5000)), .init(name: "Book 日本", color: .other(space: 3, values: [1, 2, 3, 4])),
            .init(name: "", color: .rgb(1, 2, 3)),
        ]
    }

    @Test func acoRoundTripsEverySpace() throws {
        let s = Self.acoSample()
        let bytes = try PSDAco.write(s)
        let f = try PSDAco.parse(bytes)
        #expect(f.hasNames && f.swatches == s)
        #expect(try PSDAco.write(f.swatches) == bytes)
        #expect(PSDAco.Color(space: 2, values: [0, 65535, 65535, 65535]) == .cmyk(65535, 0, 0, 0))
        #expect(PSDAco.Color(space: 7, values: [10000, 0xFF38, 200, 0]) == .lab(l: 10000, a: -200, b: 200))
    }

    @Test func acoVersion1And2Only() throws {
        let v1: [UInt8] = [0, 1, 0, 2, 0, 0, 255, 255, 0, 0, 0, 0, 0, 0, 0, 8, 0x13, 0x88, 0, 0, 0, 0, 0, 0]
        let f = try PSDAco.parse(Data(v1))
        #expect(!f.hasNames && f.swatches.map(\.color) == [.rgb(65535, 0, 0), .gray(5000)])
        #expect(try PSDAco.parse(Data(v1 + [0, 0, 0, 0])).swatches.count == 2)
        let v2: [UInt8] = [0, 2, 0, 1, 0, 0, 0, 1, 0, 2, 0, 3, 0, 0, 0, 0, 0, 2, 0, UInt8(ascii: "O"), 0, UInt8(ascii: "K")]
        #expect(try PSDAco.parse(Data(v2)).swatches == [.init(name: "OK", color: .rgb(1, 2, 3))])
    }

    @Test func acoHostileInput() throws {
        let good = [UInt8](try PSDAco.write(Self.acoSample()))
        let v1End = 4 + Self.acoSample().count * 10
        for n in 0 ..< good.count {
            let r = try? PSDAco.parse(Data(good.prefix(n)))
            if n == v1End || (n > v1End && n < v1End + 4) { #expect(r != nil, "\(n)") } else { #expect(r == nil, "\(n)") }
        }
        #expect((try? PSDAco.parse(Data([0, 3, 0, 0]))) == nil)
        #expect((try? PSDAco.parse(Data([0, 1, 0xFF, 0xFF]))) == nil)
        #expect(throws: PSDError.self) { try PSDAco.write([PSDAco.Swatch](repeating: .init(name: "", color: .gray(0)), count: PSDAco.maxSwatches + 1)) }
        let long = try PSDAco.parse(try PSDAco.write([.init(name: String(repeating: "x", count: 5000), color: .gray(0))]))
        #expect(long.swatches[0].name.count == PSDAco.maxNameUnits)
        // Names never split a surrogate pair.
        let capped = try PSDAco.parse(try PSDAco.write([.init(name: String(repeating: "a", count: PSDAco.maxNameUnits - 1) + "😀", color: .gray(0))]))
        #expect(!capped.swatches[0].name.contains("\u{FFFD}"))
        var rng = SeededRandom(0x1234_5678)
        for _ in 0 ..< 300 {
            var b = good
            b[rng.int(0 ..< b.count)] ^= UInt8(1 << rng.int(0 ..< 8))
            _ = try? PSDAco.parse(Data(b))
            _ = try? PSDAco.parse(Data([0, 1] + rng.bytes(rng.int(0 ..< 300))))
        }
    }

    static func aseSample() -> PSDAse.File {
        PSDAse.File(entries: [
            .swatch(.init(name: "Loose red", color: .rgb(1, 0, 0))),
            .group(name: "Brand ✓", swatches: [
                .init(name: "Ink", color: .cmyk(0.1, 0.2, 0.3, 0.4), kind: .spot), .init(name: "Lab", color: .lab(0.5321, -12.25, 40.5), kind: .global),
                .init(name: "Mid gray", color: .gray(0.5)), .init(name: "Odd", color: .other(model: "HSV ", data: [1, 2, 3, 4, 5, 6])),
            ]),
            .group(name: "", swatches: []),
        ])
    }

    @Test func aseRoundTripsGroupsModelsAndTypes() throws {
        let f = Self.aseSample()
        let bytes = try PSDAse.write(f)
        #expect(Array(bytes.prefix(4)) == Array("ASEF".utf8))
        #expect([UInt8](bytes)[8 ..< 12] == [0, 0, 0, 9])
        let back = try PSDAse.parse(bytes)
        #expect(back == f && back.swatchCount == 5)
        #expect(try PSDAse.write(back) == bytes)
    }

    @Test func aseLenientStructureAndHostileInput() throws {
        var body = ByteWriter()
        var c = ByteWriter(); PSDAse.putName(&c, "A"); c.fourCC("Gray"); c.f32(0.25)
        PSDAse.putBlock(&body, PSDAse.groupEnd, [])
        PSDAse.putBlock(&body, 0x7777, [9, 9, 9])
        var g = ByteWriter(); PSDAse.putName(&g, "G")
        PSDAse.putBlock(&body, PSDAse.groupStart, g.bytes)
        PSDAse.putBlock(&body, PSDAse.colorBlock, c.bytes)
        let file = Array("ASEF".utf8) + [0, 1, 0, 0, 0, 0, 0, 4] + body.bytes
        #expect(try PSDAse.parse(Data(file)).entries == [.group(name: "G", swatches: [.init(name: "A", color: .gray(0.25))])])
        let nan = try PSDAse.parse(try PSDAse.write(PSDAse.File(entries: [.swatch(.init(name: "n", color: .rgb(.nan, .infinity, 0.5)))])))
        #expect(nan.entries == [.swatch(.init(name: "n", color: .rgb(0, 0, 0.5)))])
        let good = [UInt8](try PSDAse.write(Self.aseSample()))
        for n in 0 ..< good.count { #expect((try? PSDAse.parse(Data(good.prefix(n)))) == nil, "\(n)") }
        for bad in ["ASEX\0\u{1}\0\0\0\0\0\0", "ASEF\0\u{2}\0\0\0\0\0\0"] {
            #expect((try? PSDAse.parse(Data(bad.unicodeScalars.map { UInt8($0.value) }))) == nil)
        }
        #expect((try? PSDAse.parse(Data(Array("ASEF".utf8) + [0, 1, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF]))) == nil)
        #expect(throws: PSDError.self) { try PSDAse.write(PSDAse.File(entries: [.group(name: "g", swatches: Array(repeating: .init(name: "", color: .gray(0)), count: PSDAse.maxSwatches + 1))])) }
        var rng = SeededRandom(0xDEAD_BEEF)
        for _ in 0 ..< 400 {
            _ = try? PSDAse.parse(Data(Array("ASEF".utf8) + [0, 1, 0, 0, 0, 0, 0, 0x10] + rng.bytes(rng.int(0 ..< 400))))
            var b = good
            b[rng.int(0 ..< b.count)] ^= 0x5A
            _ = try? PSDAse.parse(Data(b))
        }
    }
}

@Suite struct GradientContourPatternTests {
    static func grdSample() -> [PSDGrd.Gradient] {
        [
            .init(name: "Sunset ✓", stops: [.init(location: 0, midpoint: 0.5, color: .foreground), .init(location: 0.25, midpoint: 0.3, color: .rgb(1, 0.5, 0)),
                                             .init(location: 1, midpoint: 0.5, color: .background)],
                  opacity: [(0, 1, 0.5), (1, 0.25, 0.5)]),
            .init(name: "Noise", noise: true),
        ]
    }

    @Test func grdRoundTripAndHostile() throws {
        let b = PSDGrd.write(Self.grdSample())
        #expect(try PSDGrd.parse(b) == Self.grdSample())
        #expect((try? PSDGrd.parse(Data())) == nil)
        #expect((try? PSDGrd.parse(Data("8BGR\0\u{3}".utf8))) == nil)
        #expect((try? PSDGrd.parse(Data("8BPS\0\u{5}".utf8))) == nil)
        #expect((try? PSDGrd.parse(PSDGrd.write([]))) == nil)
        let bytes = [UInt8](b)
        for cut in 0 ..< bytes.count { #expect((try? PSDGrd.parse(Data(bytes.prefix(cut)))) == nil, "\(cut)") }
        for i in 0 ..< bytes.count {
            var c = bytes
            c[i] ^= 0x5A
            if let g = try? PSDGrd.parse(Data(c)) {
                for x in g {
                    for s in x.stops { #expect(s.location.isFinite && (0 ... 1).contains(s.location) && (0 ... 1).contains(s.midpoint)) }
                    for o in x.opacity { #expect((0 ... 1).contains(o.opacity) && (0 ... 1).contains(o.location)) }
                }
            }
        }
        // Out-of-range and non-finite numbers are clamped or defaulted.
        let hostile = PSDDescriptor(classID: "Grdn").with("Nm  ", .text("h")).with("Clrs", .list([.descriptor(PSDDescriptor(classID: "Clrt")
                .with("Clr ", .descriptor(PSDDescriptor(classID: "RGBC").with("Rd  ", .double(1e300)).with("Grn ", .double(-5)).with("Bl  ", .double(.nan))))
                .with("Type", .enumerated(type: "Clry", value: "UsrS")).with("Lctn", .double(.infinity)).with("Mdpn", .double(.nan)))]))
            .with("Trns", .list([.descriptor(PSDDescriptor(classID: "TrnS").with("Opct", .double(.nan)).with("Lctn", .integer(-100)))]))
        var file = Data("8BGR".utf8); file.append(contentsOf: [0, 5])
        file.append(PSDVersionedDescriptor(PSDDescriptor().with("GrdL", .list([.descriptor(PSDDescriptor(classID: "Grdn").with("Grad", .descriptor(hostile)))]))).serialized())
        let g = try PSDGrd.parse(file)[0]
        #expect(g.stops[0].color == .rgb(1, 0, 0) && g.stops[0].location == 1 && g.stops[0].midpoint == 0.5)
        #expect(g.opacity[0].opacity == 1 && g.opacity[0].location == 0)
    }

    @Test func shcRoundTripAndHostile() throws {
        let cone = PSDShc.Contour(name: "Cone", points: [.init(input: 0, output: 0), .init(input: 128, output: 255, continuous: false), .init(input: 255, output: 0)])
        let bytes = try PSDShc.write([cone])
        #expect(Array(bytes.prefix(4)) == Array("8BFS".utf8))
        #expect(try PSDShc.parse(bytes) == [cone])
        var v1 = ByteWriter()
        v1.fourCC("8BFS"); v1.u16(1); v1.u32(1); v1.u32(1); v1.u32(2); v1.u16(79); v1.u16(75); v1.u16(0); v1.u16(2)
        for v: UInt16 in [0, 0, 255, 255] { v1.u16(v) }
        v1.u32(0); v1.u32(255)
        let c = try PSDShc.parse(v1.data)
        #expect(c[0].name == "OK" && c[0].points.allSatisfy(\.continuous) && c[0].points[1].input == 255)
        for cut in 0 ..< bytes.count { #expect((try? PSDShc.parse(bytes.prefix(cut))) == nil) }
        #expect((try? PSDShc.parse(Data("8BFX\0\u{1}\0\0\0\0".utf8))) == nil)
        #expect((try? PSDShc.parse(Data(Array("8BFS".utf8) + [0, 1, 0xFF, 0xFF, 0xFF, 0xFF]))) == nil)
        #expect(throws: PSDError.self) { try PSDShc.write([.init(name: "", points: Array(repeating: .init(input: 0, output: 0), count: PSDShc.maxPoints + 1))]) }
    }

    static func pattern(_ depth: UInt16, alpha: Bool) -> PSDPattern {
        let (w, h) = (5, 3)
        let bpp = Int(depth / 8)
        func plane(_ s: UInt8) -> [UInt8] { (0 ..< w * h * bpp).map { UInt8(truncatingIfNeeded: $0) &* 7 &+ s } }
        return PSDPattern(mode: 3, width: w, height: h, name: "Test ✓", id: "0bd2d3ba-1234-11d4-8f8f-aabbccddeeff", depth: depth,
                          channels: [plane(1), plane(2), plane(3)], alpha: alpha ? plane(9) : nil)
    }

    @Test func patternsRoundTripEveryDepth() throws {
        for depth: UInt16 in [8, 16, 32] {
            for alpha in [false, true] {
                var second = Self.pattern(depth, alpha: false)
                second.name = "Second"
                let ps = [Self.pattern(depth, alpha: alpha), second]
                let blk = try PSDPattern.writeBlock(ps)
                #expect(blk.count % 4 == 0)
                #expect(try PSDPattern.parseBlock(blk) == ps)
                #expect(try PSDPattern.parsePatFile(try PSDPattern.writePatFile(ps)) == ps)
                #expect(try PSDPattern.writeBlock(try PSDPattern.parseBlock(blk)) == blk)
            }
        }
        #expect((try? PSDPattern.parsePatFile(Data("8BPS\0\u{1}".utf8))) == nil)
        #expect(try PSDPattern.parseBlock(Data()).isEmpty)
    }

    func vmaRect(_ start: Int, _ p: PSDPattern) -> Int { start + 16 + (p.name.utf16.count + 1) * 2 + 1 + p.id.utf8.count + 8 }
    func setI32(_ b: inout [UInt8], _ at: Int, _ v: Int32) {
        let u = UInt32(bitPattern: v)
        b[at ..< at + 4] = [UInt8(u >> 24), UInt8(u >> 16 & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u & 0xFF)]
    }

    @Test func hostilePatternRectangles() throws {
        let p = Self.pattern(8, alpha: false)
        var g = [UInt8](try PSDPattern.writeBlock([p]))
        let vma = vmaRect(4, p)
        setI32(&g, vma + 4, Int32.min)
        setI32(&g, vma + 12, Int32.max)
        #expect((try? PSDPattern.parseBlock(Data(g))) == nil)
        var huge = [UInt8](try PSDPattern.writeBlock([p]))
        setI32(&huge, vma + 8, 30000)
        setI32(&huge, vma + 12, 30000)
        #expect(throws: PSDError.self) { try PSDPattern.parseBlock(Data(huge)) }
        var zero = [UInt8](try PSDPattern.writeBlock([p]))
        setI32(&zero, vma + 8, 0)
        #expect((try? PSDPattern.parseBlock(Data(zero))) == nil)
    }

    @Test func offsetChannelRectanglesArePlaced() throws {
        for depth: UInt16 in [8, 16, 32] {
            let original = Self.pattern(depth, alpha: true)
            var block = [UInt8](try PSDPattern.writeBlock([original]))
            let vma = vmaRect(4, original)
            setI32(&block, vma, -2); setI32(&block, vma + 4, -3); setI32(&block, vma + 8, 4); setI32(&block, vma + 12, 5)
            let parsed = try PSDPattern.parseBlock(Data(block))[0]
            #expect(parsed.width == 8 && parsed.height == 6)
            let bps = Int(depth / 8)
            for (actual, expected) in zip(parsed.channels + [parsed.alpha!], original.channels + [original.alpha!]) {
                for y in 0 ..< 6 {
                    for x in 0 ..< 8 {
                        let at = (y * 8 + x) * bps
                        let a = Array(actual[at ..< at + bps])
                        if (2 ..< 5).contains(y), (3 ..< 8).contains(x) {
                            let s = ((y - 2) * 5 + (x - 3)) * bps
                            #expect(a == Array(expected[s ..< s + bps]))
                        } else {
                            #expect(a.allSatisfy { $0 == 0 })
                        }
                    }
                }
            }
        }
        let src = PlaneLayout(planes: 1, width: 5, height: 2, depth: 1, version: .psd)
        let dst = PlaneLayout(planes: 1, width: 8, height: 4, depth: 1, version: .psd)
        #expect(try PSDPattern.place([0b1010_1000, 0b0101_0000], source: src, x: 2, y: 1, destination: dst) == [0, 0b0010_1010, 0b0001_0100, 0])
    }
}

@Suite struct BrushTests {
    func sample(_ id: String, _ w: Int, _ h: Int, _ depth: UInt16) -> PSDAbr.Sample {
        let bpp = Int(depth / 8)
        return PSDAbr.Sample(id: id, width: w, height: h, depth: depth, data: (0 ..< w * h * bpp).map { ($0 / bpp) % 3 == 0 ? 255 : UInt8($0 % 7) * 30 })
    }

    @Test func v1v2RoundTrip() throws {
        for version: UInt16 in [1, 2] {
            for rle in [false, true] {
                let brushes = [
                    PSDAbr.LegacyBrush(spacing: 25, tip: .computed(diameter: 19, hardness: 80, angle: -30, roundness: 50)),
                    PSDAbr.LegacyBrush(name: version == 2 ? "Leaf ✓" : "", spacing: 40, antiAlias: false, tip: .sampled(sample("", 13, 9, 8))),
                    PSDAbr.LegacyBrush(spacing: 10, tip: .sampled(sample("", 4, 6, 16))),
                ]
                let f = try PSDAbr.parse(try PSDAbr.writeV12(version: version, brushes, rle: rle))
                #expect(f.version == version && f.legacy == brushes && f.warnings.isEmpty)
            }
        }
    }

    @Test func v6RoundTripBothSubversions() throws {
        let samples = [sample("$abc", 20, 11, 8), sample("$def", 5, 5, 16)]
        let preset = PSDDescriptor(classID: "brushPreset").with("Nm  ", .text(.nulTerminated("Grass")))
            .with("Brsh", .descriptor(PSDDescriptor(classID: "sampledBrush").with("sampledData", .text(.nulTerminated("$abc")))))
        for sub: UInt16 in [1, 2] {
            for rle in [false, true] {
                let f = try PSDAbr.parse(try PSDAbr.writeV6(subversion: sub, samples: samples, patterns: [GradientContourPatternTests.pattern(8, alpha: false)],
                                                            presets: [preset], rle: rle))
                #expect(f.version == 6 && f.subversion == sub && f.samples == samples && f.presets == [preset] && f.patterns.count == 1)
                #expect(f.warnings.isEmpty, "\(f.warnings)")
            }
        }
        #expect(samples[1].unit.count == 25)
    }

    @Test func folderHierarchy() throws {
        let presets = (0 ..< 5).map { PSDDescriptor(classID: "brushPreset").with("Nm  ", .text(.nulTerminated("B\($0)"))) }
        let folders = [[], ["Animals", "Birds"], ["Animals"], ["Animals", "Fish"], []] as [[String]]
        let f = try PSDAbr.parse(try PSDAbr.writeV6(subversion: 2, samples: [], patterns: [], presets: presets, folders: folders, rle: false))
        #expect(f.folders == folders && f.warnings.isEmpty)
        let flat = try PSDAbr.parse(try PSDAbr.writeV6(subversion: 2, samples: [], patterns: [], presets: Array(presets.prefix(2)), rle: false))
        #expect(flat.folders.isEmpty)
    }

    @Test func hostileInput() throws {
        #expect((try? PSDAbr.parse(Data())) == nil)
        #expect((try? PSDAbr.parse(Data([0, 3, 0, 0]))) == nil)
        #expect((try? PSDAbr.parse(Data([0, 6, 0, 9]))) == nil)
        var big = sample("", 2, 2, 8)
        big.width = PSDAbr.maxEdge + 1
        #expect(throws: PSDError.self) { try PSDAbr.writeV12(version: 1, [PSDAbr.LegacyBrush(spacing: 1, tip: .sampled(big))], rle: false) }
        let good = [UInt8](try PSDAbr.writeV6(subversion: 2, samples: [sample("$a", 30, 30, 8)], patterns: [], presets: [PSDDescriptor(classID: "brushPreset")], rle: true))
        for cut in 0 ..< good.count { _ = try? PSDAbr.parse(Data(good.prefix(cut))) }
        for i in 0 ..< good.count {
            var b = good
            b[i] ^= 0xA5
            _ = try? PSDAbr.parse(Data(b))
        }
        #expect((try? PSDAbr.parse(Data([0, 2, 0xFF, 0xFF]))) == nil)
    }
}
