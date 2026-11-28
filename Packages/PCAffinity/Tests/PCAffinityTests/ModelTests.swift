// Port of photocraft-affinity (crates/affinity/src/model.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// The document model on synthetic documents. The first suite ports photocraft-io's native-document
// tests (tests/affinity.rs `mod native`, tests/affinity_artboards.rs and its support fixture) to
// assertions on the model itself (the PhotoCraft layer mapping is a later step); the second covers
// the rest of the model the same way.

import Testing
@testable import PCAffinity
import PCAffinitySynth

typealias A = Affinity

@Suite struct NativeDocumentTests {
    /// A version-12 document at 144 ppi, 200×100: an artboard "Board" moved by (20, 10) holding a red
    /// ring (two subpaths, filled even-odd) with a 4 px blue stroke.
    static func ringDocument(_ method: Synth.Method) -> [UInt8] {
        func square(_ s: Double, _ o: Double) -> [[UInt8]] {
            [anchor(o, o), anchor(o + s, o), anchor(o + s, o + s), anchor(o, o + s), anchor(o, o)]
        }
        let ring: F = .def(20, ["PCrv"], [
            ("Desc", .str("Ring")),
            ("Crvs", .obj("PCvD", [("Data", .pos([.u8(0), .u32(2), .bool(true), .records(18, square(60, 0)), .bool(true), .records(18, square(20, 20))]))])),
            ("BFFl", .shared([solid(21, rgba(1, 0, 0, 1))])),
            ("LIFl", .shared([solid(24, rgba(0, 0, 1, 1))])),
            ("LILn", .shared([.def(27, ["LDsc"], [("LDeL", .def(28, ["LSty"], [("Wght", .f64(4))]))])])),
        ])
        let board: F = .def(10, ["ShpN"], [
            ("Desc", .str("Board")),
            ("ABEn", .bool(true)),
            ("Shpe", .def(11, ["ShNR"], [])),
            ("ShpB", .f64s([0, 0, 120, 80])),
            ("Xfrm", .f64s([1, 0, 20, 0, 1, 10])),
            ("BFFl", .shared([solid(12, rgba(1, 1, 1, 1))])),
            ("Chld", .shared([ring])),
        ])
        return Synth.container([("doc.dat", document([spread(2, [board])]), method)], thumbnailPNG: PreviewTests.fixture()[101...].map { $0 })
    }

    @Test func artboardsShapesAndPaintsImport() throws {
        for method in Synth.Method.allCases {
            let d = try A.read(Self.ringDocument(method))
            #expect(d.dpi == 144)
            #expect(d.warnings == [], "\(d.warnings)")
            #expect(d.spreads.count == 1)
            let s = d.spreads[0]
            #expect(s.bounds == A.Rect(x0: 0, y0: 0, x1: 200, y1: 100))
            #expect(s.transparent && s.pages.isEmpty)
            let board = s.nodes[0]
            #expect(board.name == "Board" && board.classTag == "ShpN" && board.blend == .normal)
            #expect(board.kind == .artboard(rect: A.Rect(x0: 20, y0: 10, x1: 140, y1: 90), background: [.solid(.rgb(r: 1, g: 1, b: 1, a: 1))]))
            let ring = board.children[0]
            #expect(ring.name == "Ring")
            guard case .shape(let path, let fills, let strokes, let evenOdd) = ring.kind else {
                Issue.record("ring is \(ring.kind)")
                continue
            }
            #expect(evenOdd)
            #expect(path.subpaths.count == 2)
            // The closing duplicate anchor stays in the model (photocraft-io merges it).
            #expect(path.subpaths[0].segments.count == 4)
            #expect(path.subpaths[0].start == A.Point(x: 20, y: 10))
            #expect(path.subpaths[0].segments[0] == A.Segment(A.Point(x: 20, y: 10), A.Point(x: 80, y: 10), A.Point(x: 80, y: 10)))
            #expect(path.subpaths[1].start == A.Point(x: 40, y: 30))
            #expect(path.subpaths.allSatisfy { $0.closed })
            #expect(fills == [.solid(.rgb(r: 1, g: 0, b: 0, a: 1))])
            #expect(strokes.count == 1)
            #expect(strokes[0].paint == .solid(.rgb(r: 0, g: 0, b: 1, a: 1)))
            #expect(strokes[0].width == 4 && strokes[0].miterLimit == 4 && strokes[0].align == .center && strokes[0].dash == nil)
        }
    }

