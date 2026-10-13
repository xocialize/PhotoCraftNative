// Synthetic documents exercising every part of the model.
// Port of photocraft-format (crates/format/tests/common/mod.rs), MIT OR Apache-2.0, © ArtCraft Team
// and the PhotoCraft contributors.

import Foundation
@testable import PCFormat
import PCDocument
import PCFoundation

struct Rng {
    var state: UInt64
    init(_ s: UInt64) { state = s }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func f() -> Float { Float(next() >> 40) / Float(1 << 24) }
}

/// Scribbles deterministic pixels into a surface, including negative coordinates and far-away
/// tiles. Float surfaces get HDR values.
func scribble(_ s: inout Surface, _ seed: UInt64, _ hdr: Bool) {
    var r = Rng(seed)
    let ch = s.channels
    for (x0, y0) in [(Int32(-12), Int32(-7)), (0, 0), (250, 250), (600, 30)] {
        for dy in Int32(0) ..< 9 {
            for dx in Int32(0) ..< 11 {
                let px = (0 ..< ch).map { _ in hdr ? r.f() * 4 - 1 : r.f() }
                s.setPixel(x: x0 + dx, y: y0 + dy, px)
            }
        }
    }
}

func blob(_ seed: UInt8, _ n: Int) -> [UInt8] { (0 ..< n).map { UInt8(truncatingIfNeeded: $0) &* 31 &+ seed } }

/// A path using every knot kind and path operation.
func vectorPath() -> VectorPath {
    VectorPath([
        Subpath(closed: true, knots: [
            Knot.corner(1.5, 2.25),
            Knot.smooth(anchor: PCPoint(40, 5), inCtrl: PCPoint(30, 0), outCtrl: PCPoint(50, 10)),
            Knot.corner(10, 60),
        ], op: .combine),
        Subpath.polygon([(5, 5), (9, 5), (9, 9)]).withOp(.subtract),
        Subpath.polyline([(0, 0), (3, 4)]).withOp(.exclude),
        Subpath.polygon([(0, 0), (3, 4), (3, 0)]).withOp(.intersect),
    ])
}

