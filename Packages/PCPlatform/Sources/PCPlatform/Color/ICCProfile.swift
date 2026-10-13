// ICC profiles: load, embed, describe, built-ins.
// Replaces photocraft-cms (crates/cms/src/{profile,builtin,write,synth}.rs) with ColorSync. Port of its
// API shape, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// photocraft parses ICC v2/v4 itself (matrix/TRC, mft1/mft2/mAB/mBA, curv/para) and generates its
// built-in profiles in code. Here ColorSync parses and evaluates every profile; the built-ins are the
// profiles macOS ships (sRGB, Display P3, Adobe RGB (1998), ROMM/ProPhoto, Rec. 2020, Gray Gamma 2.2,
// Generic Lab, Generic CMYK) plus three photocraft has and macOS doesn't: "sGray" (gray with the sRGB
// curve), "Dot Gain 20%" (Photoshop's default gray working space, a parabolic dot-gain TRC) — both
// written by the small ICC v2 gray-TRC writer below — and photocraft's own synthetic coated CMYK
// profile (`photocraft-coated-cmyk.icc`, CC0-1.0), bundled as a resource so CMYK conversions here use
// the very same characterisation photocraft does.

@preconcurrency import ColorSync
import CoreGraphics
import Foundation
import PCFoundation
import Synchronization

/// The colour space of a profile's device side (ICC header bytes 16–19).
public enum ProfileColorSpace: Sendable, Hashable {
    case rgb, gray, cmyk, lab, xyz
    case other(String)

    init(signature: String) {
        switch signature {
        case "RGB ": self = .rgb
        case "GRAY": self = .gray
        case "CMYK": self = .cmyk
        case "Lab ": self = .lab
        case "XYZ ": self = .xyz
        default: self = .other(signature)
        }
    }

    /// Device channels.
    public var channels: Int {
        switch self {
        case .gray: 1
        case .rgb, .lab, .xyz: 3
        case .cmyk: 4
        case .other(let s):
            // nCLR: "2CLR"…"FCLR".
            if s.hasSuffix("CLR"), let n = Int(String(s.prefix(1)), radix: 16) { n } else { 3 }
        }
    }

    /// The document colour model these pixels are stored in.
    public var colorMode: ColorMode? {
        switch self {
        case .rgb: .rgb
        case .gray: .grayscale
        case .cmyk: .cmyk
        case .lab: .lab
        default: nil
        }
    }
}

/// The profile/device class (ICC header bytes 12–15).
public enum ProfileClass: String, Sendable, Hashable {
    case input = "scnr", display = "mntr", output = "prtr", link = "link", abstract = "abst"
    case colorSpace = "spac", namedColor = "nmcl", unknown = "????"
}

/// An immutable ICC profile backed by ColorSync (photocraft `Profile`). Equality is byte equality
/// (photocraft `content_hash`); `sameColors(as:)` compares colours (photocraft `same_colors`).
public final class ICCProfile: @unchecked Sendable, Hashable, CustomStringConvertible {
    /// The profile bytes, verbatim (photocraft `to_bytes` of a parsed profile).
    public let data: Data
    /// The ColorSync profile object.
    public let colorSyncProfile: ColorSyncProfile
    /// The CoreGraphics colour space with this profile (nil when CoreGraphics refuses it, e.g. a
    /// device link).
    public let cgColorSpace: CGColorSpace?
    /// The `desc` string.
    public let profileDescription: String
    public let colorSpace: ProfileColorSpace
    /// The profile connection space ("XYZ " or "Lab ").
    public let pcs: ProfileColorSpace
    public let deviceClass: ProfileClass
    /// ICC version (major, minor).
    public let version: (major: Int, minor: Int)
    /// The rendering intent stored in the header.
    public let headerIntent: RenderingIntent

