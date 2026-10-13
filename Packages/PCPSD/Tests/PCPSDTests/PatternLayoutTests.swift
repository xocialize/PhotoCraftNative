// Pattern data in Photoshop's layout (PCIO change request, from the Photoshop 27.11 oracle):
// transparency in the sheet mask array (slot channel count + 1 = 25) with the user mask (slot 24)
// unwritten, as in every transparent pattern Photoshop ships; the 4 bytes after an indexed
// pattern's palette kept; stored arrays written back unchanged, so Photoshop's own patterns
// rewrite byte for byte; and the `patternTransparencyInUserMask` / `patternDataUnreadable` linter
// rules. The ps-corpus patterns are covered in PSCorpusTests.

import Foundation
import Testing
@testable import PCPSD

/// An independent scan of pattern bytes (not PCPSD's reader): each pattern's channel count and
/// the byte range of every array slot, empty slots included.
enum PatternBytes {
    struct Pattern {
        var slotCount: Int
        /// (slot, range of the array including its `written` word; 4 bytes when empty).
        var arrays: [(slot: Int, range: Range<Int>, written: Bool)]
        var end: Int
        var writtenSlots: [Int] { arrays.filter { $0.written }.map { $0.slot } }
    }

    static func u32(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3]) }

    /// The pattern starting at `start` (its version word).
    static func pattern(_ b: [UInt8], at start: Int) -> Pattern {
        let mode = u32(b, start + 4)
        var q = start + 16 + 2 * u32(b, start + 12)
        q += 1 + Int(b[q])
        if mode == 2 {
            q += 768
            if u32(b, q) != 3 { q += 4 }
        }
        let end = q + 8 + u32(b, q + 4)
        let count = u32(b, q + 24)
        q += 28
        var arrays: [(slot: Int, range: Range<Int>, written: Bool)] = []
        while q < end {
            let slot = arrays.count
            if u32(b, q) == 0 {
                arrays.append((slot, q ..< q + 4, false))
                q += 4
            } else {
                let next = q + 8 + u32(b, q + 4)
                arrays.append((slot, q ..< next, true))
                q = next
            }
        }
        return Pattern(slotCount: count, arrays: arrays, end: end)
    }

    /// Every pattern of a `Patt`/`Pat2`/`Pat3` block, with its offset.
    static func block(_ b: [UInt8]) -> [(offset: Int, pattern: Pattern)] {
        var out: [(offset: Int, pattern: Pattern)] = []
        var o = 0
        while o + 4 <= b.count {
            let len = u32(b, o)
            if len == 0 { break }
            out.append((o + 4, pattern(b, at: o + 4)))
            o += 4 + len + (4 - len % 4) % 4
        }
        return out
    }

    static func blockSlots(_ b: [UInt8]) -> [[Int]] { block(b).map(\.pattern.writtenSlots) }

    static func patFileSlots(_ b: [UInt8]) -> [[Int]] {
        var o = 10
        return (0 ..< u32(b, 6)).map { _ in
            let p = pattern(b, at: o)
            o = p.end
            return p.writtenSlots
        }
    }

    /// `block` in the layout PCPSD and photocraft wrote before: transparency in the user mask
    /// array (slot 24) and the sheet mask empty. Pattern lengths do not change.
    static func userMaskLayout(_ block: [UInt8]) -> [UInt8] {
        var b = block
        for (_, p) in Self.block(block) {
            guard p.arrays.count == p.slotCount + 2 else { continue }
            let user = p.arrays[p.slotCount], sheet = p.arrays[p.slotCount + 1]
            guard !user.written, sheet.written else { continue }
            b.replaceSubrange(user.range.lowerBound ..< sheet.range.upperBound, with: Array(block[sheet.range]) + [0, 0, 0, 0])
        }
        return b
    }
}

@Suite struct PatternLayoutTests {
    static func plane(_ n: Int, _ seed: UInt8) -> [UInt8] { (0 ..< n).map { UInt8(truncatingIfNeeded: $0 * 7 + Int(seed) * 13) } }

