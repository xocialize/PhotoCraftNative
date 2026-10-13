// Bridging round trips: Surface ⇄ CGImage at 8, 16 and 32 bits, gray and RGB, regions off the
// origin and off the canvas, masks at every depth, foreign CGImage layouts, and photocraft's
// selection combine modes. MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import Foundation
import PCFoundation
import Testing
@testable import PCIntelligence

@Suite struct BridgingTests {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Values on each depth's grid (f32 also outside 0…1: HDR and negative).
    func value(_ i: Int, _ k: Int, _ sample: SampleType) -> Float {
        let h = UInt32(truncatingIfNeeded: (i &* 2_654_435_761) ^ (k &* 40_503)) % 65_536
        switch sample {
        case .u8: return Float(h % 256) / 255
        case .u16: return Float(h) / 65535
        case .f32: return Float(h) / 16_384 - 0.5   // −0.5 … 3.5
        }
    }

    @Test(arguments: [SampleType.u8, .u16, .f32])
    func rgbaSurfaceRoundTripIsExact(sample: SampleType) throws {
        let format = PixelFormat(mode: .rgb, sample: sample, alpha: true)
        // A region spanning tile boundaries, partly at negative coordinates (a layer larger than the canvas).
        let rect = PixelRect(x: -20, y: 250, width: 300, height: 23)
        var s = Surface(format: format)
        var data = [Float](repeating: 0, count: rect.area * 4)
        for i in 0..<rect.area { for k in 0..<4 { data[i * 4 + k] = value(i, k, sample) } }
        // Alpha stays in 0…1 at every depth.
        for i in 0..<rect.area { data[i * 4 + 3] = min(max(data[i * 4 + 3], 0), 1) }
        s.writeRegion(rect, data)
        let cs = KitBridge.defaultColorSpace(sample: sample)
        let image = try KitBridge.image(from: s, rect: rect, colorSpace: cs)
        #expect(image.bitsPerComponent == sample.bits)
        #expect(image.width == rect.width && image.height == rect.height)
        let back = try KitBridge.surface(from: image, format: format, x: rect.x0, y: rect.y0, colorSpace: cs)
        #expect(back.readRegion(rect) == s.readRegion(rect), "depth \(sample)")
        // Nothing lands outside the region.
        #expect(back.readRegion(PixelRect(x: -20, y: 249, width: 300, height: 1)).allSatisfy { $0 == 0 })
    }

    @Test(arguments: [SampleType.u8, .u16, .f32])
    func graySurfaceRoundTripsThroughRGB(sample: SampleType) throws {
        let format = PixelFormat(mode: .grayscale, sample: sample, alpha: true)
        let rect = PixelRect(x: 3, y: 5, width: 40, height: 30)
        var s = Surface(format: format)
        var data = [Float](repeating: 0, count: rect.area * 2)
        for i in 0..<rect.area { data[i * 2] = min(max(value(i, 0, sample), 0), 1); data[i * 2 + 1] = min(max(value(i, 1, sample), 0), 1) }
        s.writeRegion(rect, data)
        let cs = KitBridge.defaultColorSpace(sample: sample)
        let image = try KitBridge.image(from: s, rect: rect, colorSpace: cs)
        let back = try KitBridge.surface(from: image, format: format, x: rect.x0, y: rect.y0, colorSpace: cs)
        let a = s.readRegion(rect), b = back.readRegion(rect)
        let tol: Float = sample == .f32 ? 1e-6 : 0
        #expect(zip(a, b).allSatisfy { abs($0 - $1) <= tol }, "gray \(sample)")
    }

    @Test(arguments: [SampleType.u8, .u16, .f32])
    func masksRoundTripAtEveryDepth(sample: SampleType) throws {
        let rect = PixelRect(x: 250, y: -4, width: 17, height: 9)
        let step: Float = sample == .u16 ? 65535 : 255
        let values = (0..<rect.area).map { Float(($0 * 37) % Int(step + 1)) / step }
        let m = CoverageMask(rect: rect, values: values)
        let img = try m.image(sample: sample)
        #expect(img.bitsPerComponent == sample.bits)
        let back = try CoverageMask(image: img, rect: rect)
        #expect(back.values == values)
        // A coverage surface is Gray at the requested depth, positioned in document space.
        let s = try #require(m.surface(sample: sample))
        #expect(s.format == PixelFormat(mode: .grayscale, sample: sample, alpha: false))
        #expect(s.pixel(x: 250 + 5, y: -4 + 2).first == m[250 + 5, -4 + 2])
        #expect(s.pixel(x: 249, y: 0) == [0], "outside the mask is uncovered")
        #expect(CoverageMask(surface: s, rect: rect).values == (sample == .u8 ? m.quantized8().values : values))
    }