    /// Parses a profile (photocraft `Profile::parse`).
    public init(data: Data) throws {
        guard data.count >= 132 else { throw PlatformError.invalidProfile("truncated (\(data.count) bytes)") }
        guard data.subdata(in: 36..<40) == Data("acsp".utf8) else {
            throw PlatformError.invalidProfile("missing 'acsp' signature")
        }
        var err: Unmanaged<CFError>?
        guard let p = ColorSyncProfileCreate(data as CFData, &err)?.takeRetainedValue() else {
            let e = err?.takeRetainedValue()
            throw PlatformError.invalidProfile(e.map { CFErrorCopyDescription($0) as String } ?? "ColorSync refused the profile")
        }
        self.data = data
        colorSyncProfile = p
        cgColorSpace = CGColorSpace(iccData: data as CFData)
        func sig(_ at: Int) -> String {
            String(decoding: data.subdata(in: at..<at + 4), as: UTF8.self)
        }
        colorSpace = ProfileColorSpace(signature: sig(16))
        pcs = ProfileColorSpace(signature: sig(20))
        deviceClass = ProfileClass(rawValue: sig(12)) ?? .unknown
        version = (Int(data[8]), Int(data[9] >> 4))
        headerIntent = RenderingIntent(rawValue: Int(data[67])) ?? .perceptual
        profileDescription = ColorSyncProfileCopyDescriptionString(p)?.takeRetainedValue() as String? ?? ""
    }

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    /// The profile of a CoreGraphics colour space (nil for spaces without ICC data, e.g. device spaces).
    public convenience init?(colorSpace: CGColorSpace) {
        guard let d = colorSpace.copyICCData() as Data? else { return nil }
        try? self.init(data: d)
    }

    /// A profile ColorSync knows by name (`kColorSyncSRGBProfile`, …).
    convenience init(colorSyncName: CFString) throws {
        guard let p = ColorSyncProfileCreateWithName(colorSyncName)?.takeRetainedValue(),
              let d = ColorSyncProfileCopyData(p, nil)?.takeRetainedValue() as Data? else {
            throw PlatformError.invalidProfile("ColorSync has no profile \(colorSyncName)")
        }
        try self.init(data: d)
    }

    /// Device channels.
    public var channels: Int { colorSpace.channels }

    /// The document colour model this profile describes.
    public var colorMode: ColorMode? { colorSpace.colorMode }

    /// ColorSync's MD5 of the profile (the ICC profile ID algorithm).
    public var md5: Data {
        var m = ColorSyncProfileGetMD5(colorSyncProfile)
        return withUnsafeBytes(of: &m.digest) { Data($0) }
    }

    /// Whether the profile can be a transform destination (it has a PCS → device direction).
    public var canBeDestination: Bool {
        if deviceClass == .link || deviceClass == .namedColor || deviceClass == .abstract { return false }
        return (try? ColorTransform(source: BuiltinProfile.labD50.profile, destination: self)) != nil
    }

    /// The media white point (`wtpt`, XYZ), when present.
    public var mediaWhitePoint: SIMD3<Double>? {
        guard let t = tag("wtpt"), t.count >= 20, String(decoding: t.prefix(4), as: UTF8.self) == "XYZ " else { return nil }
        func s15(_ at: Int) -> Double {
            let v = t.subdata(in: at..<at + 4).withUnsafeBytes { Int32(bigEndian: $0.loadUnaligned(as: Int32.self)) }
            return Double(v) / 65536
        }
        return SIMD3(s15(8), s15(12), s15(16))
    }