    static func pattern(mode: UInt32, depth: UInt16, alpha: Bool, name: String = "P") -> PSDPattern {
        let (w, h) = (6, 4)
        let n = w * h * Int(depth / 8)
        return PSDPattern(mode: mode, width: w, height: h, name: name, id: "id-\(name)", depth: depth,
                          channels: (0 ..< PSDPattern.modeChannels(mode)).map { plane(n, UInt8($0 + 1)) }, alpha: alpha ? plane(n, 9) : nil)
    }

    // MARK: Item 1 — the sheet mask

    @Test func transparencyIsWrittenInTheSheetMaskArray() throws {
        for depth: UInt16 in [8, 16, 32] {
            let ps = [Self.pattern(mode: 3, depth: depth, alpha: true, name: "rgba"), Self.pattern(mode: 1, depth: depth, alpha: true, name: "graya"),
                      Self.pattern(mode: 3, depth: depth, alpha: false, name: "rgb"), Self.pattern(mode: 4, depth: depth, alpha: true, name: "cmyka")]
            let block = [UInt8](try PSDPattern.writeBlock(ps))
            #expect(PatternBytes.blockSlots(block) == [[0, 1, 2, 25], [0, 25], [0, 1, 2], [0, 1, 2, 3, 25]], "\(depth)")
            for (_, p) in PatternBytes.block(block) {
                #expect(p.slotCount == 24 && p.arrays.count == 26)
                #expect(p.arrays[24].range.count == 4 && !p.arrays[24].written, "the user mask is an empty slot")
            }
            #expect(try PSDPattern.parseBlock(Data(block)) == ps)
            let pat = [UInt8](try PSDPattern.writePatFile(ps))
            #expect(PatternBytes.patFileSlots(pat) == [[0, 1, 2, 25], [0, 25], [0, 1, 2], [0, 1, 2, 3, 25]])
            #expect(try PSDPattern.parsePatFile(Data(pat)) == ps)
            #expect(try PSDPattern.parseBlock(Data(block)).map { $0.stored?.transparencySlot } == [25, 25, nil, 25])
        }
    }

    /// The user mask layout PCPSD and photocraft wrote before reads the same; rewriting it moves
    /// transparency to the sheet mask.
    @Test func bothTransparencySlotsRead() throws {
        for depth: UInt16 in [8, 16] {
            let ps = [Self.pattern(mode: 3, depth: depth, alpha: true, name: "a"), Self.pattern(mode: 1, depth: depth, alpha: true, name: "b")]
            let block = [UInt8](try PSDPattern.writeBlock(ps))
            let legacy = PatternBytes.userMaskLayout(block)
            #expect(legacy != block && legacy.count == block.count)
            #expect(PatternBytes.blockSlots(legacy) == [[0, 1, 2, 24], [0, 24]])
            let read = try PSDPattern.parseBlock(Data(legacy))
            #expect(read == ps)
            #expect(read.map { $0.stored?.transparencySlot } == [24, 24])
            #expect(read.allSatisfy { $0.stored?.writesUserMask == true })
            #expect([UInt8](try PSDPattern.writeBlock(read)) == block)
        }
    }

    // MARK: Item 2 — the bytes after an indexed palette

    @Test func indexedPaletteTrailerIsKept() throws {
        let palette = (0 ..< 768).map { UInt8(truncatingIfNeeded: $0 * 5) }
        func indexed(_ trailer: [UInt8]??) -> PSDPattern {
            let (w, h) = (5, 3)
            if let trailer {
                return PSDPattern(mode: 2, width: w, height: h, name: "I", id: "i", palette: palette, depth: 8, channels: [Self.plane(w * h, 4)], paletteTrailer: trailer)
            }
            return PSDPattern(mode: 2, width: w, height: h, name: "I", id: "i", palette: palette, depth: 8, channels: [Self.plane(w * h, 4)])
        }
        // A new indexed pattern gets Photoshop's bytes.
        #expect(indexed(nil).paletteTrailer == [1, 0, 0, 255])
        #expect(PSDPattern.photoshopPaletteTrailer == [1, 0, 0, 255])
        let afterPalette = 4 + 16 + 2 * 2 + 1 + 1 + 768 // length word, header, "I" + NUL, id
        for trailer: [UInt8]? in [[1, 0, 0, 255], [0, 0x83, 0, 0x82], nil] {
            let p = indexed(.some(trailer))
            #expect(p.paletteTrailer == trailer)
            let block = [UInt8](try PSDPattern.writeBlock([p]))
            #expect(Array(block[afterPalette ..< afterPalette + 4]) == (trailer ?? [0, 0, 0, 3]), "\(String(describing: trailer))")
            let back = try PSDPattern.parseBlock(Data(block))
            #expect(back == [p])
            #expect([UInt8](try PSDPattern.writeBlock(back)) == block)
            #expect(try PSDPattern.parsePatFile(PSDPattern.writePatFile([p])) == [p])
        }
        // Other modes carry none.
        #expect(PSDPattern(mode: 3, width: 1, height: 1, name: "", id: "", depth: 8, channels: [[1], [2], [3]], paletteTrailer: [9, 9, 9, 9]).paletteTrailer == nil)
        // A trailer that would read as the array list's version is refused.
        for bad: [UInt8] in [[0, 0, 0, 3], [1, 2]] {
            #expect(throws: PSDError.self) { try PSDPattern.writeBlock([indexed(.some(bad))]) }
        }
    }