    @Test func aDamagedNativeDocumentStillHasItsPreview() throws {
        var bytes = Self.ringDocument(.zlib)
        bytes[80] ^= 0xFF
        let e = failure { try A.read(bytes) }
        #expect(e != nil)
        #expect(e?.description.hasPrefix("damaged Affinity file") == true, "\(String(describing: e))")
        let p = try A.preview(bytes)
        #expect(p.width == 2 && p.height == 1)
    }

    @Test func mutatedNativeDocumentsNeverTrap() {
        var rng = SeededRNG(seed: 8)
        for _ in 0..<256 {
            var b = Self.ringDocument(Bool.random(using: &rng) ? .stored : .zstd)
            for _ in 0..<Int.random(in: 1..<16, using: &rng) {
                b[Int.random(in: 0..<2048, using: &rng) % b.count] = UInt8.random(in: 0...255, using: &rng)
            }
            _ = failure { try A.read(b) }
        }
    }

    // MARK: Current `.af` artboards (photocraft-io tests/support/current_affinity.rs)

    enum Marker { case legacy, current, otherProperties }

    static func boards(_ marker: Marker, curve: Bool, _ method: Synth.Method) -> [UInt8] {
        func board(_ id: UInt32, _ x: Double) -> F {
            let child: F = .def(id + 10, ["ShpN"], [
                ("Desc", .str("Overflow")),
                ("Shpe", .def(id + 11, ["ShNR"], [])),
                ("ShpB", .f64s([-4, -4, 20, 20])),
                ("BFFl", .shared([solid(id + 12, rgba(1, 0, 0, 1))])),
            ])
            var fields: [(Tag, F)] = [
                ("Desc", .str("Board \(id)")),
                ("Shpe", .def(id + 1, ["ShNR"], [])),
                ("ShpB", .f64s([0, 0, 16, 16])),
                ("Xfrm", .f64s([1, 0, x, 0, 1, 0])),
                ("Chld", .shared([child])),
            ]
            switch marker {
            case .legacy:
                fields.append(("ABEn", .bool(true)))
            case .current, .otherProperties:
                fields.append(("ABEn", .bool(false)))
                fields.append(("phrp", .def(id + 2, [marker == .current ? "aprp" : "prps"], [])))
            }
            return .def(id, [curve ? "PCrv" : "ShpN"], fields)
        }
        let doc = document([spread(2, [board(100, 0), board(200, 24)], bounds: [0, 0, 40, 16])])
        return Synth.container([("doc.dat", doc, method)])
    }

    @Test func currentPropertyArtboardsKeepTheirBounds() throws {
        for marker in [Marker.legacy, .current] {
            for method in Synth.Method.allCases {
                let d = try A.read(Self.boards(marker, curve: false, method))
                let nodes = d.spreads[0].nodes
                #expect(nodes.map(\.name) == ["Board 100", "Board 200"])
                #expect(nodes[0].kind == .artboard(rect: A.Rect(x0: 0, y0: 0, x1: 16, y1: 16), background: []))
                #expect(nodes[1].kind == .artboard(rect: A.Rect(x0: 24, y0: 0, x1: 40, y1: 16), background: []))
                // The overflowing child keeps its full outline: clipping is the artboard's job.
                guard case .shape(let path, let fills, _, _) = nodes[1].children[0].kind else {
                    Issue.record("child is \(nodes[1].children[0].kind)")
                    continue
                }
                #expect(path.subpaths[0].start == A.Point(x: 20, y: -4))
                #expect(fills == [.solid(.rgb(r: 1, g: 0, b: 0, a: 1))])
                #expect(d.warnings == [])
            }
        }
    }

    @Test func currentPropertiesMarkConvertedCurveArtboardsToo() throws {
        let d = try A.read(Self.boards(.current, curve: true, .stored))
        #expect(d.spreads[0].nodes.filter { if case .artboard = $0.kind { true } else { false } }.count == 2)
        #expect(d.warnings == ["a converted artboard outline (imported at its bounding box) (2×)"])
    }

    @Test func otherPropertiesDoNotTurnOrdinaryShapesIntoArtboards() throws {
        let d = try A.read(Self.boards(.otherProperties, curve: false, .stored))
        for n in d.spreads[0].nodes {
            guard case .shape(let path, _, _, let evenOdd) = n.kind else {
                Issue.record("\(n.name) is \(n.kind)")
                continue
            }
            #expect(!evenOdd && path.subpaths.count == 1)
        }
    }
}

@Suite struct ModelTests {
    static func read(_ nodes: [F], fields: [(Tag, F)] = [], entries: [(String, [UInt8])] = [], extra: [(Tag, F)] = []) throws(AffinityError) -> A.Document {
        let doc = document([spread(2, nodes, fields: fields)], extra: extra)
        return try A.read(Synth.container([("doc.dat", doc, .stored)] + entries.map { ($0.0, $0.1, .stored) }))
    }