    /// The raw bytes of tag `signature`, if present.
    public func tag(_ signature: String) -> Data? {
        guard data.count >= 132 else { return nil }
        func be32(_ at: Int) -> Int {
            guard at + 4 <= data.count else { return 0 }
            return Int(data.subdata(in: at..<at + 4).withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
        }
        let count = be32(128)
        let sig = Data(signature.utf8)
        for i in 0..<min(count, 1000) {
            let rec = 132 + 12 * i
            guard rec + 12 <= data.count else { return nil }
            if data.subdata(in: rec..<rec + 4) == sig {
                let off = be32(rec + 4), len = be32(rec + 8)
                guard off + len <= data.count else { return nil }
                return data.subdata(in: off..<off + len)
            }
        }
        return nil
    }

    /// The same colours whatever the encoding: every node of a device grid lands within ΔE76 0.5 of
    /// itself through both profiles to Lab (photocraft `Profile::same_colors`).
    public func sameColors(as other: ICCProfile) -> Bool {
        if data == other.data { return true }
        guard colorSpace == other.colorSpace,
              let a = try? ColorTransform.cached(source: self, destination: BuiltinProfile.labD50.profile, options: .init(intent: .relativeColorimetric)),
              let b = try? ColorTransform.cached(source: other, destination: BuiltinProfile.labD50.profile, options: .init(intent: .relativeColorimetric))
        else { return false }
        let n = channels, steps = n >= 4 ? 4 : 6
        var grid: [Float] = []
        var idx = [Int](repeating: 0, count: n)
        outer: while true {
            for k in 0..<n { grid.append(Float(idx[k]) / Float(steps - 1)) }
            var k = 0
            while k < n {
                idx[k] += 1
                if idx[k] < steps { continue outer }
                idx[k] = 0; k += 1
            }
            break
        }
        let count = grid.count / n
        let la = a.convert(grid, pixelCount: count), lb = b.convert(grid, pixelCount: count)
        for i in 0..<count {
            let x = LabEncoding.colorSync.decode(SIMD3(la[i * 3], la[i * 3 + 1], la[i * 3 + 2]))
            let y = LabEncoding.colorSync.decode(SIMD3(lb[i * 3], lb[i * 3 + 1], lb[i * 3 + 2]))
            if ColorMath.deltaE76(x, y) > 0.5 { return false }
        }
        return true
    }

    public static func == (a: ICCProfile, b: ICCProfile) -> Bool { a.data == b.data }
    public func hash(into h: inout Hasher) { h.combine(data) }
    public var description: String { "ICCProfile(\(profileDescription), \(colorSpace), \(deviceClass.rawValue), v\(version.major).\(version.minor))" }
}

/// The built-in profiles (photocraft `Builtin`). Each id matches photocraft's where photocraft has
/// the profile; `from(id:)` also accepts the profile descriptions Photoshop uses.
public enum BuiltinProfile: String, CaseIterable, Sendable {
    case srgb = "srgb"
    case displayP3 = "display-p3"
    case adobeRGB = "adobe-rgb"
    case proPhoto = "prophoto"
    case linearSRGB = "linear-srgb"
    case rec2020 = "rec2020"
    case grayGamma22 = "gray-gamma-2.2"
    case sGray = "sgray"
    case dotGain20 = "dot-gain-20"
    case labD50 = "lab-d50"
    case genericCMYK = "generic-cmyk"
    case coatedCMYK = "coated-cmyk"

    public var id: String { rawValue }

    /// Where the profile comes from.
    public var source: String {
        switch self {
        case .srgb, .displayP3, .adobeRGB, .proPhoto, .rec2020, .grayGamma22, .labD50, .genericCMYK: "macOS ColorSync"
        case .linearSRGB: "macOS CoreGraphics (kCGColorSpaceLinearSRGB)"
        case .sGray, .dotGain20: "PCPlatform ICC v2 gray-TRC writer"
        case .coatedCMYK: "photocraft-cms synthetic coated CMYK (CC0-1.0, bundled)"
        }
    }

    public static func from(id: String) -> BuiltinProfile? {
        let n = id.lowercased().filter { $0.isLetter || $0.isNumber }
        switch n {
        case "srgb", "srgbiec6196621": return .srgb
        case "displayp3", "p3": return .displayP3
        case "adobergb", "adobergb1998", "adobergbcompat": return .adobeRGB
        case "prophoto", "prophotorgb", "rommrgb", "prophotocompat": return .proPhoto
        case "linearsrgb": return .linearSRGB
        case "rec2020", "itur2020", "itu2020": return .rec2020
        case "graygamma22", "genericgraygamma22profile", "graygamma22profile": return .grayGamma22
        case "sgray": return .sGray
        case "dotgain20", "dotgain20percent": return .dotGain20
        case "labd50", "lab", "genericlabprofile": return .labD50
        case "genericcmyk", "genericcmykprofile": return .genericCMYK
        case "coatedcmyk", "photocraftcoatedcmyk": return .coatedCMYK
        default: return nil
        }
    }

