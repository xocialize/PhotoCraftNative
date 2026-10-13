// Port of photocraft-io (crates/io/src/affinity.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
// The rest of the mapping on synthetic documents (built as PCAffinity's ModelTests build them):
// layer properties and blend modes, pages, shapes, gradients and strokes, text, pixels, placed
// images, masks, nesting, limits; plus the gradient-handle geometry from photocraft-compose.

import Foundation
import PCAffinity
import PCAffinitySynth
@testable import PCIOAffinity
import PCDocument
import PCFoundation
import PCIOCore
import Testing

@Suite struct MappingTests {
    static func load(_ nodes: [F], bounds: [Double] = [0, 0, 200, 100], transparent: Bool = true, entries: [(String, [UInt8])] = [],
                     renderer: (any LayerContentRenderer)? = nil) throws -> ImportResult {
        try importAF("synthetic.af", container(nodes, bounds: bounds, transparent: transparent, entries: entries), renderer: renderer)
    }

    @Test func extensions() {
        #expect(AffinityImport.extensions == ["af", "afphoto", "afdesign", "afpub"])
        for name in ["a.af", "dir/B.AFDESIGN", "c:\\x\\y.afpub", "photo.AfPhoto", ".af"] {
            #expect(AffinityImport.hasExtension(name), "\(name)")
        }
        for name in ["af", "x.af.png", "dir.af/file", "dir.af\\file", "x.afx", "x.", ""] {
            #expect(!AffinityImport.hasExtension(name), "\(name)")
        }
    }

    @Test func layerPropertiesAndBlendModes() throws {
        let nodes: [F] = [
            .def(30, ["Grup"], [("Desc", .str("multiply")), ("Blnd", .enumeration(2, 0)), ("Opac", .f64(0.25)), ("Visi", .bool(false)), ("Edtb", .bool(false))]),
            .def(32, ["Scop"], []),
            .def(34, ["Grup"], [("Blnd", .enumeration(7, 0))]),
            .def(36, ["Grup"], [("Blnd", .enumeration(21, 0))]),
            .def(38, ["Grup"], [("Blnd", .enumeration(24, 0))]),
        ]
        let r = try Self.load(nodes)
        let l = r.document.layers
        #expect(l.count == 5)
        #expect(l[0].name == "multiply" && l[0].blend == .multiply && l[0].opacity == 0.25 && !l[0].visible)
        #expect(l[0].locks == Locks(all: true))
        #expect(l[0].group == LayerGroup(children: [], expanded: false, artboard: nil))
        #expect(l[1].name == "Layer" && l[1].blend == .passThrough && l[1].locks == Locks())
        #expect(l[2].name == "Group" && l[2].blend == .linearDodge)
        #expect(l[3].blend == .normal && l[4].blend == .normal)
        #expect(r.warnings == ["Affinity: the Average, Negation, Reflect, Glow and Erase blend modes import as Normal."])
    }

    @Test func everyAffinityBlendModeMaps() throws {
        let b = try AffinityBuilder("x", Affinity.read(container([])), renderer: nil, codec: ImageIOCodec())
        let expected: [Affinity.Blend: BlendMode] = [
            .normal: .normal, .passThrough: .passThrough, .darken: .darken, .darkerColor: .darkerColor, .multiply: .multiply,
            .colorBurn: .colorBurn, .lighten: .lighten, .lighterColor: .lighterColor, .screen: .screen, .colorDodge: .colorDodge,
            .add: .linearDodge, .overlay: .overlay, .softLight: .softLight, .hardLight: .hardLight, .vividLight: .vividLight,
            .pinLight: .pinLight, .linearLight: .linearLight, .hardMix: .hardMix, .difference: .difference, .exclusion: .exclusion,
            .subtract: .subtract, .hue: .hue, .saturation: .saturation, .luminosity: .luminosity, .color: .color,
        ]
        for mode in Affinity.Blend.allCases {
            #expect(b.blend(mode) == (expected[mode] ?? .normal), "\(mode)")
        }
        #expect(b.warnings == ["the Average, Negation, Reflect, Glow and Erase blend modes import as Normal"])
    }