    static func shape(_ id: UInt32, _ cls: Tag, _ box: [Double], _ params: [(Tag, F)] = [], fields: [(Tag, F)] = []) -> F {
        .def(id, ["ShpN"], [("Shpe", .def(id + 1, [cls], params)), ("ShpB", .f64s(box))] + fields)
    }

    static func outline(_ node: A.Node) -> A.Path? {
        if case .shape(let path, _, _, _) = node.kind { return path }
        return nil
    }

    @Test func documentMetadataAndPages() throws {
        let nver: (Tag, F) = ("NVer", .obj("NVer", [("Prod", .str("Affinity Designer")), ("Majr", .u32(2)), ("Minr", .u32(5)), ("Bild", .u32(3))]))
        let d = try Self.read([], extra: [nver])
        #expect(d.savedBy == "Affinity Designer 2.5.3")
        // Facing pages from `PagC`.
        let facing = try A.read(Synth.container([("doc.dat", document([spread(2, [], bounds: [0, 0, 200, 100], fields: [("PagC", .u32(2))])]), .stored)]))
        #expect(facing.spreads[0].pages == [A.Rect(x0: 0, y0: 0, x1: 100, y1: 100), A.Rect(x0: 100, y0: 0, x1: 200, y1: 100)])
        // No pages at all, no document root.
        #expect(failure { try A.read(Synth.container([("doc.dat", document([]), .stored)])) } == .malformed("document has no pages"))
        #expect(failure { try A.read(Synth.container([("doc.dat", Synth.stream([]), .stored)])) } == .malformed("document has no root node"))
        #expect(failure { try A.read(Synth.container([("other", [], .stored)])) } == .malformed("missing archive entry"))
        #expect(isLimit(failure { try A.read(Self.ringBytes(), limits: A.Limits(maxEntry: 16, maxTotal: 1 << 20)) }))
    }

    static func ringBytes() -> [UInt8] { NativeDocumentTests.ringDocument(.stored) }

    @Test func layerPropertiesAndBlendModes() throws {
        let nodes: [F] = [
            .def(30, ["Grup"], [("Desc", .str("multiply")), ("Blnd", .enumeration(2, 0)), ("Opac", .f64(0.25)), ("Visi", .bool(false)), ("Edtb", .bool(false))]),
            .def(31, ["Grup"], [("Blnd", .enumeration(99, 0))]),
            .def(32, ["Scop"], []),
            .def(33, ["Scop"], [("PasT", .bool(false))]),
            .def(34, ["Grup"], [("Blnd", .enumeration(15, 1)), ("Opac", .f64(7))]),
        ]
        let d = try Self.read(nodes)
        let n = d.spreads[0].nodes
        #expect(n[0].blend == .multiply && n[0].opacity == 0.25 && !n[0].visible && n[0].locked && n[0].kind == .group)
        #expect(n[1].blend == .normal)
        #expect(n[2].blend == .passThrough && n[2].kind == .layer)
        #expect(n[3].blend == .normal)
        #expect(n[4].blend == .linearLight && n[4].opacity == 1)
        #expect(d.warnings == ["an unknown blend mode (imported as Normal)"])
    }

