// Readers for the composites Photoshop exports: uncompressed baseline TIFF (either byte order,
// chunky or planar, 1/8/16/32 bits, palette, CMYK, CIELab, extra samples) and headerless Photoshop
// Raw. Values stay as stored (integers 0…2^bits−1, floats as written) so comparisons can be exact.

import Foundation

public struct ReferenceImage: Sendable {
    public enum Source: String, Sendable { case tiff, raw }

    public var source: Source
    public var width: Int
    public var height: Int
    /// Bits per sample: 1, 8, 16 or 32.
    public var bits: Int
    public var isFloat: Bool
    /// TIFF PhotometricInterpretation (0 WhiteIsZero, 1 BlackIsZero, 2 RGB, 3 palette, 5 separated,
    /// 8 CIELab); −1 for Photoshop Raw.
    public var photometric: Int
    public var samplesPerPixel: Int
    /// ExtraSamples values (0 unspecified, 1 associated alpha, 2 unassociated alpha).
    public var extraSamples: [Int]
    /// One plane per sample, row-major. 1-bit data holds the bit (0/1) per pixel.
    public var planes: [[Double]]
    public var colorMap: [UInt16]?
    public var iccProfile: Data?

    public var colorSamples: Int { samplesPerPixel - extraSamples.count }
    public var maxValue: Double { isFloat ? 1 : Double((1 << bits) - 1) }
}

public enum ReferenceImageError: Error, CustomStringConvertible {
    case notTIFF, unsupported(String), truncated(String)

    public var description: String {
        switch self {
        case .notTIFF: "not a classic TIFF file"
        case let .unsupported(s): "unsupported TIFF: \(s)"
        case let .truncated(s): "truncated image data: \(s)"
        }
    }
}

public enum ReferenceImageReader {
    public static func read(contentsOf url: URL) throws -> ReferenceImage {
        try readTIFF(try Data(contentsOf: url, options: .alwaysMapped))
    }