    @Test func anOpaquePageGetsAWhiteBackground() throws {
        let r = try Self.load([.def(30, ["Grup"], [])], transparent: false)
        let l = r.document.layers
        #expect(l.map(\.name) == ["Background", "Group"])
        #expect(l[0].locks == Locks(transparency: true, position: true))
        let s = try #require(l[0].surface)
        #expect(s.format == .rgba8 && s.tileCount == 0 && s.defaultPixelValue == [1, 1, 1, 1])
    }

    @Test func spreadsSitSideBySideAsPageArtboards() throws {
        let doc = stream([
            spread(2, [shapeNode(10, "ShNR", [10, 10, 20, 20], fields: [("BFFl", .shared([solid(12, rgba(0, 1, 0, 1))]))])], transparent: false),
            spread(3, [], bounds: [0, 0, 100, 150], transparent: false),
        ], dpi: 300)
        let r = try importAF("pages.afpub", Synth.container([("doc.dat", doc, .stored)]))
        let d = r.document
        #expect(d.size == PixelSize(width: 200 + 64 + 100, height: 150) && d.resolutionDpi == 300)
        #expect(d.layers.map(\.name) == ["Page 1", "Page 2"], "artboards: no Background")
        #expect(d.layers[0].artboard == Artboard(rect: PixelRect(x0: 0, y0: 0, x1: 200, y1: 100), background: .white))
        #expect(d.layers[1].artboard == Artboard(rect: PixelRect(x0: 264, y0: 0, x1: 364, y1: 150), background: .white))
        #expect(d.layers[0].group?.expanded == true)
        #expect(d.layers[0].children?.first?.shapeContent?.path.subpaths.first?.knots.first?.anchor == PCPoint(10, 10))
        #expect(r.warnings == [])
    }

    @Test func facingPagesImportAsOneArtboardPerSpread() throws {
        let doc = stream([spread(2, [], bounds: [0, 0, 200, 100], fields: [("PagC", .u32(2))])])
        let r = try importAF("facing.afpub", Synth.container([("doc.dat", doc, .stored)]))
        #expect(r.document.layers.count == 1)
        #expect(r.document.layers[0].artboard?.rect == PixelRect(x0: 0, y0: 0, x1: 100, y1: 100))
        #expect(r.warnings == ["Affinity: facing pages import as one artboard per spread."])
    }

    @Test func documentsOver300000PixelsAreRefused() {
        let e = importError("huge.af", container([], bounds: [0, 0, 300_001, 10]))
        #expect(e?.contains("larger than 300 000 pixels on a side") == true, "\(String(describing: e))")
        #expect(importError("ok.af", container([], bounds: [0, 0, 299_999.5, 0.25])) == nil)
    }