    @Test func parametricShapes() throws {
        let box: [Double] = [0, 0, 10, 20]
        let nodes: [F] = [
            Self.shape(40, "ShpE", box),
            Self.shape(42, "ShSt", box, [("Pnts", .u32(5)), ("IRad", .f64(0.5))]),
            Self.shape(44, "ShPy", box, [("Side", .u32(6))]),
            Self.shape(46, "ShCg", box),
            Self.shape(48, "ShRR", box, [rawField(0x80 | 0x2a, "CTyp", le(UInt32(4)) + [UInt8](repeating: 0, count: 10)), ("ShCR", .f64s([0.25, 0.25]))]),
            // Far-apart (but finite) pie angles: photocraft loops a turn at a time; this must return.
            Self.shape(50, "ShPi", box, [("AngS", .f64(1e300)), ("AngE", .f64(-1e300))]),
            Self.shape(52, "ShZZ", box),
            Self.shape(54, "ShHt", box),
            Self.shape(56, "ShCl", box),
            Self.shape(58, "ShCR", box),
            Self.shape(60, "ShCE", box),
            Self.shape(62, "ShDA", box),
            Self.shape(64, "ShDS", box),
            Self.shape(66, "ShTr", box),
            Self.shape(68, "ShCr", box),
            Self.shape(70, "ShpD", box),
            Self.shape(72, "ShSg", box),
            Self.shape(74, "ShpT", box),
            Self.shape(76, "ShTz", box),
            Self.shape(78, "ShSS", box),
        ]
        let d = try Self.read(nodes)
        let paths = d.spreads[0].nodes.map { Self.outline($0) }
        #expect(paths.allSatisfy { $0 != nil })
        // Ellipse: starts at the right of the box, four quarter arcs.
        #expect(paths[0]?.subpaths[0].start == A.Point(x: 10, y: 10))
        #expect(paths[0]?.subpaths[0].segments.count == 4)
        // Star: ten vertices, the first at the top.
        #expect(paths[1]?.subpaths[0].start == A.Point(x: 5, y: 0))
        #expect(paths[1]?.subpaths[0].segments.count == 9)
        #expect(paths[2]?.subpaths[0].segments.count == 5)
        // Cog: teeth and a hole, filled even-odd.
        #expect(paths[3]?.subpaths.count == 2)
        if case .shape(_, _, _, let evenOdd) = d.spreads[0].nodes[3].kind { #expect(evenOdd) }
        // Rounded rectangle: radius 0.25 × the short side.
        #expect(paths[4]?.subpaths[0].start == A.Point(x: 2.5, y: 0))
        #expect(paths[4]?.subpaths[0].segments.count == 8)
        #expect(paths.allSatisfy { $0!.subpaths.allSatisfy { sp in sp.segments.allSatisfy { $0.end.x.isFinite && $0.end.y.isFinite } } })
        #expect(d.warnings == ["an unrecognized parametric shape (imported as its bounding ellipse)"])
    }

    @Test func curvesWithHandlesAndLiveCorners() throws {
        // Anchor, out-handle, in-handle, anchor: one cubic.
        let records = [anchor(0, 0), anchor(5, 0, role: 1), anchor(10, 5, role: 2), anchor(10, 10)]
        let curve: F = .def(80, ["PCrv"], [("Crvs", .obj("PCvD", [("Data", .pos([.u8(0), .u32(1), .bool(false), .records(18, records)]))]))])
        // A closed square with a live corner of radius 2 on its first record.
        let square = [anchor(0, 0), anchor(10, 0), anchor(10, 10), anchor(0, 10), anchor(0, 0)]
        let rounded: F = .def(82, ["PCrv"], [
            ("Crvs", .obj("PCvD", [
                ("Data", .pos([.u8(0), .u32(1), .bool(true), .records(18, square)])),
                ("CnrD", .obj("CnrD", [])),
            ])),
        ])
        let d = try Self.read([curve, rounded])
        let p = Self.outline(d.spreads[0].nodes[0])
        #expect(p?.subpaths[0].segments == [A.Segment(A.Point(x: 5, y: 0), A.Point(x: 10, y: 5), A.Point(x: 10, y: 10))])
        #expect(p?.subpaths[0].closed == false)
        // `CnrD` without radii leaves the polyline as it is.
        #expect(Self.outline(d.spreads[0].nodes[1])?.subpaths[0].segments.count == 4)
    }

    @Test func liveCornersRoundThePolyline() throws {
        // CnrD positional: [u8, i32[] record indices, f64[] radii, u8[] types] — built by hand.
        var cnrd: [UInt8] = [0x01, 0]  // u8 0
        cnrd += [0x87] + le(UInt32(1)) + le(Int32(1))  // i32 array: record 1
        cnrd += [0x8A] + le(UInt32(1)) + le(Double(2).bitPattern)  // f64 array: radius 2
        cnrd += [0x81] + le(UInt32(1)) + [0]  // u8 array: type
        cnrd += [0]
        let square = [anchor(0, 0), anchor(10, 0), anchor(10, 10)]
        let curve: F = .def(84, ["PCrv"], [
            ("Crvs", .obj("PCvD", [
                ("Data", .pos([.u8(0), .u32(1), .bool(false), .records(18, square)])),
                ("CnrD", .raw([0x30] + le(Tag("CnrD").rawValue) + cnrd)),
            ])),
        ])
        let d = try Self.read([curve])
        let sp = Self.outline(d.spreads[0].nodes[0])?.subpaths[0]
        // Straight to the fillet start, the arc, then on to the end.
        #expect(sp?.start == A.Point(x: 0, y: 0))
        #expect(sp?.segments.count == 3)
        func near(_ p: A.Point?, _ x: Double, _ y: Double) -> Bool {
            guard let p else { return false }
            return abs(p.x - x) < 1e-9 && abs(p.y - y) < 1e-9
        }
        #expect(near(sp?.segments[0].end, 8, 0))
        #expect(near(sp?.segments[1].end, 10, 2))
        #expect(near(sp?.segments[2].end, 10, 10))
        // The arc's handles are tangent: the first leaves along +x, the second arrives along +y.
        #expect(abs((sp?.segments[1].c1.y ?? 1) - 0) < 1e-9 && abs((sp?.segments[1].c2.x ?? 0) - 10) < 1e-9)
    }

    @Test func gradientsStrokesAndColourModels() throws {
        func color(_ id: UInt32, _ cls: Tag, _ c: [Float]) -> F {
            .def(id, [cls], [("_col", .structure(c.flatMap { le($0.bitPattern) }))])
        }
        // Posn: an array of two-f64 vectors (offset, bias).
        let posn = rawField(0x80 | 0x24, "Posn", le(UInt32(2)) + [0, 0.5, 1, 0.25].flatMap { le(Double($0).bitPattern) })
        let gradient: F = .def(90, ["FDsc"], [("FDeF", .def(91, ["FilG"], [
            ("Type", .enumeration(1, 0)),
            ("Grad", .obj("Grad", [("Cols", .shared([color(92, "HSLA", [0, 1, 0.5, 1]), color(93, "CMYK", [0, 0, 0, 1, 0.5])])), posn])),
        ]))])
        let style: F = .def(94, ["LDsc"], [
            ("LDSc", .bool(false)),
            ("LDSa", .u32(1)),
            ("LDeL", .def(95, ["LSty"], [
                ("Wght", .f64(3)),
                ("Data", .structure(le(Double(10).bitPattern) + [2, 2, 3])),
                f64Array("Patn", [2, 1, 0, 0]),
                ("Phse", .f64(0.5)),
            ])),
        ])
        let node = Self.shape(96, "ShNR", [0, 0, 10, 10], fields: [
            ("Xfrm", .f64s([2, 0, 0, 0, 2, 0])),
            ("BFFl", .shared([gradient])),
            ("LIFl", .shared([solid(300, rgba(0, 0, 0, 1))])),
            ("LILn", .shared([style])),
            ("DrwO", .raw([0x80 | 0x2a] + le(Tag("DrwO").rawValue) + le(UInt32(1)) + le(UInt16(0)) + le(UInt16(1)))),
        ])
        let d = try Self.read([node])
        guard case .shape(_, let fills, let strokes, _) = d.spreads[0].nodes[0].kind,
              case .gradient(let g)? = fills.first
        else {
            Issue.record("no gradient fill")
            return
        }
        #expect(g.kind == .radial)
        #expect(g.stops.map(\.offset) == [0, 1] && g.stops.map(\.bias) == [0.5, 0.25])
        #expect(g.stops[0].color == .rgb(r: 1, g: 0, b: 0, a: 1))
        #expect(g.stops[1].color == .cmyk(c: 0, m: 0, y: 0, k: 1, a: 0.5))
        #expect(g.stops[0].halfPoint == 0.5)
        #expect(g.transform == A.Affine(2, 0, 0, 2, 0, 0))
        let s = strokes[0]
        // Absolute width (not scaled with the object), inside, round caps and joins, a dash of [2, 1] × width.
        #expect(s.width == 3 && s.align == .inside && s.cap == .round && s.join == .round && s.miterLimit == 10)
        #expect(s.dash?.lengths == [6, 3] && s.dash?.phase == 1.5)
        #expect(s.behind)
    }

    @Test func artisticText() throws {
        let attrs: F = .def(100, ["CAtt"], [
            f64Array("Doub", [24, 0, 0, 0, 0.1]),
            ("Objs", .shared([solid(101, rgba(0, 1, 0, 1))])),
            ("DFnt", .obj("DFnt", [("Post", .str("Helvetica-Bold")), ("Famy", .str("Helvetica")), ("Wegt", .u32(700)), ("Ital", .bool(true))])),
        ])
        let block: F = .def(104, ["Blok"], [
            ("Glyp", .obj("Glyp", [("Utf8", .str("Hello\u{0}world"))])),
            ("GAtt", .obj("GAtt", [("Runs", .shared([.def(105, ["Run_"], [("Indx", .u32(5)), ("Item", attrs)]), .def(106, ["Run_"], [("Indx", .u32(11)), ("Item", .def(107, ["CAtt"], []))])]))])),
            ("PAtt", .obj("PAtt", [("Runs", .shared([.def(108, ["Run_"], [("Item", .def(109, ["PAtt"], [i32Array("Ints", [1])]))])]))])),
        ])
        let text: F = .def(110, ["TxtA"], [
            ("StSt", .def(111, ["Stry"], [("Blok", .shared([block]))])),
            ("TxtH", .def(112, ["ArFr"], [("FrmB", .f64s([0, 0, 100, 20])), ("ArtV", .f64(16))])),
            ("Xfrm", .f64s([1, 0, 5, 0, 1, 5])),
        ])
        let d = try Self.read([text])
        guard case .text(let t) = d.spreads[0].nodes[0].kind else {
            Issue.record("no text: \(d.spreads[0].nodes[0].kind)")
            return
        }
        #expect(t.runs.map(\.text) == ["Hello", "world"])
        #expect(t.runs[0].size == 24 && t.runs[0].tracking == 0.1 && t.runs[0].weight == 700 && t.runs[0].italic)
        #expect(t.runs[0].postscript == "Helvetica-Bold" && t.runs[0].family == "Helvetica")
        #expect(t.runs[0].fill == .solid(.rgb(r: 0, g: 1, b: 0, a: 1)))
        // The second run has no attributes: 12 pt at 144 ppi.
        #expect(t.runs[1].size == 24 && t.runs[1].weight == 400 && t.runs[1].fill == .none)
        #expect(t.align == .center && t.anchor == A.Point(x: 50, y: 16) && t.frame == nil)
        #expect(t.transform == A.Affine(1, 0, 0, 1, 5, 5))
    }

    // MARK: Pixels

    /// A 256 × 256 planar tile whose byte at (x, y) is `value(x, y)`.
    static func tile(_ value: (Int, Int) -> UInt8) -> [UInt8] {
        var t = [UInt8](repeating: 0, count: 65536)
        for y in 0..<256 { for x in 0..<256 { t[y * 256 + x] = value(x, y) } }
        return t
    }

    static func bitmap(_ id: UInt32, width: UInt32, height: UInt32, format: UInt16, channels: [(state: UInt8, entry: String?)], extra: [(Tag, F)] = []) -> F {
        var fields: [(Tag, F)] = [("BmpW", .u32(width)), ("BmpH", .u32(height)), ("Frmt", .enumeration(format, 0))]
        for (i, c) in channels.enumerated() {
            fields.append((Tag("Sta\(i + 1)"), .u8s([c.state])))
            if let e = c.entry {
                fields.append((Tag("Idx\(i + 1)"), .shared([.def(id + 1 + UInt32(i), ["Blck"], [("Data", .entry(e))])])))
            }
        }
        return .def(id, ["DyBm"], fields + extra)
    }

    @Test func pixelLayersCropAndConvert() throws {
        let channels: [(state: UInt8, entry: String?)] = [(4, "t/r"), (4, "t/g"), (2, nil), (2, nil)]
        let layer: F = .def(120, ["Rstr"], [
            ("Bitm", Self.bitmap(130, width: 3, height: 2, format: 0, channels: channels)),
            ints4("BitR", [1, 0, 3, 2]),
            ("Xfrm", .f64s([1, 0, 10, 0, 1, 20])),
        ])
        let entries = [
            ("t/r", Self.tile { x, y in UInt8(truncatingIfNeeded: x * 10 + y) }),
            ("t/g", Self.tile { x, _ in UInt8(truncatingIfNeeded: 200 + x) }),
        ]
        let d = try Self.read([layer], entries: entries)
        guard case .image(let img) = d.spreads[0].nodes[0].kind, case .rgba8(let px) = img.pixels else {
            Issue.record("no pixels")
            return
        }
        #expect(img.width == 2 && img.height == 2)
        #expect(img.transform == A.Affine(1, 0, 0, 1, 11, 20))
        // Columns 1 and 2 of rows 0 and 1; blue is a full tile (state 2), alpha too.
        #expect(px == [10, 201, 255, 255, 20, 202, 255, 255, 11, 201, 255, 255, 21, 202, 255, 255])
    }

    @Test func placedImagesKeepTheirOriginalFile() throws {
        let original: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3]
        let image: F = .def(140, ["ImgN"], [("Bitm", .def(141, ["DyBm"], [("BmpW", .u32(2)), ("BmpH", .u32(1)), ("Bckg", .entry("c/1"))]))])
        let wrapped = Synth.stream([blob("Data", original)])
        let d = try Self.read([image], entries: [("c/1", wrapped)])
        guard case .image(let img) = d.spreads[0].nodes[0].kind else {
            Issue.record("no image")
            return
        }
        #expect(img.pixels == .encoded(original) && img.width == 2 && img.height == 1)
        // A missing original is reported, not fatal.
        let missing = try Self.read([image])
        #expect(missing.spreads[0].nodes[0].kind == .unsupported)
        #expect(missing.warnings.contains("an embedded image file that could not be read (its cached pixels were used)"))
    }

