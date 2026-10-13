// Sample helpers, every colour mode decoded to normalised planes, and RGBA8 previews of layers and
// of the merged image.
// Port of photocraft-psd (crates/psd/src/pixels.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors. Colour-mode breadth cross-checked against PhotoDemon pdPSDLayer.cls
// (ConstructImage_RGB/CMYK/Lab/SingleChannel/Multichannel, ExpandMonochrome), BSD-2-Clause,
// © Tanner Helland and contributors: bitmap bits set = black; indexed palettes are planar
// (256 R, 256 G, 256 B) with resource 1047 naming a transparent index; duotone reads as gray;
// CMYK is stored inverted (255 = no ink); Lab is L 0...255 → 0...100, a/b offset by 128; extra
// channels beyond the mode's colour channels are alpha/spot channels.

import Foundation

/// Conversions between planar big-endian bytes and samples.
public enum PSDSamples {
    public static func u16(_ bytes: [UInt8]) -> [UInt16] {
        stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
    }

    public static func f32(_ bytes: [UInt8]) -> [Float] {
        bytes.withUnsafeBytes { raw in
            (0 ..< raw.count / 4).map { Float(bitPattern: UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
    }

    public static func bytes(u16 samples: [UInt16]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(samples.count * 2)
        for s in samples { out.append(UInt8(s >> 8)); out.append(UInt8(s & 0xFF)) }
        return out
    }

    public static func bytes(f32 samples: [Float]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(samples.count * 4)
        for s in samples {
            let b = s.bitPattern
            out.append(UInt8(b >> 24)); out.append(UInt8(b >> 16 & 0xFF)); out.append(UInt8(b >> 8 & 0xFF)); out.append(UInt8(b & 0xFF))
        }
        return out
    }

    /// Expands a 1-bit plane (MSB first, rows padded to bytes) to one value per pixel via `map`.
    public static func unpackBits(_ bytes: [UInt8], width: Int, height: Int, map: (UInt8) -> UInt8 = { $0 }) throws -> [UInt8] {
        let (n, o) = width.multipliedReportingOverflow(by: height)
        guard !o, UInt64(n) <= PSDLimits.maxDecodedBytes else { throw PSDError.limitExceeded("plane size overflow") }
        let rb = (width + 7) / 8
        var out = [UInt8](repeating: 0, count: n)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let i = y * rb + x / 8
                let b = i < bytes.count ? bytes[i] : 0
                out[y * width + x] = map((b >> (7 - UInt8(x % 8))) & 1)
            }
        }
        return out
    }

    /// One plane at `depth` converted to 8-bit (1-bit: set = black → 0; 16-bit rounded; 32-bit
    /// clamped to 0...1, no tone mapping).
    public static func planeToU8(_ bytes: [UInt8], depth: UInt16, width: Int, height: Int) throws -> [UInt8] {
        switch depth {
        case 1: return try unpackBits(bytes, width: width, height: height) { $0 == 1 ? 0 : 255 }
        case 8: return bytes
        case 16:
            return stride(from: 0, to: bytes.count - 1, by: 2).map {
                UInt8((UInt32(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])) * 255 + 32767) / 65535)
            }
        case 32:
            return f32(bytes).map { $0.isNaN ? 0 : UInt8((min(max($0, 0), 1) * 255).rounded()) }
        default:
            throw PSDError.unsupported("depth \(depth)")
        }
    }

    /// One plane at `depth` as floats: 1/8/16-bit scaled to 0...1 (1-bit: set = 0), 32-bit as stored.
    public static func planeToFloat(_ bytes: [UInt8], depth: UInt16, width: Int, height: Int) throws -> [Float] {
        switch depth {
        case 1: return try unpackBits(bytes, width: width, height: height) { $0 == 1 ? 0 : 1 }.map(Float.init)
        case 8: return bytes.map { Float($0) / 255 }
        case 16: return u16(bytes).map { Float($0) / 65535 }
        case 32: return f32(bytes)
        default: throw PSDError.unsupported("depth \(depth)")
        }
    }
}

