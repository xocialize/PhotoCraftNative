// Format identification and capability declarations for the native codec registry.
// Replaces photocraft-codecs (crates/codecs/src/format.rs) with ImageIO's reader/writer registry.
// Port of its API shape (`Format`, `FormatCaps`, `detect`, `from_extension`), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.
//
// Two capability tables live here. `photocraftCaps` is photocraft's own table, kept verbatim so the
// comparison in PORT-NOTES is mechanical. `caps` is the native port's, measured on macOS 27.2 /
// M5 Max (Tests/PCPlatformTests/CodecTests.swift re-verifies every entry): read/write come from
// `CGImageSourceCopyTypeIdentifiers()` / `CGImageDestinationCopyTypeIdentifiers()` at run time
// plus the codecs PCPlatform adds itself (webp-swift for WebP write; small ports for QOI, Radiance
// write and binary PBM).

import Foundation
import ImageIO
import PCFoundation
import Synchronization
import UniformTypeIdentifiers

/// Sample storage a format can hold (photocraft-codecs `SampleType`, which has F16).
public enum CodecDepth: String, Sendable, CaseIterable, Comparable {
    case u8, u16, f16, f32
    public static func < (a: CodecDepth, b: CodecDepth) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
    public init(_ s: SampleType) {
        switch s { case .u8: self = .u8; case .u16: self = .u16; case .f32: self = .f32 }
    }
    public var name: String {
        switch self { case .u8: "8-bit"; case .u16: "16-bit"; case .f16: "16-bit float"; case .f32: "32-bit float" }
    }
}

/// Channel layout (photocraft-codecs `ChannelLayout`).
public enum ChannelLayout: String, Sendable, CaseIterable {
    case gray, grayA, rgb, rgba, cmyk, cmykA

    public init?(_ f: PixelFormat) {
        switch (f.mode, f.alpha) {
        case (.grayscale, false), (.bitmap, false), (.duotone, false): self = .gray
        case (.grayscale, true), (.bitmap, true), (.duotone, true): self = .grayA
        case (.rgb, false), (.indexed, false), (.multichannel, false): self = .rgb
        case (.rgb, true), (.indexed, true), (.multichannel, true): self = .rgba
        case (.cmyk, false): self = .cmyk
        case (.cmyk, true): self = .cmykA
        case (.lab, _): return nil
        }
    }

    public var hasAlpha: Bool { self == .grayA || self == .rgba || self == .cmykA }
}

/// Which implementation backs a direction.
public enum CodecBackend: String, Sendable {
    case imageIO = "ImageIO"
    case webpSwift = "webp-swift (libwebp 1.6.0)"
    case cameraRaw = "Core Image CIRAWFilter"
    case pdf = "CoreGraphics PDF / PDFKit"
    case ported = "PCPlatform port"
    case none = "—"
}

/// What a format can hold and what this build reads/writes (photocraft-codecs `FormatCaps`).
public struct FormatCaps: Sendable, Equatable {
    public var read: Bool
    public var write: Bool
    public var readBackend: CodecBackend
    public var writeBackend: CodecBackend
    /// Sample types written and read back without conversion.
    public var depths: [CodecDepth]
    /// Layouts written and read back without conversion.
    public var layouts: [ChannelLayout]
    public var alpha: Bool
    public var icc: Bool
    public var exif: Bool
    public var xmp: Bool
    public var dpi: Bool
    public var text: Bool
    /// Multiple frames/pages readable and writable.
    public var animation: Bool
    public var lossy: Bool
}

/// photocraft's support for a format (its `caps()` table plus file-format-parity.md).
public struct PhotocraftSupport: Sendable {
    public let read: Bool
    public let write: Bool
    public let notes: String
}

/// Raster formats known to the registry: photocraft's sixteen first, then what ImageIO adds.
public enum ImageFormat: String, CaseIterable, Sendable {
    // photocraft-codecs `Format::ALL`
    case png, jpeg, tiff, webp, gif, bmp, tga, ico, pnm, pcx, qoi, openEXR, hdr, avif, heif, fits
    // Native extras (ImageIO / Core Image / CoreGraphics)
    case heics, psd, jpeg2000, jpegXL, dds, icns, cur, pict, sgi, dicom, mpo, astc, ktx, ktx2, pvr, atx, cameraRaw, pdf

