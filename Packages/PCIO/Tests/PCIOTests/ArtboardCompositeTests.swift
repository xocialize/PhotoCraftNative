// Artboards composite their children with the children's own blend modes: an artboard holding a
// Multiply layer over a red one, against Photoshop's composite of the same file (ps-corpus
// `artboard-blend.psd`, written by the Photoshop oracle; `composites/artboard-blend.tif` is
// Photoshop's composite exported by it). New in the port; MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.

import CoreGraphics
import Foundation
import ImageIO
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import PCRender
import Testing
@testable import PCIO

@Suite struct ArtboardCompositeTests {
    init() { ExportSweep.install() }

    static var file: URL? { Corpus.psFiles.first { $0.lastPathComponent == "artboard-blend.psd" } }

    /// Photoshop's composite (`composites/artboard-blend.tif`) as 8-bit RGB, row-major.
    static func photoshopComposite() throws -> (width: Int, height: Int, rgb: [UInt8]) {
        let dir = try #require(Corpus.psDirectory).appendingPathComponent("composites/artboard-blend.tif")
        let src = try #require(CGImageSourceCreateWithURL(dir as CFURL, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let (w, h) = (img.width, img.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, (0 ..< w * h).flatMap { [px[$0 * 4], px[$0 * 4 + 1], px[$0 * 4 + 2]] })
    }

    /// `doc` composited by PCRender (`backend`) over white, as 8-bit RGB.
    static func ours(_ doc: Document, _ backend: PCRender.DocumentCompositor.Backend) throws -> [UInt8] {
        let compositor = PCRender.DocumentCompositor(rasterizer: PlaceholderRasterizer(), backend: backend)
        let px = try compositor.flatten(doc).px
        return px.flatMap { p -> [UInt8] in
            (0 ..< 3).map { c in UInt8(min(max((p[c] * p.w + (1 - p.w)) * 255, 0), 255).rounded()) }
        }
    }

    @Test(.enabled(if: ArtboardCompositeTests.file != nil, "artboard-blend.psd not present (set PHOTOCRAFT_FIXTURES or PCIO_PS_CORPUS)"))
    func artboardChildBlendModesMatchPhotoshop() throws {
        let url = try #require(Self.file)
        let doc = try DocumentIO.importFile(contentsOf: url, options: IOOptions(compositor: StoredPixelsCompositor())).document
        let (w, h, ps) = try Self.photoshopComposite()
        #expect(w == doc.size.width && h == doc.size.height)
        // The Multiply square ("Mul", (40, 40)–(95, 95) over "Red" in Artboard 1).
        let mul = (x: 60, y: 60)
        for backend in [PCRender.DocumentCompositor.Backend.cpu, .metal] {
            if backend == .metal, PCRender.DocumentCompositor(rasterizer: PlaceholderRasterizer()).metal == nil { continue }
            let rgb = try Self.ours(doc, backend)
            var maxDiff = 0, off = 0
            for i in 0 ..< w * h * 3 {
                let d = abs(Int(rgb[i]) - Int(ps[i]))
                maxDiff = max(maxDiff, d)
                if d > 2 { off += 1 }
            }
            let at = (mul.y * w + mul.x) * 3
            #expect(Array(rgb[at ..< at + 3]).enumerated().allSatisfy { abs(Int($0.element) - Int(ps[at + $0.offset])) <= 1 },
                    "\(backend): Mul square \(Array(rgb[at ..< at + 3])) vs Photoshop \(Array(ps[at ..< at + 3]))")
            #expect(maxDiff <= 2, "\(backend): max \(maxDiff) levels, \(off) samples > 2 off")
        }
    }

    /// Exported with the default compositor, the merged image carries the Multiply too.
    @Test(.enabled(if: ArtboardCompositeTests.file != nil, "artboard-blend.psd not present (set PHOTOCRAFT_FIXTURES or PCIO_PS_CORPUS)"))
    func exportedMergedImageHasTheMultiply() throws {
        let url = try #require(Self.file)
        let doc = try DocumentIO.importFile(contentsOf: url, options: IOOptions(compositor: StoredPixelsCompositor())).document
        let bytes = try DocumentIO.export(doc, as: "artboard-blend.psd", options: IOOptions()).bytes
        let merged = try MergedImage.composite(PSDFile(bytes: bytes))
        let (w, _, ps) = try Self.photoshopComposite()
        let i = 60 * w + 60
        let p = merged[i]
        let got = (0 ..< 3).map { c in Int((min(max(p[c] * p.w + (1 - p.w), 0), 1) * 255).rounded()) }
        #expect(got.enumerated().allSatisfy { abs($0.element - Int(ps[i * 3 + $0.offset])) <= 1 }, "\(got) vs \(Array(ps[i * 3 ..< i * 3 + 3]))")
    }
}