    @Test func foreignLayoutsAreDecoded() throws {
        // BGRA (8-bit premultiplied first, 32-bit little endian), the most common Kit output layout.
        let w = 4, h = 2
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let bgra = ctx.makeImage()!
        let px = try KitBridge.rgba(from: bgra, colorSpace: srgb, sample: .u8)
        #expect(px.allSatisfy { abs($0.x - 1) < 1e-6 && abs($0.y - Float(128) / 255) < 1e-6 && $0.z == 0 && $0.w == 1 })
        // A 16-bit big-endian RGBA image (ImageIO's PNG layout) and a gray mask in another colour space.
        let ctx16 = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: 0, space: srgb,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Big.rawValue)!
        ctx16.setFillColor(CGColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        ctx16.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let px16 = try KitBridge.rgba(from: ctx16.makeImage()!, colorSpace: srgb, sample: .u16)
        #expect(px16.allSatisfy { abs($0.x - 0.25) < 1e-4 && abs($0.y - 0.5) < 1e-4 && abs($0.z - 0.75) < 1e-4 })
        let gray = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        gray.setFillColor(gray: 0.5, alpha: 1)
        gray.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Coverage is read raw (never gamma-shifted by colour management).
        let cov = try KitBridge.coverage(from: gray.makeImage()!, width: w, height: h)
        #expect(cov.allSatisfy { abs($0 - Float(128) / 255) < 1e-6 })
    }

    @Test func coverageIsResampledToTheTargetSize() throws {
        let src: [Float] = [0, 1, 1, 0]
        let img = try KitBridge.maskImage(src, width: 2, height: 2)
        let out = try KitBridge.coverage(from: img, width: 4, height: 4)
        #expect(out.count == 16)
        #expect(out[0] == 0 && out[3] == 1 && out[12] == 1 && out[15] == 0)
        #expect(out[5] > 0.2 && out[5] < 0.8, "the middle is interpolated")
    }

    @Test func cmykAndLabGoThroughSRGB() throws {
        for mode in [ColorMode.cmyk, .lab] {
            let format = PixelFormat(mode: mode, sample: .u8, alpha: true)
            var s = Surface(format: format)
            let rect = PixelRect(x: 0, y: 0, width: 2, height: 1)
            KitBridge.write(rgba: [SIMD4(1, 0, 0, 1), SIMD4(0.5, 0.5, 0.5, 1)], into: &s, rect: rect)
            let rgba = s.readRGBA(rect)
            #expect(abs(rgba[0].x - 1) < 0.02 && rgba[0].y < 0.03 && rgba[0].z < 0.03, "\(mode) red")
            #expect(abs(rgba[1].x - 0.5) < 0.02 && abs(rgba[1].y - 0.5) < 0.02, "\(mode) grey")
            let img = try KitBridge.image(from: s, rect: rect, colorSpace: srgb)
            #expect(img.colorSpace?.model == .rgb)
        }
    }

    @Test func documentColourSpaces() {
        var d = Fixture.disc(width: 8, height: 8)
        #expect(KitBridge.colorSpace(for: d).name == CGColorSpace.sRGB)
        d.depth = .f32
        #expect(KitBridge.colorSpace(for: d).name == CGColorSpace.extendedSRGB)
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!.copyICCData()! as Data
        d.iccProfile = [UInt8](p3)
        #expect(KitBridge.colorSpace(for: d).model == .rgb)
        #expect(KitBridge.colorSpace(for: d).name != CGColorSpace.sRGB, "an embedded RGB profile is kept")
        d.mode = .cmyk
        #expect(KitBridge.colorSpace(for: d).name == CGColorSpace.extendedSRGB, "non-RGB documents cross as sRGB")
    }

    // MARK: Selection combine (photocraft combine_region)

    @Test func combineModesFollowPhotocraft() throws {
        let a = PixelRect(x: 0, y: 0, width: 10, height: 10), b = PixelRect(x: 5, y: 0, width: 10, height: 10)
        let old = Fixture.selection(a)
        let new = CoverageMask(rect: b, fill: 1)
        let replace = try #require(CoverageMask.combine(new, with: old, mode: .replace))
        #expect(replace.contentBounds == b)
        let add = try #require(CoverageMask.combine(new, with: old, mode: .add))
        #expect(add.contentBounds == a.union(b))
        let sub = try #require(CoverageMask.combine(new, with: old, mode: .subtract))
        #expect(sub.contentBounds == PixelRect(x: 0, y: 0, width: 5, height: 10))
        let inter = try #require(CoverageMask.combine(new, with: old, mode: .intersect))
        #expect(inter.contentBounds == PixelRect(x: 5, y: 0, width: 5, height: 10))
        #expect(CoverageMask.combine(new, with: nil, mode: .subtract) == nil)
        #expect(CoverageMask.combine(new, with: nil, mode: .intersect) == nil)
        #expect(CoverageMask.combine(CoverageMask(rect: a, fill: 1), with: old, mode: .subtract) == nil, "nothing left is nil")
        #expect(add.format == .gray8, "selections are GRAY8 by default")
        // Soft coverage is quantised to the 8-bit grid, so combining a mask with itself is exact.
        let soft = CoverageMask(rect: a, values: (0..<100).map { Float($0) / 99 })
        let s1 = try #require(CoverageMask.combine(soft, with: nil, mode: .replace))
        let s2 = try #require(CoverageMask.combine(soft, with: s1, mode: .add))
        #expect(s1.readRegion(a) == s2.readRegion(a))
        #expect(SelectionMode(parsing: "new") == .replace && SelectionMode(parsing: "bogus") == .replace)
    }
}