    public var name: String {
        switch self {
        case .png: "PNG"; case .jpeg: "JPEG"; case .tiff: "TIFF"; case .webp: "WebP"; case .gif: "GIF"
        case .bmp: "BMP"; case .tga: "TGA"; case .ico: "ICO"; case .pnm: "Netpbm"; case .pcx: "PCX"
        case .qoi: "QOI"; case .openEXR: "OpenEXR"; case .hdr: "Radiance HDR"; case .avif: "AVIF"
        case .heif: "HEIF/HEIC"; case .fits: "FITS"; case .heics: "HEIF sequence"; case .psd: "Photoshop (flattened)"
        case .jpeg2000: "JPEG 2000"; case .jpegXL: "JPEG XL"; case .dds: "DirectDraw Surface"; case .icns: "Apple Icon"
        case .cur: "Windows Cursor"; case .pict: "PICT"; case .sgi: "SGI"; case .dicom: "DICOM"; case .mpo: "MPO (stereo)"
        case .astc: "ASTC"; case .ktx: "KTX"; case .ktx2: "KTX2"; case .pvr: "PowerVR"; case .atx: "Apple texture (ATX)"
        case .cameraRaw: "Camera raw"; case .pdf: "PDF"
        }
    }

    /// The UTI ImageIO registers (camera raw: the DNG one; every vendor UTI maps back here).
    public var uti: String {
        switch self {
        case .png: "public.png"; case .jpeg: "public.jpeg"; case .tiff: "public.tiff"; case .webp: "org.webmproject.webp"
        case .gif: "com.compuserve.gif"; case .bmp: "com.microsoft.bmp"; case .tga: "com.truevision.tga-image"
        case .ico: "com.microsoft.ico"; case .pnm: "public.pbm"; case .pcx: "com.pcx"; case .qoi: "org.qoiformat.qoi"
        case .openEXR: "com.ilm.openexr-image"; case .hdr: "public.radiance"; case .avif: "public.avif"
        case .heif: "public.heic"; case .fits: "gov.nasa.fits"; case .heics: "public.heics"
        case .psd: "com.adobe.photoshop-image"; case .jpeg2000: "public.jpeg-2000"; case .jpegXL: "public.jpeg-xl"
        case .dds: "com.microsoft.dds"; case .icns: "com.apple.icns"; case .cur: "com.microsoft.cur"; case .pict: "com.apple.pict"
        case .sgi: "com.sgi.sgi-image"; case .dicom: "org.nema.dicom"; case .mpo: "public.mpo-image"; case .astc: "org.khronos.astc"
        case .ktx: "org.khronos.ktx"; case .ktx2: "org.khronos.ktx2"; case .pvr: "public.pvr"; case .atx: "com.apple.atx"
        case .cameraRaw: "com.adobe.raw-image"; case .pdf: "com.adobe.pdf"
        }
    }

    /// Extensions, lowercase; the first is preferred for writing (photocraft `extensions`).
    public var extensions: [String] {
        switch self {
        case .png: ["png", "apng"]; case .jpeg: ["jpg", "jpeg", "jpe", "jfif"]; case .tiff: ["tif", "tiff"]
        case .webp: ["webp"]; case .gif: ["gif"]; case .bmp: ["bmp", "dib"]; case .tga: ["tga", "icb", "vda", "vst"]
        case .ico: ["ico"]; case .pnm: ["pnm", "pbm", "pgm", "ppm", "pam", "pfm"]; case .pcx: ["pcx"]; case .qoi: ["qoi"]
        case .openEXR: ["exr"]; case .hdr: ["hdr"]; case .avif: ["avif"]; case .heif: ["heic", "heif", "hif"]
        case .fits: ["fits", "fit", "fts"]; case .heics: ["heics"]; case .psd: ["psd"]; case .jpeg2000: ["jp2", "j2k", "jpf", "jpx"]
        case .jpegXL: ["jxl"]; case .dds: ["dds"]; case .icns: ["icns"]; case .cur: ["cur"]; case .pict: ["pict", "pct"]
        case .sgi: ["sgi", "rgb", "bw"]; case .dicom: ["dcm", "dicom"]; case .mpo: ["mpo"]; case .astc: ["astc"]
        case .ktx: ["ktx"]; case .ktx2: ["ktx2"]; case .pvr: ["pvr"]; case .atx: ["atx"]
        case .cameraRaw: ["dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "rwl", "pef",
                          "srw", "3fr", "fff", "iiq", "mos", "mef", "mrw", "erf", "dcr", "x3f"]
        case .pdf: ["pdf"]
        }
    }