/// An 8-bit RGBA image (straight alpha) positioned in document coordinates.
public struct PSDRGBA8Image: Equatable, Sendable {
    public var left: Int32
    public var top: Int32
    public var width: Int
    public var height: Int
    /// Interleaved RGBA, row-major.
    public var data: [UInt8]
}

/// An 8-bit single-channel image (a layer mask).
public struct PSDGrayImage: Equatable, Sendable {
    public var left: Int32
    public var top: Int32
    public var width: Int
    public var height: Int
    public var data: [UInt8]
    /// Value outside the rectangle.
    public var defaultValue: UInt8
}

/// What the normalised colour planes mean.
public enum PSDPlaneSpace: Hashable, Sendable {
    /// One plane, 0 black ... 1 white (Gray, Bitmap, Duotone).
    case gray
    /// Red, green, blue (RGB, and Indexed through its palette).
    case rgb
    /// Cyan, magenta, yellow, black ink amounts, 0 = no ink (stored inverted in the file).
    case cmyk
    /// L 0...1 (×100), a and b 0...1 (×255 − 128).
    case lab
    /// Every channel as stored (Multichannel inks / unknown modes).
    case channels(Int)
}

/// Pixels decoded to floats: what every colour mode and depth reduces to.
public struct PSDNormalizedImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var space: PSDPlaneSpace
    /// Colour planes, row-major. 1/8/16-bit data is 0...1; 32-bit data is linear and may exceed 1.
    public var planes: [[Float]]
    /// Transparency, when present.
    public var alpha: [Float]?
    /// Extra (spot/alpha) channels beyond the colour planes and transparency.
    public var extraChannels: [[Float]]
    public var depth: UInt16
}

/// Converts decoded planes of one colour mode to normalised planes.
public enum PSDModeDecoder {
    /// `stored`: planes as decoded (big-endian, at `depth`), colour channels first. Indexed uses
    /// `palette` (768 bytes, planar) and `transparentIndex`.
    public static func normalize(mode: PSDColorMode, depth: UInt16, width: Int, height: Int, stored: [[UInt8]], alphaIndex: Int?,
                                 palette: Data = Data(), transparentIndex: Int? = nil) throws -> PSDNormalizedImage {
        let n = width * height
        func plane(_ i: Int) throws -> [Float] {
            guard i < stored.count else { throw PSDError.invalid("missing channel \(i)") }
            let p = try PSDSamples.planeToFloat(stored[i], depth: depth, width: width, height: height)
            guard p.count == n else { throw PSDError.invalid("channel \(i) has \(p.count) samples, expected \(n)") }
            return p
        }
        var space: PSDPlaneSpace
        var planes: [[Float]] = []
        var alpha: [Float]? = try alphaIndex.map(plane)
        var colorCount: Int
        switch mode {
        case .bitmap, .grayscale, .duotone:
            space = .gray
            colorCount = 1
            planes = [try plane(0)]
        case .rgb:
            space = .rgb
            colorCount = 3
            planes = try (0 ..< 3).map(plane)
        case .cmyk:
            space = .cmyk
            colorCount = 4
            planes = try (0 ..< 4).map { try plane($0).map { 1 - $0 } }
        case .lab:
            space = .lab
            colorCount = 3
            planes = try (0 ..< 3).map(plane)
        case .indexed:
            space = .rgb
            colorCount = 1
            guard let idx = stored.first, idx.count >= n else { throw PSDError.invalid("missing index channel") }
            let pal = [UInt8](palette)
            func entry(_ k: Int, _ i: Int) -> Float { k * 256 + i < pal.count ? Float(pal[k * 256 + i]) / 255 : 0 }
            planes = (0 ..< 3).map { k in idx.prefix(n).map { entry(k, Int($0)) } }
            if let t = transparentIndex, t >= 0, t < 256 {
                let a = idx.prefix(n).map { Int($0) == t ? Float(0) : 1 }
                alpha = alpha.map { zip($0, a).map { $0 * $1 } } ?? a
            }
        case .multichannel, .unknown:
            colorCount = stored.count - (alphaIndex == nil ? 0 : 1)
            space = .channels(colorCount)
            planes = try (0 ..< colorCount).map(plane)
        }
        var extra: [[Float]] = []
        for i in colorCount ..< stored.count where i != alphaIndex {
            extra.append(try plane(i))
        }
        return PSDNormalizedImage(width: width, height: height, space: space, planes: planes, alpha: alpha, extraChannels: extra, depth: depth)
    }
}

