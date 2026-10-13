// Tests for PatternMap. Port of photocraft-io (crates/io/src/pattern_map.rs `#[cfg(test)]`), MIT OR
// Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
@testable import PCIOMaps
import PCPSD
import Testing

@Suite struct PatternMapTests {
    static func pattern(_ mode: ColorMode, _ s: SampleType, _ alpha: Bool) -> Pattern {
        let fmt = PixelFormat(mode: mode, sample: s, alpha: alpha)
        var surf = Surface(format: fmt)
        let n = fmt.channels
        for y in 0 ..< 3 {
            for x in 0 ..< 5 {
                let px = (0 ..< n).map { c in Float((x * 3 + y * 7 + c * 5) % 11) / 10 }
                surf.setPixel(x: Int32(x), y: Int32(y), px)
            }
        }
        return Pattern(name: "P", surface: surf, width: 5, height: 3)
    }

    @Test func patternsRoundTripThroughPSDAtEveryDepthAndModel() throws {
        for mode in [ColorMode.rgb, .grayscale, .cmyk, .lab] {
            for s in [SampleType.u8, .u16, .f32] {
                for alpha in [false, true] {
                    let p = Self.pattern(mode, s, alpha)
                    let back = try #require(PatternMap.fromPSD(PatternMap.toPSD(p)))
                    #expect(back.id == p.id && back.name == p.name && back.width == p.width && back.surface.format == p.surface.format)
                    // Exact except float CMYK, whose stored inversion (1 − v) rounds.
                    let (a, b) = (back.surface.readRegion(p.rect), p.surface.readRegion(p.rect))
                    #expect(zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 }, "\(mode) \(s) \(alpha)")
                    if !(mode == .cmyk && s == .f32) {
                        #expect(back == p, "\(mode) \(s) \(alpha)")
                    }
                }
            }
        }
    }

    @Test func exportReusesRawBlocksUntilPatternsChange() throws {
        var d = Document(name: "x", size: PixelSize(width: 4, height: 4), mode: .rgb, depth: .u8)
        let p = Self.pattern(.rgb, .u8, false)
        let raw = [UInt8](try PSDPattern.writeBlock([PatternMap.toPSD(p)]))
        d.metadata.psdGlobalBlocks = [PSDGlobalBlock(signature: "8BIM", key: "Txt2", data: [1]), PSDGlobalBlock(signature: "8BIM", key: "Patt", data: raw)]
        d.patterns = PatternMap.fromGlobalBlocks(d)
        #expect(d.patterns.count == 1)
        #expect(PatternMap.exportGlobalBlocks(d) == d.metadata.psdGlobalBlocks)
        d.patterns.append(Self.pattern(.grayscale, .u16, true))
        let out = PatternMap.exportGlobalBlocks(d)
        #expect(out.count == 2)
        #expect(out[1].key == "Patt")
        var d2 = d
        d2.metadata.psdGlobalBlocks = out
        #expect(PatternMap.fromGlobalBlocks(d2) == d.patterns)
        #expect(try PatternMap.readPat(PatternMap.writePat(d.patterns)) == d.patterns)
    }