func richDoc(_ mode: ColorMode, _ depth: SampleType) -> Document {
    let hdr = depth == .f32
    var d = Document.withBackground(name: "Rich", size: PixelSize(width: 300, height: 280), mode: mode, depth: depth, fill: .white)
    d.resolutionDpi = 300
    d.iccProfile = blob(1, 500)
    let pf = d.pixelFormat

    var paint = Layer.raster("Paint", format: pf)
    paint.withRaster { scribble(&$0, 1, hdr) }
    paint.blend = .multiply
    paint.opacity = 0.75
    paint.fillOpacity = 0.5
    paint.clipped = true
    paint.label = .violet
    paint.locks.pixels = true
    var mask = LayerMask.hideAll()
    scribble(&mask.surface, 2, false)
    mask.density = 0.8
    mask.feather = 3.5
    mask.linked = false
    paint.mask = mask
    paint.effects.items.append(.colorOverlay(.init(common: FxCommon(.normal, 0.8), color: .rgb(1, 0.2, 0.1))))
    paint.effects.items.append(.gradientOverlay(.init(common: FxCommon(.normal, 0.8), gradient: StyleGradient(), dither: true)))
    paint.effects.psdRaw = blob(3, 64)
    paint.psdBlocks.append(PSDLayerBlock(key: "vmsk", data: blob(4, 40)))
    paint.psdBlocks.append(PSDLayerBlock(key: "lnsr", data: blob(5, 4)))
    paint.psdId = 42

    var inner = Layer.raster("Inner", format: pf)
    inner.withRaster { scribble(&$0, 6, hdr) }
    let nested = Layer.group("Nested", [inner])
    var adj = Layer(name: "Hue/Sat", content: .adjustment(.hueSaturation(.init(hue: 30, saturation: -10, lightness: 5, colorize: false,
                                                                                  ranges: HueRange.defaults))))
    adj.visible = false
    var group = Layer.group("Group", [nested, adj])
    group.withGroup { $0.expanded = false }

    var fill = Layer(name: "Fill", content: .fill(.solid(.rgb(0.1, 0.2, 0.3, 0.9))))
    var fc = Surface(format: pf)
    scribble(&fc, 7, false)
    fill.fillCache = FillCache(fill: .solid(.rgb(0.1, 0.2, 0.3, 0.9)), surface: fc)
    let grad = Layer(name: "Gradient", content: .fill(.gradient(GradientFill(
        stops: [ColorStop(0, .black), ColorStop(1, .white)], angle: 45, scale: 1.5, style: .linear, reverse: true,
        opacityStops: [OpacityStop(0, 1), OpacityStop(1, 0.25)], midpoints: [0.3], offset: SIMD2(0.1, -0.2), dither: true, align: false))))

    var cache = Surface(format: pf)
    scribble(&cache, 8, false)
    var tl = TextLayer(text: "Hello ✓ world", fontFamily: "Inter", sizePt: 24, color: .rgb(0.2, 0.4, 0.6))
    tl.transform = .translate(10.5, 20.25)
    tl.cache = cache
    tl.psdRaw = blob(9, 100)
    var s0 = CharStyle()
    s0.kerning = .off
    s0.kern = 120
    var s2 = CharStyle()
    s2.kerning = .optical
    tl.runs = [TextRun(len: 1, style: s0), TextRun(len: 5, style: CharStyle()), TextRun(len: 9, style: s2)]
    tl.paragraphs = [ParagraphRun(len: 15, style: ParagraphStyle())]
    tl.shape = .box(.init(x: 1, y: 2, width: 100, height: 50))
    tl.orientation = .vertical
    tl.antialias = .crisp
    tl.warp = TextWarp(style: "warpArc", value: 25)
    let text = Layer(name: "Type", content: .text(tl))

    var shape = Layer(name: "Shape", content: .shape(ShapeLayer(
        path: vectorPath(), fill: .solid(.black),
        stroke: ShapeStroke(width: 2.5, paint: .solid(.rgb(0, 0.5, 1)), opacity: 0.75, align: .outside, cap: .round, join: .bevel,
                            miterLimit: 4, dashes: [2, 1], dashOffset: 0.5),
        live: .rect(rect: SIMD4(1, 2, 30, 40), radii: SIMD4(4, 0, 4, 0)), cache: cache, psdRaw: blob(10, 30))))
    shape.label = .green
    var vm = VectorMask(path: vectorPath())
    vm.enabled = false
    vm.density = 0.4
    vm.feather = 3
    vm.path.inverted = true
    paint.vectorMask = vm

    var so = SmartObject(source: .embedded(fileName: "inner.png", bytes: blob(11, 2000)), transform: .scale(0.5), cache: cache)
    so.smartFilters = [SmartFilter(command: "filter.blur.gaussian", params: ["radius": 2.5, "nested": ["a": [1, 2, 3]]], blend: .screen,
                                   opacity: 0.6, visible: true)]
    so.filtersEnabled = false
    so.filterMask = LayerMask(surface: Surface(format: .gray8, defaultPixel: [1]), enabled: true, linked: false, density: 0.75, feather: 0)
    so.warp = Warp.custom(BezierMesh.identity(bounds: SIMD4(0, 0, 48, 24), cols: 2, rows: 1), bounds: SIMD4(0, 0, 48, 24))
    so.stackMode = .median
    // Distort / Perspective placement, so the round trip covers it.
    so.perspective = [1, 0.1, 2, 0.05, 1, 3, 0.001, 0.0005, 1]
    let smart = Layer(name: "Smart", content: .smart(so))
    var lo = SmartObject(source: .linked(path: "/tmp/linked.psd"), transform: .identity, cache: nil)
    lo.psdRaw = blob(12, 8)
    let linked = Layer(name: "Linked", content: .smart(lo))
    d.layers += [paint, group, fill, grad, text, shape, smart, linked]

    var ch = Surface(format: PixelFormat.gray8.with(sample: depth))
    scribble(&ch, 13, false)
    var alpha = AlphaChannel(name: "Alpha 1", surface: ch)
    alpha.color = .rgb(0, 0.5, 1)
    alpha.opacity = 0.35
    alpha.indicates = .selectedAreas
    d.channels.append(alpha)
    var spot = AlphaChannel(name: "Spot", surface: ch)
    spot.spot = SpotInk(color: .rgb(1, 0, 0.5), solidity: 0.7)
    d.channels.append(spot)
    d.quickMask = AlphaChannel(name: "Quick Mask", surface: ch)
    d.quickMaskUnselected = true
    var pat = Surface(format: PixelFormat(mode: .rgb, sample: .u16, alpha: true))
    scribble(&pat, 21, false)
    d.patterns.append(Pattern(name: "$$$/Patterns/Test=Scribble", surface: pat, width: 32, height: 24))
    d.colorTable = ColorTable(colors: [SIMD3(0, 0, 0), SIMD3(255, 128, 0)], transparent: 1)
    d.duotone = Duotone(inks: [DuotoneInk(name: "Black", color: SIMD3(repeating: 0)), DuotoneInk(name: "PANTONE 151 C", color: SIMD3(1, 0.5, 0))],
                        psdRaw: [1, 2, 3])
    d.guides = Guides(horizontal: [10, 20.5], vertical: [100.25], colors: [GuideColor(vertical: true, position: 100.25, rgb: SIMD3(0x33, 0x66, 0xFF))])
    var sel = Surface(format: .gray8)
    scribble(&sel, 14, false)
    d.selection = sel
    d.metadata.xmp = "<x:xmpmeta/>"
    d.metadata.text = [MetadataText("Author", "Synthetic é 雪"), MetadataText("Comment", "first"), MetadataText("Comment", "second")]
    d.metadata.exif = blob(15, 64)
    d.metadata.psdResources.append(PSDResource(id: 1036, name: "thumb", data: blob(16, 20)))
    d.metadata.psdGlobalBlocks.append(PSDGlobalBlock(signature: "8BIM", key: "Patt", data: blob(17, 50)))
    d.globalLight = GlobalLight(angle: 120, altitude: 30)
    d.paths.append(NamedPath(name: "Path 1", path: vectorPath(), psdRaw: blob(18, 52)))
    d.paths.append(NamedPath(name: "Empty", path: VectorPath(), psdRaw: nil))
    var wp = vectorPath()
    wp.fillRule = .evenOdd
    d.workPath = wp
    d.clippingPath = ClippingPath(name: "Path 1", flatness: 2)
    return d
}

