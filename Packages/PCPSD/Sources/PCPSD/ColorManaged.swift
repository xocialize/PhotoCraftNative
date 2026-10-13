// Colour-managed images of decoded planes through CoreGraphics: the native substitute for
// PhotoDemon's LittleCMS pipeline (pdPSDLayer.cls ConstructImage_*: CMYK and Lab through the
// embedded ICC profile or a default one, 32-bit data as linear light), BSD-2-Clause, © Tanner
// Helland and contributors. Compositor IO/PSD/PSDChannelCoder.swift (MIT, © 2026 Wonder Assembly
// LLC) converts CMYK through a CGImage in the profile's space the same way; no code copied.

import CoreGraphics
import Foundation

public enum PSDColorManagement {
    /// The colour space for a file's pixels: its embedded ICC profile when it matches the mode,
    /// otherwise Photoshop's defaults (sRGB, gray gamma 2.2, generic CMYK, Lab D50; linear for 32-bit).
    public static func colorSpace(for space: PSDPlaneSpace, depth: UInt16, icc: Data?) -> CGColorSpace? {
        if let icc, let cs = CGColorSpace(iccData: icc as CFData) {
            switch (space, cs.model) {
            case (.rgb, .rgb), (.gray, .monochrome), (.cmyk, .cmyk), (.lab, .lab): return cs
            default: break
            }
        }
        switch space {
        case .rgb: return CGColorSpace(name: depth == 32 ? CGColorSpace.extendedLinearSRGB : CGColorSpace.sRGB)
        case .gray: return CGColorSpace(name: depth == 32 ? CGColorSpace.extendedLinearGray : CGColorSpace.genericGrayGamma2_2)
        case .cmyk: return CGColorSpace(name: CGColorSpace.genericCMYK)
        case .lab:
            return CGColorSpace(labWhitePoint: [0.9642, 1.0, 0.8249], blackPoint: [0, 0, 0], range: [-128, 127, -128, 127])
        case .channels: return nil
        }
    }

    /// A 32-bit float CGImage of normalised planes in their colour space (straight alpha for RGB and
    /// Gray; CMYK and Lab without alpha). Draw it into any context for a managed conversion.
    public static func cgImage(_ img: PSDNormalizedImage, icc: Data?) -> CGImage? {
        guard let cs = colorSpace(for: img.space, depth: img.depth, icc: icc) else { return nil }
        let n = img.width * img.height
        guard n > 0 else { return nil }
        var comps: [[Float]]
        switch img.space {
        case .lab:
            comps = [img.planes[0].map { $0 * 100 }, img.planes[1].map { $0 * 255 - 128 }, img.planes[2].map { $0 * 255 - 128 }]
        default:
            comps = img.planes
        }
        let alpha = (img.space == .rgb || img.space == .gray) ? img.alpha : nil
        if let a = alpha { comps.append(a) }
        let spp = comps.count
        var buf = [Float](repeating: 0, count: n * spp)
        for c in 0 ..< spp { for i in 0 ..< n { buf[i * spp + c] = comps[c][i] } }
        let info: CGBitmapInfo = [.floatComponents, CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue),
                                  CGBitmapInfo(rawValue: (alpha != nil ? CGImageAlphaInfo.last : CGImageAlphaInfo.none).rawValue)]
        guard let provider = CGDataProvider(data: Data(bytes: buf, count: buf.count * 4) as CFData) else { return nil }
        return CGImage(width: img.width, height: img.height, bitsPerComponent: 32, bitsPerPixel: 32 * spp, bytesPerRow: img.width * spp * 4,
                       space: cs, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric)
    }

    /// The image converted to 8-bit sRGB RGBA (straight alpha).
    public static func srgbRGBA8(_ img: PSDNormalizedImage, icc: Data?) -> [UInt8]? {
        guard let cg = cgImage(img, icc: icc), let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let (w, h) = (img.width, img.height)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = out.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setBlendMode(.copy)
            ctx.setRenderingIntent(.relativeColorimetric)
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        for i in 0 ..< w * h {
            let a = Int(out[i * 4 + 3])
            guard a > 0, a < 255 else { continue }
            for k in 0 ..< 3 { out[i * 4 + k] = UInt8(min(255, (Int(out[i * 4 + k]) * 255 + a / 2) / a)) }
        }
        return out
    }
}

extension PSDFile {
    /// The merged composite as a colour-managed CGImage (the file's ICC profile, or Photoshop's
    /// default for the mode). Transparent RGB/Gray composites have the white matte removed.
    public func compositeCGImage(lenient: Bool = false) throws -> CGImage? {
        var img = try normalizedComposite(lenient: lenient)
        if (img.space == .rgb || img.space == .gray), header.colorMode != .indexed, let a = img.alpha {
            img.planes = img.planes.map { p in zip(p, a).map { c, a in a > 0 ? (c + a - 1) / a : c } }
        }
        return PSDColorManagement.cgImage(img, icc: iccProfile)
    }
}

extension PSDLayerView {
    /// The layer as a colour-managed CGImage (straight alpha), in the document's colour space.
    public func cgImage(icc: Data?, lenient: Bool = false) throws -> CGImage? {
        PSDColorManagement.cgImage(try normalized(lenient: lenient), icc: icc)
    }
}
