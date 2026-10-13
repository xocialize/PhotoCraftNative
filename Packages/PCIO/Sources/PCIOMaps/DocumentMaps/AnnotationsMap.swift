// Port of photocraft-io (crates/io/src/annotations_map.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.
//
// Notes and Image › Analysis data ⇄ PSD.
//
// * Notes: the global additional-info block `Anno` ("Annotations (Photoshop 6.0)" in the Adobe PSD
//   spec): `u16` major version 2, `u16` minor version 1, `u32` count, then per annotation a `u32`
//   length (including itself), type `txtA` (text) or `sndA` (sound), open flag `u8`, flags `u8`,
//   optional blocks `u16`, icon rect and popup rect (four `i32` each: top, left, bottom, right), a
//   colour (`u16` space + four `u16`), author, name and modification date as even-padded Pascal
//   strings, then a `u32` length (including itself) of the data block: `txtC`/`sndM`, `u32` size and
//   the data. Text is UTF-16BE with a byte-order mark, lines separated by CR. Sound annotations are
//   not modelled; they are carried over verbatim when notes are rewritten.
// * Measurement scale: image resource 1074 (a version-16 descriptor). The key names
//   (`pixelLength`, `logicalLength`, `logicalUnits`) follow Photoshop's scripting names for the
//   measurement scale; parsing is lenient and the raw resource is kept byte-exact while the scale
//   is unchanged.
// * Count information: image resource 1080 is kept verbatim (its layout is not public) unless the
//   document has its own count markers, which only `.pcraft` stores.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD

public enum AnnotationsMap {
    public static let measurementScale: UInt16 = 1074
    public static let countInfo: UInt16 = 1080
    public static let anno: FourCC = "Anno"

    /// A bounds-checked cursor (photocraft's `Reader`).
    struct Reader {
        let d: [UInt8]
        var p = 0

        mutating func take(_ n: Int) -> ArraySlice<UInt8>? {
            let (end, o) = p.addingReportingOverflow(n)
            guard n >= 0, !o, end <= d.count else { return nil }
            defer { p = end }
            return d[p ..< end]
        }

        mutating func u8() -> UInt8? { take(1)?.first }

        mutating func u16() -> UInt16? {
            guard let b = take(2) else { return nil }
            return UInt16(b[b.startIndex]) << 8 | UInt16(b[b.startIndex + 1])
        }

        mutating func u32() -> UInt32? {
            guard let b = take(4) else { return nil }
            let s = b.startIndex
            return UInt32(b[s]) << 24 | UInt32(b[s + 1]) << 16 | UInt32(b[s + 2]) << 8 | UInt32(b[s + 3])
        }

        mutating func i32() -> Int32? { u32().map { Int32(bitPattern: $0) } }

        mutating func pascal() -> String? {
            guard let n = u8().map(Int.init), let s = take(n) else { return nil }
            if (n + 1) % 2 == 1, take(1) == nil { return nil }
            return latin1(s)
        }
    }

    static func latin1<S: Sequence<UInt8>>(_ bytes: S) -> String {
        var v = String.UnicodeScalarView()
        for b in bytes { v.append(Unicode.Scalar(b)) }
        return String(v)
    }

    static func pascal(_ out: inout [UInt8], _ s: String) {
        let bytes = s.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?") }.prefix(255)
        out.append(UInt8(bytes.count))
        out += bytes
        if (bytes.count + 1) % 2 == 1 { out.append(0) }
    }

    /// PSD colour struct (space + 4 × u16) → RGB.
    static func colorFrom(_ space: UInt16, _ c: [UInt16]) -> PCColor {
        func f(_ v: UInt16) -> Float { Float(v) / 65535 }
        switch space {
        // HSB: hue 0–65535 maps to 0–360°.
        case 1:
            let (h, s, v) = (f(c[0]) * 6, f(c[1]), f(c[2]))
            let fl = h.rounded(.down)
            // Rust's `(h.floor() as i32).rem_euclid(6)`.
            let i = ((satCast(fl) as Int32) % 6 + 6) % 6
            let fr = h - fl
            let (p, q, t) = (v * (1 - s), v * (1 - s * fr), v * (1 - s * (1 - fr)))
            let (r, g, b): (Float, Float, Float) = switch i {
            case 0: (v, t, p)
            case 1: (q, v, p)
            case 2: (p, v, t)
            case 3: (p, q, v)
            case 4: (t, p, v)
            default: (v, p, q)
            }
            return .rgb(r, g, b)
        // CMYK (inverted: 0 = 100 % ink), naive.
        case 2:
            let k = 1 - f(c[3])
            return .rgb(f(c[0]) * (1 - k), f(c[1]) * (1 - k), f(c[2]) * (1 - k))
        // Grayscale 0–10000.
        case 8:
            let g = 1 - rustClamp(Float(c[0]) / 10000, 0, 1)
            return .rgb(g, g, g)
        default:
            return .rgb(f(c[0]), f(c[1]), f(c[2]))
        }
    }

