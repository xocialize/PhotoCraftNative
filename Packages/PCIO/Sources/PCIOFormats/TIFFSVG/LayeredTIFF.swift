// Port of photocraft-codecs (crates/codecs/src/codecs/tiff.rs: `photoshop_tags`,
// `writes_little_endian` and the encoder's tag set), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// The TIFF container of a layered TIFF. ImageIO decodes and encodes TIFF pixels but can neither read
// nor write private tags, so this file does both ends of what photocraft's codecs crate does for
// the Photoshop tags:
//
// * **Reading.** `photoshopTags` walks IFD0 with bounds checks (classic and BigTIFF, either byte
//   order) and returns the raw payloads of 34377 (image resources), 37724 (`ImageSourceData`, the
//   layers) and 700 (XMP) without touching anything else; anything malformed reads as "absent".
//   `read` pairs them with ImageIO's decode of the composite (`ImageIOCodec`).
// * **Writing.** `write` produces a baseline TIFF itself: one directory, chunky (interleaved)
//   strips of about 1 MB, Gray/RGB/CMYK at 8/16-bit unsigned or 32-bit IEEE float, optional
//   unassociated alpha (ExtraSamples = 2), uncompressed, Deflate (zlib, with the horizontal
//   predictor for integer samples, as photocraft) or PackBits; ICC (34675), resolution (282/283/
//   296), XMP (700), a few ASCII text tags, and the two Photoshop tags (34377 as BYTE, 37724 as
//   UNDEFINED, like photocraft). BigTIFF when asked or when the file could pass 4 GiB. Either byte
//   order; Intel order by default, like photocraft on every target it builds for, and the layer
//   data inside 37724 must be produced in the same order (`PSDTIFF.ImageSourceData.toBytes`).
//   LZW is not written.

import Foundation
import PCFoundation
import PCIOCore
import PCPSD

/// The TIFF container of a layered TIFF: Photoshop's private tags next to the composite.
public enum LayeredTIFF {
    /// TIFF tag of the XMP packet.
    public static let xmpTag: UInt16 = 700
    /// TIFF tag of the ICC profile.
    public static let iccTag: UInt16 = 34675

    /// `true`: `write` writes Intel-order (`II`) files unless told otherwise (photocraft
    /// `writes_little_endian`, true on every target it builds for). Byte-order-sensitive payloads
    /// (the layer data) must be produced to match.
    public static let writesLittleEndian = true

    // MARK: - Reading

    /// The private tags of a TIFF's first directory.
    public struct Tags: Equatable, Sendable {
        /// 34377: the Photoshop image resources.
        public var resources: [UInt8]?
        /// 37724: `ImageSourceData`, the layers of a layered TIFF.
        public var layers: [UInt8]?
        /// 700: the XMP packet.
        public var xmp: [UInt8]?
        /// The container's byte order (which the layer data follows).
        public var byteOrder: PSDTIFF.ByteOrder
        /// A BigTIFF (8-byte offsets).
        public var bigTIFF: Bool

        public init(resources: [UInt8]? = nil, layers: [UInt8]? = nil, xmp: [UInt8]? = nil, byteOrder: PSDTIFF.ByteOrder = .little, bigTIFF: Bool = false) {
            self.resources = resources; self.layers = layers; self.xmp = xmp; self.byteOrder = byteOrder; self.bigTIFF = bigTIFF
        }
    }

