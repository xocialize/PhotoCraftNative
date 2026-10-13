// Tests for VectorMap. Port of photocraft-io (crates/io/src/vector_map.rs `#[cfg(test)]` and the
// map-level parts of crates/io/tests/vector.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
@testable import PCIOMaps
import PCPSD
import Testing

@Suite struct VectorMapTests {
    static func samplePath() -> VectorPath {
        var p = VectorPath([
            Subpath(closed: true, knots: [
                Knot.corner(10, 10),
                Knot.smooth(anchor: PCPoint(50, 20), inCtrl: PCPoint(40, 10), outCtrl: PCPoint(60, 30)),
                Knot.corner(20, 40),
            ], op: .combine),
            Subpath.polyline([(1, 2), (3, 4)]).withOp(.subtract),
        ])
        p.inverted = false
        return p
    }

    @Test func pathRecordsRoundtrip() {
        let p = Self.samplePath()
        let rec = VectorMap.pathToRecords(p, 64, 64)
        let back = VectorMap.pathFromRecords(rec, 64, 64)
        #expect(back == p)
        for op in PathOp.allCases {
            #expect(VectorMap.opFromPSD(VectorMap.opToPSD(op)) == op)
        }
        #expect(VectorMap.opFromPSD(-1) == .join)
        #expect(VectorMap.opFromPSD(7) == .combine)
    }

    static func vmskWith(_ initialFill: Bool, _ ops: [Int16]) -> [UInt8] {
        func square(_ x: Double) -> PSDSubpath {
            let pts = [(x, 0.25), (x + 0.25, 0.25), (x + 0.25, 0.5), (x, 0.5)].map { CGPoint(x: $0.0, y: $0.1) }
            return PSDSubpath(closed: true, operation: 0, knots: pts.map { PSDKnot(linked: false, pre: $0, anchor: $0, post: $0) })
        }
        let subs = ops.enumerated().map { i, op in
            var s = square(0.1 * Double(i))
            s.operation = op
            return s
        }
        return [UInt8](PSDVectorMask(version: 3, flags: 0, path: PSDPathData(subpaths: subs, initialFill: initialFill)).serialized())
    }

    /// psd-tools vector-mask.psd / vector-mask2.psd / vector-mask3.psd: Photoshop's initial-fill
    /// record only matters without subpaths; a leading subtract inverts; -1 continues the previous
    /// component.
    @Test func layerPathSemanticsFollowPhotoshop() throws {
        // Initial fill with a combine subpath: a plain (not inverted) shape.
        var p = try #require(VectorMap.pathFromVmsk(Self.vmskWith(true, [1]), 100, 100)).path
        #expect(!p.inverted)
        // Leading subtract: everything but the shape; later ops become their complements.
        p = try #require(VectorMap.pathFromVmsk(Self.vmskWith(true, [2, 1, 2, 0]), 100, 100)).path
        #expect(p.inverted)
        #expect(p.subpaths.map(\.op) == [.combine, .subtract, .combine, .exclude])
        // -1 continues the previous component (filled together with it, then subtracted).
        p = try #require(VectorMap.pathFromVmsk(Self.vmskWith(false, [1, 2, -1]), 100, 100)).path
        #expect(p.subpaths[2].op == .join)
        #expect(p.components == [0 ..< 1, 1 ..< 3])
        // Under a leading subtract the joined subpaths stay with their (first) component.
        p = try #require(VectorMap.pathFromVmsk(Self.vmskWith(false, [2, -1, 1]), 100, 100)).path
        #expect(p.inverted)
        #expect(p.subpaths.map(\.op) == [.combine, .join, .subtract])
        // No subpaths: a vector mask with initial fill reveals all, without hides all; a shape with
        // initial fill covers everything. (photocraft checks the rendered mask values; the vector
        // engine is not part of PCIO, so the model's reveal/hide flags are checked: a vector mask
        // without subpaths reveals everything unless inverted.)
        let reveal = try #require(VectorMap.vectorMaskFromBlock(Self.vmskWith(true, []), 100, 100))
        #expect(reveal.path.subpaths.isEmpty && !reveal.path.inverted)
        let hide = try #require(VectorMap.vectorMaskFromBlock(Self.vmskWith(false, []), 100, 100))
        #expect(hide.path.subpaths.isEmpty && hide.path.inverted)
        #expect(try #require(VectorMap.pathFromVmsk(Self.vmskWith(true, []), 100, 100)).path.inverted)
        // Our own writer round-trips each case.
        for m in [reveal, hide] {
            #expect(VectorMap.vectorMaskFromBlock(VectorMap.vectorMaskBytes(m, 100, 100), 100, 100) == m)
        }
        var lead = Self.samplePath()
        lead.subpaths[0].op = .subtract
        let back = try #require(VectorMap.pathFromVmsk(VectorMap.vmskBytes(lead, 0, 64, 64), 64, 64)).path
        #expect(!back.inverted, "a stored leading subtract is drawn as combine by the model")
    }