    @Test func parametricShapesBecomeShapeLayers() throws {
        let fill: (Tag, F) = ("BFFl", .shared([solid(300, rgba(0, 0, 1, 0.5))]))
        let nodes: [F] = [
            shapeNode(40, "ShpE", [0, 0, 10, 20], fields: [fill]),
            shapeNode(44, "ShCg", [0, 0, 10, 20]),
        ]
        let r = try Self.load(nodes)
        let l = r.document.layers
        let ellipse = try #require(l[0].shapeContent)
        #expect(l[0].name == "Shape")
        #expect(ellipse.path.subpaths.count == 1 && ellipse.path.subpaths[0].closed)
        // Four quarter arcs from the right of the box; the closing knot is merged.
        #expect(ellipse.path.subpaths[0].knots.count == 4)
        let k0 = ellipse.path.subpaths[0].knots[0]
        #expect(k0.anchor == PCPoint(10, 10) && k0.inCtrl != k0.anchor && k0.outCtrl != k0.anchor)
        #expect(ellipse.fill == .solid(.rgb(0, 0, 1, 0.5)) && ellipse.stroke == nil && ellipse.cache == nil)
        // The cog is filled even-odd: its hole joins the outline.
        let cog = try #require(l[1].shapeContent)
        #expect(cog.path.fillRule == .evenOdd && cog.path.subpaths.count == 2 && cog.path.subpaths[1].op == .join)
        #expect(cog.fill == nil)
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
        let node = shapeNode(96, "ShNR", [0, 0, 10, 10], fields: [
            ("Xfrm", .f64s([2, 0, 0, 0, 2, 0])),
            ("BFFl", .shared([gradient])),
            ("LIFl", .shared([solid(300, rgba(0, 0, 0, 1))])),
            ("LILn", .shared([style])),
            ("DrwO", .raw([0x80 | 0x2a] + le(Tag("DrwO").rawValue) + le(UInt32(1)) + le(UInt16(0)) + le(UInt16(1)))),
        ])
        let r = try Self.load([node])
        let sh = try #require(r.document.layers.first?.shapeContent)
        guard case .gradient(let g)? = sh.fill else {
            Issue.record("no gradient: \(String(describing: sh.fill))")
            return
        }
        #expect(g.style == .radial && !g.reverse && !g.dither && g.align)
        // Colour stops are opaque; their alpha moves to the opacity stops.
        #expect(g.stops == [ColorStop(0, .rgb(1, 0, 0, 1)), ColorStop(1, .rgb(0, 0, 0, 1))])
        #expect(g.opacityStops == [OpacityStop(0, 1), OpacityStop(1, 0.5)])
        #expect(g.midpoints == [0.5])
        // A circle of radius 2 centred on the frame's corner (0, 0)-(20, 20).
        #expect(g.angle == 0 && abs(g.scale - 0.2) < 1e-6 && g.offset == SIMD2(-0.5, -0.5))
        let s = try #require(sh.stroke)
        #expect(s.width == 3 && s.align == .inside && s.cap == .round && s.join == .round && s.miterLimit == 10)
        // Dashes in multiples of the width.
        #expect(s.dashes == [2, 1] && s.dashOffset == 0.5)
        #expect(s.paint == .solid(.rgb(0, 0, 0, 1)))
        #expect(r.warnings == ["Affinity: strokes drawn behind their fill import in front of it."])
    }

    @Test func ellipticalGradientsAreReported() throws {
        let posn = rawField(0x80 | 0x24, "Posn", le(UInt32(2)) + [0, 0.5, 1, 0.5].flatMap { le(Double($0).bitPattern) })
        let gradient: F = .def(90, ["FDsc"], [("FDeF", .def(91, ["FilG"], [
            ("Type", .enumeration(1, 0)),
            ("Grad", .obj("Grad", [("Cols", .shared([.def(92, ["RGBA"], [("_col", rgba(1, 1, 1, 1))]), .def(93, ["RGBA"], [("_col", rgba(0, 0, 0, 1))])])), posn])),
        ]))])
        let node = shapeNode(96, "ShNR", [0, 0, 10, 10], fields: [("Xfrm", .f64s([2, 0, 0, 0, 1, 0])), ("BFFl", .shared([gradient]))])
        let r = try Self.load([node])
        #expect(r.warnings == ["Affinity: elliptical gradients import as circular ones."])
    }

    @Test func multipleFillsAndStrokesAreReported() throws {
        // PCAffinity keeps only the active fill and stroke, and says so.
        let node = shapeNode(40, "ShNR", [0, 0, 10, 10], fields: [
            ("BFFl", .shared([solid(300, rgba(1, 0, 0, 1)), solid(310, rgba(0, 1, 0, 1))])),
        ])
        let r = try Self.load([node])
        #expect(r.document.layers[0].shapeContent?.fill != nil)
        #expect(r.warnings == ["Affinity: not imported or approximated: several fills or strokes on one object (only the active one is imported)."])
        // The mapping's own guard, for a model that lists several.
        let b = try AffinityBuilder("x", Affinity.read(container([])), renderer: nil, codec: ImageIOCodec())
        let path = VectorPath([Subpath.polygon([(0, 0), (4, 0), (4, 4)])])
        let sh = b.shape(path, [.solid(.gray(v: 1, a: 1)), .solid(.gray(v: 0, a: 1))], [], .identity)
        #expect(sh.fill == .solid(.rgb(1, 1, 1, 1)) && sh.stroke == nil)
        #expect(b.warnings == ["only one fill and one stroke per shape import"])
    }

