// Photoshop brush files (`.abr`): the legacy v1/v2 layout and the sectioned v6+ layout (sampled
// tips, embedded patterns, preset descriptors and the preset folder hierarchy).
// Port of photocraft-psd (crates/psd/src/abr.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// v1/v2 := u16 version, u16 count, brushes (u16 type 1 computed / 2 sampled, u32 length, body)
// v6+   := u16 version (6...10), u16 subversion (1|2), `8BIM` sections: `samp` (sampled tips),
//          `patt` (patterns), `desc` (versioned descriptor, `Brsh` list of brushPreset objects),
//          `phry` (versioned descriptor, `hierarchy` token stream: Grup / preset / groupEnd).
// Parsing never traps; damaged brushes are skipped with a warning.

import Foundation

public enum PSDAbr {
    public static let maxEdge = 8192
    public static let maxBrushes = 20_000
    public static let maxTotalBytes = 512 << 20
    public static let maxFolderDepth = 32
    static let maxFolderName = 255
    static let maxFolderBytes = 16 << 20

    /// A sampled tip: one gray plane where the maximum value is full paint.
    public struct Sample: Equatable, Sendable {
        /// The id `sampledData` in a preset refers to (v6+), or empty.
        public var id: String
        public var width: Int
        public var height: Int
        /// 8 or 16.
        public var depth: UInt16
        /// Row-major big-endian samples.
        public var data: [UInt8]

        public init(id: String, width: Int, height: Int, depth: UInt16, data: [UInt8]) {
            self.id = id
            self.width = width
            self.height = height
            self.depth = depth
            self.data = data
        }

        /// Samples as 0...1 paint amounts.
        public var unit: [Float] {
            depth == 16 ? PSDSamples.u16(data).map { Float($0) / 65535 } : data.map { Float($0) / 255 }
        }
    }

    public enum LegacyTip: Equatable, Sendable {
        case computed(diameter: UInt16, hardness: UInt16, angle: Int16, roundness: UInt16)
        case sampled(Sample)
    }

    public struct LegacyBrush: Equatable, Sendable {
        public var name: String
        /// Percent of the diameter (0 = spacing off).
        public var spacing: UInt16
        public var antiAlias: Bool
        public var tip: LegacyTip
        public init(name: String = "", spacing: UInt16, antiAlias: Bool = true, tip: LegacyTip) {
            self.name = name
            self.spacing = spacing
            self.antiAlias = antiAlias
            self.tip = tip
        }
    }

    public struct File: Equatable, Sendable {
        public var version: UInt16 = 0
        public var subversion: UInt16 = 0
        public var legacy: [LegacyBrush] = []
        public var samples: [Sample] = []
        public var patterns: [PSDPattern] = []
        /// The `brushPreset` objects of `desc`.
        public var presets: [PSDDescriptor] = []
        /// Each preset's folder path (outermost first), parallel to `presets`; empty when the file has
        /// no readable hierarchy.
        public var folders: [[String]] = []
        public var warnings: [String] = []
    }

    static func readSampleBody(_ r: inout ByteReader, id: String, budget: inout Int) throws -> Sample {
        let top = Int64(try r.i32()), left = Int64(try r.i32()), bottom = Int64(try r.i32()), right = Int64(try r.i32())
        let (w, h) = (right - left, bottom - top)
        guard w > 0, h > 0 else { throw PSDError.invalid("brush sample bounds \(w)×\(h)") }
        guard w <= Int64(maxEdge), h <= Int64(maxEdge) else { throw PSDError.limitExceeded("brush sample larger than maxEdge") }
        let depth = try r.u16()
        guard depth == 8 || depth == 16 else { throw PSDError.invalid("brush sample depth \(depth)") }
        let comp = try r.u8()
        let compression: PSDCompression
        switch comp {
        case 0: compression = .raw
        case 1: compression = .rle
        default: throw PSDError.unsupported("brush sample compression \(comp)")
        }
        let layout = PlaneLayout(planes: 1, width: Int(w), height: Int(h), depth: depth, version: .psd)
        let len = try layout.decodedLength()
        guard budget >= len else { throw PSDError.limitExceeded("abr samples exceed maxTotalBytes") }
        budget -= len
        let data = try PlaneCodec.decode(compression, r.rest, layout: layout)
        try r.skip(r.remaining)
        return Sample(id: id, width: Int(w), height: Int(h), depth: depth, data: data)
    }

    static func readUCS2(_ r: inout ByteReader) throws -> String {
        let n = Int(try r.u32())
        guard n <= 4096 else { throw PSDError.limitExceeded("abr name length") }
        var s = String(decoding: try (0 ..< n).map { _ in try r.u16() }, as: UTF16.self)
        while s.hasSuffix("\0") { s.removeLast() }
        return s
    }