    public var mimeType: String {
        switch self {
        case .png: "image/png"; case .jpeg: "image/jpeg"; case .tiff: "image/tiff"; case .webp: "image/webp"
        case .gif: "image/gif"; case .bmp: "image/bmp"; case .tga: "image/x-tga"; case .ico: "image/x-icon"
        case .pnm: "image/x-portable-anymap"; case .pcx: "image/x-pcx"; case .qoi: "image/qoi"; case .openEXR: "image/x-exr"
        case .hdr: "image/vnd.radiance"; case .avif: "image/avif"; case .heif: "image/heif"; case .fits: "image/fits"
        case .heics: "image/heic-sequence"; case .psd: "image/vnd.adobe.photoshop"; case .jpeg2000: "image/jp2"
        case .jpegXL: "image/jxl"; case .dds: "image/vnd-ms.dds"; case .icns: "image/icns"; case .cur: "image/x-win-bitmap"
        case .pict: "image/x-pict"; case .sgi: "image/sgi"; case .dicom: "application/dicom"; case .mpo: "image/mpo"
        case .astc: "image/astc"; case .ktx: "image/ktx"; case .ktx2: "image/ktx2"; case .pvr: "image/x-pvr"
        case .atx: "image/x-apple-atx"; case .cameraRaw: "image/x-dcraw"; case .pdf: "application/pdf"
        }
    }

    /// Maximum encodable dimensions (photocraft `max_dimensions`, plus ICO's square ≤ 256 rule).
    public var maxDimensions: (width: Int, height: Int)? {
        switch self {
        case .jpeg, .gif: (65535, 65535)
        case .webp: (16383, 16383)
        case .ico, .cur: (256, 256)
        default: nil
        }
    }

    /// photocraft's own support (crates/codecs/src/format.rs + docs/file-format-parity.md).
    public var photocraftSupport: PhotocraftSupport {
        switch self {
        case .png: .init(read: true, write: true, notes: "8/16-bit, ICC/text; APNG first frame only")
        case .jpeg: .init(read: true, write: true, notes: "8-bit Gray/RGB/CMYK, ICC/EXIF/XMP; quality kept on Save (#2399)")
        case .tiff: .init(read: true, write: true, notes: "8/16/32f, Gray/RGB/CMYK, BigTIFF, every IFD, layered TIFF")
        case .webp: .init(read: true, write: true, notes: "lossless + own lossy VP8 encoder; ICC/EXIF/XMP")
        case .gif: .init(read: true, write: true, notes: "frames for video layers; Open keeps first frame")
        case .bmp: .init(read: true, write: true, notes: "8-bit; palette BMPs open Indexed")
        case .tga: .init(read: true, write: true, notes: "8-bit")
        case .ico: .init(read: true, write: true, notes: "RGBA")
        case .pnm: .init(read: true, write: true, notes: "PBM/PGM/PPM/PAM/PFM, 8/16/32f")
        case .pcx: .init(read: true, write: false, notes: "import only")
        case .qoi: .init(read: true, write: true, notes: "")
        case .openEXR: .init(read: true, write: true, notes: "f16/f32; deep EXR and Cryptomatte readers, multi-part")
        case .hdr: .init(read: true, write: true, notes: "f32")
        case .avif: .init(read: false, write: false, notes: "write behind a non-default feature; read #463")
        case .heif: .init(read: true, write: false, notes: "pure-Rust heic-rs decode; no HEVC encoder")
        case .fits: .init(read: true, write: true, notes: "8/16/32f gray or RGB, header cards kept")
        case .psd: .init(read: true, write: true, notes: "full layered PSD/PSB in photocraft-psd (PCPSD's area)")
        case .pdf: .init(read: false, write: true, notes: "raster-only write, no multi-page, no read (#2541)")
        case .cameraRaw: .init(read: true, write: false, notes: "clean-room DNG/CR2/NEF/ARW/RW2/PEF/ORF/RAF; CR3 unsupported")
        case .jpeg2000: .init(read: false, write: false, notes: "#1047")
        case .jpegXL: .init(read: false, write: false, notes: "inside DNG only")
        case .dicom: .init(read: false, write: false, notes: "")
        case .mpo: .init(read: false, write: false, notes: "")
        case .pict: .init(read: false, write: false, notes: "")
        default: .init(read: false, write: false, notes: "")
        }
    }

    // MARK: Native capabilities