    @Test func shapesClipTheirChildren() throws {
        let node = shapeNode(40, "ShNR", [0, 0, 10, 10], fields: [
            ("Desc", .str("Frame")),
            ("Opac", .f64(0.5)),
            ("BFFl", .shared([solid(300, rgba(1, 0, 0, 1))])),
            ("LIFl", .shared([solid(310, rgba(0, 0, 1, 1))])),
            ("LILn", .shared([lineStyle(320, width: 2)])),
            ("Chld", .shared([.def(50, ["Grup"], [("Desc", .str("inside"))])])),
        ])
        let r = try Self.load([node])
        let g = try #require(r.document.layers.first)
        #expect(g.name == "Frame" && g.opacity == 0.5 && g.group?.expanded == false)
        #expect(g.children?.map(\.name) == ["Frame", "inside"])
        let own = try #require(g.children?.first)
        #expect(own.opacity == 1 && own.shapeContent?.fill == .solid(.rgb(1, 0, 0, 1)))
        #expect(g.vectorMask == VectorMask(path: own.shapeContent!.path, enabled: true, linked: true, density: 1, feather: 0))
        #expect(r.warnings == ["Affinity: strokes of shapes that clip other layers are clipped to the shape."])
    }

    @Test func nestedArtboardsBecomeMaskedGroups() throws {
        let board: F = .def(60, ["ShpN"], [
            ("Desc", .str("Inner")),
            ("ABEn", .bool(true)),
            ("Shpe", .def(61, ["ShNR"], [])),
            ("ShpB", .f64s([0.5, 0, 10, 10])),
            ("BFFl", .shared([solid(62, rgba(1, 1, 1, 0))])),
        ])
        let top: F = .def(70, ["ShpN"], [
            ("ABEn", .bool(true)),
            ("Shpe", .def(71, ["ShNR"], [])),
            ("ShpB", .f64s([0, 0, 50, 50])),
            ("BFFl", .shared([solid(72, rgba(0, 0, 0, 0))])),
        ])
        let r = try Self.load([.def(50, ["Grup"], [("Chld", .shared([board]))]), top])
        let inner = try #require(r.document.layers[0].children?.first)
        #expect(inner.name == "Inner" && inner.artboard == nil)
        let mask = try #require(inner.vectorMask)
        #expect(mask.path.subpaths.count == 1 && mask.path.subpaths[0].closed)
        #expect(mask.path.subpaths[0].knots.map(\.anchor) == [PCPoint(0, 0), PCPoint(10, 0), PCPoint(10, 10), PCPoint(0, 10)])
        // A top-level board with a transparent colour has a transparent background.
        #expect(r.document.layers[1].name == "Artboard")
        #expect(r.document.layers[1].artboard == Artboard(rect: PixelRect(x0: 0, y0: 0, x1: 50, y1: 50), background: .transparent))
        #expect(r.warnings == ["Affinity: artboards inside groups import as masked groups."])
    }

    @Test func unsupportedLayersKeepTheirChildren() throws {
        let nodes: [F] = [
            .def(236, ["HSLA"], []),
            .def(237, ["XyZw"], [("Desc", .str("odd")), ("Chld", .shared([.def(238, ["Grup"], [])]))]),
        ]
        let r = try Self.load(nodes)
        #expect(r.document.layers.map(\.name) == ["odd"])
        #expect(r.document.layers[0].children?.map(\.name) == ["Group"])
        #expect(r.warnings.allSatisfy { $0.hasPrefix("Affinity: not imported or approximated: ") }, "\(r.warnings)")
    }