    public static func readTIFF(_ data: Data) throws -> ReferenceImage {
        let b = [UInt8](data)
        guard b.count >= 8 else { throw ReferenceImageError.notTIFF }
        let big: Bool
        switch (b[0], b[1]) {
        case (0x4D, 0x4D): big = true
        case (0x49, 0x49): big = false
        default: throw ReferenceImageError.notTIFF
        }
        func u16(_ o: Int) throws -> Int {
            guard o + 2 <= b.count else { throw ReferenceImageError.truncated("u16 at \(o)") }
            return big ? Int(b[o]) << 8 | Int(b[o + 1]) : Int(b[o + 1]) << 8 | Int(b[o])
        }
        func u32(_ o: Int) throws -> Int {
            guard o + 4 <= b.count else { throw ReferenceImageError.truncated("u32 at \(o)") }
            return big ? Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
                : Int(b[o + 3]) << 24 | Int(b[o + 2]) << 16 | Int(b[o + 1]) << 8 | Int(b[o])
        }
        guard try u16(2) == 42 else { throw ReferenceImageError.unsupported("magic \(try u16(2)) (BigTIFF?)") }
        let ifd = try u32(4)
        let n = try u16(ifd)
        var tags: [Int: [Int]] = [:]
        var icc: Data?
        for i in 0 ..< n {
            let e = ifd + 2 + 12 * i
            let tag = try u16(e), type = try u16(e + 2), count = try u32(e + 4)
            let size: Int
            switch type {
            case 1, 2, 6, 7: size = 1
            case 3, 8: size = 2
            case 4, 9, 11: size = 4
            case 5, 10, 12: size = 8
            default: size = 1
            }
            let total = size * count
            let off = total <= 4 ? e + 8 : try u32(e + 8)
            guard off + total <= b.count else { throw ReferenceImageError.truncated("tag \(tag)") }
            if tag == 34675 {
                icc = Data(b[off ..< off + total])
                continue
            }
            switch type {
            case 3, 8: tags[tag] = try (0 ..< count).map { try u16(off + 2 * $0) }
            case 4, 9: tags[tag] = try (0 ..< count).map { try u32(off + 4 * $0) }
            case 1, 6, 7: if count <= 64 { tags[tag] = (0 ..< count).map { Int(b[off + $0]) } }
            default: break
            }
        }
        func one(_ t: Int, _ d: Int? = nil) throws -> Int {
            if let v = tags[t]?.first { return v }
            if let d { return d }
            throw ReferenceImageError.unsupported("missing tag \(t)")
        }
        let width = try one(256), height = try one(257)
        let compression = try one(259, 1)
        guard compression == 1 else { throw ReferenceImageError.unsupported("compression \(compression)") }
        let spp = try one(277, 1)
        let bps = tags[258] ?? [1]
        let bits = bps.first ?? 1
        guard bps.allSatisfy({ $0 == bits }), [1, 8, 16, 32].contains(bits) else { throw ReferenceImageError.unsupported("bits per sample \(bps)") }
        let photometric = try one(262)
        let planar = try one(284, 1)
        let sampleFormat = tags[339]?.first ?? 1
        let isFloat = sampleFormat == 3
        guard !(bits == 32 && !isFloat) else { throw ReferenceImageError.unsupported("32-bit integer samples") }
        let offsets = tags[273] ?? []
        let counts = tags[279] ?? []
        guard !offsets.isEmpty, offsets.count == counts.count else { throw ReferenceImageError.unsupported("strip tables") }
        // Concatenate the strips in order (rows per strip does not matter for uncompressed data).
        var stream = [UInt8]()
        stream.reserveCapacity(counts.reduce(0, +))
        for (o, c) in zip(offsets, counts) {
            guard o + c <= b.count else { throw ReferenceImageError.truncated("strip at \(o)") }
            stream.append(contentsOf: b[o ..< o + c])
        }
        let bytesPer = bits / 8
        var planes = [[Double]](repeating: [Double](repeating: 0, count: width * height), count: spp)
        func sample(_ o: Int) -> Double {
            switch bits {
            case 8: return Double(stream[o])
            case 16: return Double(big ? Int(stream[o]) << 8 | Int(stream[o + 1]) : Int(stream[o + 1]) << 8 | Int(stream[o]))
            default:
                let u = big ? UInt32(stream[o]) << 24 | UInt32(stream[o + 1]) << 16 | UInt32(stream[o + 2]) << 8 | UInt32(stream[o + 3])
                    : UInt32(stream[o + 3]) << 24 | UInt32(stream[o + 2]) << 16 | UInt32(stream[o + 1]) << 8 | UInt32(stream[o])
                return Double(Float(bitPattern: u))
            }
        }
        if bits == 1 {
            guard spp == 1 else { throw ReferenceImageError.unsupported("1-bit with \(spp) samples") }
            let rb = (width + 7) / 8
            guard stream.count >= rb * height else { throw ReferenceImageError.truncated("1-bit data") }
            for y in 0 ..< height {
                for x in 0 ..< width { planes[0][y * width + x] = Double((stream[y * rb + x / 8] >> (7 - UInt8(x % 8))) & 1) }
            }
        } else if planar == 1 {
            let need = width * height * spp * bytesPer
            guard stream.count >= need else { throw ReferenceImageError.truncated("\(stream.count) of \(need) bytes") }
            for i in 0 ..< width * height {
                for s in 0 ..< spp { planes[s][i] = sample((i * spp + s) * bytesPer) }
            }
        } else {
            let plane = width * height * bytesPer
            guard stream.count >= plane * spp else { throw ReferenceImageError.truncated("planar data") }
            for s in 0 ..< spp {
                for i in 0 ..< width * height { planes[s][i] = sample(s * plane + i * bytesPer) }
            }
        }
        return ReferenceImage(source: .tiff, width: width, height: height, bits: bits, isFloat: isFloat, photometric: photometric,
                              samplesPerPixel: spp, extraSamples: tags[338] ?? [], planes: planes,
                              colorMap: tags[320].map { $0.map { UInt16(truncatingIfNeeded: $0) } }, iccProfile: icc)
    }

    /// Photoshop Raw: interleaved, no header, big-endian samples.
    public static func readRaw(contentsOf url: URL, width: Int, height: Int, channels: Int, bits: Int) throws -> ReferenceImage {
        let b = [UInt8](try Data(contentsOf: url))
        let bytesPer = max(1, bits / 8)
        let need = width * height * channels * bytesPer
        guard b.count >= need else { throw ReferenceImageError.truncated("raw: \(b.count) of \(need) bytes") }
        var planes = [[Double]](repeating: [Double](repeating: 0, count: width * height), count: channels)
        for i in 0 ..< width * height {
            for c in 0 ..< channels {
                let o = (i * channels + c) * bytesPer
                switch bits {
                case 8: planes[c][i] = Double(b[o])
                case 16: planes[c][i] = Double(Int(b[o]) << 8 | Int(b[o + 1]))
                default: planes[c][i] = Double(Float(bitPattern: UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])))
                }
            }
        }
        return ReferenceImage(source: .raw, width: width, height: height, bits: bits, isFloat: bits == 32, photometric: -1,
                              samplesPerPixel: channels, extraSamples: [], planes: planes, colorMap: nil, iccProfile: nil)
    }
}