    // MARK: Stored arrays

    /// A pattern laid out as Photoshop stores many: raw colour channels and transparency in
    /// PackBits runs PCPSD's encoder would not choose (literal packets only).
    static func photoshopStyleBlock() -> (block: [UInt8], pattern: PSDPattern) {
        let (w, h) = (6, 4)
        let channels = (0 ..< 3).map { plane(w * h, UInt8($0 + 1)) }
        let alpha = [UInt8](repeating: 200, count: w * h)
        var p = ByteWriter()
        p.u32(1); p.u32(3); p.u16(UInt16(h)); p.u16(UInt16(w))
        p.unicodeUnits(Array("Raw".utf16) + [0])
        p.u8(1); p.put([0x72])
        var body = ByteWriter()
        for v: Int32 in [0, 0, Int32(h), Int32(w)] { body.i32(v) }
        body.u32(24)
        func array(_ comp: UInt8, _ data: [UInt8]) {
            body.u32(1); body.u32(UInt32(23 + data.count)); body.u32(8)
            for v: Int32 in [0, 0, Int32(h), Int32(w)] { body.i32(v) }
            body.u16(8); body.u8(comp); body.put(data)
        }
        for c in channels { array(0, c) }
        for _ in 3 ..< 25 { body.u32(0) }
        // RLE rows as 6-byte literals: count table (2 bytes per row), then [5, row…] per row.
        let counts: [UInt8] = (0 ..< h).flatMap { _ -> [UInt8] in [0, 7] }
        let rows: [UInt8] = (0 ..< h).flatMap { _ -> [UInt8] in [5] + [UInt8](repeating: 200, count: w) }
        array(1, counts + rows)
        p.u32(3); p.u32(UInt32(body.count)); p.put(body.bytes)
        var block = ByteWriter()
        block.u32(UInt32(p.count)); block.put(p.bytes); block.zeros((4 - p.count % 4) % 4)
        return (block.bytes, PSDPattern(mode: 3, width: w, height: h, name: "Raw", id: "r", depth: 8, channels: channels, alpha: alpha))
    }

    @Test func storedArraysAreWrittenBackUntilTheirPlaneChanges() throws {
        let (block, expected) = Self.photoshopStyleBlock()
        var p = try #require(try PSDPattern.parseBlock(Data(block)).first)
        #expect(p == expected)
        #expect(p.stored?.writtenSlots == [0, 1, 2, 25])
        // Unchanged: byte for byte, raw channels and literal-only runs included.
        #expect([UInt8](try PSDPattern.writeBlock([p])) == block)
        // A freshly built equal pattern encodes its own way (RLE, PCPSD's runs) and reads the same.
        let fresh = [UInt8](try PSDPattern.writeBlock([expected]))
        #expect(fresh != block)
        #expect(try PSDPattern.parseBlock(Data(fresh)) == [expected])
        // Name and id come from the model; the arrays stay stored.
        p.name = "Renamed"
        #expect(try PSDPattern.parseBlock(PSDPattern.writeBlock([p])) == [p])
        // A changed plane is encoded again; the other arrays keep their bytes.
        p.channels[1][0] ^= 0xFF
        let edited = [UInt8](try PSDPattern.writeBlock([p]))
        let back = try #require(try PSDPattern.parseBlock(Data(edited)).first)
        #expect(back == p)
        let arrays = try #require(PatternBytes.block(edited).first?.pattern.arrays)
        let original = try #require(PatternBytes.block(block).first?.pattern.arrays)
        let compression = { (b: [UInt8], r: Range<Int>) in b[r.lowerBound + 30] }
        #expect(compression(edited, arrays[0].range) == 0 && compression(edited, arrays[1].range) == 1 && compression(edited, arrays[2].range) == 0)
        #expect(edited[arrays[25].range] == block[original[25].range])
        // A depth or size change re-encodes everything.
        var deeper = back
        deeper.depth = 16
        deeper.channels = deeper.channels.map { $0.flatMap { [$0, 0] } }
        deeper.alpha = deeper.alpha.map { $0.flatMap { [$0, 0] } }
        #expect(try PSDPattern.parseBlock(PSDPattern.writeBlock([deeper])) == [deeper])
    }