    @Test func maskLayersBecomePixelMasks() throws {
        func mask(_ id: UInt32) -> F {
            .def(id, ["MRst"], [("Bitm", Self.bitmap(id + 1, width: 2, height: 2, format: 6, channels: [(4, "m/1")]))])
        }
        let group: F = .def(150, ["Grup"], [("Chld", .shared([.def(152, ["Grup"], []), mask(160), mask(170)]))])
        let d = try Self.read([group], entries: [("m/1", Self.tile { x, y in UInt8(truncatingIfNeeded: 100 * x + y) })])
        let g = d.spreads[0].nodes[0]
        #expect(g.children.count == 1)
        guard case .rgba8(let px)? = g.pixelMask?.pixels else {
            Issue.record("no mask")
            return
        }
        #expect(px == [0, 0, 0, 255, 100, 100, 100, 255, 1, 1, 1, 255, 101, 101, 101, 255])
        #expect(d.warnings == ["several pixel masks on one layer (only the first is used)"])
    }

    @Test func tileErrorsAndBudgets() throws {
        // A tile state of 4 without a tile, and an unknown state, are damaged files.
        let noTile: F = .def(180, ["Rstr"], [("Bitm", Self.bitmap(181, width: 1, height: 1, format: 6, channels: [(4, nil)]))])
        #expect(failure { try Self.read([noTile]) } == .malformed("missing pixel tile"))
        let badState: F = .def(182, ["Rstr"], [("Bitm", Self.bitmap(183, width: 1, height: 1, format: 6, channels: [(9, nil)]))])
        #expect(failure { try Self.read([badState]) } == .malformed("unknown pixel tile state"))
        // A tile entry of the wrong size.
        let short: F = .def(184, ["Rstr"], [("Bitm", Self.bitmap(185, width: 1, height: 1, format: 6, channels: [(4, "t/s")]))])
        #expect(failure { try Self.read([short], entries: [("t/s", [1, 2, 3])]) } == .malformed("pixel tile size"))
        // Over 64 megapixels: reported, not decoded.
        let huge: F = .def(186, ["Rstr"], [("Bitm", Self.bitmap(187, width: 9000, height: 9000, format: 0, channels: []))])
        let d = try Self.read([huge])
        #expect(d.spreads[0].nodes[0].kind == .unsupported)
        #expect(d.warnings == ["pixel layers larger than 64 megapixels"])
    }