    @Test func vectorMaskRoundtripWithFlags() throws {
        var m = VectorMask(path: Self.samplePath())
        m.enabled = false
        m.linked = false
        m.path.inverted = true
        let b = VectorMap.vectorMaskBytes(m, 64, 64)
        let back = try #require(VectorMap.vectorMaskFromBlock(b, 64, 64))
        #expect(back == m)
        #expect(VectorMap.vectorMaskBlockMatches(b, m, 64, 64))
    }

    @Test func vstkRoundtrip() throws {
        let s = ShapeStroke(width: 4.5, paint: .solid(.rgb(1, 0, 0)), opacity: 0.5, align: .outside, cap: .round, join: .bevel,
                            miterLimit: 10, dashes: [2, 1], dashOffset: 0.5)
        let b = VectorMap.vstkBytes(s, false, 72)
        let v = try #require(VectorMap.parseVstk(b, 72))
        #expect(!v.fillEnabled)
        let got = try #require(v.stroke)
        #expect(got.width == s.width)
        #expect(got.cap == s.cap && got.join == s.join && got.align == s.align)
        #expect(got.dashes == s.dashes)
        guard case let .solid(c) = got.paint else {
            Issue.record("\(got.paint)")
            return
        }
        #expect(abs(c.rgb.x - 1) < 1e-3)
        let off = try #require(VectorMap.parseVstk(VectorMap.vstkBytes(nil, true, 72), 72))
        #expect(off.stroke == nil && off.fillEnabled)
    }

    @Test func vogkRoundtrip() throws {
        let shapes: [LiveShape] = [
            .rect(rect: SIMD4(1, 2, 30, 40), radii: .zero),
            .rect(rect: SIMD4(1, 2, 30, 40), radii: SIMD4(1, 2, 3, 4)),
            .ellipse(rect: SIMD4(5, 6, 7, 8)),
            .line(from: SIMD2(0, 10), to: SIMD2(20, 0), weight: 3),
        ]
        for s in shapes {
            let b = try #require(VectorMap.vogkBytes(s, 72))
            #expect(VectorMap.liveFromVogk(b) == s)
        }
        #expect(VectorMap.vogkBytes(.polygon(rect: .zero, sides: 5, starRatio: 1), 72) == nil)
    }

    @Test func shapeBlocksKeepUnchangedAndRegenerateChanged() throws {
        let sh = ShapeLayer(path: Self.samplePath(), fill: .solid(.rgb(0, 1, 0)), stroke: ShapeStroke(),
                            live: .ellipse(rect: SIMD4(0, 0, 10, 10)))
        var raw: RawBlocks = []
        VectorMap.shapeBlocks(sh, &raw, 64, 64, 72)
        #expect(raw.map(\.key) == ["vmsk", "vstk", "vogk"])
        let before = raw
        VectorMap.shapeBlocks(sh, &raw, 64, 64, 72)
        #expect(raw.map(\.key) == before.map(\.key) && raw.map(\.data) == before.map(\.data))
        var back = ShapeLayer()
        let snapshot = raw
        VectorMap.shapeFromBlocks(&back, { k in snapshot.first { $0.key == k }?.data }, 64, 64, 72)
        #expect(back.path == sh.path)
        #expect(back.stroke == sh.stroke)
        #expect(back.live == sh.live)
        // Edit: path changes → vmsk regenerated, live dropped when polygon.
        var edited = sh
        edited.path.subpaths.removeLast()
        edited.live = .polygon(rect: .zero, sides: 3, starRatio: 1)
        VectorMap.shapeBlocks(edited, &raw, 64, 64, 72)
        #expect(!raw.contains { $0.key == "vogk" })
        let p = try #require(VectorMap.pathFromVmsk(raw[0].data, 64, 64)).path
        #expect(p == edited.path)
    }

    // MARK: Map-level parts of tests/vector.rs

