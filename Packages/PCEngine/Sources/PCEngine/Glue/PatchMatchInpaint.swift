// Port of photocraft-engine (crates/engine/src/edit_menu_cmds.rs `content_aware_fill_as`: PatchMatch Content-Aware Fill through photocraft-algo content_aware.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// PCAlgo's PatchMatch completion as PCIntelligence's classical `inpaint` backer: set as the
// registry's built-in tier under the inpaint slot (`EngineServices`), it replaces EraseKit's
// diffusion for the Remove tool and Content-Aware Fill while no model (LaMa / MI-GAN) is registered,
// and a host emptying the slot leaves it there (AB-T-0304). Content-Aware Fill's photocraft options — colour and rotation adaptation, scale, mirror,
// seed, and the sampling area (Auto's look-alike surroundings, a custom area or channel) — arrive
// through PCIntelligence's `OptionsInpaintProvider` seam (`ContentAwareFillOptions.inpaint`); the
// Remove tool passes the defaults (the whole window, photocraft's default adaptation).

import CoreGraphics
import EraseKit
import Foundation
import PCAlgo
import PCDocument
import PCIntelligence

struct PatchMatchInpaintProvider: OptionsInpaintProvider {
    var name: String { "PatchMatch" }

    func engineName(for quality: InpaintQuality) -> String { "PCAlgo PatchMatch (content_aware::fill)" }

    /// photocraft's `FillOptions` for the seam's options.
    static func fillOptions(_ o: InpaintOptions) -> InpaintKit.FillOptions {
        InpaintKit.FillOptions(colorAdaptation: InpaintKit.colorLevel(o.colorAdaptation.rawValue),
                               rotations: InpaintKit.rotationLevel(o.rotationAdaptation.rawValue),
                               scale: o.scale, mirror: o.mirror, seed: o.seed)
    }

    func inpaint(_ image: CGImage, mask: CGImage, quality: InpaintQuality, options: InpaintOptions) async throws -> CGImage {
        let w = image.width, h = image.height
        guard w > 0, h > 0, mask.width == w, mask.height == h else { throw InpaintError.badInput }
        guard var px = Self.rgba(image) else { throw InpaintError.badInput }
        guard let m = Self.gray(mask) else { throw InpaintError.badInput }
        let hole = m.map { $0 > 127 }
        let source: [Bool]
        switch options.sampling {
        case .window: source = hole.map { !$0 }
        case .auto: source = try InpaintKit.autoSamplingWith(width: w, height: h, channels: 4, image: px, hole: hole,
                                                             interrupt: .cancelOnly { Task.isCancelled })
        case .mask(let mk): source = mk.count == w * h ? zip(mk, hole).map { $0 && !$1 } : hole.map { !$0 }
        }
        do {
            px = try InpaintKit.fillWith(width: w, height: h, channels: 4, image: px, hole: hole, source: source,
                                         options: Self.fillOptions(options), interrupt: .cancelOnly { Task.isCancelled })
        } catch is InpaintKit.Cancelled {
            throw CancellationError()
        }
        guard let out = Self.image(px, w, h) else { throw InpaintError.badInput }
        return out
    }

    enum InpaintError: Error { case badInput }

    // MARK: CGImage ⇄ straight RGBA floats (sRGB)

    static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    static func rgba(_ img: CGImage) -> [Float]? {
        let w = img.width, h = img.height
        var buf = [Float](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16,
                                      space: space, bitmapInfo: info) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        for i in stride(from: 0, to: buf.count, by: 4) {
            let a = buf[i + 3]
            if a > 1e-7 { for k in 0..<3 { buf[i + k] /= a } } else { buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0 }
        }
        return buf
    }

    static func gray(_ img: CGImage) -> [UInt8]? {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }

    static func image(_ straight: [Float], _ w: Int, _ h: Int) -> CGImage? {
        var buf = straight
        for i in stride(from: 0, to: buf.count, by: 4) {
            let a = min(max(buf[i + 3], 0), 1)
            buf[i + 3] = a
            for k in 0..<3 { buf[i + k] = min(max(buf[i + k], 0), 1) * a }
        }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        return buf.withUnsafeMutableBytes { p -> CGImage? in
            CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16, space: space, bitmapInfo: info)?.makeImage()
        }
    }
}