    // MARK: Hostile references (each would recurse without end in photocraft or here)

    @Test func aLayerThatContainsItselfIsReported() throws {
        let group: F = .def(200, ["Grup"], [("Chld", .shared([.ref(200)]))])
        let d = try Self.read([group])
        #expect(d.spreads[0].nodes[0].children.isEmpty)
        #expect(d.warnings == ["a layer that contains itself"])
    }

    /// photocraft #6486: a compound that lists one shared child twice per level doubles the work
    /// at each level, so 20 levels are a million outline calls inside the depth limit. The
    /// outline's budget stops it.
    @Test func aCompoundThatFansOutIsStoppedByTheOutlineBudget() throws {
        func comp(_ level: Int) -> F {
            let id = UInt32(300 + level)
            if level == 20 { return .def(id, ["Comp"], [("Chld", .shared([]))]) }
            return .def(id, ["Comp"], [("Chld", .shared([comp(level + 1), .ref(id + 1)]))])
        }
        let d = try Self.read([comp(0)])
        #expect(d.warnings.contains("compound outlines exceeding the geometry work limit"), "\(d.warnings)")
    }

    @Test func aCompoundThatContainsItselfStops() throws {
        let compound: F = .def(210, ["Comp"], [("Chld", .shared([.ref(210)]))])
        let d = try Self.read([compound])
        #expect(Self.outline(d.spreads[0].nodes[0])?.subpaths.isEmpty == true)
        #expect(d.warnings == ["compound shapes nested too deeply (or containing themselves)"])
    }

