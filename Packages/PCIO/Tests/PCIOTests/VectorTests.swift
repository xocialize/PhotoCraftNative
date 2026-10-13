// Port of photocraft-io (crates/io/tests/vector.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Vector data ⇄ PSD: synthetic round trips of paths, shape layers and vector masks through
// whole-file export and import (the block-level halves are PCIOMapsTests' VectorMapTests), plus
// the corpus check that unedited shapes and vector masks export with byte-identical vector blocks,
// run over the Photoshop corpus (PCPSD_CORPUS).
//
// Shape caches and the composite's vector-mask coverage come from the CoreGraphics stand-in for
// photocraft-vector (MapsKit.CGRasterizer). Not ported: `corpus_shape_coverage_matches_photoshop`
// (it measures photocraft-vector's rasterizer against Photoshop's pixels; the engine's vector
// renderer is PCPlatform's, not PCIO's).

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import Testing
@testable import PCIO

@Suite struct VectorTests {
    init() { ExportSweep.install() }
    /// Coordinates on a 64-px grid are exact in PSD's 8.24 fixed point for a 256-px canvas.
    static func path() -> VectorPath {
        VectorPath([
            Subpath(closed: true, knots: [
                Knot.corner(16, 16),
                Knot.smooth(anchor: PCPoint(128, 32), inCtrl: PCPoint(96, 16), outCtrl: PCPoint(160, 48)),
                Knot.corner(64, 192),
            ], op: .combine),
            Subpath.polygon([(32, 32), (64, 32), (64, 64)]).withOp(.subtract),
            Subpath.polyline([(200, 10), (250, 60)]).withOp(.exclude),
        ])
    }

    static func doc() -> Document {
        Document.withBackground(name: "v", size: PixelSize(width: 256, height: 256), mode: .rgb, depth: .u8, fill: .white)
    }

    static func shapeLayer(_ sh: ShapeLayer) -> Layer { MapsKit.shapeLayer("Shape", sh, canvas: rect(0, 0, 256, 256)) }