    @Test func oneBitAndIndexedPatternsExpand() throws {
        // 1-bit: set bits are black, clear bits white (8 × 1, one byte per row).
        let bits = PSDPattern(mode: 1, width: 8, height: 2, name: "B", id: "b", depth: 1, channels: [[0b1010_0000, 0xFF]])
        let b = try #require(PatternMap.fromPSD(bits))
        #expect(b.surface.format == PixelFormat(mode: .grayscale, sample: .u8, alpha: false))
        #expect(b.surface.readRegion(PixelRect(x0: 0, y0: 0, x1: 4, y1: 1)) == [0, 1, 0, 1])
        #expect(b.surface.readRegion(PixelRect(x0: 0, y0: 1, x1: 8, y1: 2)) == [Float](repeating: 0, count: 8))
        // Indexed: palette triplets per index.
        var pal = [UInt8](repeating: 0, count: 768)
        pal[3] = 255; pal[4] = 128; pal[5] = 0
        let idx = PSDPattern(mode: 2, width: 2, height: 1, name: "I", id: "i", palette: pal, depth: 8, channels: [[0, 1]])
        let i = try #require(PatternMap.fromPSD(idx))
        #expect(i.surface.format.mode == .rgb)
        #expect(i.surface.readInterleaved(PixelRect(x0: 0, y0: 0, x1: 2, y1: 1)) == [0, 0, 0, 255, 128, 0])
        // No palette, no pixels, too few channels: no pattern.
        #expect(PatternMap.fromPSD(PSDPattern(mode: 2, width: 2, height: 1, name: "", id: "", depth: 8, channels: [[0, 1]])) == nil)
        #expect(PatternMap.fromPSD(PSDPattern(mode: 3, width: 0, height: 1, name: "", id: "", depth: 8, channels: [[], [], []])) == nil)
        #expect(PatternMap.fromPSD(PSDPattern(mode: 3, width: 1, height: 1, name: "", id: "", depth: 8, channels: [[1]])) == nil)
        #expect(throws: PCIOError.self) { try PatternMap.readPat([1, 2, 3]) }
    }

    @Test func otherModelsAreWrittenAsRGB() throws {
        var surf = Surface(format: PixelFormat(mode: .multichannel, sample: .u8, alpha: false))
        surf.fill(PixelRect(x0: 0, y0: 0, x1: 2, y1: 2), with: [0.2, 0.4, 0.6])
        let p = Pattern(id: "m", name: "M", width: 2, height: 2, surface: surf)
        let psd = PatternMap.toPSD(p)
        #expect(psd.mode == 3 && psd.channels.count == 3 && psd.alpha == nil)
        let back = try #require(PatternMap.fromPSD(psd))
        #expect(back.surface.format == PixelFormat(mode: .rgb, sample: .u8, alpha: false))
        #expect(back.surface.readInterleaved(PixelRect(x0: 1, y0: 1, x1: 2, y1: 2)) == surf.readInterleaved(PixelRect(x0: 1, y0: 1, x1: 2, y1: 2)))
    }

    /// The written arrays of each pattern in a `Patt`-style block (index, by position in the
    /// virtual memory array list), read independently of the code under test.
    static func writtenArrays(_ block: [UInt8]) -> [[Int]] {
        func u32(_ o: Int) -> Int { Int(block[o]) << 24 | Int(block[o + 1]) << 16 | Int(block[o + 2]) << 8 | Int(block[o + 3]) }
        var out: [[Int]] = []
        var o = 0
        while o + 4 <= block.count, u32(o) > 0 {
            let len = u32(o), start = o + 4
            var q = start + 16 + 2 * u32(start + 12)
            q += 1 + Int(block[q])
            if u32(start + 4) == 2 { q += 768 }
            let end = q + 8 + u32(q + 4)
            q += 28
            var written: [Int] = []
            var k = 0
            while q < end {
                if u32(q) == 0 { q += 4 } else { written.append(k); q += 8 + u32(q + 4) }
                k += 1
            }
            out.append(written)
            o = start + len + (4 - len % 4) % 4
        }
        return out
    }

    /// Photoshop keeps a pattern's transparency in the sheet mask array (index 25, after the 24
    /// channel slots and the user mask), never the user mask (Photoshop 2026's 23 transparent
    /// preset patterns); Photoshop 27.11 refused every file whose pattern block had it in the
    /// user mask. Both layouts read back the same.
    @Test func transparencyIsWrittenInTheSheetMaskArray() throws {
        var d = Document(name: "x", size: PixelSize(width: 4, height: 4), mode: .rgb, depth: .u8)
        d.patterns = [Self.pattern(.rgb, .u8, true), Self.pattern(.grayscale, .u8, true), Self.pattern(.rgb, .u8, false)]
        let block = try #require(PatternMap.exportGlobalBlocks(d).first)
        #expect(block.key == "Patt")
        #expect(Self.writtenArrays(block.data) == [[0, 1, 2, 25], [0, 25], [0, 1, 2]])
        var d2 = d
        d2.metadata.psdGlobalBlocks = [block]
        #expect(PatternMap.fromGlobalBlocks(d2) == d.patterns)
        // PCPSD writes the sheet mask itself: the export writes its bytes unchanged.
        let pcpsd = [UInt8](try PSDPattern.writeBlock(d.patterns.map(PatternMap.toPSD)))
        #expect(Self.writtenArrays(pcpsd) == [[0, 1, 2, 25], [0, 25], [0, 1, 2]])
        #expect(block.data == pcpsd)
        // `.pat` files too.
        let pat = try PatternMap.writePat(d.patterns)
        #expect(try PatternMap.readPat(pat) == d.patterns)
        let raw = [UInt8](try PSDPattern.writePatFile(d.patterns.map(PatternMap.toPSD)))
        #expect(pat == raw)
    }