    @Test func artisticText() throws {
        let attrs: F = .def(100, ["CAtt"], [
            f64Array("Doub", [24, 0, 0, 0, 0.1]),
            ("Objs", .shared([solid(101, rgba(0, 1, 0, 1))])),
            ("DFnt", .obj("DFnt", [("Post", .str("Helvetica-Bold")), ("Famy", .str("Helvetica")), ("Wegt", .u32(700)), ("Ital", .bool(true))])),
        ])
        let block: F = .def(104, ["Blok"], [
            ("Glyp", .obj("Glyp", [("Utf8", .str("Hello\u{2029}w\u{0}orld"))])),
            ("GAtt", .obj("GAtt", [("Runs", .shared([.def(105, ["Run_"], [("Indx", .u32(6)), ("Item", attrs)]), .def(106, ["Run_"], [("Indx", .u32(12)), ("Item", .def(107, ["CAtt"], []))])]))])),
            ("PAtt", .obj("PAtt", [("Runs", .shared([.def(108, ["Run_"], [("Item", .def(109, ["PAtt"], [i32Array("Ints", [1])]))])]))])),
        ])
        let text: F = .def(110, ["TxtA"], [
            ("Desc", .str("Title")),
            ("StSt", .def(111, ["Stry"], [("Blok", .shared([block]))])),
            ("TxtH", .def(112, ["ArFr"], [("FrmB", .f64s([0, 0, 100, 20])), ("ArtV", .f64(16))])),
            ("Xfrm", .f64s([1, 0, 5, 0, 1, 5])),
        ])
        let r = try Self.load([text])
        let l = try #require(r.document.layers.first)
        #expect(l.name == "Title")
        let t = try #require(l.textContent)
        // The paragraph separator becomes a carriage return.
        #expect(t.text == "Hello\rworld")
        #expect(t.runs.map(\.len) == [6, 5])
        let a = t.runs[0].style
        // 24 px at 144 ppi is 12 pt; tracking in thousandths of an em.
        #expect(a.fontFamily == "Helvetica" && a.postscriptName == "Helvetica-Bold" && a.weight == 700 && a.italic)
        #expect(a.sizePt == 12 && abs(a.tracking - 100) < 1e-4 && a.color == .rgb(0, 1, 0, 1) && a.leadingPt == nil)
        let b = t.runs[1].style
        #expect(b.fontFamily == "" && b.postscriptName == nil && b.weight == 400 && b.sizePt == 12 && b.color == .black)
        #expect(t.fontFamily == "Helvetica" && t.sizePt == 12 && t.color == .rgb(0, 1, 0, 1))
        #expect(t.paragraphs == [ParagraphRun(len: 11, style: ParagraphStyle(align: .center))])
        // The first baseline's anchor (the line's centre) placed by the node transform.
        #expect(t.transform == PCAffine.translate(55, 21))
        #expect(t.shape == .point && t.cache == nil)
    }

    @Test func frameTextScalesIntoItsBox() throws {
        let block: F = .def(104, ["Blok"], [
            ("Glyp", .obj("Glyp", [("Utf8", .str("Hi"))])),
            ("GAtt", .obj("GAtt", [("Runs", .shared([.def(105, ["Run_"], [("Indx", .u32(2)), ("Item", .def(100, ["CAtt"], [f64Array("Doub", [24])]))])]))])),
        ])
        let text: F = .def(110, ["TxtF"], [
            ("StSt", .def(111, ["Stry"], [("Blok", .shared([block]))])),
            ("TxtH", .def(112, ["FrFr"], [("FrmB", .f64s([10, 20, 60, 40]))])),
            ("Xfrm", .f64s([2, 0, 0, 0, 2, 0])),
        ])
        let r = try Self.load([text])
        let t = try #require(r.document.layers.first?.textContent)
        #expect(r.document.layers[0].name == "Text")
        // Scale 2 moves into the type size and the box; the transform keeps the box origin.
        #expect(t.runs.first?.style.sizePt == 24)
        #expect(t.transform == PCAffine.translate(20, 40))
        #expect(t.shape == .box(TextShape.TextBox(x: 0, y: 0, width: 100, height: 40)))
        #expect(t.paragraphs.first?.style.align == .left)
    }

