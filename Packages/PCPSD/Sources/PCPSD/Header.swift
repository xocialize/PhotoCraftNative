// File header: signature, version, channels, dimensions, depth and colour mode.
// Port of photocraft-psd (crates/psd/src/header.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors. Header validation cross-checked against PhotoDemon pdPSD.cls
// (Step1_ValidateHeader), BSD-2-Clause, © Tanner Helland and contributors.

/// File format version.
public enum PSDVersion: UInt16, Sendable, Hashable, CaseIterable {
    /// Version 1: Photoshop Document (32-bit section lengths, ≤ 30 000 px).
    case psd = 1
    /// Version 2: Large Document Format (64-bit lengths for some sections, ≤ 300 000 px).
    case psb = 2

    public var isPSB: Bool { self == .psb }
}

/// Document colour mode (header field `Mode`).
public enum PSDColorMode: Hashable, Sendable, CustomStringConvertible {
    case bitmap, grayscale, indexed, rgb, cmyk, multichannel, duotone, lab
    /// Any other stored value, preserved.
    case unknown(UInt16)

    public static let known: [PSDColorMode] = [.bitmap, .grayscale, .indexed, .rgb, .cmyk, .multichannel, .duotone, .lab]

    public init(code: UInt16) {
        switch code {
        case 0: self = .bitmap
        case 1: self = .grayscale
        case 2: self = .indexed
        case 3: self = .rgb
        case 4: self = .cmyk
        case 7: self = .multichannel
        case 8: self = .duotone
        case 9: self = .lab
        default: self = .unknown(code)
        }
    }

    public var code: UInt16 {
        switch self {
        case .bitmap: 0
        case .grayscale: 1
        case .indexed: 2
        case .rgb: 3
        case .cmyk: 4
        case .multichannel: 7
        case .duotone: 8
        case .lab: 9
        case let .unknown(v): v
        }
    }

    /// Number of colour (non-alpha) channels for the mode, when fixed.
    public var colorChannels: Int? {
        switch self {
        case .bitmap, .grayscale, .indexed, .duotone: 1
        case .rgb, .lab: 3
        case .cmyk: 4
        case .multichannel, .unknown: nil
        }
    }

    public var description: String {
        switch self {
        case .bitmap: "Bitmap"
        case .grayscale: "Grayscale"
        case .indexed: "Indexed"
        case .rgb: "RGB"
        case .cmyk: "CMYK"
        case .multichannel: "Multichannel"
        case .duotone: "Duotone"
        case .lab: "Lab"
        case let .unknown(v): "Unknown(\(v))"
        }
    }
}

/// The 26-byte file header.
public struct PSDHeader: Hashable, Sendable {
    /// Maximum width/height accepted by the parser (the PSB limit).
    public static let maxDimension: UInt32 = 300_000
    /// The PSD (version 1) limit, enforced by `PSDFile.validate()` and the writer.
    public static let maxPSDDimension: UInt32 = 30_000
    /// Channel count limit (spec: 1...56).
    public static let maxChannels: UInt16 = 56

    public var version: PSDVersion
    /// Reserved bytes (spec: zero), kept for exact round trips.
    public var reserved: [UInt8]
    /// Channels of the merged image, including alpha channels (1...56).
    public var channels: UInt16
    public var height: UInt32
    public var width: UInt32
    /// Bits per channel: 1, 8, 16 or 32.
    public var depth: UInt16
    public var colorMode: PSDColorMode

    public init(version: PSDVersion, width: UInt32, height: UInt32, channels: UInt16, depth: UInt16, colorMode: PSDColorMode) {
        self.version = version
        reserved = [0, 0, 0, 0, 0, 0]
        self.channels = channels
        self.height = height
        self.width = width
        self.depth = depth
        self.colorMode = colorMode
    }

    /// Bytes per row of one channel plane.
    public var rowBytes: Int { PSDHeader.rowBytes(width: Int(width), depth: depth) }

    /// Bytes per row for `width` samples at `depth` bits (1-bit rows are padded to whole bytes).
    public static func rowBytes(width: Int, depth: UInt16) -> Int {
        depth == 1 ? (width + 7) / 8 : width.multipliedReportingOverflow(by: max(1, Int(depth / 8))).partialValue
    }

    static func read(_ r: inout ByteReader) throws -> PSDHeader {
        let sig = try r.fourCC()
        guard sig == "8BPS" else { throw PSDError.invalidSignature(expected: "8BPS", found: sig) }
        let v = try r.u16()
        guard let version = PSDVersion(rawValue: v) else { throw PSDError.unsupportedVersion(v) }
        var h = PSDHeader(version: version, width: 0, height: 0, channels: 0, depth: 0, colorMode: .rgb)
        h.reserved = try r.bytes(6)
        h.channels = try r.u16()
        h.height = try r.u32()
        h.width = try r.u32()
        h.depth = try r.u16()
        h.colorMode = PSDColorMode(code: try r.u16())
        try h.validate()
        return h
    }

    /// Checks spec constraints and safety limits (dimensions up to the PSB limit for both versions,
    /// as photocraft does; `PSDFile.validate()` enforces the 30 000 PSD limit before writing).
    public func validate() throws {
        guard channels >= 1, channels <= PSDHeader.maxChannels else {
            throw PSDError.invalid("channel count \(channels) out of range 1...56")
        }
        guard width >= 1, height >= 1 else {
            throw PSDError.invalid("image dimensions \(width)x\(height) must be at least 1x1")
        }
        guard width <= PSDHeader.maxDimension, height <= PSDHeader.maxDimension else {
            throw PSDError.limitExceeded("image dimensions exceed 300000")
        }
        guard [1, 8, 16, 32].contains(depth) else { throw PSDError.invalid("unsupported bit depth \(depth)") }
    }

    func write<S: ByteSink>(to s: inout S) throws {
        try s.fourCC("8BPS")
        try s.u16(version.rawValue)
        var res = reserved
        if res.count != 6 { res = Array((res + [0, 0, 0, 0, 0, 0]).prefix(6)) }
        try s.write(res)
        try s.u16(channels)
        try s.u32(height)
        try s.u32(width)
        try s.u16(depth)
        try s.u16(colorMode.code)
    }
}
