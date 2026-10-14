// The `.pcraft` previews from one reduced composite (AB-T-0259): within a level of the two
// full-resolution composites 0.3.0 rendered them from, through PCRender's own reduction and
// through the band-by-band default; and the second reduction taken from the first.

import CoreGraphics
import Foundation
import PCDocument
import PCFormat
import PCFoundation
import PCIOCore
import PCRender
import simd
import Testing
@testable import PCIO

@Suite struct PreviewTests {
    /// Two layers: a soft-edged disc with noise over a half-transparent gradient.
    static func document(_ w: Int, _ h: Int, mode: ColorMode = .rgb, depth: SampleType = .u8) -> Document {
        var d = Document(name: "previews", size: PixelSize(width: w, height: h), mode: mode, depth: depth)
        let fmt = d.pixelFormat
        let canvas = PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h))
        func layer(_ name: String, _ px: (Int, Int) -> SIMD4<Float>) -> Layer {
            var l = Layer.raster(name, format: fmt)
            var values = [Float]()
            values.reserveCapacity(w * h * fmt.channels)
            for y in 0 ..< h { for x in 0 ..< w { values += fmt.components(fromRGBA: px(x, y)) } }
            l.withRaster { $0.writeRegion(canvas, values) }
            return l
        }
        let gradient = layer("gradient") { x, y in SIMD4(Float(x) / Float(w), 0.4, Float(y) / Float(h), 0.5 + 0.5 * Float(x) / Float(w)) }
        let disc = layer("disc") { x, y in
            let dx = Float(x) - Float(w) / 2, dy = Float(y) - Float(h) / 2
            let r = (dx * dx + dy * dy).squareRoot() / Float(min(w, h))
            let noise = Float((x &* 73_856_093 ^ y &* 19_349_663) & 255) / 255
            return SIMD4(0.9, 0.3 + 0.4 * noise, 0.2, max(0, min(1, (0.4 - r) * 20)))
        }
        d.layers = [gradient, disc]
        return d
    }

    /// The previews as 0.3.0 rendered them: a full-resolution composite for each.
    static func before(_ doc: Document, _ compositor: some PCIOCore.DocumentCompositor) throws -> (RGBA8Image, RGBA8Image) {
        func one(_ side: Int) throws -> RGBA8Image {
            let (px, w, h) = try PSDThumbnail.thumbnailRGBA(doc, compositor: compositor, side: side)
            return DocumentIO.rgba8(px, w, h)
        }
        return (try one(256), try one(1024))
    }

    /// The largest difference of any channel, in levels (sizes must match).
    static func levels(_ a: RGBA8Image?, _ b: RGBA8Image) -> Int {
        guard let a, a.width == b.width, a.height == b.height else { return .max }
        return zip(a.data, b.data).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }

    static let cases: [(ColorMode, SampleType, Bool)] = [(.rgb, .u8, true), (.rgb, .u16, true), (.cmyk, .u8, true), (.grayscale, .u8, false)]

    /// Where the canvas divides into the previews' cells evenly (2048 × 1024 to 1024 × 512 and
    /// 256 × 128), the previews are those 0.3.0 rendered, within a level: RGB through PCRender's
    /// reduction, CMYK and gray through the band-by-band default.
    @Test(arguments: cases.indices) func previewsAreWithinALevelOfTwoFullComposites(_ i: Int) throws {
        let (mode, depth, pcrender) = Self.cases[i]
        let d = Self.document(2048, 1024, mode: mode, depth: depth)
        let compositor: any PCIOCore.DocumentCompositor = pcrender ? RenderCompositor(backend: .cpu) : StoredPixelsCompositor()
        let previews = try DocumentIO.pcraftPreviews(d, options: IOOptions(compositor: compositor))
        let (thumbnail, composite) = try Self.before(d, compositor)
        #expect(previews.composite?.width == 1024 && previews.composite?.height == 512)
        #expect(previews.thumbnail?.width == 256 && previews.thumbnail?.height == 128)
        #expect(Self.levels(previews.composite, composite) <= 1, "\(mode) \(depth)")
        #expect(Self.levels(previews.thumbnail, thumbnail) <= 1, "\(mode) \(depth)")
    }

    /// PCRender's reduction is the default's, cell for cell, where the cells are uneven too.
    @Test func pcrendersReductionIsTheDefaults() throws {
        let d = Self.document(1500, 700)
        let c = RenderCompositor(backend: .cpu)
        let fast = try c.reduced(d, width: 1024, height: 478)
        let bands = try ReducedComposite.reduce(d, width: 1024, height: 478, compositor: c)
        #expect(fast.count == bands.count)
        // The default reads the composite back through 8-bit samples, colour and alpha each within
        // half a level: within a level, straight or premultiplied.
        func premultiplied(_ p: SIMD4<Float>) -> SIMD4<Float> { SIMD4(p.x * p.w, p.y * p.w, p.z * p.w, p.w) }
        let worst = zip(fast, bands).reduce(Float(0)) { max($0, simd_reduce_max(simd_abs(premultiplied($1.0) - premultiplied($1.1)))) }
        let straight = zip(fast, bands).reduce(Float(0)) { max($0, simd_reduce_max(simd_abs($1.0 - $1.1))) }
        #expect(worst * 255 <= 1 && straight * 255 <= 1, "\(worst * 255) levels premultiplied, \(straight * 255) straight")
    }

    /// A reduction taken from a reduction is the canvas's own where the first one's cells fall on
    /// the second's, and close where they don't.
    @Test func aSecondReductionComesFromTheFirst() throws {
        func image(_ w: Int, _ h: Int, _ px: (Int, Int) -> SIMD4<Float>) -> FixedCompositor {
            var values = [Float]()
            for y in 0 ..< h { for x in 0 ..< w { let p = px(x, y); values += [p.x, p.y, p.z, p.w] } }
            return FixedCompositor(pixels: values, size: PixelSize(width: w, height: h))
        }
        func worst(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Float {
            zip(a, b).reduce(0) { max($0, simd_reduce_max(simd_abs($1.0 - $1.1))) }
        }
        // Noise, alpha included: 96 × 64 → 48 × 32 → 12 × 8 is exact.
        var seed: UInt64 = 7
        func next() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(seed >> 40) / Float(1 << 24)
        }
        var noise = [SIMD4<Float>]()
        for _ in 0 ..< 96 * 64 { noise.append(SIMD4(next(), next(), next(), next())) }
        let size = PixelSize(width: 96, height: 64)
        var doc = Document(name: "n", size: size, mode: .rgb, depth: .f32)
        let c = image(96, 64) { x, y in noise[y * 96 + x] }
        doc.layers = []
        let first = try c.reduced(doc, width: 48, height: 32)
        let second = ReducedComposite.reduce(first, width: 48, height: 32, of: size, to: 12, 8)
        #expect(worst(second, try c.reduced(doc, width: 12, height: 8)) < 1e-5)
        // The canvas's own size as the first: the second is the canvas's reduction exactly.
        let whole = try c.reduced(doc, width: 96, height: 64)
        #expect(worst(ReducedComposite.reduce(whole, width: 96, height: 64, of: size, to: 10, 7), try c.reduced(doc, width: 10, height: 7)) < 1e-5)
        // Uneven cells (100 × 70 → 30 × 21 → 7 × 5) on a smooth gradient: within a level.
        let smooth = image(100, 70) { x, y in SIMD4(Float(x) / 100, Float(y) / 70, 0.5, 0.25 + 0.75 * Float(x + y) / 170) }
        var sdoc = Document(name: "s", size: PixelSize(width: 100, height: 70), mode: .rgb, depth: .f32)
        sdoc.layers = []
        let coarse = ReducedComposite.reduce(try smooth.reduced(sdoc, width: 30, height: 21), width: 30, height: 21, of: sdoc.size, to: 7, 5)
        #expect(worst(coarse, try smooth.reduced(sdoc, width: 7, height: 5)) * 255 <= 1)
    }

    /// A document no larger than the composite preview keeps its full size there, and its
    /// thumbnail is reduced from the canvas itself.
    @Test func smallDocumentsReduceFromTheirOwnPixels() throws {
        let d = Self.document(300, 200)
        let c = RenderCompositor(backend: .cpu)
        let previews = try DocumentIO.pcraftPreviews(d, options: IOOptions(compositor: c))
        #expect(previews.composite?.width == 300 && previews.composite?.height == 200)
        let direct = DocumentIO.rgba8(try ReducedComposite.reduce(d, width: 256, height: 171, compositor: c), 256, 171)
        #expect(Self.levels(previews.thumbnail, direct) <= 1)
    }

    /// The damaged cells PCRender reduces are the whole reduction's, and previews updated from them
    /// are the previews rendered whole.
    @Test func damagedCellsAreTheWholeReductions() throws {
        var d = Self.document(1500, 700)
        let c = RenderCompositor(backend: .cpu)
        let options = IOOptions(compositor: c)
        let before = try DocumentIO.pcraftPreviews(d, options: options, updating: nil)
        let damage = PixelRect(x0: 400, y0: 200, x1: 520, y1: 260)
        d.layers[1].withRaster { $0.fill(damage, with: [0, 0, 1, 1]) }
        let (rect, pixels) = try c.reduced(d, width: 1024, height: 478, damage: damage)
        #expect(rect == ReducedComposite.cells(meeting: damage, canvas: d.size, width: 1024, height: 478) && !rect.isEmpty)
        let whole = try c.reduced(d, width: 1024, height: 478)
        #expect(pixels == ReducedComposite.crop(whole, width: 1024, rect))
        let updated = try DocumentIO.pcraftPreviews(d, options: options, updating: (before, damage))
        let fresh = try DocumentIO.pcraftPreviews(d, options: options, updating: nil)
        #expect(updated.reduction == fresh.reduction)
        #expect(updated.options.composite == fresh.options.composite && updated.options.thumbnail == fresh.options.thumbnail)
        // Damage off the canvas changes nothing.
        let off = try DocumentIO.pcraftPreviews(d, options: options, updating: (fresh, PixelRect(x0: -50, y0: 0, x1: -10, y1: 10)))
        #expect(off.reduction == fresh.reduction)
    }

    /// A file's previews stand for the reduction only at the sizes a save writes, and only for a
    /// document they need no conversion for.
    @Test func storedPreviewsStandForTheReductionOnlyAsWritten() throws {
        let d = Self.document(1500, 700)
        let fresh = try DocumentIO.pcraftPreviews(d, options: IOOptions(compositor: RenderCompositor(backend: .cpu)), updating: nil)
        let stored = try #require(PcraftPreviews(stored: fresh.options, of: d))
        #expect(stored.width == 1024 && stored.height == 478)
        #expect(zip(stored.reduction, fresh.reduction).allSatisfy { simd_reduce_max(simd_abs($0 - $1)) <= 0.5 / 255 + 1e-6 })
        #expect(PcraftPreviews(stored: SaveOptions(thumbnail: fresh.options.thumbnail), of: d) == nil)
        var profiled = d
        profiled.iccProfile = CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData().map { [UInt8]($0 as Data) }
        #expect(PcraftPreviews(stored: fresh.options, of: profiled) == nil)
    }
}
