// Port of photocraft-algo (crates/algo/src/exif.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Minimal EXIF reader for the camera settings the photography commands use (exposure, aperture,
// ISO, focal length, camera and lens names). Input is the raw TIFF-structured EXIF payload
// (`II*\0` / `MM\0*`, optionally behind `Exif\0\0`); malformed data yields nil fields, never a
// trap: every offset and size is checked. Tag numbers from EXIF 2.32 (CIPA DC-008).

import Foundation

/// EXIF camera settings (photocraft `exif`).
public enum Exif {
    /// Camera settings read from EXIF (photocraft `CameraInfo`).
    public struct CameraInfo: Hashable, Sendable, Codable {
        public var make: String?
        public var model: String?
        public var lens: String?
        /// Seconds.
        public var exposureTime: Double?
        public var fNumber: Double?
        public var iso: Double?
        /// Millimetres.
        public var focalLength: Double?
        /// 35 mm-equivalent focal length in millimetres.
        public var focalLength35mm: Double?
        /// DateTimeOriginal as stored (`YYYY:MM:DD HH:MM:SS`).
        public var dateTaken: String?

        public init(make: String? = nil, model: String? = nil, lens: String? = nil, exposureTime: Double? = nil, fNumber: Double? = nil,
                    iso: Double? = nil, focalLength: Double? = nil, focalLength35mm: Double? = nil, dateTaken: String? = nil) {
            self.make = make; self.model = model; self.lens = lens; self.exposureTime = exposureTime; self.fNumber = fNumber
            self.iso = iso; self.focalLength = focalLength; self.focalLength35mm = focalLength35mm; self.dateTaken = dateTaken
        }

        /// Linear exposure factor `t · ISO / N²` (relative brightness of the image for one scene).
        public var exposureFactor: Double? {
            guard let t = exposureTime else { return nil }
            let n = PhotoKit.dmax(fNumber ?? 1, 0.1)
            return t * (iso ?? 100) / 100 / (n * n)
        }
    }

    struct Tiff {
        let b: [UInt8]
        let le: Bool

        func u16(_ o: Int) -> UInt16? {
            guard o >= 0, o <= b.count - 2 else { return nil }
            return le ? UInt16(b[o]) | UInt16(b[o + 1]) << 8 : UInt16(b[o]) << 8 | UInt16(b[o + 1])
        }

        func u32(_ o: Int) -> UInt32? {
            guard o >= 0, o <= b.count - 4 else { return nil }
            let (a, c, d, e) = (UInt32(b[o]), UInt32(b[o + 1]), UInt32(b[o + 2]), UInt32(b[o + 3]))
            return le ? a | c << 8 | d << 16 | e << 24 : a << 24 | c << 16 | d << 8 | e
        }

        /// Entries of the IFD at `off`: (tag, type, count, value-field position).
        func ifd(_ off: Int) -> [(UInt16, UInt16, UInt32, Int)] {
            guard let n = u16(off) else { return [] }
            var out: [(UInt16, UInt16, UInt32, Int)] = []
            for k in 0..<Int(n) {
                let e = off + 2 + k * 12
                guard let tag = u16(e), let typ = u16(e + 2), let count = u32(e + 4) else { continue }
                out.append((tag, typ, count, e + 8))
            }
            return out
        }

        func dataAt(_ typ: UInt16, _ count: UInt32, _ field: Int) -> Int? {
            let unit: Int
            switch typ {
            case 1, 2, 6, 7: unit = 1
            case 3, 8: unit = 2
            case 4, 9, 11: unit = 4
            case 5, 10, 12: unit = 8
            default: return nil
            }
            let (size, overflow) = unit.multipliedReportingOverflow(by: Int(count))
            if overflow { return nil }
            let at: Int
            if size <= 4 { at = field } else { guard let v = u32(field) else { return nil }; at = Int(v) }
            // The whole value must lie inside the payload, not just its first element.
            let (end, o2) = at.addingReportingOverflow(size)
            if o2 || at < 0 || end > b.count { return nil }
            return at
        }

        func number(_ typ: UInt16, _ count: UInt32, _ field: Int) -> Double? {
            guard let at = dataAt(typ, count, field) else { return nil }
            switch typ {
            case 3: return u16(at).map { Double($0) }
            case 4: return u32(at).map { Double($0) }
            case 5:
                guard let n = u32(at), let d = u32(at + 4) else { return nil }
                return d != 0 ? Double(n) / Double(d) : nil
            case 10:
                guard let n = u32(at), let d = u32(at + 4) else { return nil }
                let ni = Int32(bitPattern: n), di = Int32(bitPattern: d)
                return di != 0 ? Double(ni) / Double(di) : nil
            default: return nil
            }
        }

        func text(_ typ: UInt16, _ count: UInt32, _ field: Int) -> String? {
            if typ != 2 { return nil }
            guard let at = dataAt(typ, count, field) else { return nil }
            let end = at + Int(count)
            guard end <= b.count else { return nil }
            var s = String(decoding: b[at..<end], as: UTF8.self)
            while s.hasSuffix("\0") { s.removeLast() }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
    }