    /// `Patt` at 8 bits, `Pat2` at 16 and `Pat3` at 32, after the depth the file is written at.
    @Test func blockKeyFollowsTheWrittenDepth() throws {
        #expect([SampleType.u8, .u16, .f32].map { PatternMap.blockKey($0) } == ["Patt", "Pat2", "Pat3"])
        var d = Document(name: "x", size: PixelSize(width: 4, height: 4), mode: .cmyk, depth: .f32)
        d.patterns = [Self.pattern(.rgb, .u8, false)]
        #expect(PatternMap.exportGlobalBlocks(d).map(\.key) == ["Pat3"])
        #expect(PatternMap.exportGlobalBlocks(d, depth: .u16).map(\.key) == ["Pat2"])
    }

    /// A kept pattern block that does not parse is dropped (Photoshop refuses a file whose pattern
    /// data it cannot read); Photoshop's empty `Patt` is kept.
    @Test func unreadablePatternBlocksAreDropped() throws {
        var d = Document(name: "x", size: PixelSize(width: 4, height: 4), mode: .rgb, depth: .u8)
        d.metadata.psdGlobalBlocks = [PSDGlobalBlock(signature: "8BIM", key: "Patt", data: [1, 2]),
                                      PSDGlobalBlock(signature: "8BIM", key: "Patt", data: []),
                                      PSDGlobalBlock(signature: "8BIM", key: "zzzz", data: [1, 2])]
        #expect(PatternMap.exportGlobalBlocks(d).map { "\($0.key)\($0.data.count)" } == ["Patt0", "zzzz2"])
    }

    /// References to patterns the document lacks get placeholders; present ones are untouched.
    @Test func missingPatternsGetPlaceholders() throws {
        var d = Document(name: "x", size: PixelSize(width: 4, height: 4), mode: .rgb, depth: .u8)
        let have = Self.pattern(.rgb, .u8, false)
        d.patterns = [have]
        d.layers = [Layer(name: "fill", content: .fill(.pattern(PatternFill(name: "Dots")))),
                    Layer(name: "known", content: .fill(.pattern(PatternFill(name: "other name", id: have.id))))]
        var styled = Layer.raster("fx", format: d.pixelFormat)
        styled.effects.items = [.stroke(StrokeFx(common: FxCommon(.normal, 1), size: 2, position: .outside, paint: .pattern(.init(name: "Weave", id: "w-1", scale: 1)))),
                                .patternOverlay(.init(common: FxCommon(.normal, 1), name: "P", id: ""))]
        d.layers.append(styled)
        var e = d
        let warnings = PatternMap.addMissingPatterns(&e)
        #expect(warnings.count == 1 && warnings[0].contains("\"Dots\", \"Weave\""), "\(warnings)")
        #expect(e.patterns.map(\.name) == [have.name, "Dots", "Weave"])
        #expect(e.patterns[2].id == "w-1")
        guard case let .fill(.pattern(p)) = e.layers[0].content else { Issue.record("fill"); return }
        #expect(p.id == e.patterns[1].id && !p.id.isEmpty)
        #expect(e.layers[1] == d.layers[1] && e.layers[2] == d.layers[2], "references that resolve are left alone")
        var again = e
        #expect(PatternMap.addMissingPatterns(&again).isEmpty && again == e)
    }
}
