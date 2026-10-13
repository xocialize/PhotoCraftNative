// Shared test helpers: document generators, structural comparison, the corpus.
// Port of photocraft-io (crates/io/tests/common/mod.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.

import CoreGraphics
import Foundation
import ImageIO
import PCDocument
import PCFoundation
import PCIOCore
import PCIOMaps
import PCIOText
import PCPSD
import Testing
@testable import PCIO

enum Corpus {
    /// The Unity corpus: `PCPSD_CORPUS`, default `<fixtures>/psd-corpus` (`Fixtures`); nil when absent.
    static var directory: URL? { Fixtures.psdCorpus }

    /// The PSD/PSB files under `d` (recursively), sorted by path.
    static func psdFiles(in d: URL?) -> [URL] {
        guard let d, let e = FileManager.default.enumerator(at: d, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { ["psd", "psb"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
    }

    static var files: [URL] { psdFiles(in: directory) }

    static var available: Bool { !files.isEmpty }

    /// The second, Photoshop-generated corpus (every mode and depth, blend modes, adjustments,
    /// effects, type, shapes, smart objects, PSB): `PCIO_PS_CORPUS`, default `<fixtures>/ps-corpus`.
    static var psDirectory: URL? { Fixtures.directory("PCIO_PS_CORPUS", default: "ps-corpus") }
    static var psFiles: [URL] { psdFiles(in: psDirectory) }
    static var psAvailable: Bool { !psFiles.isEmpty }

    /// A corpus file's sweep name: its path below the corpus root, `/` as `__`.
    static func sweepName(_ url: URL, _ suffix: String) -> String {
        let roots = [directory, psDirectory].compactMap { $0?.standardizedFileURL.path }
        var rel = url.standardizedFileURL.path
        for r in roots where rel.hasPrefix(r + "/") { rel = String(rel.dropFirst(r.count + 1)) }
        return rel.replacingOccurrences(of: "/", with: "__") + suffix
    }
}

/// When `PCIO_EXPORT_DIR` is set (and not `none`), every PSD/PSB the tests write is also saved
/// there for the Photoshop oracle, which opens each in Photoshop and compares its composite and
/// layer tree with ours. Unset, nothing is written (never into the fixtures folder by default).
/// Corpus re-exports are named `<corpus-file>.reexport.psd`; everything else
/// `synthetic-<test>-<content hash>.psd|psb`.
enum ExportSweep {
    static let directory: URL? = {
        guard let p = ProcessInfo.processInfo.environment["PCIO_EXPORT_DIR"], !p.isEmpty, p != "none" else { return nil }
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return URL(fileURLWithPath: p)
    }()

    /// The file name for exports made inside `withValue` (empty: not saved).
    @TaskLocal static var name: String?

    /// Files larger than this are not swept.
    static let maxBytes = 256 << 20

    private static let installed: Bool = {
        PSDExport.sweep.observer = { bytes in
            guard let b = bytes() else { return }
            ExportSweep.checkTypeLayers(b)
            ExportSweep.save { b }
        }
        return true
    }()

    /// Every type layer a test exports must be one Photoshop can open: its EngineData carries all
    /// the structures Photoshop needs (PCPSD `photoshopStructureGaps()`; without them Photoshop
    /// 27.11 crashes on open or refuses the file).
    static func checkTypeLayers(_ bytes: [UInt8]) {
        guard let file = try? PSDFile(bytes: bytes) else { return }
        for r in file.layers {
            guard let tysh = r.block("TySh") else { continue }
            let gaps = (try? PSDTypeTool(bytes: tysh.data))?.photoshopStructureGaps() ?? [PSDEngineDataGap(path: "TySh", consequence: .crashesPhotoshop)]
            if !gaps.isEmpty { Issue.record("exported type layer \"\(r.displayName)\" has EngineData Photoshop can't open: \(gaps.prefix(4))") }
        }
    }

    /// Runs `body` without saving its exports: they don't belong in the Photoshop acceptance set.
    /// For fixtures that are damaged on purpose (a truncated block kept verbatim, an unreadable
    /// `Anno`, stand-in `CAI ` bytes, a PCIO-built `Txt2`), hostile on purpose (type sizes Photoshop
    /// rasterizes, with a modal for some), or that hold what Photoshop can't in that document (an
    /// adjustment it doesn't offer in the mode/depth).
    static func excluded<T>(_ body: () throws -> T) rethrows -> T { try $name.withValue("") { try body() } }

    /// Installs the sweep (once per process); every suite calls it from its initialiser.
    static func install() { _ = installed }

    static func save(_ bytes: () -> [UInt8]?) {
        guard let dir = directory, ExportSweep.name != "", let b = bytes(), b.count <= maxBytes, b.count > 26 else { return }
        let psb = b[5] == 2
        let file: String
        if let n = ExportSweep.name {
            file = n
        } else {
            let test = (Test.current?.name ?? "export").prefix { $0 != "(" }
            let hash = BLAKE3.hex(b).prefix(10)
            file = "synthetic-\(test)-\(hash).\(psb ? "psb" : "psd")"
        }
        try? Data(b).write(to: dir.appendingPathComponent(file), options: .atomic)
    }
}

/// Quantise to the 1/255 grid so values survive 8-bit PSD fields.
func g(_ v: UInt8) -> Float { Float(v) / 255 }

/// A deterministic pattern surface of `fmt` over `r` (values on the 8-bit grid).
func pattern(_ fmt: PixelFormat, _ r: PixelRect, _ seed: Int, _ alpha: Bool) -> Surface {
    var s = Surface(format: fmt)
    let n = fmt.channels
    var vals: [Float] = []
    vals.reserveCapacity(r.area * n)
    for y in r.y0 ..< r.y1 {
        for x in r.x0 ..< r.x1 {
            for c in 0 ..< n {
                let v: Int
                if c == n - 1 && fmt.alpha {
                    v = alpha ? ((Int(x + y) * 37 + seed) % 256 + 256) % 256 : 255
                } else {
                    v = ((Int(x) * 13 + Int(y) * 7 + seed * 31 + c * 50) % 256 + 256) % 256
                }
                vals.append(Float(v) / 255)
            }
        }
    }
    s.writeRegion(r, vals)
    s.prune()
    return s
}

func maskSurface(_ sample: SampleType, _ r: PixelRect, _ def: Float, _ seed: Int) -> Surface {
    var s = Surface(format: PixelFormat(mode: .grayscale, sample: sample, alpha: false), defaultPixel: [def])
    s.writeRegion(r, (0 ..< r.area).map { Float(($0 * 29 + seed) % 256) / 255 })
    s.prune()
    return s
}

func rect(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) -> PixelRect { PixelRect(x0: x0, y0: y0, x1: x1, y1: y1) }

func fillColor(_ mode: ColorMode) -> PCColor {
    switch mode {
    case .cmyk: PCColor(mode: .cmyk, c: SIMD4(0.2, 0.4, 0.6, 0.1))
    case .grayscale: .gray(0.25)
    default: .rgb(1, 0.5, 0.25)
    }
}

struct Features {
    var groups, masks, adjustments, fills, allBlends, extras: Bool
    static let all = Features(groups: true, masks: true, adjustments: true, fills: true, allBlends: true, extras: true)
    static let pixels = Features(groups: true, masks: true, adjustments: false, fills: false, allBlends: true, extras: false)
}

func rasterLayer(_ name: String, _ fmt: PixelFormat, _ r: PixelRect, _ seed: Int, _ alpha: Bool) -> Layer {
    Layer(name: name, content: .raster(pattern(fmt, r, seed, alpha)))
}

func toneSpace(_ mode: ColorMode) -> ToneSpace {
    switch mode {
    case .cmyk: .cmyk
    case .lab: .lab
    default: .rgb
    }
}

/// A generated document exercising the level 1–3 mapping (photocraft `gen_doc`).
func genDoc(_ mode: ColorMode, _ depth: SampleType, _ f: Features) -> Document {
    var d = Document(name: "gen", size: PixelSize(width: 24, height: 16), mode: mode, depth: depth)
    let fmt = d.pixelFormat
    var bg = rasterLayer("Background", fmt, d.bounds, 1, false)
    bg.locks.transparency = true
    bg.locks.position = true
    d.layers.append(bg)
    var neg = rasterLayer("Negative \u{1F600}", fmt, rect(-5, -3, 7, 6), 2, true)
    neg.opacity = g(200)
    neg.fillOpacity = g(128)
    neg.blend = .multiply
    neg.label = .blue
    neg.advanced.blendInterior = true
    neg.advanced.transparencyShapes = false
    d.layers.append(neg)
    var hidden = rasterLayer("Hidden", fmt, rect(3, 3, 9, 9), 3, true)
    hidden.visible = false
    d.layers.append(hidden)
    var clipped = rasterLayer("Clipped", fmt, rect(0, 0, 10, 10), 4, true)
    clipped.clipped = true
    clipped.blend = .screen
    d.layers.append(clipped)
    d.layers.append(Layer(name: "Empty", content: .raster(Surface(format: fmt))))
    if f.masks {
        var m = rasterLayer("Masked", fmt, rect(2, 2, 14, 12), 5, true)
        m.mask = LayerMask(surface: maskSurface(depth, rect(4, 4, 10, 9), 1, 1))
        m.advanced.layerMaskHidesEffects = true
        m.advanced.vectorMaskHidesEffects = true
        d.layers.append(m)
        var m2 = rasterLayer("Masked2", fmt, rect(-2, 1, 6, 5), 6, true)
        m2.mask = LayerMask(surface: maskSurface(depth, rect(-1, 0, 3, 4), 0, 2), enabled: false, linked: false, density: g(128), feather: 2.5)
        d.layers.append(m2)
    }
    if f.groups {
        let innerChild = rasterLayer("Inner child", fmt, rect(1, 1, 5, 5), 7, true)
        var inner = Layer.group("Inner", [innerChild])
        inner.blend = .multiply
        inner.opacity = g(180)
        inner.withGroup { $0.expanded = false }
        inner.advanced.knockout = .shallow
        let a = rasterLayer("Outer child", fmt, rect(6, 2, 12, 8), 8, true)
        var outer = Layer.group("Outer", [a, inner])
        outer.locks.position = true
        outer.label = .red
        outer.advanced.knockout = .deep
        outer.advanced.blendClipped = false
        d.layers.append(outer)
        d.layers.append(Layer.group("Empty group", []))
    }
    if f.allBlends {
        for (i, m) in BlendMode.layerModes.enumerated() where m != .dissolve {
            var l = rasterLayer("blend \(m.label)", fmt, PixelRect(x: i % 20, y: i % 12, width: 3, height: 2), 10 + i, true)
            l.blend = m
            d.layers.append(l)
        }
    }
    if f.adjustments {
        let line = [CurvePoint(input: 0, output: 0), CurvePoint(input: 1, output: 1)]
        var adjs: [Adjustment] = [
            .invert,
            .threshold(level: g(100)),
            .posterize(levels: 5),
            .brightnessContrast(.init(brightness: 20, contrast: -10, legacy: false)),
            .hueSaturation(.init(hue: 30, saturation: -20, lightness: 5, colorize: false)),
            .exposure(.init(exposure: 0.5, offset: 0, gamma: 1)),
            .levels(.init(master: LevelsChannel(inBlack: g(10), inWhite: g(240), gamma: 1.2, outBlack: 0, outWhite: 1), space: toneSpace(mode))),
            .curves(.init(master: [CurvePoint(input: 0, output: 0), CurvePoint(input: g(128), output: g(150)), CurvePoint(input: 1, output: 1)],
                          perChannel: [line, line, line], space: toneSpace(mode))),
        ]
        if mode != .grayscale {
            adjs += [
                // photocraft's fixture is a truncated `selc` kept as `.unsupported` (in every mode);
                // Photoshop refuses a file with a damaged block it parses (oracle: 47 files), so a
                // valid Selective Color is used, in the colour modes.
                .selectiveColor(.init(relative: true, adjustments: (0 ..< 9).map { SIMD4(Float($0) * 10 - 40, 5, -30, 20) })),
                .vibrance(.init(vibrance: 40, saturation: -10)),
                .colorBalance(.init(shadows: SIMD3(10, 0, -5), midtones: SIMD3(0, 20, 0), highlights: SIMD3(-30, 0, 15), preserveLuminosity: true)),
                .blackWhite(.init(weights: [50, 60, 40, 60, 20, 70], tint: SIMD3(1, 0.8, 0.6))),
                .photoFilter(.init(color: SIMD3(1, Float(32768) / 65535, 0), density: 0.25, preserveLuminosity: false)),
                .channelMixer(.init(matrix: [SIMD4(0.8, 0.2, 0, 0), SIMD4(0, 1, 0, 0.1), SIMD4(0.1, 0, 0.9, 0)], monochrome: false)),
            ]
        }
        // Only the kinds Photoshop offers in this mode and depth (it opens the others as empty
        // pixel layers; `AdjustMap.photoshopOffers`), so the exports are an acceptance set.
        let written: SampleType = depth == .f32 && (mode == .cmyk || mode == .lab) ? .u16 : depth
        adjs = adjs.filter { a in AdjustMap.psdKey(a).map { AdjustMap.photoshopOffers($0, mode: mode, depth: written) } ?? true }
        for (i, a) in adjs.enumerated() {
            var l = Layer(name: "adj \(i)", content: .adjustment(a))
            l.opacity = g(i % 2 == 0 ? 255 : 128)
            d.layers.append(l)
        }
    }
    if f.fills {
        var solid = Layer(name: "Solid fill", content: .fill(.solid(fillColor(mode))))
        solid.opacity = g(64)
        d.layers.append(solid)
    }
    if f.extras {
        d.resolutionDpi = 300
        d.iccProfile = [1, 2, 3, 4]
        d.metadata.xmp = "<x:xmpmeta/>"
        d.metadata.exif = Array("MM\0*\0\0\0\u{08}".utf8)
        d.metadata.psdResources.append(PSDResource(id: 4000, name: "", data: [9, 9, 9]))
        d.guides.horizontal.append(5.5)
        d.guides.vertical.append(12)
        d.channels.append(AlphaChannel(name: "Selection", surface: maskSurface(depth, d.bounds, 0, 3)))
    }
    // A document Photoshop can hold: blend modes it accepts for this mode and depth (photocraft's
    // generator uses every mode everywhere; the export maps the others, see
    // BlendModeAcceptanceTests).
    let written = PixelFormat(mode: mode, sample: depth == .f32 && (mode == .cmyk || mode == .lab) ? .u16 : depth, alpha: true)
    d.forEachLayerMut { l in
        let key = PSDExport.photoshopBlend(l.blend, group: l.isGroup, written).key.string
        if l.blend.hasPSDEquivalent, key != l.blend.psdKey, let b = BlendMode(psdKey: key) { l.blend = b }
    }
    return d
}

/// Differences between two documents, ignoring runtime ids (photocraft `assert_docs_eq`).
struct DocDiff {
    var problems: [String] = []
    /// Compare type layers' `TySh` blocks (off where the export rebuilds EngineData Photoshop can't
    /// open, as photocraft's `assert_layers_eq`, which never compares them).
    var compareTySh = true
    mutating func check(_ ok: Bool, _ what: @autoclosure () -> String) { if !ok { problems.append(what()) } }

    static func pruned(_ s: Surface) -> Surface {
        var s = s
        s.prune()
        return s
    }

    mutating func surfaces(_ a: Surface, _ b: Surface, _ ctx: String) {
        let (a, b) = (DocDiff.pruned(a), DocDiff.pruned(b))
        check(a.format == b.format, "\(ctx): format \(a.format) vs \(b.format)")
        check(a.defaultPixel == b.defaultPixel, "\(ctx): default pixel")
        check(a.contentBounds == b.contentBounds, "\(ctx): bounds \(a.contentBounds) vs \(b.contentBounds)")
        let r = a.contentBounds.union(b.contentBounds)
        if !r.isEmpty, a.format == b.format { check(a.readInterleaved(r) == b.readInterleaved(r), "\(ctx): pixels differ") }
    }

    mutating func color(_ a: PCColor, _ b: PCColor, _ ctx: String) {
        check(a.mode == b.mode, "\(ctx): colour mode")
        for i in 0 ..< 4 where abs(a.c[i] - b.c[i]) >= 1e-4 { problems.append("\(ctx): colour \(a) vs \(b)") }
    }

    mutating func layers(_ a: Layer, _ b: Layer, _ path: String, strictBlocks: Bool = false) {
        let ctx = "\(path)/\(a.name)"
        check(a.name == b.name, "\(ctx): name \(b.name)")
        check(a.visible == b.visible, "\(ctx): visible")
        check(a.locks == b.locks, "\(ctx): locks \(a.locks) vs \(b.locks)")
        check(a.blend == b.blend, "\(ctx): blend \(a.blend) vs \(b.blend)")
        check(a.opacity == b.opacity, "\(ctx): opacity")
        check(a.fillOpacity == b.fillOpacity, "\(ctx): fill")
        check(a.clipped == b.clipped, "\(ctx): clipped")
        check(a.label == b.label, "\(ctx): label")
        check(a.advanced == b.advanced, "\(ctx): advanced blending \(a.advanced) vs \(b.advanced)")
        check(a.excludedChannels == b.excludedChannels, "\(ctx): channel restrictions")
        check(a.blendIf == b.blendIf, "\(ctx): blend if")
        check(a.effects.psdRaw == b.effects.psdRaw, "\(ctx): effects raw")
        check(a.effects.enabled == b.effects.enabled, "\(ctx): effects enabled")
        check(a.effects.items == b.effects.items, "\(ctx): effects items")
        check(a.vectorMask == b.vectorMask, "\(ctx): vector mask")
        check(a.linkGroup == b.linkGroup, "\(ctx): link group")
        if a.psdId != nil { check(a.psdId == b.psdId, "\(ctx): psd id \(String(describing: a.psdId)) vs \(String(describing: b.psdId))") }
        for blk in a.psdBlocks where !b.psdBlocks.contains(blk) {
            problems.append("\(ctx): preserved block \(blk.key) (\(blk.data.count) bytes) missing or changed")
        }
        if strictBlocks {
            for blk in b.psdBlocks where !a.psdBlocks.contains(where: { $0.key == blk.key }) {
                problems.append("\(ctx): extra block \(blk.key) after the round trip")
            }
        }
        if let fc = a.fillCache {
            if let o = b.fillCache { surfaces(fc.surface, o.surface, "\(ctx): fill cache") } else { problems.append("\(ctx): fill cache lost") }
        }
        switch (a.mask, b.mask) {
        case (nil, nil): break
        case let (x?, y?):
            check(x.enabled == y.enabled, "\(ctx): mask enabled")
            check(x.linked == y.linked, "\(ctx): mask linked")
            check(x.density == y.density, "\(ctx): mask density")
            check(x.feather == y.feather, "\(ctx): mask feather")
            surfaces(x.surface, y.surface, "\(ctx): mask")
        default: problems.append("\(ctx): mask presence differs")
        }
        switch (a.content, b.content) {
        case let (.raster(x), .raster(y)): surfaces(x, y, ctx)
        case let (.group(x), .group(y)):
            check(x.expanded == y.expanded, "\(ctx): expanded")
            check(x.artboard == y.artboard, "\(ctx): artboard")
            check(x.children.count == y.children.count, "\(ctx): child count \(x.children.count) vs \(y.children.count)")
            for (p, q) in zip(x.children, y.children) { layers(p, q, ctx, strictBlocks: strictBlocks) }
        case let (.adjustment(x), .adjustment(y)): check(x == y, "\(ctx): adjustment \(x) vs \(y)")
        case let (.fill(.solid(x)), .fill(.solid(y))): color(x, y, ctx)
        case let (.fill(x), .fill(y)): check(x == y, "\(ctx): fill")
        case let (.text(x), .text(y)):
            check(x.text == y.text, "\(ctx): text")
            // The first save adds the `TextIndex` naming the layer's `Txt2` object (#1348), and an
            // odd-length block gains its pad byte (#200).
            func normal(_ t: TextLayer) -> [UInt8]? {
                t.psdRaw.flatMap { PSDText.setTextIndex($0, 0) }.map { Array($0.reversed().drop { $0 == 0 }.reversed()) }
            }
            check(!compareTySh || x.psdRaw == y.psdRaw || normal(x) == normal(y), "\(ctx): TySh")
            switch (x.cache, y.cache) {
            case let (p?, q?): surfaces(p, q, ctx)
            case (nil, nil): break
            default: problems.append("\(ctx): text cache presence")
            }
        case let (.shape(x), .shape(y)):
            check(x.path == y.path, "\(ctx): shape path")
            check(x.fill == y.fill, "\(ctx): shape fill")
            check(x.stroke == y.stroke, "\(ctx): shape stroke")
            if let p = x.cache, let q = y.cache { surfaces(p, q, ctx) }
        case let (.smart(x), .smart(y)):
            check(x.source == y.source, "\(ctx): smart source")
            check(x.transform == y.transform, "\(ctx): smart transform")
            check(x.smartFilters == y.smartFilters, "\(ctx): smart filters")
            check(x.psdRaw == y.psdRaw, "\(ctx): placed data")
            check(x.warp == y.warp, "\(ctx): warp")
            check(x.perspective == y.perspective, "\(ctx): perspective")
            if let p = x.cache, let q = y.cache { surfaces(p, q, ctx) }
        default: problems.append("\(ctx): kind \(a.content.kindName) vs \(b.content.kindName)")
        }
    }

    mutating func documents(_ a: Document, _ b: Document, strictBlocks: Bool = false) {
        check(a.size == b.size, "size")
        check(a.mode == b.mode, "mode")
        check(a.depth == b.depth, "depth")
        check(abs(a.resolutionDpi - b.resolutionDpi) < 1e-3, "dpi \(a.resolutionDpi) vs \(b.resolutionDpi)")
        check(a.iccProfile == b.iccProfile, "icc")
        // EXIF is normalised on export (Orientation 1, no stale thumbnail, the saved resolution;
        // photocraft #1691/#2147): compared after the same normalisation.
        var ma = a.metadata, mb = b.metadata
        let ppi: (Float, Float)? = a.resolutionDpi > 0 ? (a.resolutionDpi, a.resolutionDpi) : nil
        ma.exif = ma.exif.map { MetadataExport.exportExif($0, ppi) }
        ma.xmp = ma.xmp.map { MetadataExport.exportXmp($0, ppi) }
        mb.exif = mb.exif.map { MetadataExport.exportExif($0, ppi) }
        check(ma.xmp == mb.xmp, "xmp")
        check(ma.exif == mb.exif, "exif")
        check(ma.text == mb.text, "metadata text")
        check(ma.psdResources == mb.psdResources, "resources \(ma.psdResources.map(\.id)) vs \(mb.psdResources.map(\.id))")
        check(ma.psdGlobalBlocks == mb.psdGlobalBlocks, "global blocks \(ma.psdGlobalBlocks.map { "\($0.key):\($0.data.count)" }) vs \(mb.psdGlobalBlocks.map { "\($0.key):\($0.data.count)" })")
        check(a.guides == b.guides, "guides")
        check(a.paths == b.paths, "paths")
        check(a.workPath == b.workPath, "work path")
        check(a.globalLight == b.globalLight, "global light")
        check(a.patterns == b.patterns, "patterns")
        check(a.notes == b.notes, "notes")
        check(a.slices == b.slices, "slices")
        check(a.layerComps.count == b.layerComps.count, "comps")
        check(a.textStyles == b.textStyles, "text styles")
        check(a.channels.count == b.channels.count, "alpha channels \(a.channels.count) vs \(b.channels.count)")
        for (x, y) in zip(a.channels, b.channels) {
            check(x.name == y.name, "channel name \(x.name) vs \(y.name)")
            surfaces(x.surface, y.surface, "channel \(x.name)")
        }
        check(a.layers.count == b.layers.count, "root layer count \(a.layers.count) vs \(b.layers.count)")
        for (x, y) in zip(a.layers, b.layers) { layers(x, y, "", strictBlocks: strictBlocks) }
    }

    static func of(_ a: Document, _ b: Document, strictBlocks: Bool = false) -> [String] {
        var d = DocDiff()
        d.documents(a, b, strictBlocks: strictBlocks)
        return d.problems
    }
}

/// A file's merged image in its document's pixel format, un-matted, for `FixedCompositor`.
func mergedPixels(_ file: PSDFile, _ doc: Document) throws -> [Float] {
    let fmt = doc.pixelFormat
    let cc = fmt.mode.colorChannels
    let h = file.header
    let n = Int(h.width) * Int(h.height)
    let all = try file.decodeMerged()
    let plane = h.rowBytes * Int(h.height)
    var planes: [[UInt8]?] = (0 ..< cc).map { c in (c + 1) * plane <= all.count ? Array(all[c * plane ..< (c + 1) * plane]) : nil }
    planes.append(file.mergedHasAlpha && (cc + 1) * plane <= all.count ? Array(all[cc * plane ..< (cc + 1) * plane]) : nil)
    var fill = [[UInt8]](repeating: PSDPixels.zeroSample(fmt.sample), count: cc)
    fill.append(PSDPixels.maxSample(fmt.sample))
    let bytes = PSDPixels.interleave(planes, fill, n, fmt.sample, [Bool](repeating: fmt.mode == .cmyk, count: cc) + [false])
    let s = Surface(format: fmt, rect: doc.bounds, interleaved: bytes)
    var v = s.readRegion(doc.bounds)
    if file.mergedHasAlpha {
        let white = fmt.components(fromRGBA: SIMD4(1, 1, 1, 1))
        for i in 0 ..< n {
            let a = v[i * (cc + 1) + cc]
            for c in 0 ..< cc { v[i * (cc + 1) + c] = a <= 0 ? 0 : PSDPixels.unmatte(v[i * (cc + 1) + c], a, white[c]) }
        }
    }
    return v
}

/// ImageIO's decode of a PSD's composite as straight-or-premultiplied 8-bit RGBA, with the alpha
/// info it reports.
func imageIORGBA8(_ bytes: [UInt8]) -> (data: [UInt8], width: Int, height: Int, alpha: CGImageAlphaInfo)? {
    guard let src = CGImageSourceCreateWithData(Data(bytes) as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let (w, h) = (img.width, img.height)
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ok = buf.withUnsafeMutableBytes { p -> Bool in
        guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: img.colorSpace?.model == .rgb ? img.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.setBlendMode(.copy)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? (buf, w, h, img.alphaInfo) : nil
}