    private static let readable: Set<String> = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
    private static let writable: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    /// ImageIO's readable / writable UTIs on this OS (measured at run time).
    public static var imageIOReadableTypes: [String] { readable.sorted() }
    public static var imageIOWritableTypes: [String] { writable.sorted() }

    /// The native port's capabilities (measured; see the file header).
    public var caps: FormatCaps {
        let r = Self.readable.contains(uti), w = Self.writable.contains(uti)
        let io: (Bool, Bool) -> (CodecBackend, CodecBackend) = { r, w in (r ? .imageIO : .none, w ? .imageIO : .none) }
        let rgbGray: [ChannelLayout] = [.gray, .grayA, .rgb, .rgba]
        func c(_ read: Bool, _ write: Bool, _ rb: CodecBackend, _ wb: CodecBackend, depths: [CodecDepth] = [.u8],
               layouts: [ChannelLayout] = [.rgb, .rgba], alpha: Bool = true, icc: Bool = false, exif: Bool = false,
               xmp: Bool = false, dpi: Bool = false, text: Bool = false, animation: Bool = false, lossy: Bool = false) -> FormatCaps {
            FormatCaps(read: read, write: write, readBackend: rb, writeBackend: wb, depths: depths, layouts: layouts, alpha: alpha,
                       icc: icc, exif: exif, xmp: xmp, dpi: dpi, text: text, animation: animation, lossy: lossy)
        }
        let (rb, wb) = io(r, w)
        switch self {
        case .png: return c(r, w, rb, wb, depths: [.u8, .u16], layouts: rgbGray, icc: true, exif: true, xmp: true, dpi: true, text: true, animation: true)
        case .jpeg: return c(r, w, rb, wb, layouts: [.gray, .rgb, .cmyk], alpha: false, icc: true, exif: true, xmp: true, dpi: true, lossy: true)
        case .tiff: return c(r, w, rb, wb, depths: [.u8, .u16, .f16, .f32], layouts: ChannelLayout.allCases, icc: true, exif: true, xmp: true, dpi: true, text: true, animation: true)
        case .webp: return c(r, true, rb, .webpSwift, icc: false, exif: false, xmp: false, animation: false, lossy: true)
        case .gif: return c(r, w, rb, wb, layouts: [.rgba], animation: true, lossy: true)
        case .bmp: return c(r, w, rb, wb)
        case .tga: return c(r, w, rb, wb, layouts: rgbGray)
        case .ico, .cur: return c(r, w, rb, wb, layouts: [.rgba])
        // ImageIO reads P1–P3, P5–P7 and PF/Pf; PCPlatform adds P4 and the binary writer.
        case .pnm: return c(r, true, rb, .ported, depths: [.u8, .u16, .f32], layouts: rgbGray)
        case .pcx: return c(true, false, .ported, .none, layouts: [.rgb], alpha: false)
        case .qoi: return c(true, true, .ported, .ported)
        // ImageIO's writer always adds an A channel to RGB (an opaque one), so RGB reads back RGBA.
        case .openEXR: return c(r, w, rb, wb, depths: [.f16, .f32], layouts: [.gray, .rgba])
        case .hdr: return c(r, true, rb, .ported, depths: [.f32], layouts: [.rgb], alpha: false, lossy: true)
        case .avif, .heif: return c(r, w, rb, wb, depths: [.u8, .u16], icc: true, exif: true, xmp: true, lossy: true)
        case .heics: return c(r, w, rb, wb, depths: [.u8], icc: true, animation: true, lossy: true)
        case .fits: return c(true, true, .ported, .ported, depths: [.u8, .u16, .f32], layouts: [.gray, .rgb], alpha: false, text: true)
        // Flattened only (layers are PCPSD's). Measured: ImageIO's PSD with alpha comes back with
        // colour multiplied by alpha, so alpha is not offered.
        case .psd: return c(r, w, rb, wb, depths: [.u8, .u16], layouts: [.gray, .rgb, .cmyk], alpha: false, icc: true, exif: true, xmp: true, dpi: true)
        case .jpeg2000: return c(r, w, rb, wb, icc: true, lossy: true)
        case .jpegXL: return c(r, false, rb, .none, depths: [.u8, .u16], icc: true)
        case .dds: return c(r, false, rb, .none)   // listed writable, but every write measured fails
        case .icns: return c(r, w, rb, wb, layouts: [.rgba])
        case .pict, .sgi, .dicom, .mpo: return c(r, false, rb, .none)
        case .astc, .ktx, .ktx2, .pvr, .atx: return c(r, w, rb, wb, layouts: [.rgba], lossy: true)
        case .cameraRaw: return c(true, false, .cameraRaw, .none, depths: [.u16, .f32], layouts: [.rgb], alpha: false, icc: true, exif: true, xmp: true)
        case .pdf: return c(true, true, .pdf, .pdf, layouts: [.rgb, .rgba, .gray, .cmyk], icc: true, animation: true)
        }
    }

