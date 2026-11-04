// An opened flat image's Background (AB-T-0422, AB-T-0423): its surface reads transparent where it has no tile, as a
// File › New Background does, so a tile of opaque black is content and not the surface's default.

import CoreGraphics
import Foundation
import ImageIO
@testable import PCEngine
import PCDocument
import PCFoundation
import Testing
import UniformTypeIdentifiers

@Suite struct OpenedBackgroundTests {
    /// An opaque 8-bit sRGB JPEG of one colour (no alpha channel), at `quality` 1 so its pixels stay that colour.
    static func solidJPEG(_ dir: URL, _ name: String, width: Int, height: Int, rgb: (UInt8, UInt8, UInt8)) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0 ..< width * height { px[i * 4] = rgb.0; px[i * 4 + 1] = rgb.1; px[i * 4 + 2] = rgb.2; px[i * 4 + 3] = 255 }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test func anOpenedJPEGsBackgroundIsTransparentWhereItHasNoTile() throws {
        let dir = try ioDir("opened-bg")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Self.solidJPEG(dir, "black-64.jpg", width: 64, height: 64, rgb: (0, 0, 0))
        let s = Session()
        try s.execute("file.open", ["path": .string(url.path)])
        let doc = try #require(s.active?.doc)
        let bg = try #require(doc.background)
        let surface = try #require(bg.surface)
        #expect(surface.format.alpha)
        #expect(surface.defaultPixelValue.allSatisfy { $0 == 0 })
        #expect(surface.contentBounds == doc.bounds)
        #expect(surface.rgba(x: 10, y: 10) == SIMD4(0, 0, 0, 1))
    }

    @Test func canvasSizeKeepsASolidBlackBackgroundsPixels() throws {
        let dir = try ioDir("opened-bg-canvas")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Self.solidJPEG(dir, "black-64.jpg", width: 64, height: 64, rgb: (0, 0, 0))
        let s = Session()
        try s.execute("file.open", ["path": .string(url.path)])
        try s.execute("image.canvasSize", ["width": 80, "height": 80, "anchor": "center", "extensionColor": "white"])
        let surface = try #require(s.active?.doc.background?.surface)
        #expect(surface.rgba(x: 40, y: 40) == SIMD4(0, 0, 0, 1))
        #expect(surface.rgba(x: 8, y: 8) == SIMD4(0, 0, 0, 1))
        #expect(surface.rgba(x: 71, y: 71) == SIMD4(0, 0, 0, 1))
        #expect(surface.rgba(x: 7, y: 40) == SIMD4(1, 1, 1, 1))
        #expect(surface.rgba(x: 72, y: 72) == SIMD4(1, 1, 1, 1))
    }

    /// A grey photo-like JPEG opens as before: its pixels, size and Background (the fix only changes what the surface
    /// reads past them).
    @Test func anOpenedJPEGKeepsItsPixelsAndBackgroundAtEveryDepth() throws {
        let dir = try ioDir("opened-bg-depth")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Self.solidJPEG(dir, "grey.jpg", width: 300, height: 200, rgb: (128, 128, 128))
        let s = Session()
        try s.execute("file.open", ["path": .string(url.path)])
        for depth in ["image.mode.bits32", "image.mode.bits16"] {
            try s.execute(depth)
            let doc = try #require(s.active?.doc)
            let surface = try #require(doc.background?.surface)
            #expect(surface.defaultPixelValue.allSatisfy { $0 == 0 }, "\(depth)")
            #expect(surface.contentBounds == doc.bounds, "\(depth)")
            let mid = surface.rgba(x: 150, y: 100)
            #expect(mid.w == 1 && mid.x > 0.1 && mid.x < 0.9, "\(depth)")
            #expect(surface.rgba(x: 299, y: 199).w == 1, "\(depth)")
            #expect(surface.rgba(x: 300, y: 100) == .zero, "\(depth)")
        }
    }
}
