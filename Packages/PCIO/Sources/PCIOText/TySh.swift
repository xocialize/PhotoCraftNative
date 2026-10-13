// The `TySh` block as photocraft reads and writes it: transform + text descriptor (with
// `EngineData`) + warp descriptor + four trailing f32 bounds.
// Port of photocraft-text (crates/text/src/psd.rs: `TySh`, `parse_tysh`, `write_tysh`,
// `translate_tysh`, `default_warp`, `engine_data`, `engine_text_is_blank`, `parse_txt2`, the
// descriptor helpers), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// PCPSD's `PSDTypeTool` is the lossless byte-level view (it keeps versions and trailing bytes as
// stored). This file keeps photocraft's normalising view, because `build_tysh` and the style-sheet
// writer must produce photocraft's bytes: version 1, text version 50, a warp descriptor always
// present (the default one when the layer has none) and exactly four f32 bounds. The descriptors
// themselves are PCPSD's (`PSDVersionedDescriptor`), whose layout matches photocraft's.

import Foundation
import PCDocument
import PCPSD

extension PSDText {
    /// Parsed `TySh` contents.
    public struct TySh: Equatable, Sendable {
        public var transform: PCAffine
        public var text: PSDDescriptor
        public var warp: PSDDescriptor?
        /// The four trailing big-endian f32 values (left, top, right, bottom) after the warp
        /// descriptor. Photoshop writes zeros for unwarped type and the text-space bounds (the
        /// `bounds` descriptor's rectangle) for warped type.
        public var bounds: SIMD4<Float>

        public init(transform: PCAffine, text: PSDDescriptor, warp: PSDDescriptor? = nil, bounds: SIMD4<Float> = .zero) {
            self.transform = transform
            self.text = text
            self.warp = warp
            self.bounds = bounds
        }
    }

    /// Parses a `TySh` block (photocraft `parse_tysh`): nil when the transform or the text
    /// descriptor is missing or malformed. A missing or malformed warp descriptor reads as none,
    /// and missing trailing bounds as zeros.
    public static func parseTySh(_ data: [UInt8]) -> TySh? {
        guard data.count >= 52 else { return nil }
        var m = [Double](repeating: 0, count: 6)
        for i in 0 ..< 6 { m[i] = readF64(data, 2 + i * 8) }
        guard let (text, used) = try? PSDVersionedDescriptor.parsePrefix(Data(data[52...])) else { return nil }
        let restStart = 52 + used
        let rest: [UInt8] = restStart <= data.count ? Array(data[restStart...]) : []
        var warp: PSDDescriptor?
        var wused = 0
        if rest.count >= 2, let (w, n) = try? PSDVersionedDescriptor.parsePrefix(Data(rest[2...])) {
            warp = w.descriptor
            wused = n + 2
        }
        let tail: [UInt8] = wused <= rest.count ? Array(rest[wused...]) : []
        var bounds = SIMD4<Float>.zero
        for i in 0 ..< 4 where i * 4 + 4 <= tail.count {
            bounds[i] = Float(bitPattern: UInt32(tail[i * 4]) << 24 | UInt32(tail[i * 4 + 1]) << 16 | UInt32(tail[i * 4 + 2]) << 8 | UInt32(tail[i * 4 + 3]))
        }
        return TySh(transform: PCAffine(m: m), text: text.descriptor, warp: warp, bounds: bounds)
    }

    /// Serializes a `TySh` block (photocraft `write_tysh`).
    public static func writeTySh(_ t: TySh) -> [UInt8] {
        var v: [UInt8] = []
        putU16(&v, 1)
        for x in t.transform.m { putU64(&v, x.bitPattern) }
        putU16(&v, 50)
        v += [UInt8](PSDVersionedDescriptor(t.text).serialized())
        putU16(&v, 1)
        v += [UInt8](PSDVersionedDescriptor(t.warp ?? defaultWarp()).serialized())
        for i in 0 ..< 4 { putU32(&v, t.bounds[i].bitPattern) }
        return v
    }