    /// Reads `CameraInfo` from a TIFF-structured EXIF payload (an `Exif\0\0` prefix is skipped)
    /// (photocraft `exif::read`).
    public static func read(_ exif: [UInt8]) -> CameraInfo {
        let prefix: [UInt8] = Array("Exif\0\0".utf8)
        let b = exif.starts(with: prefix) ? Array(exif.dropFirst(prefix.count)) : exif
        var info = CameraInfo()
        guard b.count >= 4 else { return info }
        let le: Bool
        if b[0] == 0x49, b[1] == 0x49, b[2] == 42, b[3] == 0 { le = true } else if b[0] == 0x4D, b[1] == 0x4D, b[2] == 0, b[3] == 42 { le = false } else {
            return info
        }
        let t = Tiff(b: b, le: le)
        guard let ifd0 = t.u32(4) else { return info }
        var queue = [Int(ifd0)]
        var seen: [Int] = []
        while let off = queue.popLast() {
            if seen.contains(off) || seen.count > 8 { continue }
            seen.append(off)
            for (tag, typ, count, field) in t.ifd(off) {
                switch tag {
                case 0x010F: info.make = t.text(typ, count, field)
                case 0x0110: info.model = t.text(typ, count, field)
                case 0x829A: info.exposureTime = t.number(typ, count, field)
                case 0x829D: info.fNumber = t.number(typ, count, field)
                case 0x8827: info.iso = t.number(typ, count, field)
                case 0x920A: info.focalLength = t.number(typ, count, field)
                case 0xA405: info.focalLength35mm = t.number(typ, count, field).flatMap { $0 > 0 ? $0 : nil }
                case 0xA434: info.lens = t.text(typ, count, field)
                case 0x9003: info.dateTaken = t.text(typ, count, field)
                case 0x8769: if let p = t.u32(field) { queue.append(Int(p)) }
                default: break
                }
            }
        }
        return info
    }

    /// Builds a little-endian EXIF payload (tests and synthetic fixtures; photocraft `exif::build`).
    public static func build(_ info: CameraInfo) -> [UInt8] {
        typealias Entry = (tag: UInt16, typ: UInt16, count: UInt32, bytes: [UInt8])
        var ifd0: [Entry] = [], exif: [Entry] = []
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
        func text(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }
        func rational(_ v: Double) -> [UInt8] {
            let d: UInt32 = 10000
            let n = UInt32(clamping: Int64(clamping: PhotoKit.i64((v * Double(d)).rounded())))
            return le32(n) + le32(d)
        }
        func u16Of(_ v: Double) -> [UInt8] { le16(UInt16(clamping: PhotoKit.usize(v))) }
        if let s = info.make { ifd0.append((0x010F, 2, UInt32(s.utf8.count + 1), text(s))) }
        if let s = info.model { ifd0.append((0x0110, 2, UInt32(s.utf8.count + 1), text(s))) }
        if let v = info.exposureTime { exif.append((0x829A, 5, 1, rational(v))) }
        if let v = info.fNumber { exif.append((0x829D, 5, 1, rational(v))) }
        if let v = info.iso { exif.append((0x8827, 3, 1, u16Of(v))) }
        if let s = info.dateTaken { exif.append((0x9003, 2, UInt32(s.utf8.count + 1), text(s))) }
        if let v = info.focalLength { exif.append((0x920A, 5, 1, rational(v))) }
        if let v = info.focalLength35mm { exif.append((0xA405, 3, 1, u16Of(v))) }
        if let s = info.lens { exif.append((0xA434, 2, UInt32(s.utf8.count + 1), text(s))) }
        func ifdLen(_ n: Int) -> Int { 2 + 12 * n + 4 }
        let ifd0Off = 8
        let n0 = ifd0.count + 1
        let exifOff = ifd0Off + ifdLen(n0)
        var dataOff = exifOff + ifdLen(exif.count)
        var out: [UInt8] = Array("II*\0".utf8) + le32(UInt32(ifd0Off))
        var data: [UInt8] = []
        func writeIFD(_ entries: [Entry], _ extra: UInt32?) {
            let n = entries.count + (extra != nil ? 1 : 0)
            out += le16(UInt16(n))
            for e in entries {
                out += le16(e.tag) + le16(e.typ) + le32(e.count)
                if e.bytes.count <= 4 {
                    out += e.bytes + [UInt8](repeating: 0, count: 4 - e.bytes.count)
                } else {
                    out += le32(UInt32(dataOff))
                    data += e.bytes
                    dataOff += e.bytes.count
                }
            }
            if let p = extra { out += le16(0x8769) + le16(4) + le32(1) + le32(p) }
            out += le32(0)
        }
        writeIFD(ifd0, UInt32(exifOff))
        writeIFD(exif, nil)
        return out + data
    }
}