/// A layer record with the file context needed to decode it.
public struct PSDLayerView: Sendable {
    public let index: Int
    public let record: PSDLayerRecord
    public let header: PSDHeader
    public let palette: Data

    public var name: String { record.displayName }

    public func channelBytes(_ id: Int16, lenient: Bool = false) throws -> [UInt8] {
        try record.decodeChannel(id, depth: header.depth, version: header.version, lenient: lenient)
    }

    /// Colour channels of the layer's mode.
    var colorCount: Int {
        if header.colorMode == .multichannel || header.colorMode == .unknown(header.colorMode.code) {
            return record.channels.filter { $0.id >= 0 }.count
        }
        return header.colorMode.colorChannels ?? 1
    }

    /// The layer decoded to normalised planes (channels decode concurrently). Missing colour
    /// channels read as 0 (CMYK: no ink).
    public func normalized(lenient: Bool = false) throws -> PSDNormalizedImage {
        let (w, h) = try record.rect.size()
        let n = w * h
        let cc = colorCount
        let ids = (0 ..< Int16(cc)).filter { record.channel($0) != nil } + (record.channel(-1) != nil ? [-1] : [])
            + record.channels.map(\.id).filter { $0 >= Int16(cc) }
        let decoded = try record.decodeChannels(ids, depth: header.depth, version: header.version, lenient: lenient)
        let rb = PSDHeader.rowBytes(width: w, depth: header.depth) * h
        let blank: UInt8 = header.colorMode == .cmyk ? 0xFF : 0
        var stored: [[UInt8]] = (0 ..< cc).map { decoded[Int16($0)] ?? [UInt8](repeating: header.depth == 32 ? 0 : blank, count: rb) }
        var alphaIndex: Int?
        if let a = decoded[-1] {
            alphaIndex = stored.count
            stored.append(a)
        }
        for id in ids where id >= Int16(cc) { if let p = decoded[id] { stored.append(p) } }
        guard stored.allSatisfy({ $0.count == rb }) || n == 0 else { throw PSDError.invalid("channel size mismatch") }
        return try PSDModeDecoder.normalize(mode: header.colorMode, depth: header.depth, width: w, height: h, stored: stored,
                                            alphaIndex: alphaIndex, palette: palette)
    }

    /// Layer pixels as RGBA8 (transparency as alpha; the user mask is not applied — see `userMask`).
    /// RGB, Gray, Bitmap, Duotone, Indexed, CMYK (naive), Lab and Multichannel at every depth.
    public func rgba8(lenient: Bool = false) throws -> PSDRGBA8Image {
        let (w, h) = try record.rect.size()
        guard UInt64(w) * UInt64(h) * 4 <= PSDLimits.maxDecodedBytes else { throw PSDError.limitExceeded("RGBA output exceeds maxDecodedBytes") }
        let img = try normalized(lenient: lenient)
        return PSDRGBA8Image(left: record.rect.left, top: record.rect.top, width: w, height: h, data: PSDRender.rgba8(img))
    }

    /// The raster user mask as 8-bit gray with its rectangle and default. It is channel -3 when
    /// present (a layer with both masks), else channel -2 unless the mask record says it "came
    /// from rendering other data". That flag marks Photoshop's rasterisation of a vector mask,
    /// which is not a user mask; see `vectorMaskRendering()`. `nil` when the layer has no raster
    /// mask.
    public func userMask() -> Result<PSDGrayImage, Error>? {
        let id: Int16
        if record.channel(PSDChannelID.realUserMask) != nil {
            id = PSDChannelID.realUserMask
        } else if record.channel(PSDChannelID.userMask) != nil, !maskCameFromRendering {
            id = PSDChannelID.userMask
        } else {
            return nil
        }
        return maskImage(id)
    }

