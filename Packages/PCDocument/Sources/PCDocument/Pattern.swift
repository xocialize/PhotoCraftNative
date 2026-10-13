// Patterns: tiles used by Pattern Overlay, pattern fill layers, pattern strokes, Edit › Fill and
// brush textures. Pure data; rendering lives in the compositor, the PSD mapping (`Patt`/`Pat2`/
// `Pat3` global blocks) in the doc⇄PSD layer.
// Port of photocraft-doc (crates/doc/src/pattern.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

import PCFoundation

/// One pattern tile. Pixels cover `0..<width × 0..<height` of `surface`, in any pixel format (depth
/// and colour model are the pattern's own, as in Photoshop).
public struct Pattern: Equatable, Sendable {
    /// Largest pattern edge a file may declare (the PSD reader's limit; Define Pattern stops at 4000).
    public static let maxEdge: UInt32 = 30_000

    /// Most pixels a pattern may have to be painted. Renderers expand a pattern into a
    /// 16-byte-per-pixel working copy, so this keeps that copy at 1 GiB; larger patterns paint
    /// nothing.
    public static let maxPaintPixels: UInt64 = 1 << 26

    /// Unique id (a UUID string, as Photoshop's `Idnt`).
    public var id: String
    /// Name as stored (Photoshop's built-ins use `$$$/Patterns/…=Display Name`; see `displayName`).
    public var name: String
    public var width: UInt32
    public var height: UInt32
    public var surface: Surface

    /// A pattern with an explicit id (e.g. read from a file).
    public init(id: String, name: String, width: UInt32, height: UInt32, surface: Surface) {
        self.id = id; self.name = name; self.width = width; self.height = height; self.surface = surface
    }

    /// A pattern with an id derived from its name and pixels (same content → same id, so defining a
    /// pattern is deterministic and replayable). Ids match photocraft's for the same content.
    public init(name: String, surface: Surface, width: UInt32, height: UInt32) {
        let r = PixelRect(x0: 0, y0: 0, x1: Int32(truncatingIfNeeded: width), y1: Int32(truncatingIfNeeded: height))
        let px = surface.readRegion(r)
        var h1 = fnv1a(0xcbf2_9ce4_8422_2325, Array(name.utf8))
        h1 = fnv1a(h1, withUnsafeBytes(of: width.littleEndian, Array.init))
        h1 = fnv1a(h1, withUnsafeBytes(of: height.littleEndian, Array.init))
        for v in px { h1 = fnv1a(h1, withUnsafeBytes(of: v.bitPattern.littleEndian, Array.init)) }
        let h2 = fnv1a(h1 ^ 0x9e37_79b9_7f4a_7c15, Array(rustDebugString(surface.format).utf8))
        func hex(_ v: UInt64, _ width: Int) -> String {
            let s = String(v, radix: 16)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        let id = "\(hex(h1 >> 32 & 0xffff_ffff, 8))-\(hex(h1 >> 16 & 0xffff, 4))-\(hex(h1 & 0xffff, 4))-\(hex(h2 >> 48 & 0xffff, 4))-\(hex(h2 & 0xffff_ffff_ffff, 12))"
        self.init(id: id, name: name, width: width, height: height, surface: surface)
    }

    /// The name shown in UIs: Photoshop's localisation keys (`$$$/Patterns/…=Water`) show the text
    /// after `=`; trailing NULs are dropped.
    public var displayName: String { Pattern.displayName(name) }

    /// The tile's rectangle.
    public var rect: PixelRect {
        PixelRect(x0: 0, y0: 0, x1: Int32(clamping: Int(width)), y1: Int32(clamping: Int(height)))
    }

    /// Whether the tile has pixels.
    public var isEmpty: Bool { width == 0 || height == 0 }

    /// Pixels in the tile (`width × height`, never overflowing).
    public var pixelCount: UInt64 { UInt64(width) * UInt64(height) }

    /// Whether the tile has pixels and is small enough to paint (see `maxPaintPixels`).
    public var isPaintable: Bool { !isEmpty && pixelCount <= Pattern.maxPaintPixels }

    /// Display form of a stored pattern name (see `displayName`).
    public static func displayName(_ name: String) -> String {
        var n = Substring(name)
        while n.unicodeScalars.last == "\0" { n = n.dropLast() }
        if n.hasPrefix("$$$/"), let eq = n.firstIndex(of: "=") { return String(n[n.index(after: eq)...]) }
        return String(n)
    }

    /// Finds a pattern by id, else by stored name, else by display name (ASCII case-insensitive).
    public static func find(_ patterns: [Pattern], id: String, name: String) -> Pattern? {
        if !id.isEmpty, let p = patterns.first(where: { $0.id == id }) { return p }
        if name.isEmpty { return nil }
        if let p = patterns.first(where: { $0.name == name }) { return p }
        let wanted = asciiLowercased(displayName(name))
        return patterns.first { asciiLowercased($0.displayName) == wanted }
    }
}

/// 64-bit FNV-1a, used for deterministic pattern ids.
func fnv1a(_ h: UInt64, _ bytes: [UInt8]) -> UInt64 {
    bytes.reduce(h) { ($0 ^ UInt64($1)) &* 0x0100_0000_01b3 }
}

/// ASCII-only lowercasing (Rust's `eq_ignore_ascii_case`).
func asciiLowercased(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.map { $0.value >= 65 && $0.value <= 90 ? Unicode.Scalar($0.value + 32)! : $0 }))
}

/// photocraft's `{:?}` of a `PixelFormat` (part of the pattern-id hash).
func rustDebugString(_ f: PixelFormat) -> String {
    let mode: String = switch f.mode {
    case .bitmap: "Bitmap"
    case .grayscale: "Grayscale"
    case .indexed: "Indexed"
    case .rgb: "Rgb"
    case .cmyk: "Cmyk"
    case .lab: "Lab"
    case .multichannel: "Multichannel"
    case .duotone: "Duotone"
    }
    let sample: String = switch f.sample {
    case .u8: "U8"
    case .u16: "U16"
    case .f32: "F32"
    }
    return "PixelFormat { mode: \(mode), sample: \(sample), alpha: \(f.alpha) }"
}