    @Test func typeLayersAreRenderedAndTheirFontsResolvedByTheRenderer() throws {
        let attrs: F = .def(100, ["CAtt"], [("DFnt", .obj("DFnt", [("Post", .str("Helvetica-Bold")), ("Famy", .str("Helvetica"))]))])
        let block: F = .def(104, ["Blok"], [
            ("Glyp", .obj("Glyp", [("Utf8", .str("Hi"))])),
            ("GAtt", .obj("GAtt", [("Runs", .shared([.def(105, ["Run_"], [("Indx", .u32(2)), ("Item", attrs)])]))])),
        ])
        let text: F = .def(110, ["TxtA"], [
            ("StSt", .def(111, ["Stry"], [("Blok", .shared([block]))])),
            ("TxtH", .def(112, ["ArFr"], [("FrmB", .f64s([0, 0, 100, 20]))])),
        ])
        let r = try Self.load([.def(120, ["Grup"], [("Chld", .shared([text]))])], renderer: FontRenderer())
        let t = try #require(r.document.layers.first?.children?.first?.textContent)
        #expect(t.runs[0].style.fontFamily == "Helvetica Neue" && t.runs[0].style.weight == 700 && !t.runs[0].style.italic)
        #expect(t.fontFamily == "Helvetica Neue")
        #expect(t.cache?.pixel(x: 0, y: 0) == [0, 0, 0, 1])
    }

    @Test func pixelLayersCopyExactlyAtIntegerOffsets() throws {
        let channels: [(state: UInt8, entry: String?)] = [(4, "t/r"), (4, "t/g"), (2, nil), (2, nil)]
        let layer: F = .def(120, ["Rstr"], [
            ("Bitm", bitmap(130, width: 3, height: 2, format: 0, channels: channels)),
            ints4("BitR", [1, 0, 3, 2]),
            ("Xfrm", .f64s([1, 0, 10, 0, 1, 20])),
        ])
        let entries = [
            ("t/r", tile { x, y in UInt8(truncatingIfNeeded: x * 10 + y) }),
            ("t/g", tile { x, _ in UInt8(truncatingIfNeeded: 200 + x) }),
        ]
        let r = try Self.load([layer], entries: entries)
        let l = try #require(r.document.layers.first)
        #expect(l.name == "Image")
        let s = try #require(l.rasterSurface)
        #expect(s.format == .rgba8)
        #expect(s.contentBounds == PixelRect(x0: 11, y0: 20, x1: 13, y1: 22))
        #expect(bytes(s, PixelRect(x0: 11, y0: 20, x1: 13, y1: 22)) == [10, 201, 255, 255, 20, 202, 255, 255, 11, 201, 255, 255, 21, 202, 255, 255])
    }

    @Test func pixelLayersResampleBilinearlyWithoutBleeding() throws {
        // Red, then blue, both opaque, moved by half a pixel.
        let channels: [(state: UInt8, entry: String?)] = [(4, "t/r"), (0, nil), (4, "t/b"), (2, nil)]
        let layer: F = .def(120, ["Rstr"], [
            ("Bitm", bitmap(130, width: 2, height: 1, format: 0, channels: channels)),
            ("Xfrm", .f64s([1, 0, 0.5, 0, 1, 0])),
        ])
        let entries = [("t/r", tile { x, _ in x == 0 ? 255 : 0 }), ("t/b", tile { x, _ in x == 1 ? 255 : 0 })]
        let r = try Self.load([layer], entries: entries)
        let s = try #require(r.document.layers.first?.rasterSurface)
        #expect(s.contentBounds == PixelRect(x0: 0, y0: 0, x1: 3, y1: 1))
        #expect(bytes(s, PixelRect(x0: 0, y0: 0, x1: 3, y1: 1)) == [255, 0, 0, 128, 128, 0, 128, 255, 0, 0, 255, 128])
    }