    private static let cache = Mutex<[BuiltinProfile: ICCProfile]>([:])

    /// The profile (built once, then cached).
    public var profile: ICCProfile {
        if let p = Self.cache.withLock({ $0[self] }) { return p }
        let p: ICCProfile
        do { p = try make() } catch { fatalError("built-in profile \(rawValue) failed: \(error)") }
        Self.cache.withLock { $0[self] = p }
        return p
    }

    private func make() throws -> ICCProfile {
        switch self {
        case .srgb: return try ICCProfile(colorSyncName: kColorSyncSRGBProfile.takeUnretainedValue())
        case .displayP3: return try ICCProfile(colorSyncName: kColorSyncDisplayP3Profile.takeUnretainedValue())
        case .adobeRGB: return try ICCProfile(colorSyncName: kColorSyncAdobeRGB1998Profile.takeUnretainedValue())
        case .proPhoto: return try ICCProfile(colorSyncName: kColorSyncROMMRGBProfile.takeUnretainedValue())
        case .rec2020: return try ICCProfile(colorSyncName: kColorSyncITUR2020Profile.takeUnretainedValue())
        case .grayGamma22: return try ICCProfile(colorSyncName: kColorSyncGenericGrayGamma22Profile.takeUnretainedValue())
        case .labD50: return try ICCProfile(colorSyncName: kColorSyncGenericLabProfile.takeUnretainedValue())
        case .genericCMYK: return try ICCProfile(colorSyncName: kColorSyncGenericCMYKProfile.takeUnretainedValue())
        case .linearSRGB:
            guard let d = CGColorSpace(name: CGColorSpace.linearSRGB)?.copyICCData() as Data? else {
                throw PlatformError.invalidProfile("no linear sRGB ICC data")
            }
            return try ICCProfile(data: d)
        case .sGray:
            return try ICCProfile(data: ICCWriter.grayProfile(description: "sGray (sRGB curve)") { y in
                // Device gray → linear Y through the sRGB EOTF.
                Double(ColorConvert.srgbToLinear(Float(y)))
            })
        case .dotGain20:
            return try ICCProfile(data: ICCWriter.grayProfile(description: "Dot Gain 20%") { d in
                // Gray value d (1 = paper white) is ink t = 1 − d; a parabolic 20 % dot gain at the
                // 50 % tone gives coverage t + 4·0.2·t(1 − t); reflectance is 1 − coverage.
                let t = 1 - d
                return 1 - (t + 0.8 * t * (1 - t))
            })
        case .coatedCMYK:
            guard let url = Bundle.module.url(forResource: "photocraft-coated-cmyk", withExtension: "icc") else {
                throw PlatformError.invalidProfile("photocraft-coated-cmyk.icc resource missing")
            }
            return try ICCProfile(contentsOf: url)
        }
    }