    /// `tysh` moved by (`dx`, `dy`): only the transform's translation changes. The text, its
    /// styles, the warp and the trailing bounds (which are in text space) stay byte for byte, so
    /// a moved Photoshop type layer keeps everything Photoshop wrote. nil when the block is too
    /// short.
    public static func translateTySh(_ tysh: [UInt8], dx: Double, dy: Double) -> [UInt8]? {
        var out = tysh
        // Version (2 bytes), then xx, xy, yx, yy, tx, ty as big-endian f64: tx at 34, ty at 42.
        for (at, d) in [(34, dx), (42, dy)] {
            guard at + 8 <= out.count else { return nil }
            let v = readF64(out, at) + d
            var b: [UInt8] = []
            putU64(&b, v.bitPattern)
            out.replaceSubrange(at ..< at + 8, with: b)
        }
        return out
    }

    /// The EngineData of a text descriptor (its `EngineData` raw-data item, parsed).
    public static func engineData(_ text: PSDDescriptor) -> PSDEngineData? {
        guard case let .rawData(b)? = text["EngineData"] else { return nil }
        return try? PSDEngineData.parse(b)
    }

    /// Whether the text engine of a `TySh` block has nothing to draw: its EngineData text
    /// (`EngineDict/Editor/Text`, what Photoshop lays out) is present and only whitespace. Some
    /// Photoshop layers carry their characters only in the descriptor's `Txt ` and render nothing.
    public static func engineTextIsBlank(_ tysh: [UInt8]) -> Bool {
        guard let t = parseTySh(tysh), let s = engineData(t.text)?.at("EngineDict", "Editor", "Text")?.str else { return false }
        return trimmedWhitespace(s).isEmpty
    }

    /// Parses the document's `Txt2` block (Photoshop's text engine data for all type layers): a
    /// bare sequence of `/key value` pairs, read as one dictionary. nil when it doesn't parse.
    public static func parseTxt2(_ data: [UInt8]) -> PSDEngineData? {
        guard let v = try? PSDEngineData.parseBare(Data(data)), v.isDict else { return nil }
        return v
    }

    // MARK: Descriptor helpers

    static func defaultWarp() -> PSDDescriptor {
        PSDDescriptor(classID: "warp")
            .with("warpStyle", enumv("warpStyle", "warpNone"))
            .with("warpValue", .double(0))
            .with("warpPerspective", .double(0))
            .with("warpPerspectiveOther", .double(0))
            .with("warpRotate", enumv("Ornt", "Hrzn"))
    }

    static func enumv(_ t: String, _ v: String) -> PSDDescriptor.Value {
        .enumerated(type: PSDDescriptor.ID(t), value: PSDDescriptor.ID(v))
    }

    static func enumValue(_ d: PSDDescriptor, _ key: String) -> String? {
        guard case let .enumerated(_, value)? = d[key] else { return nil }
        return String(decoding: value.bytes, as: UTF8.self)
    }

    static func dnum(_ v: PSDDescriptor.Value?) -> Double? {
        switch v {
        case let .double(x)?: x
        case let .unitFloat(_, value)?: value
        case let .integer(i)?: Double(i)
        default: nil
        }
    }

    /// A rectangle descriptor (`Left`, `Top `, `Rght`, `Btom`) when finite and non-empty.
    static func descriptorRect(_ text: PSDDescriptor, _ key: String) -> [Double]? {
        guard case let .descriptor(rect)? = text[key],
              let l = dnum(rect["Left"]), let t = dnum(rect["Top "]), let r = dnum(rect["Rght"]), let b = dnum(rect["Btom"]) else { return nil }
        let bounds = [l, t, r, b]
        return bounds.allSatisfy(\.isFinite) && r > l && b > t ? bounds : nil
    }

    /// The `TextIndex` integer of a text descriptor, when present and not negative.
    static func rawTextIndex(_ text: PSDDescriptor) -> Int? {
        guard case let .integer(i)? = text["TextIndex"], i >= 0 else { return nil }
        return Int(i)
    }

    // MARK: Bytes

    static func readF64(_ b: [UInt8], _ at: Int) -> Double {
        var v: UInt64 = 0
        for i in 0 ..< 8 { v = v << 8 | UInt64(b[at + i]) }
        return Double(bitPattern: v)
    }

    static func putU16(_ v: inout [UInt8], _ x: UInt16) { v += [UInt8(x >> 8), UInt8(x & 0xFF)] }
    static func putU32(_ v: inout [UInt8], _ x: UInt32) { for s in stride(from: 24, through: 0, by: -8) { v.append(UInt8((x >> UInt32(s)) & 0xFF)) } }
    static func putU64(_ v: inout [UInt8], _ x: UInt64) { for s in stride(from: 56, through: 0, by: -8) { v.append(UInt8((x >> UInt64(s)) & 0xFF)) } }
}