    // MARK: Lookup

    /// Looks a format up by extension, file name or path (photocraft `from_extension`).
    public static func from(extension ext: String) -> ImageFormat? {
        let e = (ext.split(whereSeparator: { $0 == "." || $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ext).lowercased()
        return allCases.first { $0.extensions.contains(e) }
    }

    /// The format of an ImageIO type identifier (every camera-raw UTI maps to `.cameraRaw`).
    public static func from(uti: String) -> ImageFormat? {
        if let f = allCases.first(where: { $0.uti == uti }) { return f }
        switch uti {
        case "public.heif", "public.avci": return .heif
        case "public.avis": return .avif
        default: break
        }
        if let t = UTType(uti), t.conforms(to: .rawImage) { return .cameraRaw }
        return nil
    }

    /// Identifies a format from its leading bytes (photocraft `detect`), falling back to ImageIO's
    /// own sniffing for the formats it adds.
    public static func detect(_ data: Data) -> ImageFormat? {
        let b = [UInt8](data.prefix(64))
        func starts(_ s: [UInt8]) -> Bool { b.count >= s.count && Array(b[0..<s.count]) == s }
        func ascii(_ s: String) -> Bool { starts(Array(s.utf8)) }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts([0xFF, 0xD8, 0xFF]) {
            // MPO is a JPEG with an MP Extensions APP2; ImageIO tells them apart.
            return sniff(data) == .mpo ? .mpo : .jpeg
        }
        if ascii("II*\0") || ascii("MM\0*") || ascii("II+\0") || ascii("MM\0+") {
            // DNG and most camera raws are TIFF containers; ImageIO tells them apart.
            if let s = sniff(data), s == .cameraRaw { return .cameraRaw }
            return .tiff
        }
        if b.count >= 12, ascii("RIFF"), Array(b[8..<12]) == Array("WEBP".utf8) { return .webp }
        if ascii("GIF87a") || ascii("GIF89a") { return .gif }
        if ascii("qoif") { return .qoi }
        if starts([0x76, 0x2F, 0x31, 0x01]) { return .openEXR }
        if ascii("#?RADIANCE") || ascii("#?RGBE") { return .hdr }
        if ascii("%PDF") { return .pdf }
        if ascii("8BPS") { return .psd }
        if b.count >= 12, Array(b[4..<8]) == Array("ftyp".utf8) {
            let brands = stride(from: 8, to: min(b.count, 40) - 3, by: 4).map { String(decoding: b[$0..<$0 + 4], as: UTF8.self) }
            if brands.contains("avif") || brands.contains("avis") { return .avif }
            if brands.contains(where: { ["heic", "heix", "heim", "heis", "mif1", "miaf"].contains($0) }) {
                return brands.contains("msf1") || brands.contains("hevc") ? .heics : .heif
            }
            if brands.contains("crx ") { return .cameraRaw }
        }
        if b.count >= 14, ascii("BM") { return .bmp }
        if b.count >= 6, b[0] == 0, b[1] == 0, b[2] == 1 || b[2] == 2, b[3] == 0, b[4] != 0 || b[5] != 0 { return b[2] == 1 ? .ico : .cur }
        if b.count >= 3, b[0] == UInt8(ascii: "P"), "1234567Ff".utf8.contains(b[1]), [9, 10, 13, 32].contains(b[2]) { return .pnm }
        if ascii("SIMPLE  =") { return .fits }
        if ascii("DDS ") { return .dds }
        if ascii("icns") { return .icns }
        if b.count >= 4, b[0] == 0x0A, b[1] <= 5, b[2] == 1, [1, 2, 4, 8].contains(b[3]) { return .pcx }
        return sniff(data)
    }

    /// ImageIO's identification.
    static func sniff(_ data: Data) -> ImageFormat? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let t = CGImageSourceGetType(src) as String? else { return nil }
        return from(uti: t)
    }
}