    /// Photoshop's rasterisation of the layer's vector mask: channel -2 when the mask record is
    /// flagged as rendered from other data. Vector-mask coverage, not a user mask. `nil` otherwise.
    public func vectorMaskRendering() -> Result<PSDGrayImage, Error>? {
        guard maskCameFromRendering, record.channel(PSDChannelID.userMask) != nil else { return nil }
        return maskImage(PSDChannelID.userMask)
    }

    /// The mask record's "user mask came from rendering other data" flag (bit 3).
    var maskCameFromRendering: Bool { (record.layerMask?.flags ?? 0) & PSDLayerMask.flagFromRendering != 0 }

    func maskImage(_ id: Int16) -> Result<PSDGrayImage, Error> {
        Result {
            let rect = record.channelRect(id)
            let (w, h) = try rect.size()
            let data = try PSDSamples.planeToU8(try channelBytes(id), depth: header.depth, width: w, height: h)
            var def: UInt8 = 0
            if let m = record.layerMask { def = id == PSDChannelID.realUserMask ? (m.real?.background ?? m.defaultColor) : m.defaultColor }
            return PSDGrayImage(left: rect.left, top: rect.top, width: w, height: h, data: data, defaultValue: def)
        }
    }
}

extension PSDFile {
    public func layer(_ index: Int) -> PSDLayerView? {
        guard index >= 0, index < layers.count else { return nil }
        return PSDLayerView(index: index, record: layers[index], header: header, palette: colorModeData)
    }

    public var layerViews: [PSDLayerView] {
        layers.enumerated().map { PSDLayerView(index: $0.offset, record: $0.element, header: header, palette: colorModeData) }
    }

    /// Transparent palette index of an indexed file (resource 1047).
    public var transparentIndex: Int? {
        if case let .transparentIndex(t)? = resource(PSDResourceID.transparentIndex)?.typed { return Int(t) }
        return nil
    }

    /// The merged image decoded to normalised planes (every mode and depth).
    public func normalizedComposite(lenient: Bool = false) throws -> PSDNormalizedImage {
        try header.validate()
        let (w, h) = (Int(header.width), Int(header.height))
        let all = try decodeMerged(lenient: lenient)
        let plane = header.rowBytes * h
        let count = Int(header.channels)
        guard all.count >= plane * count else { throw PSDError.invalid("merged data too short") }
        let stored = (0 ..< count).map { Array(all[$0 * plane ..< ($0 + 1) * plane]) }
        let cc = colorChannelCount ?? count
        guard count >= min(cc, count), header.colorMode == .multichannel || count >= cc else {
            throw PSDError.invalid("fewer channels than the colour mode requires")
        }
        let alphaIndex = mergedHasAlpha && header.colorMode != .multichannel ? cc : nil
        return try PSDModeDecoder.normalize(mode: header.colorMode, depth: header.depth, width: w, height: h, stored: stored,
                                            alphaIndex: alphaIndex, palette: colorModeData, transparentIndex: transparentIndex)
    }

    /// The merged composite as RGBA8, like photocraft's `composite_rgba8`: no colour management
    /// (CMYK naive, Lab by formula, 32-bit clamped), alpha from the first extra channel when
    /// `mergedHasAlpha`, the white matte Photoshop composites transparent RGB against removed
    /// (`unmatte: false` keeps the stored colour, as macOS ImageIO presents it).
    public func compositeRGBA8(lenient: Bool = false, unmatte: Bool = true) throws -> PSDRGBA8Image {
        let (w, h) = (Int(header.width), Int(header.height))
        guard UInt64(w) * UInt64(h) * 4 <= PSDLimits.maxDecodedBytes else { throw PSDError.limitExceeded("RGBA output exceeds maxDecodedBytes") }
        var img = try normalizedComposite(lenient: lenient)
        let matted = unmatte && (header.colorMode == .rgb || header.colorMode == .grayscale) && img.alpha != nil
        if matted, header.depth != 8, let a = img.alpha {
            img.planes = img.planes.map { p in zip(p, a).map { c, a in a > 0 ? min(max((c + a - 1) / a, 0), 1) : c } }
        }
        var data = PSDRender.rgba8(img)
        if matted, header.depth == 8 {
            // photocraft's integer unmatte: straight = ((c + a − 255) × 255 + a/2) / a.
            for i in stride(from: 0, to: data.count, by: 4) {
                let a = UInt32(data[i + 3])
                guard a > 0 else { continue }
                for k in 0 ..< 3 {
                    let c = UInt32(data[i + k])
                    let s = (c + a > 255 ? c + a - 255 : 0) * 255 + a / 2
                    data[i + k] = UInt8(min(255, s / a))
                }
            }
        }
        return PSDRGBA8Image(left: 0, top: 0, width: w, height: h, data: data)
    }
}