    @Test func aSpotColourThatRefersToItselfStops() throws {
        let fill: F = .def(220, ["FDsc"], [("FDeF", .def(221, ["FilS"], [("Colr", .def(222, ["Pant"], [("srgb", .ref(222))]))]))])
        let node = Self.shape(224, "ShNR", [0, 0, 1, 1], fields: [("BFFl", .shared([fill]))])
        let d = try Self.read([node])
        guard case .shape(_, let fills, _, _) = d.spreads[0].nodes[0].kind else {
            Issue.record("not a shape")
            return
        }
        #expect(fills.isEmpty)
        #expect(d.warnings == ["spot colours (imported as their RGB equivalent) (9×)"])
    }

    @Test func layersNestedTooDeeplyAreReported() throws {
        let bytes = onLargeStack { () -> [UInt8] in
            var node: F = .def(1000, ["Grup"], [])
            for i in 1...140 { node = .def(1000 + UInt32(i), ["Grup"], [("Chld", .shared([node]))]) }
            return Synth.container([("doc.dat", document([spread(2, [node])]), .stored)])
        }
        let d = try A.read(bytes)
        var depth = 0
        var n = d.spreads[0].nodes.first
        while let current = n {
            depth += 1
            n = current.children.first
        }
        #expect(depth == 128)
        #expect(d.warnings == ["layers nested deeper than 128 levels"])
    }