    /// Coordinates on a 64-px grid are exact in PSD's 8.24 fixed point for a 256-px canvas.
    static func gridPath() -> VectorPath {
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

    /// `saved_paths_work_path_and_clipping_roundtrip`, resource half: saved paths (plain and
    /// inverted) and the work path survive their resource encoding exactly.
    @Test func savedPathResourcesRoundtrip() throws {
        var inv = Self.gridPath()
        inv.inverted = true
        let work = VectorPath([Subpath.polygon([(0, 0), (128, 0), (128, 128)])])
        for p in [Self.gridPath(), inv, work] {
            let data = [UInt8](VectorMap.pathToRecords(p, 256, 256).serialized())
            #expect(VectorMap.pathFromResource(data, 256, 256) == p)
        }
        #expect(VectorMap.savedPaths.contains(2000) && VectorMap.savedPaths.contains(2997) && !VectorMap.savedPaths.contains(2998))
        #expect(VectorMap.workPath == 1025 && VectorMap.clippingPath == 2999)
    }

    /// `custom_stroke_styles_roundtrip_through_psd_vstk`, block half: every alignment, cap and join
    /// with dashes and a negative dash offset round-trips through `vstk`.
    @Test func customStrokeStylesRoundtripThroughVstk() throws {
        for align in StrokeAlign.allCases {
            for (cap, join) in [(LineCap.butt, LineJoin.miter), (.round, .round), (.square, .bevel)] {
                let want = ShapeStroke(width: 5, paint: .solid(.rgb(0, 0, 1)), opacity: 0.5, align: align, cap: cap, join: join,
                                       miterLimit: 2, dashes: [0, 2, 4, 1], dashOffset: -0.5)
                let sh = ShapeLayer(path: VectorPath([Subpath.polygon([(32, 32), (160, 32), (96, 160)])]), stroke: want)
                var raw: RawBlocks = []
                VectorMap.shapeBlocks(sh, &raw, 256, 256, 72)
                var back = ShapeLayer()
                VectorMap.shapeFromBlocks(&back, { k in raw.first { $0.key == k }?.data }, 256, 256, 72)
                #expect(back.stroke == want, "\(align) \(cap) \(join)")
                #expect(back.fill == nil)
                #expect(back.path == sh.path)
            }
        }
    }

    /// `shape_layer_typed_roundtrip`, block half: fill, stroke and the ellipse live shape decode
    /// back, and a second pass keeps every vector block byte-identical.
    @Test func shapeLayerBlocksRoundtrip() throws {
        let stroke = ShapeStroke(width: 4, paint: .solid(.rgb(0, 0, 1)), opacity: 0.5, align: .inside, cap: .round, join: .round,
                                 miterLimit: 100, dashes: [2, 1], dashOffset: 0)
        let a = ShapeLayer(path: Self.gridPath(), fill: .solid(.rgb(1, 0, 0)), stroke: stroke)
        let e = ShapeLayer(path: VectorPath([Subpath.polygon([(64, 64), (192, 64), (192, 128), (64, 128)])]), fill: nil,
                           stroke: ShapeStroke(), live: .ellipse(rect: SIMD4(64, 64, 128, 64)))
        for sh in [a, e] {
            // A shape written from scratch starts from its fill block, as the exporter does.
            var raw: RawBlocks = []
            if let f = sh.fill { raw.append((key: "vscg", data: VectorMap.vscgBytes(f))) }
            VectorMap.shapeBlocks(sh, &raw, 256, 256, 72)
            var back = ShapeLayer()
            VectorMap.shapeFromBlocks(&back, { k in raw.first { $0.key == k }?.data }, 256, 256, 72)
            #expect(back.path == sh.path)
            #expect(back.fill == sh.fill)
            #expect(back.stroke == sh.stroke)
            #expect(back.live == sh.live)
            let again = raw
            VectorMap.shapeBlocks(back, &raw, 256, 256, 72)
            #expect(raw.map(\.key) == again.map(\.key) && raw.map(\.data) == again.map(\.data))
        }
    }

    /// `vector_mask_roundtrip_and_removal`, block half: an unlinked vector mask round-trips.
    @Test func unlinkedVectorMaskRoundtrip() throws {
        var vm = VectorMask(path: VectorPath([Subpath.polygon([(0, 0), (128, 0), (128, 256), (0, 256)])]))
        vm.linked = false
        let b = VectorMap.vectorMaskBytes(vm, 256, 256)
        #expect(VectorMap.vectorMaskFromBlock(b, 256, 256) == vm)
        #expect(VectorMap.vectorMaskBlockMatches(b, vm, 256, 256))
    }

    @Test func malformedBlocksDecodeToNil() {
        #expect(VectorMap.pathFromVmsk([0, 0, 0], 10, 10) == nil)
        #expect(VectorMap.vectorMaskFromBlock([], 10, 10) == nil)
        #expect(VectorMap.fillFromVscg([0x53, 0x6F]) == nil)
        #expect(VectorMap.fillFromVscg(Array("SoCo".utf8)) == nil)
        #expect(VectorMap.parseVstk([0, 0, 0, 16, 1], 72) == nil)
        #expect(VectorMap.liveFromVogk([0, 0, 1]) == nil)
        #expect(VectorMap.pathFromResource(Array(repeating: 0xFF, count: 25), 10, 10) == VectorPath([], inverted: false))
        // NaN coordinates are written as 0, as photocraft's saturating cast does.
        let nan = VectorPath([Subpath.polygon([(.nan, 1), (2, .nan)])])
        let back = VectorMap.pathFromRecords(VectorMap.pathToRecords(nan, 4, 4), 4, 4)
        #expect(back.subpaths[0].knots.map(\.anchor) == [PCPoint(0, 1), PCPoint(2, 0)])
    }
}