    // MARK: Item 4 — the linter

    static func file(patternBlocks: [PSDTaggedBlock]) throws -> PSDFile {
        var b = PSDBuilder(width: 2, height: 2)
        b.pushLayer(PSDLayerSpec(name: "a", left: 0, top: 0, width: 1, height: 1, pixels: .u8([1, 2, 3, 255])))
        var f = try PSDFile(data: b.serialized())
        f.globalBlocks += patternBlocks
        return try PSDFile(data: f.serialized())
    }

    static func patternIssues(_ f: PSDFile) -> [PSDCompatibilityIssue] {
        f.compatibilityIssues().filter { [.patternTransparencyInUserMask, .patternDataUnreadable].contains($0.rule) }
    }

    @Test func linterFlagsTransparencyInTheUserMask() throws {
        let ps = [Self.pattern(mode: 3, depth: 8, alpha: true, name: "Leaves"), Self.pattern(mode: 3, depth: 8, alpha: false, name: "Opaque"),
                  Self.pattern(mode: 1, depth: 8, alpha: true, name: "Gray")]
        let block = try PSDPattern.writeBlock(ps)
        #expect(Self.patternIssues(try Self.file(patternBlocks: [PSDTaggedBlock(key: "Patt", data: block)])).isEmpty)
        for key: FourCC in ["Patt", "Pat2", "Pat3"] {
            let legacy = PSDTaggedBlock(key: key, data: Data(PatternBytes.userMaskLayout([UInt8](block))))
            let issues = Self.patternIssues(try Self.file(patternBlocks: [legacy]))
            #expect(issues.count == 2, "\(issues)")
            #expect(issues.allSatisfy { $0.rule == .patternTransparencyInUserMask && $0.severity == .error && $0.message.hasPrefix("PHOTOSHOP REFUSES THE FILE") })
            #expect(issues.map(\.message).allSatisfy { $0.contains("\(key) pattern") && $0.contains("slot 24") && $0.contains("slot 25") })
            #expect(issues[0].message.contains("\"Leaves\"") && issues[1].message.contains("\"Gray\""))
            // Rewritten through the model, the block is clean.
            let fixed = PSDTaggedBlock(key: key, data: try PSDPattern.writeBlock(try PSDPattern.parseBlock(legacy.data)))
            #expect(Self.patternIssues(try Self.file(patternBlocks: [fixed])).isEmpty)
        }
    }