    /// photocraft recurses once per nesting level, which needs megabytes of stack in a debug build;
    /// the stream and the layer tree are read with explicit stacks here, so the deepest documents the
    /// limits allow read on a 256 KiB thread (an app's secondary threads get 512 KiB).
    @Test func theDeepestAllowedDocumentsNeedLittleStack() throws {
        let deepStream = onLargeStack { () -> [UInt8] in
            var fields: [(Tag, F)] = []
            for _ in 0..<(A.Stream.maxDepth - 1) { fields = [("Chld", .obj("Grup", fields))] }
            return Synth.stream(fields)
        }
        let deepTree = onLargeStack { () -> [UInt8] in
            var node: F = .def(1000, ["Grup"], [])
            for i in 1...130 { node = .def(1000 + UInt32(i), ["Grup"], [("Chld", .shared([node]))]) }
            return Synth.container([("doc.dat", document([spread(2, [node])]), .stored)])
        }
        let compound = Synth.container([("doc.dat", document([spread(2, [.def(210, ["Comp"], [("Chld", .shared([.ref(210)]))])])]), .stored)])
        let results = onThread(stack: 256 << 10) { () -> [String] in
            var out: [String] = []
            do {
                let s = try A.Stream.parse(deepStream)
                out.append("stream \(s.objects.count)")
                let d = try A.read(deepTree)
                out.append("tree \(d.warnings)")
                let c = try A.read(compound)
                out.append("compound \(c.warnings)")
            } catch {
                out.append("\(error)")
            }
            return out
        }
        #expect(results == [
            "stream \(A.Stream.maxDepth)",
            "tree [\"layers nested deeper than 128 levels\"]",
            "compound [\"compound shapes nested too deeply (or containing themselves)\"]",
        ])
    }

    @Test func effectsFillLayersAndUnknownClassesAreNamed() throws {
        let nodes: [F] = [
            .def(230, ["Grup"], [("FiEf", .shared([.def(231, ["Shdw"], [("Enab", .bool(true))])]))]),
            .def(232, ["FRst"], [("Bitm", .def(233, ["DyBm"], [("BmpW", .u32(4)), ("BmpH", .u32(2))])), ("BFFl", .shared([solid(310, rgba(0, 0, 0, 1))]))]),
            .def(236, ["HSLA"], []),
            .def(237, ["CuRA"], []),
            .def(238, ["Grup"], [("AdCh", .shared([.def(239, ["LvRA"], [])]))]),
        ]
        let d = try Self.read(nodes)
        let n = d.spreads[0].nodes
        #expect(Self.outline(n[1])?.subpaths.first?.segments.last?.end == A.Point(x: 0, y: 2))
        #expect(n[2].kind == .unsupported && n[3].kind == .unsupported)
        #expect(d.warnings == [
            "adjustment layers",
            "adjustment layers attached to other layers (imported without them)",
            "layer effects (shadows, glows, outlines, bevels…)",
            "unknown layers",
        ])
    }

    @Test func vectorMasksFromAttachedShapes() throws {
        let masked: F = .def(240, ["Grup"], [
            ("Xfrm", .f64s([1, 0, 100, 0, 1, 0])),
            ("AdCh", .shared([Self.shape(242, "ShNR", [0, 0, 5, 5], fields: [("Xfrm", .f64s([1, 0, 1, 0, 1, 1]))])])),
        ])
        let d = try Self.read([masked])
        let mask = d.spreads[0].nodes[0].mask
        #expect(mask?.subpaths.count == 1)
        #expect(mask?.subpaths[0].start == A.Point(x: 101, y: 1))
    }
}