    static func isBudget(_ e: Error) -> Bool { if case let PSDError.limitExceeded(m) = e { m.contains("maxTotalBytes") } else { false } }

    static func parseV12(_ r: inout ByteReader, version: UInt16, _ out: inout File) throws {
        let count = try r.u16()
        var budget = maxTotalBytes
        for i in 0 ..< Int(count) {
            if r.isAtEnd {
                out.warnings.append("file ends after \(i) of \(count) brushes")
                break
            }
            let type = try r.u16()
            let len = Int(try r.u32())
            guard len <= r.remaining else {
                out.warnings.append("brush \(i + 1): truncated")
                break
            }
            var b = try r.sub(len)
            do {
                switch type {
                case 1:
                    _ = try b.u32()
                    let spacing = try b.u16(), diameter = try b.u16(), roundness = try b.u16()
                    let angle = try b.i16(), hardness = try b.u16()
                    out.legacy.append(LegacyBrush(spacing: spacing, tip: .computed(diameter: diameter, hardness: hardness, angle: angle, roundness: roundness)))
                case 2:
                    _ = try b.u32()
                    let spacing = try b.u16()
                    let name = version == 2 ? try readUCS2(&b) : ""
                    let aa = try b.u8() != 0
                    try b.skip(8)
                    let s = try readSampleBody(&b, id: "", budget: &budget)
                    out.legacy.append(LegacyBrush(name: name, spacing: spacing, antiAlias: aa, tip: .sampled(s)))
                default:
                    out.warnings.append("brush \(i + 1): unknown brush type \(type) skipped")
                }
            } catch {
                if isBudget(error) { throw error }
                out.warnings.append("brush \(i + 1): \(error); skipped")
            }
        }
    }

    static func readSamp(_ data: Data, subversion: UInt16, _ out: inout File, budget: inout Int) throws {
        try data.withByteReader { r in
            while r.remaining >= 4 {
                if out.samples.count >= maxBrushes {
                    out.warnings.append("too many sampled tips; the rest were skipped")
                    break
                }
                let len = Int(try r.u32())
                if len == 0 { break }
                let padded = (len + 3) & ~3
                guard min(padded, r.remaining) >= len else {
                    out.warnings.append("sampled tip \(out.samples.count + 1): truncated")
                    break
                }
                var b = try r.sub(min(padded, r.remaining))
                do {
                    let n = Int(try b.u8())
                    let id = String(decoding: try b.bytes(n), as: UTF8.self)
                    try b.skip(subversion == 1 ? 10 : 264)
                    var body = try b.sub(len - 1 - n - (subversion == 1 ? 10 : 264))
                    out.samples.append(try readSampleBody(&body, id: id, budget: &budget))
                } catch {
                    if isBudget(error) { throw error }
                    out.warnings.append("sampled tip \(out.samples.count + 1): \(error); skipped")
                }
            }
        }
    }

    static func readDesc(_ data: Data, _ out: inout File) {
        do {
            let (vd, _) = try PSDVersionedDescriptor.parsePrefix(data)
            guard let items = vd.descriptor.list("Brsh") else {
                out.warnings.append("brush settings (desc) hold no brush list")
                return
            }
            out.presets += items.prefix(maxBrushes).compactMap(\.descriptor)
        } catch {
            out.warnings.append("brush settings (desc) unreadable: \(error)")
        }
    }

    static func readHierarchy(_ data: Data, presets: Int, _ warnings: inout [String]) -> [[String]]? {
        guard let (vd, _) = try? PSDVersionedDescriptor.parsePrefix(data) else {
            warnings.append("brush folders (phry) unreadable; brushes imported without folders")
            return nil
        }
        guard let items = vd.descriptor.list("hierarchy") else {
            warnings.append("brush folders (phry) hold no hierarchy; brushes imported without folders")
            return nil
        }
        var stack: [String] = []
        var overflow = 0, listed = 0, bytes = 0
        var unbalanced = false, tooDeep = false, tooBig = false
        var out: [[String]] = []
        for v in items {
            guard let d = v.descriptor else { continue }
            if d.classID.is("Grup") {
                if stack.count >= maxFolderDepth {
                    overflow += 1
                    tooDeep = true
                    continue
                }
                let name = String((d.text("Nm  ") ?? "").trimmingCharacters(in: .whitespaces).prefix(maxFolderName))
                stack.append(name.isEmpty ? "Group" : name)
            } else if d.classID.is("groupEnd") {
                if overflow > 0 { overflow -= 1 } else if stack.popLast() == nil { unbalanced = true }
            } else if d.classID.is("preset") {
                listed += 1
                if out.count >= presets { continue }
                let size = stack.reduce(0) { $0 + $1.utf8.count + 16 }
                if !tooBig, bytes + size <= maxFolderBytes {
                    bytes += size
                    out.append(stack)
                } else {
                    tooBig = true
                    out.append([])
                }
            }
        }
        if unbalanced { warnings.append("brush folders (phry): a folder end without a folder was ignored") }
        if tooDeep { warnings.append("brush folders nested deeper than \(maxFolderDepth) levels were merged into their parent") }
        if tooBig { warnings.append("brush folders (phry) too large; the remaining brushes were imported at the top level") }
        if listed != presets {
            warnings.append("brush folders (phry) list \(listed) brushes but the file holds \(presets)")
            while out.count < presets { out.append([]) }
        }
        return out
    }