    static func roundtrip(_ d: Document, photoshop: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws -> Document {
        try MapsKit.roundtrip(d, options: MapsKit.options(photoshop: photoshop), sourceLocation: sourceLocation)
    }

    @Test(arguments: [false, true]) func savedPathsWorkPathAndClippingRoundtrip(_ photoshop: Bool) throws {
        var d = Self.doc()
        d.paths.append(NamedPath(name: "Outline", path: Self.path(), psdRaw: nil))
        var inv = Self.path()
        inv.inverted = true
        d.paths.append(NamedPath(name: "Inverted", path: inv, psdRaw: nil))
        d.workPath = VectorPath([Subpath.polygon([(0, 0), (128, 0), (128, 128)])])
        d.clippingPath = ClippingPath(name: "Outline", flatness: 0)
        let b = try Self.roundtrip(d, photoshop: photoshop)
        #expect(b.paths.count == 2)
        guard b.paths.count == 2 else { return }
        #expect(b.paths[0].name == "Outline")
        #expect(b.paths[0].path == d.paths[0].path)
        #expect(b.paths[1].path == d.paths[1].path)
        #expect(b.workPath == d.workPath)
        #expect(b.clippingPath?.name == "Outline")
        // Unedited paths are written back byte-identical; edited ones are regenerated.
        let raw0 = try #require(b.paths[0].psdRaw)
        var b2 = b
        b2.paths[1].path.subpaths.removeLast()
        let c = try Self.roundtrip(b2, photoshop: photoshop)
        #expect(c.paths[0].psdRaw == raw0)
        #expect(c.paths[1].path == b2.paths[1].path)
        // Removing the clipping path drops the preserved resource.
        var b3 = c
        b3.clippingPath = nil
        #expect(try Self.roundtrip(b3, photoshop: photoshop).clippingPath == nil)
    }

    @Test(arguments: [false, true]) func shapeLayerTypedRoundtrip(_ photoshop: Bool) throws {
        var d = Self.doc()
        let sh = ShapeLayer(path: Self.path(), fill: .solid(.rgb(1, 0, 0)),
                            stroke: ShapeStroke(width: 4, paint: .solid(.rgb(0, 0, 1)), opacity: 0.5, align: .inside, cap: .round, join: .round,
                                                miterLimit: 100, dashes: [2, 1], dashOffset: 0),
                            live: nil)
        d.layers.append(Self.shapeLayer(sh))
        var ell = ShapeLayer(path: MapsKit.ellipsePath(64, 64, 128, 64), fill: nil, stroke: ShapeStroke(), live: .ellipse(rect: SIMD4(64, 64, 128, 64)))
        ell.path.subpaths[0].op = .combine
        d.layers.append(Self.shapeLayer(ell))
        let b = try Self.roundtrip(d, photoshop: photoshop)
        guard case let .shape(s) = b.layers[1].content else {
            Issue.record("not a shape: \(b.layers[1].content.kindName)")
            return
        }
        #expect(s.path == sh.path)
        #expect(s.fill == sh.fill)
        let st = try #require(s.stroke)
        let want = try #require(sh.stroke)
        #expect(st.width == want.width && st.align == want.align && st.cap == want.cap && st.join == want.join && st.dashes == want.dashes)
        #expect(abs(st.opacity - 0.5) < 1e-6)
        #expect(s.cache != nil)
        guard case let .shape(e) = b.layers[2].content else {
            Issue.record("not a shape: \(b.layers[2].content.kindName)")
            return
        }
        #expect(e.fill == nil)
        #expect(e.live == ell.live)
        // Kappa handles are quantized to PSD's 8.24 fixed point (1/65536 of 256 px).
        func pts(_ p: VectorPath) -> [PCPoint] { p.subpaths.flatMap { $0.knots.flatMap { [$0.anchor, $0.inCtrl, $0.outCtrl] } } }
        #expect(pts(e.path).count == pts(ell.path).count)
        for (a, q) in zip(pts(e.path), pts(ell.path)) { #expect(abs(a.x - q.x) < 1e-4 && abs(a.y - q.y) < 1e-4) }
        // A second round trip keeps every vector block byte-identical.
        let c = try Self.roundtrip(b, photoshop: photoshop)
        for i in 1 ..< 3 {
            func keys(_ l: Layer) -> [PSDLayerBlock] { l.psdBlocks.filter { ["vmsk", "vsms", "vstk", "vogk", "vscg", "SoCo"].contains($0.key) } }
            #expect(keys(c.layers[i]) == keys(b.layers[i]), "layer \(i)")
        }
    }

    @Test func customStrokeStylesRoundtripThroughPSDVstk() throws {
        for align in [StrokeAlign.inside, .center, .outside] {
            for (cap, join) in [(LineCap.butt, LineJoin.miter), (.round, .round), (.square, .bevel)] {
                for depth in [SampleType.u8, .u16, .f32] {
                    var d = Self.doc()
                    d.depth = depth
                    let want = ShapeStroke(width: 5, paint: .solid(.rgb(0, 0, 1)), opacity: 0.5, align: align, cap: cap, join: join, miterLimit: 2,
                                           dashes: [0, 2, 4, 1], dashOffset: -0.5)
                    let sh = ShapeLayer(path: VectorPath([Subpath.polygon([(32, 32), (160, 32), (96, 160)])]), stroke: want)
                    d.layers.append(Self.shapeLayer(sh))
                    let back = try MapsKit.roundtrip(d)
                    guard case let .shape(result) = back.layers[1].content else {
                        Issue.record("not a shape")
                        continue
                    }
                    #expect(result.stroke == want, "\(align) \(cap) \(join) \(depth)")
                    // The same rendering before and after (the stand-in renderer).
                    let clip = d.bounds
                    let before = MapsKit.renderShape(sh, format: .rgba8, clip: clip)?.readRGBA(clip)
                    let after = MapsKit.renderShape(result, format: .rgba8, clip: clip)?.readRGBA(clip)
                    #expect(before == after, "\(align) \(cap) \(join) \(depth)")
                }
            }
        }
    }

    @Test(arguments: [false, true]) func vectorMaskRoundtripAndRemoval(_ photoshop: Bool) throws {
        var d = Self.doc()
        var l = Layer.raster("pix", format: d.pixelFormat)
        l.withRaster { $0.fill(rect(0, 0, 256, 256), with: [0, 0, 0, 1]) }
        var vm = VectorMask(path: VectorPath([Subpath.polygon([(0, 0), (128, 0), (128, 256), (0, 256)])]))
        vm.linked = false
        l.vectorMask = vm
        d.layers.append(l)
        let b = try Self.roundtrip(d, photoshop: photoshop)
        #expect(b.layers[1].vectorMask == vm)
        #expect(b.layers[1].psdBlocks.contains { $0.key == "vmsk" })
        // The composite honours it (left half black, right half white).
        let f = try MapsKit.flatten(b)
        #expect(f.get(10, 10).x < 0.01 && f.get(200, 10).x > 0.99)
        // Removing the vector mask removes the block.
        var c = b
        c.layers[1].vectorMask = nil
        let e = try Self.roundtrip(c, photoshop: photoshop)
        #expect(e.layers[1].vectorMask == nil)
        #expect(!e.layers[1].psdBlocks.contains { $0.key == "vmsk" || $0.key == "vsms" })
        // Groups carry vector masks too.
        var g = Self.doc()
        var grp = Layer.group("G", [Layer.raster("in", format: g.pixelFormat)])
        grp.vectorMask = vm
        g.layers.append(grp)
        #expect(try Self.roundtrip(g, photoshop: photoshop).layers[1].vectorMask != nil)
    }

    /// Unedited corpus shapes and vector masks export with byte-identical vector blocks (and saved
    /// paths with identical resources).
    @Test(.enabled(if: Corpus.available, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)")) func corpusVectorBlocksSurviveRoundtrip() throws {
        let keys: [FourCC] = ["vmsk", "vsms", "vogk", "vstk", "vscg", "SoCo"]
        var checked = 0
        // photocraft's export options (its record shape), PCRender for the merged image (the
        // exports reach the Photoshop oracle).
        let options = MapsKit.options()
        for url in Corpus.files {
            let name = url.lastPathComponent
            let file = try PSDFile(contentsOf: url)
            let d = try MapsKit.psdToDocument(file)
            let out = try MapsKit.export(d, "x.psd", options: options)
            let back = try PSDFile(bytes: out.bytes)
            func blocks(_ f: PSDFile) -> [String] {
                f.layers.flatMap { l in l.blocks.filter { keys.contains($0.key) }.map { "\(l.displayName)/\($0.key.string):\([UInt8]($0.data))" } }
            }
            let (a, b) = (blocks(file), blocks(back))
            checked += a.count
            for x in a where !b.contains(x) { Issue.record("\(name): \(x.prefix(60)) changed or missing") }
            // Saved paths too.
            for r in file.resources where (2000 ... 2997).contains(r.id) {
                #expect(back.resources.contains { $0.id == r.id && $0.data == r.data }, "\(name): path resource \(r.id)")
            }
        }
        print("vector corpus: \(checked) vector blocks byte-identical after round trip")
        #expect(checked > 0)
    }
}