/// Uncolour-managed rendering of normalised planes to RGBA8.
public enum PSDRender {
    @inline(__always) static func q(_ v: Float) -> UInt8 { v.isNaN ? 0 : UInt8((min(max(v, 0), 1) * 255).rounded()) }

    public static func rgba8(_ img: PSDNormalizedImage) -> [UInt8] {
        let n = img.width * img.height
        var out = [UInt8](repeating: 255, count: n * 4)
        let p = img.planes
        switch img.space {
        case .gray:
            for i in 0 ..< n { let g = q(p[0][i]); out[i * 4] = g; out[i * 4 + 1] = g; out[i * 4 + 2] = g }
        case .rgb:
            for i in 0 ..< n { out[i * 4] = q(p[0][i]); out[i * 4 + 1] = q(p[1][i]); out[i * 4 + 2] = q(p[2][i]) }
        case .cmyk:
            // Naive: r = (1 − c)(1 − k), computed on the stored (inverted) 8-bit values as photocraft does.
            for i in 0 ..< n {
                let k = UInt32(q(1 - p[3][i]))
                func f(_ c: Float) -> UInt8 { UInt8((UInt32(q(1 - c)) * k + 127) / 255) }
                out[i * 4] = f(p[0][i]); out[i * 4 + 1] = f(p[1][i]); out[i * 4 + 2] = f(p[2][i])
            }
        case .lab:
            for i in 0 ..< n {
                let (r, g, b) = LabColor.toSRGB(l: Double(p[0][i]) * 100, a: Double(p[1][i]) * 255 - 128, b: Double(p[2][i]) * 255 - 128)
                out[i * 4] = q(Float(r)); out[i * 4 + 1] = q(Float(g)); out[i * 4 + 2] = q(Float(b))
            }
        case let .channels(c):
            // Spot/multichannel inks: shown as the first three channels (or gray for one).
            for i in 0 ..< n {
                let v = (0 ..< 3).map { k in q(p[min(k, max(0, c - 1))][i]) }
                out[i * 4] = v[0]; out[i * 4 + 1] = v[1]; out[i * 4 + 2] = v[2]
            }
        }
        if let a = img.alpha {
            for i in 0 ..< n { out[i * 4 + 3] = q(a[i]) }
        }
        return out
    }
}

/// CIE Lab (D50) → sRGB, for previews without a colour management system.
enum LabColor {
    static func toSRGB(l: Double, a: Double, b: Double) -> (Double, Double, Double) {
        let fy = (l + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
        func finv(_ t: Double) -> Double { t > 6.0 / 29 ? t * t * t : 3 * (6.0 / 29) * (6.0 / 29) * (t - 4.0 / 29) }
        let x = 0.9642 * finv(fx), y = 1.0 * finv(fy), z = 0.8249 * finv(fz)
        // XYZ D50 → linear sRGB (Bradford-adapted matrix).
        let r = 3.1338561 * x - 1.6168667 * y - 0.4906146 * z
        let g = -0.9787684 * x + 1.9161415 * y + 0.0334540 * z
        let bl = 0.0719453 * x - 0.2289914 * y + 1.4052427 * z
        func gamma(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        return (gamma(r), gamma(g), gamma(bl))
    }
}