    static func decodeText(_ data: ArraySlice<UInt8>) -> String {
        var scalars: [Unicode.Scalar]
        if data.count >= 2, data[data.startIndex] == 0xFE, data[data.startIndex + 1] == 0xFF {
            var units: [UInt16] = []
            var i = data.startIndex + 2
            while i + 1 < data.endIndex {
                units.append(UInt16(data[i]) << 8 | UInt16(data[i + 1]))
                i += 2
            }
            scalars = Array(String(decoding: units, as: UTF16.self).unicodeScalars)
        } else {
            scalars = data.map { Unicode.Scalar($0) }
        }
        while scalars.last == "\0" { scalars.removeLast() }
        // "\r\n" → "\n", then "\r" → "\n".
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if scalars[i] == "\r" {
                out.append("\n")
                if i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
            } else {
                out.append(scalars[i])
            }
            i += 1
        }
        return String(out)
    }

    static func encodeText(_ s: String) -> [UInt8] {
        // "\r\n" → "\n", then "\n" → "\r".
        let scalars = Array(s.unicodeScalars)
        var t = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if scalars[i] == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" {
                t.append("\r")
                i += 2
                continue
            }
            t.append(scalars[i] == "\n" ? "\r" : scalars[i])
            i += 1
        }
        var out: [UInt8] = [0xFE, 0xFF]
        for u in String(t).utf16 { out += [UInt8(u >> 8), UInt8(u & 0xFF)] }
        return out
    }

    /// One parsed `Anno` entry: a note, or a raw entry we keep (sound annotations).
    enum Entry {
        case text(Note)
        case raw([UInt8])
    }

    static func parseEntries(_ data: [UInt8]) -> [Entry]? {
        var r = Reader(d: data)
        guard r.u16() != nil, r.u16() != nil, let count = r.u32() else { return nil }
        var out: [Entry] = []
        out.reserveCapacity(Int(min(count, 4096)))
        for _ in 0 ..< count {
            let start = r.p
            guard let len = r.u32().map(Int.init) else { return nil }
            // Deviation: a zero length makes no progress, so photocraft would repeat the same empty
            // entry up to 2³² times; the block is reported unreadable (and kept verbatim) instead.
            if len == 0 { return nil }
            let (end, o) = start.addingReportingOverflow(len)
            guard !o, end <= data.count else { return nil }
            let raw = Array(data[start ..< end])
            guard let kind = r.take(4) else { return nil }
            if Array(kind) != Array("txtA".utf8) {
                out.append(.raw(raw))
                r.p = end
                continue
            }
            guard let openFlag = r.u8(), r.u8() != nil, r.u16() != nil,
                  let i0 = r.i32(), let i1 = r.i32(), r.i32() != nil, r.i32() != nil,
                  let p0 = r.i32(), let p1 = r.i32(), let p2 = r.i32(), let p3 = r.i32(),
                  let space = r.u16(), let c0 = r.u16(), let c1 = r.u16(), let c2 = r.u16(), let c3 = r.u16(),
                  let author = r.pascal(), r.pascal() != nil, let modified = r.pascal(),
                  r.u32() != nil, r.take(4) != nil, let n = r.u32().map(Int.init), let textBytes = r.take(n)
            else { return nil }
            out.append(.text(Note(
                author: author,
                color: colorFrom(space, [c0, c1, c2, c3]),
                text: decodeText(textBytes),
                position: SIMD2(Double(i1), Double(i0)),
                popup: SIMD4(Double(p1), Double(p0), Double(p3), Double(p2)),
                open: openFlag != 0,
                modified: modified
            )))
            r.p = end
        }
        return out
    }

    /// Notes in an `Anno` block (nil when it doesn't parse).
    public static func parseAnno(_ data: [UInt8]) -> [Note]? {
        parseEntries(data).map { $0.compactMap { if case let .text(n) = $0 { n } else { nil } } }
    }

    static func writeNote(_ n: Note) -> [UInt8] {
        var b: [UInt8] = Array("txtA".utf8)
        b.append(n.open ? 1 : 0)
        b.append(0x1C)
        be16(&b, 1)
        // The position comes from the file or a command and can sit anywhere in Int32 (issue #939):
        // the cast saturates, and the icon's far edge must saturate too rather than wrap when the
        // note is re-saved.
        let (x, y): (Int32, Int32) = (roundCast(n.position[0]), roundCast(n.position[1]))
        for v in [y, x, satAdd(y, 20), satAdd(x, 16)] { be32(&b, UInt32(bitPattern: v)) }
        let pp = n.popup == .zero
            ? SIMD4(n.position[0] + 20, n.position[1] + 20, n.position[0] + 260, n.position[1] + 160)
            : n.popup
        for v in [pp[1], pp[0], pp[3], pp[2]] { be32(&b, UInt32(bitPattern: roundCast(v) as Int32)) }
        be16(&b, 0)
        let rgb = n.color.rgb
        for v in [rgb.x, rgb.y, rgb.z] { be16(&b, roundCast(rustClamp(v, 0, 1) * 65535) as UInt16) }
        be16(&b, 0)
        pascal(&b, n.author)
        pascal(&b, "")
        pascal(&b, n.modified)
        let text = encodeText(n.text)
        be32(&b, UInt32(truncatingIfNeeded: text.count + 12))
        b += Array("txtC".utf8)
        be32(&b, UInt32(truncatingIfNeeded: text.count))
        b += text
        var out: [UInt8] = []
        be32(&out, UInt32(truncatingIfNeeded: b.count + 4))
        return out + b
    }

    /// An `Anno` block holding `notes` (plus raw sound entries carried over).
    public static func writeAnno(_ notes: [Note], _ rawExtra: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        be16(&out, 2)
        be16(&out, 1)
        be32(&out, UInt32(truncatingIfNeeded: notes.count + rawExtra.count))
        for n in notes { out += writeNote(n) }
        for r in rawExtra { out += r }
        return out
    }

    static func annoBlock(_ blocks: [PSDGlobalBlock]) -> PSDGlobalBlock? { blocks.first { FourCC($0.key) == anno } }

    /// The document's notes from its raw global blocks (empty when there is no `Anno` block).
    public static func notesFromBlocks(_ doc: Document) -> [Note] {
        annoBlock(doc.metadata.psdGlobalBlocks).flatMap { parseAnno($0.data) } ?? []
    }

    /// Whether the document holds an `Anno` block that doesn't parse (its notes can't be shown).
    public static func annoUnreadable(_ doc: Document) -> Bool {
        annoBlock(doc.metadata.psdGlobalBlocks).map { parseEntries($0.data) == nil } ?? false
    }

    /// Global blocks to write: the raw `Anno` block while it still describes `doc.notes` (or doesn't
    /// parse and no note was added), else a regenerated one in its place (appended when new,
    /// dropped when the last note is deleted).
    public static func exportBlocks(_ doc: Document, _ blocks: [PSDGlobalBlock]) -> [PSDGlobalBlock] {
        var blocks = blocks
        let at = blocks.firstIndex { FourCC($0.key) == anno }
        let entries = at.flatMap { parseEntries(blocks[$0].data) }
        let parsed: [Note]? = entries.map { $0.compactMap { if case let .text(n) = $0 { n } else { nil } } }
        // Compare in stored precision (colours are 16-bit, positions whole pixels, empty popups get
        // a default rectangle).
        let want = parseAnno(writeAnno(doc.notes, []))
        func same(_ a: [Note], _ b: [Note]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { x, y in
                var xx = x
                xx.color = y.color
                let (cx, cy) = (x.color.rgb, y.color.rgb)
                return xx == y && (0 ..< 3).allSatisfy { abs(cx[$0] - cy[$0]) < 1 / 512 }
            }
        }
        // With no notes, a block we can't read is kept as is: it isn't "the last note deleted", and
        // dropping it would delete the annotations it holds (issue #944).
        if let p = parsed, let w = want, same(p, w) { return blocks }
        if entries == nil && doc.notes.isEmpty { return blocks }
        let extra: [[UInt8]] = (entries ?? []).compactMap { if case let .raw(r) = $0 { r } else { nil } }
        let fresh = !doc.notes.isEmpty || !extra.isEmpty ? writeAnno(doc.notes, extra) : nil
        switch (at, fresh) {
        case let (i?, f?): blocks[i].data = f
        case let (i?, nil): blocks.remove(at: i)
        case let (nil, f?): blocks.append(PSDGlobalBlock(signature: "8BIM", key: anno.psdKey, data: f))
        case (nil, nil): break
        }
        return blocks
    }

    // MARK: Measurement scale

    static func find(_ d: PSDDescriptor, _ keys: [String]) -> DValue? {
        for k in keys { if let v = d[k] { return v } }
        // The scale may be nested one object deep (`measurementScale` object).
        for it in d.items {
            guard case let .descriptor(o) = it.value else { continue }
            for k in keys { if let v = o[k] { return v } }
        }
        return nil
    }

    /// Measurement scale described by resource 1074 (nil when it doesn't parse).
    public static func scaleFromResource(_ data: [UInt8]) -> MeasurementScale? {
        guard let d = try? PSDVersionedDescriptor.parsePrefix(Data(data)).0.descriptor,
              let pixelLength = find(d, ["pixelLength", "PxlL"])?.number,
              let logicalLength = find(d, ["logicalLength", "LglL"])?.number else { return nil }
        var units = "pixels"
        if case let .text(t)? = find(d, ["logicalUnits", "LglU"]) { units = t.string }
        return MeasurementScale(pixelLength: pixelLength, logicalLength: logicalLength, units: units)
    }

    /// Resource 1074 data for a scale.
    public static func writeScaleResource(_ s: MeasurementScale) -> [UInt8] {
        let d = PSDDescriptor(classID: "null")
            .with("pixelLength", .double(s.pixelLength))
            .with("logicalLength", .double(s.logicalLength))
            .with("logicalUnits", .text(PSDUnicodeString(s.units)))
        var v = Blocks.versionedBytes(d)
        if v.count % 2 == 1 { v.append(0) }
        return v
    }

    /// The measurement scale a document's preserved resource 1074 holds (nil when absent or
    /// unreadable).
    public static func rawScale(_ doc: Document) -> MeasurementScale? {
        guard let raw = doc.metadata.psdResources.first(where: { $0.id == measurementScale }) else { return nil }
        return scaleFromResource(raw.data)
    }

    /// Whether the preserved resource 1074 may be written as is: it still describes the document's
    /// scale (or doesn't parse and the scale was never changed from the default).
    public static func keepRawScale(_ doc: Document) -> Bool {
        if let s = rawScale(doc) { return s == doc.measurement.scale }
        return doc.measurement.scale.isDefault
    }

    /// Resource 1074 to write when the preserved one can't be used (nil = write nothing).
    public static func freshScaleResource(_ doc: Document) -> [UInt8]? {
        let hasRaw = doc.metadata.psdResources.contains { $0.id == measurementScale }
        if hasRaw && keepRawScale(doc) { return nil }
        return doc.measurement.scale.isDefault ? nil : writeScaleResource(doc.measurement.scale)
    }

    /// Whether to keep a preserved resource with this id on export.
    public static func keepResource(_ doc: Document, _ id: UInt16) -> Bool {
        switch id {
        case measurementScale: keepRawScale(doc)
        // Our count markers can't be written into Photoshop's (unpublished) layout; a stale copy
        // would contradict them, so it is dropped once the document has markers of its own.
        case countInfo: doc.measurement.countTotal == 0
        default: true
        }
    }
}

private func be16(_ out: inout [UInt8], _ v: UInt16) { out += [UInt8(v >> 8), UInt8(v & 0xFF)] }

private func be32(_ out: inout [UInt8], _ v: UInt32) {
    out += [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
}

private func satAdd(_ a: Int32, _ b: Int32) -> Int32 {
    let (v, o) = a.addingReportingOverflow(b)
    return o ? (b > 0 ? .max : .min) : v
}

/// Rust's `f32::clamp`: NaN stays NaN.
private func rustClamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { v.isNaN ? v : min(max(v, lo), hi) }