    /// The raw payloads of the private tags in the first directory (photocraft `photoshop_tags`,
    /// plus XMP and the container's byte order). Classic and BigTIFF, either byte order; only
    /// header bytes and the payloads are touched. `nil` when `tiff` has no TIFF header; a tag that
    /// is malformed (wrong type, out of bounds) reads as absent.
    public static func photoshopTags(_ tiff: [UInt8]) -> Tags? {
        guard tiff.count >= 8 else { return nil }
        let little: Bool
        switch (tiff[0], tiff[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return nil
        }
        let r = IFDReader(bytes: tiff, little: little)
        let big: Bool
        let ifd: UInt64
        switch r.u16(2) {
        case 42:
            guard let o = r.u32(4) else { return nil }
            (big, ifd) = (false, UInt64(o))
        case 43:
            guard let o = r.u64(8) else { return nil }
            (big, ifd) = (true, o)
        default:
            return nil
        }
        var tags = Tags(byteOrder: little ? .little : .big, bigTIFF: big)
        let count: UInt64? = big ? r.u64(ifd) : r.u16(ifd).map(UInt64.init)
        guard let n0 = count else { return tags }
        let n = min(n0, 4096)
        let (entry, inline): (UInt64, UInt64) = big ? (20, 8) : (12, 4)
        let (first, o1) = ifd.addingReportingOverflow(big ? 8 : 2)
        guard !o1 else { return tags }
        for i in 0 ..< n {
            let (e, o2) = first.addingReportingOverflow(i &* entry)
            guard !o2, let tag = r.u16(e) else { break }
            guard tag == PSDTIFF.resourcesTag || tag == PSDTIFF.imageSourceDataTag || tag == xmpTag else { continue }
            // BYTE, ASCII, SBYTE or UNDEFINED: one byte per element.
            guard let type = r.u16(e &+ 2), [1, 2, 6, 7].contains(type) else { continue }
            guard let cnt = big ? r.u64(e &+ 4) : r.u32(e &+ 4).map(UInt64.init) else { continue }
            let valueAt = e &+ (big ? 12 : 8)
            let start: UInt64?
            if cnt <= inline {
                start = valueAt
            } else {
                start = big ? r.u64(valueAt) : r.u32(valueAt).map(UInt64.init)
            }
            guard let s = start, let data = r.slice(s, cnt) else { continue }
            switch tag {
            case PSDTIFF.resourcesTag: tags.resources = data
            case PSDTIFF.imageSourceDataTag: tags.layers = data
            default: tags.xmp = data
            }
        }
        return tags
    }

    /// A decoded layered TIFF: ImageIO's composite plus the private tags.
    public struct Contents: Sendable {
        /// The composite of the first directory (ImageIO).
        public var image: DecodedImage
        public var tags: Tags
    }

    /// Decodes the composite with ImageIO and reads the private tags of the first directory.
    public static func read(_ tiff: [UInt8], codec: any FlatImageCodec = ImageIOCodec()) throws -> Contents {
        guard let tags = photoshopTags(tiff) else { throw PCIOError.format("TIFF", "not a TIFF file") }
        return Contents(image: try codec.decode(tiff), tags: tags)
    }

    /// Bounds-checked reads at absolute offsets.
    private struct IFDReader {
        let bytes: [UInt8]
        let little: Bool

        func range(_ o: UInt64, _ n: Int) -> Range<Int>? {
            guard o <= UInt64(Int.max) else { return nil }
            let s = Int(o)
            let (e, ov) = s.addingReportingOverflow(n)
            guard !ov, e <= bytes.count else { return nil }
            return s ..< e
        }

        func value(_ o: UInt64, _ n: Int) -> UInt64? {
            guard let r = range(o, n) else { return nil }
            var v: UInt64 = 0
            if little {
                for i in r.reversed() { v = v << 8 | UInt64(bytes[i]) }
            } else {
                for i in r { v = v << 8 | UInt64(bytes[i]) }
            }
            return v
        }

        func u16(_ o: UInt64) -> UInt16? { value(o, 2).map { UInt16($0) } }
        func u32(_ o: UInt64) -> UInt32? { value(o, 4).map { UInt32($0) } }
        func u64(_ o: UInt64) -> UInt64? { value(o, 8) }

        func slice(_ o: UInt64, _ n: UInt64) -> [UInt8]? {
            guard n <= UInt64(Int.max), let r = range(o, Int(n)) else { return nil }
            return Array(bytes[r])
        }
    }

    // MARK: - Writing

    /// An image to write: interleaved samples, alpha last.
    public struct Image: Sendable {
        public var width: Int
        public var height: Int
        /// `.grayscale`, `.rgb` or `.cmyk`.
        public var mode: ColorMode
        /// An unassociated (straight) alpha sample follows the colour samples.
        public var alpha: Bool
        /// `.u8`, `.u16` or `.f32`.
        public var sample: SampleType
        /// Interleaved samples in native byte order, row-major, `width × height × channels`.
        /// CMYK is ink (0 = no ink), as TIFF stores it.
        public var samples: [UInt8]
        public var iccProfile: [UInt8]?
        /// The XMP packet (tag 700).
        public var xmp: [UInt8]?
        /// Resolution in pixels per inch (tags 282/283, unit 296 = inch).
        public var dpi: (x: Double, y: Double)?
        /// ASCII tags: 270 ImageDescription, 271 Make, 272 Model, 305 Software, 306 DateTime,
        /// 315 Artist, 33432 Copyright (others are ignored). Non-ASCII values and values holding NUL
        /// are skipped, as photocraft does.
        public var text: [(tag: UInt16, value: String)]
        /// Tag 34377.
        public var photoshopResources: [UInt8]?
        /// Tag 37724 (in the byte order the file is written in).
        public var photoshopLayers: [UInt8]?

        public init(width: Int, height: Int, mode: ColorMode, alpha: Bool, sample: SampleType, samples: [UInt8],
                    iccProfile: [UInt8]? = nil, xmp: [UInt8]? = nil, dpi: (x: Double, y: Double)? = nil, text: [(tag: UInt16, value: String)] = [],
                    photoshopResources: [UInt8]? = nil, photoshopLayers: [UInt8]? = nil) {
            self.width = width; self.height = height; self.mode = mode; self.alpha = alpha; self.sample = sample; self.samples = samples
            self.iccProfile = iccProfile; self.xmp = xmp; self.dpi = dpi; self.text = text
            self.photoshopResources = photoshopResources; self.photoshopLayers = photoshopLayers
        }

        /// Colour samples per pixel.
        public var colorChannels: Int { mode == .cmyk ? 4 : mode == .grayscale ? 1 : 3 }
        /// Samples per pixel.
        public var channels: Int { colorChannels + (alpha ? 1 : 0) }
    }

    /// Strip compression.
    public enum Compression: Sendable, Hashable, CaseIterable {
        case none
        /// Adobe Deflate (zlib), with the horizontal predictor on integer samples.
        case deflate
        case packBits
    }

    public struct WriteOptions: Sendable {
        public var compression: Compression
        public var byteOrder: PSDTIFF.ByteOrder
        /// Always write BigTIFF (otherwise only when the file could pass 4 GiB).
        public var bigTIFF: Bool

        public init(compression: Compression = .deflate, byteOrder: PSDTIFF.ByteOrder = .little, bigTIFF: Bool = false) {
            self.compression = compression; self.byteOrder = byteOrder; self.bigTIFF = bigTIFF
        }
    }

    /// The ASCII tags `Image.text` may carry.
    public static let textTags: Set<UInt16> = [270, 271, 272, 305, 306, 315, 33432]

    /// Classic TIFF offsets are 32-bit: a file that may grow past this is written as BigTIFF.
    static let classicLimit = UInt64(UInt32.max)

    /// Writes `image` as a single-directory baseline TIFF.
    public static func write(_ image: Image, options: WriteOptions = WriteOptions()) throws -> [UInt8] {
        guard [.grayscale, .rgb, .cmyk].contains(image.mode) else {
            throw PCIOError.format("TIFF", "\(image.mode) images cannot be written as TIFF")
        }
        guard image.width > 0, image.height > 0, image.width <= Int(UInt32.max), image.height <= Int(UInt32.max) else {
            throw PCIOError.format("TIFF", "cannot write a \(image.width) × \(image.height) image")
        }
        let bps = image.sample.bytes
        let rowBytes = image.width.multipliedReportingOverflow(by: image.channels * bps)
        let total = rowBytes.partialValue.multipliedReportingOverflow(by: image.height)
        guard !rowBytes.overflow, !total.overflow, image.samples.count == total.partialValue else {
            throw PCIOError.format("TIFF", "\(image.samples.count) sample bytes for a \(image.width) × \(image.height) × \(image.channels) image")
        }
        let strips = try encodeStrips(image, rowBytes: rowBytes.partialValue, options: options)
        let big = options.bigTIFF || estimatedSize(image, strips.data) > classicLimit
        do {
            return try assemble(image, strips, big: big, little: options.byteOrder == .little)
        } catch OffsetOverflow.classic where !big {
            return try assemble(image, strips, big: true, little: options.byteOrder == .little)
        }
    }

    /// The strips: encoded bytes, each strip's byte count, rows per strip.
    struct Strips {
        var data: [[UInt8]]
        var rowsPerStrip: Int
        var compression: UInt16
        var predictor: Bool
    }

    static func encodeStrips(_ image: Image, rowBytes: Int, options: WriteOptions) throws -> Strips {
        let rowsPerStrip = max(1, min(image.height, (1 << 20) / max(1, rowBytes)))
        let bps = image.sample.bytes
        let littleOut = options.byteOrder == .little
        let predictor = options.compression == .deflate && image.sample != .f32
        let ch = image.channels
        var strips: [[UInt8]] = []
        var y = 0
        while y < image.height {
            let rows = min(rowsPerStrip, image.height - y)
            var raw = Array(image.samples[y * rowBytes ..< (y + rows) * rowBytes])
            // Native (little) → file order.
            if !littleOut, bps > 1 {
                raw.withUnsafeMutableBufferPointer { p in
                    var i = 0
                    while i + bps <= p.count {
                        var a = i, b = i + bps - 1
                        while a < b { p.swapAt(a, b); a += 1; b -= 1 }
                        i += bps
                    }
                }
            }
            if predictor { horizontalPredict(&raw, rows: rows, rowBytes: rowBytes, channels: ch, bps: bps, little: littleOut) }
            switch options.compression {
            case .none: strips.append(raw)
            case .deflate: strips.append(try Deflate.zlibDeflate(raw))
            case .packBits:
                var out: [UInt8] = []
                out.reserveCapacity(raw.count + raw.count / 128 + rows)
                raw.withUnsafeBytes { p in
                    for r in 0 ..< rows { PackBits.encode(UnsafeRawBufferPointer(rebasing: p[r * rowBytes ..< (r + 1) * rowBytes]), into: &out) }
                }
                strips.append(out)
            }
            y += rows
        }
        let code: UInt16 = switch options.compression {
        case .none: 1
        case .deflate: 8
        case .packBits: 32773
        }
        return Strips(data: strips, rowsPerStrip: rowsPerStrip, compression: code, predictor: predictor)
    }

    /// TIFF Predictor 2: each sample minus the same sample of the pixel before it, per row
    /// (wrapping, in sample units, in the file's byte order).
    static func horizontalPredict(_ buf: inout [UInt8], rows: Int, rowBytes: Int, channels: Int, bps: Int, little: Bool) {
        let stride = channels * bps
        buf.withUnsafeMutableBufferPointer { p in
            for r in 0 ..< rows {
                let row = r * rowBytes
                var x = rowBytes - stride
                while x >= stride {
                    for c in 0 ..< channels {
                        let at = row + x + c * bps, prev = at - stride
                        if bps == 1 {
                            p[at] = p[at] &- p[prev]
                        } else {
                            func get(_ i: Int) -> UInt16 { little ? UInt16(p[i]) | UInt16(p[i + 1]) << 8 : UInt16(p[i]) << 8 | UInt16(p[i + 1]) }
                            let v = get(at) &- get(prev)
                            if little { p[at] = UInt8(v & 0xFF); p[at + 1] = UInt8(v >> 8) } else { p[at] = UInt8(v >> 8); p[at + 1] = UInt8(v & 0xFF) }
                        }
                    }
                    x -= stride
                }
            }
        }
    }

    /// An upper estimate of the file size: the encoded strips plus every tag payload plus room for
    /// the directory and strip tables.
    static func estimatedSize(_ image: Image, _ strips: [[UInt8]]) -> UInt64 {
        let data = strips.reduce(UInt64(0)) { $0 &+ UInt64($1.count) }
        let payloads = [image.iccProfile, image.xmp, image.photoshopResources, image.photoshopLayers].compactMap { $0 }.reduce(UInt64(0)) { $0 &+ UInt64($1.count) }
        let text = image.text.reduce(UInt64(0)) { $0 &+ UInt64($1.value.utf8.count) }
        let tables = UInt64(strips.count) * 16
        return data &+ payloads &+ text &+ tables &+ (1 << 20)
    }

    enum OffsetOverflow: Error { case classic }

    /// One directory entry: tag, type, count and the value bytes (in the file's order).
    struct Entry {
        var tag: UInt16
        var type: UInt16
        var count: UInt64
        var value: [UInt8]
    }

    static func assemble(_ image: Image, _ strips: Strips, big: Bool, little: Bool) throws -> [UInt8] {
        func le(_ v: UInt64, _ n: Int) -> [UInt8] {
            let b = (0 ..< n).map { UInt8(v >> (8 * UInt64($0)) & 0xFF) }
            return little ? b : b.reversed()
        }
        func shorts(_ vs: [UInt16]) -> [UInt8] { vs.flatMap { le(UInt64($0), 2) } }
        func longs(_ vs: [UInt32]) -> [UInt8] { vs.flatMap { le(UInt64($0), 4) } }

        let align = big ? 8 : 2
        var out: [UInt8] = little ? [0x49, 0x49] : [0x4D, 0x4D]
        out += le(big ? 43 : 42, 2)
        if big { out += le(8, 2) + le(0, 2) }
        let ifdPointerAt = out.count
        out += [UInt8](repeating: 0, count: big ? 8 : 4)
        func pad() { while out.count % align != 0 { out.append(0) } }

        // Pixel strips.
        var offsets: [UInt64] = []
        var counts: [UInt64] = []
        for s in strips.data {
            pad()
            offsets.append(UInt64(out.count))
            counts.append(UInt64(s.count))
            out += s
        }
        func checkOffset(_ v: UInt64) throws { if !big, v > classicLimit { throw OffsetOverflow.classic } }
        for o in offsets { try checkOffset(o) }
        for c in counts { try checkOffset(c) }

        let ch = image.channels
        let bits = UInt16(image.sample.bits)
        var entries: [Entry] = []
        func add(_ tag: UInt16, _ type: UInt16, _ count: Int, _ value: [UInt8]) { entries.append(Entry(tag: tag, type: type, count: UInt64(count), value: value)) }
        let longType: UInt16 = big ? 16 : 4
        func offsetValues(_ vs: [UInt64]) -> [UInt8] { big ? vs.flatMap { le($0, 8) } : longs(vs.map { UInt32(truncatingIfNeeded: $0) }) }
        add(256, 4, 1, longs([UInt32(image.width)]))
        add(257, 4, 1, longs([UInt32(image.height)]))
        add(258, 3, ch, shorts([UInt16](repeating: bits, count: ch)))
        add(259, 3, 1, shorts([strips.compression]))
        add(262, 3, 1, shorts([image.mode == .cmyk ? 5 : image.mode == .grayscale ? 1 : 2]))
        for (tag, value) in image.text where textTags.contains(tag) {
            guard value.unicodeScalars.allSatisfy({ $0.isASCII }), !value.contains("\0") else { continue }
            let b = Array(value.utf8) + [0]
            add(tag, 2, b.count, b)
        }
        add(273, longType, offsets.count, offsetValues(offsets))
        add(277, 3, 1, shorts([UInt16(ch)]))
        add(278, 4, 1, longs([UInt32(strips.rowsPerStrip)]))
        add(279, longType, counts.count, offsetValues(counts))
        if let dpi = image.dpi, dpi.x > 0, dpi.y > 0, dpi.x.isFinite, dpi.y.isFinite {
            let rx: UInt32 = satCast((dpi.x * 1000).rounded()), ry: UInt32 = satCast((dpi.y * 1000).rounded())
            add(282, 5, 1, longs([rx, 1000]))
            add(283, 5, 1, longs([ry, 1000]))
            add(296, 3, 1, shorts([2]))
        }
        add(284, 3, 1, shorts([1]))
        if strips.predictor { add(317, 3, 1, shorts([2])) }
        if image.mode == .cmyk { add(332, 3, 1, shorts([1])) }
        if image.alpha { add(338, 3, 1, shorts([2])) }
        add(339, 3, ch, shorts([UInt16](repeating: image.sample == .f32 ? 3 : 1, count: ch)))
        if let x = image.xmp, !x.isEmpty { add(xmpTag, 1, x.count, x) }
        if let r = image.photoshopResources, !r.isEmpty { add(PSDTIFF.resourcesTag, 1, r.count, r) }
        if let icc = image.iccProfile, !icc.isEmpty { add(iccTag, 7, icc.count, icc) }
        if let l = image.photoshopLayers, !l.isEmpty { add(PSDTIFF.imageSourceDataTag, 7, l.count, l) }
        entries.sort { $0.tag < $1.tag }

        // Out-of-line values, then the directory.
        let inline = big ? 8 : 4
        var valueOffsets: [UInt64?] = []
        for e in entries {
            if e.value.count <= inline {
                valueOffsets.append(nil)
            } else {
                pad()
                let at = UInt64(out.count)
                try checkOffset(at)
                valueOffsets.append(at)
                out += e.value
            }
        }
        pad()
        let ifdAt = UInt64(out.count)
        try checkOffset(ifdAt)
        out.replaceSubrange(ifdPointerAt ..< ifdPointerAt + (big ? 8 : 4), with: le(ifdAt, big ? 8 : 4))
        out += le(UInt64(entries.count), big ? 8 : 2)
        for (e, vo) in zip(entries, valueOffsets) {
            out += le(UInt64(e.tag), 2)
            out += le(UInt64(e.type), 2)
            out += le(e.count, big ? 8 : 4)
            if let vo {
                out += le(vo, inline)
            } else {
                out += e.value + [UInt8](repeating: 0, count: inline - e.value.count)
            }
        }
        out += [UInt8](repeating: 0, count: big ? 8 : 4)
        try checkOffset(UInt64(out.count))
        return out
    }
}