    @Test func placedImagesBecomeEmbeddedSmartObjects() throws {
        let original = png()
        let image: F = .def(140, ["ImgN"], [
            ("Bitm", .def(141, ["DyBm"], [("BmpW", .u32(2)), ("BmpH", .u32(1)), ("Bckg", .entry("c/1"))])),
            ("Xfrm", .f64s([1, 0, 3, 0, 1, 4])),
        ])
        let r = try Self.load([image], entries: [("c/1", Synth.stream([blob("Data", original)]))])
        let l = try #require(r.document.layers.first)
        let so = try #require(l.smartContent)
        #expect(so.source == .embedded(fileName: "Affinity image", bytes: original))
        #expect(so.transform == PCAffine.translate(3, 4))
        #expect(bytes(so.cache, PixelRect(x0: 3, y0: 4, x1: 5, y1: 5)) == [220, 40, 60, 255, 0, 0, 0, 0])
        #expect(r.warnings == [])
    }

    @Test func placedImagesMapTheirFileOntoTheAffinitySize() throws {
        // The node says 4×2; the embedded file is 2×1: each file pixel covers 2×2 canvas pixels.
        let image: F = .def(140, ["ImgN"], [("Bitm", .def(141, ["DyBm"], [("BmpW", .u32(4)), ("BmpH", .u32(2)), ("Bckg", .entry("c/1"))]))])
        let r = try Self.load([image], entries: [("c/1", Synth.stream([blob("Data", png())]))])
        let so = try #require(r.document.layers.first?.smartContent)
        #expect(so.transform == PCAffine.scale(2, 2))
        #expect(so.cache?.contentBounds == PixelRect(x0: 0, y0: 0, x1: 3, y1: 2))
        // Bilinear: the corner pixel is (3/4)² covered by the opaque file pixel.
        #expect(bytes(so.cache, PixelRect(x0: 0, y0: 0, x1: 1, y1: 1)) == [220, 40, 60, 143])
    }

    @Test func undecodableEmbeddedImagesAreLeftOut() throws {
        let image: F = .def(140, ["ImgN"], [("Bitm", .def(141, ["DyBm"], [("BmpW", .u32(2)), ("BmpH", .u32(1)), ("Bckg", .entry("c/1"))]))])
        let r = try Self.load([image], entries: [("c/1", Synth.stream([blob("Data", [0x89, 0x50, 0x4E, 0x47, 1, 2, 3])]))])
        #expect(r.document.layers.isEmpty)
        #expect(r.warnings == ["Affinity: an embedded image that could not be decoded was left out."])
    }

    @Test func pixelMasksBecomeLayerMasks() throws {
        func mask(_ id: UInt32) -> F {
            .def(id, ["MRst"], [("Bitm", bitmap(id + 1, width: 2, height: 2, format: 6, channels: [(4, "m/1")]))])
        }
        let group: F = .def(150, ["Grup"], [("Chld", .shared([.def(152, ["Grup"], []), mask(160), mask(170)]))])
        let r = try Self.load([group], entries: [("m/1", tile { x, y in UInt8(truncatingIfNeeded: 100 * x + y) })])
        let g = try #require(r.document.layers.first)
        #expect(g.children?.count == 1)
        let m = try #require(g.mask)
        #expect(m.enabled && m.linked && m.density == 1 && m.feather == 0)
        #expect(m.surface.format == .gray8 && m.surface.defaultPixelValue == [0], "outside the mask the layer is hidden")
        #expect(bytes(m.surface, PixelRect(x0: 0, y0: 0, x1: 2, y1: 2)) == [0, 100, 1, 101])
        #expect(r.warnings == ["Affinity: not imported or approximated: several pixel masks on one layer (only the first is used)."])
    }