/// A fresh, empty directory under the system temp dir, unique per test process and call.
func tempDir(_ tag: String) -> URL {
    let n = tempCounter.wrappingAdd(1, ordering: .relaxed).oldValue
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pcformat-\(tag)-\(getpid())-\(n)")
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

import Synchronization
let tempCounter = Atomic<UInt64>(0)

func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

func save(_ d: Document, _ opts: SaveOptions = SaveOptions()) throws -> [UInt8] { try PcraftFormat.save(d, options: opts) }
func load(_ b: [UInt8], _ opts: LoadOptions = LoadOptions()) throws -> Document { try PcraftFormat.load(b, options: opts) }

/// Rebuilds a ZIP bundle entry by entry; `f` returns the new data or nil to drop the entry.
func rebuild(_ bytes: [UInt8], _ f: (String, [UInt8]) throws -> [UInt8]?) throws -> [UInt8] {
    let r = try ZipReader(bytes)
    var z = ZipWriter()
    for e in r.entries {
        if let d = try f(e.name, try r.read(e, max: .max)) { try z.add(e.name, d) }
    }
    return try z.finish()
}

/// The manifest of a bundle as a JSON object tree (Foundation), and back.
func manifestJSON(_ bytes: [UInt8]) throws -> [String: Any] {
    let r = try ZipReader(bytes)
    return try JSONSerialization.jsonObject(with: Data(try r.read(named: "manifest.json", max: .max))) as? [String: Any] ?? [:]
}

func withManifest(_ bytes: [UInt8], _ edit: (inout [String: Any]) throws -> Void) throws -> [UInt8] {
    try rebuild(bytes) { name, data in
        guard name == "manifest.json" else { return data }
        var m = try JSONSerialization.jsonObject(with: Data(data)) as? [String: Any] ?? [:]
        try edit(&m)
        return [UInt8](try JSONSerialization.data(withJSONObject: m))
    }
}

import PCIOCore