    static func parseV6(_ r: inout ByteReader, _ out: inout File) throws {
        out.subversion = try r.u16()
        guard out.subversion == 1 || out.subversion == 2 else { throw PSDError.unsupported("brush file subversion \(out.subversion)") }
        var budget = maxTotalBytes
        var hierarchy: Data?
        while r.remaining >= 12 {
            let sig = try r.fourCC()
            guard sig == "8BIM" else {
                out.warnings.append("unexpected data at offset \(r.pos - 4) ignored")
                break
            }
            let key = try r.fourCC()
            let len = Int(try r.u32())
            let data: Data
            if len <= r.remaining { data = try r.data(len) } else {
                out.warnings.append("section \(key) truncated")
                data = try r.data(r.remaining)
            }
            // Sections are padded to 4; tolerate writers that do not pad.
            let pad = (4 - len % 4) % 4
            if pad > 0, r.remaining >= pad + 4 {
                let rest = Array(r.rest.prefix(pad + 4))
                if Array(rest.prefix(4)) != Array("8BIM".utf8), Array(rest[pad ..< pad + 4]) == Array("8BIM".utf8) { try r.skip(pad) }
            }
            switch key {
            case "samp": try readSamp(data, subversion: out.subversion, &out, budget: &budget)
            case "patt":
                do { out.patterns += try PSDPattern.parseBlock(data) } catch { out.warnings.append("embedded patterns unreadable: \(error)") }
            case "desc": readDesc(data, &out)
            case "phry": hierarchy = data
            case "lPdc": break
            default: out.warnings.append("section \(key) ignored")
            }
        }
        if let h = hierarchy, let folders = readHierarchy(h, presets: out.presets.count, &out.warnings), folders.contains(where: { !$0.isEmpty }) {
            out.folders = folders
        }
    }

    /// Parses an `.abr` file.
    public static func parse(_ data: Data) throws -> File {
        try data.withByteReader { r in
            var out = File()
            out.version = try r.u16()
            switch out.version {
            case 1, 2: try parseV12(&r, version: out.version, &out)
            case 6 ... 10: try parseV6(&r, &out)
            default: throw PSDError.unsupported("brush file version \(out.version)")
            }
            if out.legacy.isEmpty, out.samples.isEmpty, out.presets.isEmpty {
                throw PSDError.invalid("the brush file holds no readable brushes\(out.warnings.first.map { " (\($0))" } ?? "")")
            }
            return out
        }
    }

    // MARK: Writing

    static func writeSampleBody(_ w: inout ByteWriter, _ s: Sample, rle: Bool) throws {
        guard s.width > 0, s.height > 0, s.width <= maxEdge, s.height <= maxEdge, s.depth == 8 || s.depth == 16 else {
            throw PSDError.limitExceeded("brush sample size or depth")
        }
        for v: Int32 in [0, 0, Int32(s.height), Int32(s.width)] { w.i32(v) }
        w.u16(s.depth)
        w.u8(rle ? 1 : 0)
        w.put(try PlaneCodec.encode(rle ? .rle : .raw, s.data, layout: PlaneLayout(planes: 1, width: s.width, height: s.height, depth: s.depth, version: .psd)))
    }