    /// The default profile for a document colour model (photocraft `builtin::default_for`):
    /// sRGB, sGray, coated CMYK, Lab D50.
    public static func defaultProfile(for mode: ColorMode) -> ICCProfile {
        switch mode {
        case .rgb, .indexed, .multichannel: BuiltinProfile.srgb.profile
        case .grayscale, .bitmap, .duotone: BuiltinProfile.sGray.profile
        case .cmyk: BuiltinProfile.coatedCMYK.profile
        case .lab: BuiltinProfile.labD50.profile
        }
    }
}

/// A minimal ICC v2.1 writer for monochrome display profiles (header, desc, cprt, wtpt, kTRC):
/// what PCPlatform needs to provide sGray and Dot Gain 20%, which macOS doesn't ship. photocraft's
/// general writer (crates/cms/src/write.rs) is not needed: ColorSync keeps profile bytes verbatim.
public enum ICCWriter {
    /// A gray profile whose kTRC maps device gray `d` (0 black … 1 white) to relative luminance
    /// `trc(d)`, sampled at `entries` points.
    public static func grayProfile(description: String, entries: Int = 1024, trc: (Double) -> Double) -> Data {
        var tags: [(String, [UInt8])] = []
        tags.append(("desc", textDescription(description)))
        tags.append(("cprt", text("No copyright: CC0-1.0 public domain dedication. Generated by PCPlatform.")))
        tags.append(("wtpt", xyz(0.9642, 1.0, 0.8249)))
        var curve = Array("curv".utf8) + [0, 0, 0, 0] + be32(UInt32(entries))
        for i in 0..<entries {
            let y = min(max(trc(Double(i) / Double(entries - 1)), 0), 1)
            curve += be16(UInt16((y * 65535).rounded()))
        }
        tags.append(("kTRC", curve))
        return assemble(class: "mntr", space: "GRAY", pcs: "XYZ ", tags: tags)
    }

    static func be32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian) { Array($0) } }
    static func be16(_ v: UInt16) -> [UInt8] { withUnsafeBytes(of: v.bigEndian) { Array($0) } }
    static func s15(_ v: Double) -> [UInt8] { be32(UInt32(bitPattern: Int32((v * 65536).rounded()))) }

    static func xyz(_ x: Double, _ y: Double, _ z: Double) -> [UInt8] {
        Array("XYZ ".utf8) + [0, 0, 0, 0] + s15(x) + s15(y) + s15(z)
    }

    static func text(_ s: String) -> [UInt8] {
        Array("text".utf8) + [0, 0, 0, 0] + Array(s.utf8) + [0]
    }

    /// v2 `textDescriptionType`: ASCII, an empty Unicode part, an empty ScriptCode part.
    static func textDescription(_ s: String) -> [UInt8] {
        let ascii = Array(s.utf8) + [0]
        return Array("desc".utf8) + [0, 0, 0, 0] + be32(UInt32(ascii.count)) + ascii
            + [0, 0, 0, 0] + [0, 0, 0, 0]            // Unicode language code, count
            + [0, 0] + [0] + [UInt8](repeating: 0, count: 67)   // ScriptCode code, count, data
    }

    static func assemble(class cls: String, space: String, pcs: String, tags: [(String, [UInt8])]) -> Data {
        let tableSize = 4 + 12 * tags.count
        var offset = 128 + tableSize
        var table = be32(UInt32(tags.count))
        var body: [UInt8] = []
        for (sig, d) in tags {
            while (offset + body.count) % 4 != 0 { body.append(0) }
            table += Array(sig.utf8) + be32(UInt32(offset + body.count)) + be32(UInt32(d.count))
            body += d
        }
        offset = 0
        while body.count % 4 != 0 { body.append(0) }
        let size = 128 + tableSize + body.count
        var h = be32(UInt32(size))
        h += [0, 0, 0, 0]                                   // CMM
        h += [0x02, 0x10, 0, 0]                             // version 2.1
        h += Array(cls.utf8) + Array(space.utf8) + Array(pcs.utf8)
        for v in [2026, 10, 12, 0, 0, 0] as [UInt16] { h += be16(v) }
        h += Array("acsp".utf8) + Array("APPL".utf8)
        h += [UInt8](repeating: 0, count: 4 + 4 + 4 + 8)    // flags, manufacturer, model, attributes
        h += be32(0)                                         // perceptual
        h += s15(0.9642) + s15(1.0) + s15(0.8249)            // PCS illuminant D50
        h += Array("PCNT".utf8)                              // creator
        h += [UInt8](repeating: 0, count: 128 - h.count)
        return Data(h + table + body)
    }
}