    @Test func vectorMasksFromAttachedShapes() throws {
        let masked: F = .def(240, ["Grup"], [
            ("Xfrm", .f64s([1, 0, 100, 0, 1, 0])),
            ("AdCh", .shared([shapeNode(242, "ShNR", [0, 0, 5, 5], fields: [("Xfrm", .f64s([1, 0, 1, 0, 1, 1]))])])),
        ])
        let r = try Self.load([masked])
        let mask = try #require(r.document.layers.first?.vectorMask)
        #expect(mask.enabled && mask.linked && mask.density == 1 && mask.feather == 0)
        #expect(mask.path.fillRule == .nonZero && mask.path.subpaths.count == 1)
        #expect(mask.path.subpaths[0].knots.first?.anchor == PCPoint(101, 1))
    }

    @Test func colours() {
        #expect(AffinityBuilder.color(.rgb(r: 2, g: -1, b: 0.5, a: 0.25)) == .rgb(1, 0, 0.5, 0.25))
        #expect(AffinityBuilder.color(.gray(v: 0.5, a: 1)) == .rgb(0.5, 0.5, 0.5, 1))
        #expect(AffinityBuilder.color(.cmyk(c: 0, m: 0, y: 0, k: 0, a: 1)) == PCColor.rgb(1, 1, 1, 1))
        let lab = AffinityBuilder.color(.lab(l: 100, a: 0, b: 0, alpha: 0.5))
        #expect(lab.mode == .rgb && lab.alpha == 0.5 && abs(lab.c.x - 1) < 1e-3 && abs(lab.c.y - 1) < 1e-3 && abs(lab.c.z - 1) < 1e-3)
    }

    /// The deepest tree PCAffinity returns (128 levels) maps on a 256 KiB thread (an app's
    /// secondary threads get 512 KiB); a recursive walk needs megabytes in a debug build.
    @Test func theDeepestAllowedTreesNeedLittleStack() throws {
        let bytes = onThread(stack: 64 << 20) { () -> [UInt8] in
            var node: F = .def(1000, ["Grup"], [])
            for i in 1...140 { node = .def(1000 + UInt32(i), ["Grup"], [("Chld", .shared([node]))]) }
            return container([node])
        }
        let depth = onThread(stack: 256 << 10) { () -> Int in
            guard let r = try? importAF("deep.af", bytes, renderer: FontRenderer()) else { return -1 }
            var depth = 0
            var l = r.document.layers.first
            while let current = l {
                depth += 1
                l = current.children?.first
            }
            return depth
        }
        #expect(depth == 128)
    }

    // MARK: photocraft-compose gradient_fill.rs tests

    @Test func handlesRoundTrip() {
        let frame = PixelRect(x0: 10, y0: -4, x1: 210, y1: 96)
        for style in GradientStyle.allCases {
            for (from, to) in [(SIMD2<Float>(30, 40), SIMD2<Float>(180, 10)), (SIMD2(100, 50), SIMD2(100, 90)), (SIMD2(5, 5), SIMD2(-40, 70))] {
                let (a, s, o) = GradientHandles.fromHandles(style, from, to, frame, 0)
                let (f2, t2) = GradientHandles.handles(style, a, s, o, frame)
                for (p, q) in [(from, f2), (to, t2)] {
                    #expect(abs(p.x - q.x) < 1e-2 && abs(p.y - q.y) < 1e-2, "\(style): \(p) vs \(q)")
                }
            }
        }
        // A zero-length drag keeps the fallback direction at the shortest length.
        let (a, s, _) = GradientHandles.fromHandles(.radial, SIMD2(0, 0), SIMD2(0, 0), PixelRect(x0: 0, y0: 0, x1: 10, y1: 10), 30)
        #expect(a == 30 && s > 0)
    }
}