    /// Writes a v1 or v2 file (sampled tips PackBits-compressed when `rle`).
    public static func writeV12(version: UInt16, _ brushes: [LegacyBrush], rle: Bool) throws -> Data {
        guard version == 1 || version == 2, brushes.count <= Int(UInt16.max) else { throw PSDError.unsupported("writing brush file version \(version)") }
        var w = ByteWriter()
        w.u16(version)
        w.u16(UInt16(brushes.count))
        for b in brushes {
            var body = ByteWriter()
            body.u32(0)
            body.u16(b.spacing)
            let type: UInt16
            switch b.tip {
            case let .computed(diameter, hardness, angle, roundness):
                body.u16(diameter); body.u16(roundness); body.i16(angle); body.u16(hardness)
                type = 1
            case let .sampled(s):
                if version == 2 { body.unicodeUnits(Array(b.name.utf16) + [0]) }
                body.u8(b.antiAlias ? 1 : 0)
                for v in [0, 0, min(s.height, 0xFFFF), min(s.width, 0xFFFF)] { body.u16(UInt16(v)) }
                try writeSampleBody(&body, s, rle: rle)
                type = 2
            }
            w.u16(type)
            w.u32(UInt32(body.count))
            w.put(body.bytes)
        }
        return w.data
    }

    static func section(_ w: inout ByteWriter, _ key: FourCC, _ data: [UInt8]) {
        w.fourCC("8BIM")
        w.fourCC(key)
        let pad = (4 - data.count % 4) % 4
        w.u32(UInt32(data.count + pad))
        w.put(data)
        w.zeros(pad)
    }

    /// A stable uuid-shaped folder id from the path and position (FNV-1a, two seeds).
    static func folderUUID(_ path: [String], _ seq: Int) -> String {
        func hash(_ seed: UInt64) -> UInt64 {
            var h: UInt64 = 0xCBF2_9CE4_8422_2325 ^ seed
            var bytes: [UInt8] = path.flatMap { Array($0.utf8) + [0] }
            withUnsafeBytes(of: UInt64(seq).littleEndian) { bytes += $0 }
            for b in bytes {
                h ^= UInt64(b)
                h = h &* 0x0000_0100_0000_01B3
            }
            return h
        }
        let (a, b) = (hash(1), hash(2))
        return String(format: "%08llx-%04llx-%04llx-%04llx-%012llx", a >> 32, (a >> 16) & 0xFFFF, a & 0xFFFF, b >> 48, b & 0xFFFF_FFFF_FFFF)
    }

    static func hierarchyDescriptor(_ folders: [[String]]) -> PSDDescriptor {
        var items: [PSDDescriptor.Value] = []
        var open: [String] = []
        var seq = 0
        for p in folders {
            let path = Array(p.prefix(maxFolderDepth))
            let common = zip(open, path).prefix { $0 == $1 }.count
            while open.count > common {
                open.removeLast()
                items.append(.descriptor(PSDDescriptor(classID: "groupEnd")))
            }
            for name in path.dropFirst(common) {
                open.append(name)
                seq += 1
                items.append(.descriptor(PSDDescriptor(classID: "Grup").with("Nm  ", .text(.nulTerminated(name))).with("zuid", .text(.nulTerminated(folderUUID(open, seq))))))
            }
            items.append(.descriptor(PSDDescriptor(classID: "preset")))
        }
        for _ in open { items.append(.descriptor(PSDDescriptor(classID: "groupEnd"))) }
        return PSDDescriptor().with("hierarchy", .list(items))
    }

    /// Writes a v6 file (subversion 1 or 2): sampled tips, embedded patterns, presets under `Brsh`,
    /// and the folder hierarchy when `folders` (parallel to `presets`) holds any path.
    public static func writeV6(subversion: UInt16, samples: [Sample], patterns: [PSDPattern], presets: [PSDDescriptor], folders: [[String]] = [], rle: Bool) throws -> Data {
        guard folders.isEmpty || folders.count == presets.count else { throw PSDError.invalid("\(folders.count) folder paths for \(presets.count) brush presets") }
        guard subversion == 1 || subversion == 2 else { throw PSDError.unsupported("brush file subversion \(subversion)") }
        var w = ByteWriter()
        w.u16(6)
        w.u16(subversion)
        var samp = ByteWriter()
        for s in samples {
            var e = ByteWriter()
            let id = Array(s.id.utf8.prefix(255))
            e.u8(UInt8(id.count)); e.put(id)
            e.zeros(subversion == 1 ? 10 : 264)
            try writeSampleBody(&e, s, rle: rle)
            samp.u32(UInt32(e.count))
            samp.put(e.bytes)
            samp.zeros((4 - e.count % 4) % 4)
        }
        section(&w, "samp", samp.bytes)
        if !patterns.isEmpty { section(&w, "patt", [UInt8](try PSDPattern.writeBlock(patterns))) }
        section(&w, "desc", [UInt8](PSDVersionedDescriptor(PSDDescriptor().with("Brsh", .list(presets.map { .descriptor($0) }))).serialized()))
        if folders.contains(where: { !$0.isEmpty }) {
            section(&w, "phry", [UInt8](PSDVersionedDescriptor(hierarchyDescriptor(folders)).serialized()))
        }
        return w.data
    }
}