    @Test func linterFlagsPatternDataThatDoesNotParse() throws {
        let good = [UInt8](try PSDPattern.writeBlock([Self.pattern(mode: 3, depth: 8, alpha: true)]))
        var badVersion = good
        badVersion[7] = 9 // pattern version 9
        let cases: [(String, [UInt8])] = [
            ("a 6-byte placeholder (PCIO's old raw-preservation fixture)", [7, 7, 7, 7, 7, 7]),
            ("garbage", [0, 0, 0, 9, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 0, 0]),
            ("truncated", Array(good.prefix(good.count / 2))),
            ("bad version", badVersion),
        ]
        for (name, bytes) in cases {
            let issues = Self.patternIssues(try Self.file(patternBlocks: [PSDTaggedBlock(key: "Patt", bytes: bytes)]))
            #expect(issues.count == 1 && issues.first?.rule == .patternDataUnreadable && issues.first?.severity == .error, "\(name): \(issues)")
            #expect(issues.first?.message.hasPrefix("Patt pattern data does not parse") == true, "\(name)")
        }
        // Bytes after the last pattern that are not padding only warn: Photoshop 27.11 opened 6
        // PCIO exports whose Patt was TestGen's old 2-byte placeholder `01 02`.
        for (bytes, tail) in [([UInt8]([1, 2]), 2), (good + [0, 0, 0, 0, 7], 1)] {
            let all = try Self.file(patternBlocks: [PSDTaggedBlock(key: "Patt", bytes: bytes)]).compatibilityIssues()
            #expect(!all.contains { $0.rule == .patternDataUnreadable || $0.rule == .patternTransparencyInUserMask })
            #expect(all.filter { $0.message.hasPrefix("Patt: \(tail) bytes after the last pattern are not zero padding") }.map(\.severity) == [.warning], "\(all)")
        }
        // Clean: Photoshop's empty block, zero padding after the last pattern, a zero length word.
        for bytes in [[], good + [0, 0, 0, 0], good + [0, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0]] {
            let all = try Self.file(patternBlocks: [PSDTaggedBlock(key: "Pat2", bytes: bytes)]).compatibilityIssues()
            #expect(!all.contains { $0.message.contains("Pat2") }, "\(bytes.count): \(all)")
        }
        // The public reader reads what it read before.
        #expect(try PSDPattern.parseBlock(Data([1, 2])).isEmpty)
        #expect(try PSDPattern.parseBlock(Data(good + [0, 0, 0, 0, 7])).count == 1)
    }

    // MARK: Item 3 — the generator's pattern block

    @Test func generatorWritesPhotoshopsEmptyPatternBlock() throws {
        for version in PSDVersion.allCases {
            for c in PSDCompression.all {
                let f = TestGen.small(version, c)
                #expect(f.globalBlocks.map(\.key) == ["Patt"] && f.globalBlocks[0].data.isEmpty)
                let back = try PSDFile(data: f.serialized())
                #expect(back.globalBlocks.first.map { $0.key == "Patt" && $0.data.isEmpty } == true)
                #expect(Self.patternIssues(back).isEmpty)
            }
        }
        for c in TestGen.allCases() + TestGen.allCases(invalidBlendModes: true) {
            #expect(Self.patternIssues(c.file).isEmpty, "\(c.name)")
        }
    }

    // MARK: Calibration on the Unity corpus (the ps-corpus is in PSCorpusTests)

    @Test(.enabled(if: Corpus.directory != nil, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)"))
    func patternRulesAreSilentOnTheCorpus() throws {
        var blocks = 0, hits: [String] = []
        for url in Corpus.files {
            let f = try PSDFile(contentsOf: url)
            blocks += f.globalBlocks.filter { PSDPattern.blockKeys.contains($0.key) }.count
            hits += Self.patternIssues(f).map { "\(url.lastPathComponent): \($0)" }
            for b in f.globalBlocks where PSDPattern.blockKeys.contains(b.key) {
                #expect(try PSDPattern.writeBlock(PSDPattern.parseBlock(b.data)) == b.data, "\(url.lastPathComponent)")
            }
        }
        #expect(Corpus.files.count == 36)
        #expect(hits.isEmpty, "\(hits.prefix(10))")
        print("PATTERN rules, Unity corpus: \(Corpus.files.count) files, \(blocks) pattern blocks, \(hits.count) hits")
    }

    // MARK: Against Photoshop's verdicts on PCIO's exports (opt-in)

    /// The oracle's two sweeps of PCIO exports (`PCPSD_PS_ORACLE`, default `<fixtures>/ps-oracle`:
    /// `pcio/pcio.json` over `pcio-snapshot`, before PCIO moved transparency to the sheet mask, and
    /// `pcio-c2/pcio-c2.json` after).
    static var sweeps: [(json: URL, files: URL)] {
        guard let root = Corpus.psOracle else { return [] }
        return [("pcio/pcio.json", "pcio-snapshot"), ("pcio-c2/pcio-c2.json", "pcio-snapshot-c2")]
            .map { (root.appendingPathComponent($0.0), root.appendingPathComponent($0.1)) }
            .filter { FileManager.default.fileExists(atPath: $0.json.path) && FileManager.default.fileExists(atPath: $0.files.path) }
    }

    /// `patternTransparencyInUserMask` fires on exactly the exports Photoshop refused for their
    /// pattern data, and on no file it opened.
    @Test(.enabled(if: !PatternLayoutTests.sweeps.isEmpty, "Photoshop oracle sweeps not present (set PHOTOCRAFT_FIXTURES or PCPSD_PS_ORACLE)"))
    func userMaskRuleAgreesWithPhotoshopsVerdicts() throws {
        var flaggedRefused = 0, flaggedOpened: [String] = [], opened = 0, sheetMaskOpened = 0
        for sweep in Self.sweeps {
            let rows = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: sweep.json)) as? [[String: Any]])
            for row in rows {
                guard let path = row["file"] as? String, let ok = row["opened"] as? Bool else { continue }
                let url = sweep.files.appendingPathComponent((path as NSString).lastPathComponent)
                guard let f = try? PSDFile(contentsOf: url) else { continue }
                let flagged = f.compatibilityIssues().contains { $0.rule == .patternTransparencyInUserMask }
                if ok {
                    opened += 1
                    if flagged { flaggedOpened.append(url.lastPathComponent) }
                    let transparent = f.globalBlocks.filter { PSDPattern.blockKeys.contains($0.key) }
                        .flatMap { (try? PSDPattern.parseBlock($0.data)) ?? [] }.filter { $0.alpha != nil }
                    if !transparent.isEmpty, transparent.allSatisfy({ $0.stored?.transparencySlot == 25 }) { sheetMaskOpened += 1 }
                } else if flagged {
                    flaggedRefused += 1
                }
            }
        }
        #expect(flaggedOpened.isEmpty, "\(flaggedOpened.prefix(10))")
        print("PATTERN user-mask rule vs Photoshop: \(flaggedRefused) refused files flagged, \(flaggedOpened.count) of \(opened) opened files flagged; \(sheetMaskOpened) opened files with transparency in the sheet mask")
    }

    // MARK: Photoshop's preset patterns (opt-in, read only)

    /// The `.pat` presets Photoshop 2026 ships (`PCPSD_PS_PATTERNS`: directories separated by `:`),
    /// read only. Every pattern rewrites byte for byte (the preset hierarchy some files append is
    /// not part of `PSDPattern`), and none writes the user mask.
    static var presetFiles: [URL] {
        let app = "/Applications/Adobe Photoshop 2026"
        let dirs = ProcessInfo.processInfo.environment["PCPSD_PS_PATTERNS"].map { $0.split(separator: ":").map(String.init) }
            ?? [app + "/Presets/Patterns", app + "/Adobe Photoshop 2026.app/Contents/Required"]
        return dirs.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "pat" }
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test(.enabled(if: !PatternLayoutTests.presetFiles.isEmpty, "Photoshop preset patterns not present (set PCPSD_PS_PATTERNS)"))
    func photoshopPresetPatternsRewriteByteForByte() throws {
        var patterns = 0, transparent = 0, indexed: [String: Int] = [:]
        for url in Self.presetFiles {
            let data = try Data(contentsOf: url)
            let ps = try PSDPattern.parsePatFile(data)
            let back = try PSDPattern.writePatFile(ps)
            #expect(data.prefix(back.count) == back, "\(url.lastPathComponent)")
            patterns += ps.count
            for p in ps {
                #expect(p.stored?.slotCount == 24 && p.stored?.writesUserMask == false, "\(p.name)")
                if p.alpha != nil {
                    transparent += 1
                    #expect(p.stored?.transparencySlot == 25, "\(p.name)")
                }
                if let t = p.paletteTrailer { indexed[t.map { String(format: "%02x", $0) }.joined(), default: 0] += 1 }
            }
        }
        #expect(patterns > 0)
        print("PRESET patterns: \(Self.presetFiles.count) files, \(patterns) patterns rewrite byte for byte; \(transparent) transparent (all in slot 25); indexed trailers \(indexed)")
    }
}
