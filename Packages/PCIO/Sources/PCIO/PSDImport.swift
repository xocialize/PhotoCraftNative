// PSD/PSB → Document: fidelity levels 1–7 (flattened image; raster layers, masks, blend, opacity
// and fill, visibility, names, locks, colours; groups incl. pass-through, clipping, Blend If,
// knockout; adjustment and fill layers; effects; type; smart objects; vector masks and shapes),
// plus resources (resolution, ICC, XMP/EXIF, guides, paths, alpha/spot channels, comps, slices,
// notes, patterns).
// Port of photocraft-io (crates/io/src/psd_import.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// Never fails on a parsed file: problems become warnings. Every layer keeps its unmodelled tagged
// blocks in `Layer.psdBlocks` (vector masks, blending options, original adjustment/fill blocks,
// type and smart-object data) and re-export writes them back; type, shape and smart-object layers
// keep Photoshop's pixels as their cache, fill layers Photoshop's rendering as `fillCache`.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCIOMaps
import PCIOSmart
import PCIOText
import PCPSD

/// Options for a PSD import.
public struct PSDImportOptions: Sendable {
    /// Renders shape layers stored without pixels (32-bit files, files saved without layer
    /// pixels) and type layers without pixels. nil keeps them empty, with a warning.
    public var renderer: (any LayerContentRenderer)?
    /// Cancellation and progress (checked per layer record).
    public var interrupt: Interrupt

    public init(renderer: (any LayerContentRenderer)? = nil, interrupt: Interrupt = .none) {
        self.renderer = renderer
        self.interrupt = interrupt
    }
}

public enum PSDImport {
    /// Resources that are mapped to document fields or regenerated on export.
    public static let mappedResources: [UInt16] = [
        PSDResourceID.globalAngle, PSDResourceID.globalAltitude, PSDResourceID.resolutionInfo, PSDResourceID.iccProfile, PSDResourceID.xmp,
        PSDResourceID.exif, PSDResourceID.versionInfo, PSDResourceID.thumbnail, PSDResourceID.thumbnailPS4, PSDResourceID.layerState,
        PSDResourceID.layerGroupInfo, 1032, 1045, 1006, 1069, 1072, ChannelMap.displayInfo, ChannelMap.displayInfoOld, ChannelMap.quickMaskInfo,
    ]

    /// The synthetic block a group's `psdBlocks` keeps its bounding divider's own blocks in (the
    /// divider is not a layer of the model): (signature, key, u32 length, data) entries. Never
    /// written to a file as a block; the exporter rebuilds the divider record from it.
    public static let dividerKey: FourCC = "PcDv"

    /// The divider blocks a group kept from its file (see `dividerKey`).
    public static func dividerBlocks(_ group: Layer) -> [PSDTaggedBlock] {
        guard let raw = group.psdBlocks.first(where: { FourCC($0.key) == dividerKey })?.data else { return [] }
        var r = BEReader(raw)
        var out: [PSDTaggedBlock] = []
        while r.remaining >= 12 {
            guard let sig = try? r.fourCC(), let key = try? r.fourCC(), let n = try? r.u32(), let d = try? r.bytes(Int(n)) else { break }
            out.append(PSDTaggedBlock(key: key, data: Data(d), signature: sig))
        }
        return out
    }

    /// Encodes a divider record's blocks for `dividerKey` (nil when it has none worth keeping).
    static func dividerBlockData(_ rec: PSDLayerRecord) -> [UInt8]? {
        let kept = rec.blocks.filter { !["luni", "lyid", "lsct", "lsdk"].contains($0.key) }
        if kept.isEmpty { return nil }
        var w = BEWriter()
        for b in kept {
            w.fourCC(b.signature)
            w.fourCC(b.key)
            w.u32(UInt32(b.data.count))
            w.put(b.data)
        }
        return w.bytes
    }

    /// Mapped resources whose original bytes are also kept in `Metadata.psdResources`: the export
    /// writes them back verbatim while they still describe the document (resolution and its
    /// display units, guides and the grid, link groups, the merged transparency's channel name and
    /// options) and regenerates them otherwise.
    public static let rawKeptResources: [UInt16] = [PSDResourceID.resolutionInfo, 1032, PSDResourceID.layerGroupInfo, 1006, 1045,
                                                     ChannelMap.displayInfo, ChannelMap.displayInfoOld]

    /// Drops the kept copies of mapped resources (`rawKeptResources`) that add nothing to the
    /// model: those the export writes identically from the document fields, the channel
    /// names/options the export regenerates whenever the document has extra channels, and
    /// Photoshop's default IPTC and print-output resources (written by the default record
    /// conventions; a photocraft-shape export leaves them out). A document →
    /// PSD → document round trip then gives back the document it started from, while a
    /// Photoshop file's own spelling (display units, grid, transparency-only channel options)
    /// still survives.
    static func dropRedundantRawResources(_ doc: inout Document, transparency: Bool = false) {
        let resolution = [UInt8](PSDResolutionInfo(dpi: Double(doc.resolutionDpi)).serialized())
        let guides: [UInt8]? = doc.guides.isEmpty ? nil : PSDExport.guidesResource(doc)
        let links = PSDExport.linkGroupResource(doc.layers)
        // Records the export writes: one per layer, two per group (folder and divider).
        var records = 0
        doc.forEachLayer { _, _, l in records += l.isGroup ? 2 : 1 }
        // With extra channels the export writes the kept channel resources while they still
        // describe the channels: copies equal to what it would generate add nothing.
        let extra = doc.channels + (doc.quickMask.map { [$0] } ?? [])
        let generated = extra.isEmpty ? [] : PSDExport.channelResources(Document(name: "", size: doc.size, mode: doc.mode, depth: doc.depth), extra,
                                                                            transparency: transparency && doc.mode != .multichannel)
        doc.metadata.psdResources.removeAll { r in
            switch r.id {
            case PSDResourceID.resolutionInfo: r.name.isEmpty && r.data == resolution
            case 1032: r.name.isEmpty && r.data == guides
            // The export writes its own when anything is linked, and Photoshop's all-zero list
            // (one id per record) only when it still has one entry per record.
            case PSDResourceID.layerGroupInfo: links != nil || !(r.data.allSatisfy { $0 == 0 } && r.data.count == records * 2)
            case 1006, 1045, ChannelMap.displayInfo:
                !extra.isEmpty && r.name.isEmpty && generated.contains { $0.id == r.id && [UInt8]($0.data) == r.data }
            case ChannelMap.displayInfoOld: !extra.isEmpty
            // Photoshop's defaults, which the export writes anyway.
            case PSDResourceID.iptc, PSDResourceID.printInformation:
                r.name.isEmpty && PSDExport.photoshopDefaultResources.contains { $0.id == r.id && [UInt8]($0.data) == r.data }
            default: false
            }
        }
    }

    /// Blocks regenerated from document fields on export; not kept in `Layer.psdBlocks`.
    public static let regenerated: [FourCC] = ["luni", "lyid", "lsct", "lsdk", "iOpa", "lspf", "lclr", "lfx2", "lfxs"]

    /// Converts a parsed PSD into a document. Never fails: problems become warnings. Throws only
    /// `PCIOError.cancelled` when `options.interrupt` is cancelled.
    public static func document(_ file: PSDFile, options: PSDImportOptions = PSDImportOptions()) throws -> (document: Document, warnings: [String]) {
        var importer = Importer(file: file, options: options)
        return try importer.run()
    }

    /// Rejects a file whose groups nest deeper than the document model's cap (nesting past the
    /// cap could never be saved; `.pcraft` refuses it).
    public static func checkGroupDepth(_ file: PSDFile) throws {
        if groupDepth(file) > maxGroupDepthLimit {
            throw PCIOError.unsupported("layer groups nested deeper than \(maxGroupDepthLimit)")
        }
    }

    /// Deepest group nesting of the file's layer records, computed iteratively.
    public static func groupDepth(_ file: PSDFile) -> Int {
        var open = 0, depth = 0
        for rec in file.layers {
            switch rec.sectionType {
            case .boundingDivider:
                open += 1
                depth = max(depth, open)
            case .openFolder, .closedFolder:
                open = max(0, open - 1)
            default: break
            }
        }
        return depth
    }

    static func docMode(_ m: PSDColorMode) -> ColorMode? {
        switch m {
        case .bitmap: .bitmap
        case .grayscale: .grayscale
        case .indexed: .indexed
        case .rgb: .rgb
        case .cmyk: .cmyk
        case .multichannel: .multichannel
        case .duotone: .duotone
        case .lab: .lab
        default: nil
        }
    }

    /// The Unicode alpha names resource (1045): u32 count + UTF-16 units each.
    static func unicodeNames(_ data: [UInt8]) -> [String] {
        var out: [String] = []
        var r = BEReader(data)
        while r.remaining >= 4 {
            guard let units = try? r.unicodeUnits() else { break }
            out.append(String(decoding: units, as: UTF16.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0")))
        }
        return out
    }

    /// Grid and guides (1032): version, grid cycle ×2, count, then (location in 1/32 px, direction).
    static func parseGuides(_ data: [UInt8], _ doc: inout Document) {
        var r = BEReader(data, at: 12)
        guard let count = try? r.u32() else { return }
        for _ in 0 ..< Int(count) {
            guard let loc = try? r.u32(), let dir = try? r.u8() else { break }
            let pos = Double(Int32(bitPattern: loc)) / 32
            if dir == 1 { doc.guides.horizontal.append(pos) } else { doc.guides.vertical.append(pos) }
        }
    }

    /// Real-mask metadata without a -3 channel still selects the synthetic -2 mask.
    static func selectedRealMask(_ rec: PSDLayerRecord) -> PSDRealMask? {
        guard rec.channel(PSDChannelID.realUserMask) != nil else { return nil }
        return rec.layerMask?.real
    }

    static func pixelRect(_ r: PSDRect) -> PixelRect { PixelRect(x0: r.left, y0: r.top, x1: r.right, y1: r.bottom) }

    /// The fill of a plain shape layer (fill block + vector path, no stroke) to import as a fill
    /// layer with a vector mask: when its mask parameters give the vector mask a density below
    /// 100 % or a feather, or when it fills with a pattern.
    static func softShapeFill(_ rec: PSDLayerRecord, hasVector: Bool, fillKey: FourCC?) -> (fill: Fill, soft: Bool)? {
        guard hasVector, rec.block("vstk") == nil, rec.block("vscg") == nil, let k = fillKey,
              let b = rec.block(k), let fill = Blocks.parseFill(k, [UInt8](b.data)) else { return nil }
        let p = rec.layerMask?.parameters
        let soft = p.map { ($0.vectorDensity.map { $0 < 255 } ?? false) || ($0.vectorFeather.map { $0 > 0 } ?? false) } ?? false
        // A pattern-filled shape can't be rasterised on its own, and its stored pixels may be the
        // unclipped fill (photocraft's own export writes fill layers so, #1907): it is a pattern
        // fill layer seen through its vector mask.
        var pattern = false
        if case .pattern = fill { pattern = true }
        return soft || pattern ? (fill, soft) : nil
    }
}

/// The import state (photocraft `Ctx`).
struct Importer {
    let file: PSDFile
    let options: PSDImportOptions
    var fmt = PixelFormat.rgba8
    var maskFmt = PixelFormat.gray8
    var cc = 3
    var cmyk = false
    var warnings: [String] = []
    /// Document resolution (type sizes are converted to points with it).
    var dpi: Float = 72
    /// The parsed `Txt2` block (type settings EngineData lacks, e.g. optical kerning).
    var txt2: PSDEngineData?
    /// Smart-filter caches from the global `FEid`/`FXid` blocks (filter masks, by placed id).
    var filterEffects: [PSDFilterEffectsItem] = []
    /// Placed layers naming the same source share editable contents, not their placement.
    var smartContents: [String: SmartContentsId] = [:]
    var done = 0
    var total = 0

    init(file: PSDFile, options: PSDImportOptions) {
        self.file = file
        self.options = options
    }

    mutating func warn(_ s: String) { warnings.append(s) }

    var depthBits: UInt16 { file.header.depth }

    mutating func channelPlane(_ rec: PSDLayerRecord, _ id: Int16, _ name: String) -> [UInt8]? {
        guard rec.channel(id) != nil else { return nil }
        do {
            return try rec.decodeChannel(id, depth: file.header.depth, version: file.header.version)
        } catch {
            warn("layer \"\(name)\": channel \(id) could not be decoded (\(PCIOError.wrap(error))); treated as empty")
            return nil
        }
    }

    mutating func recordSurface(_ rec: PSDLayerRecord, _ name: String) -> Surface {
        let r = rec.rect
        guard !r.isEmpty, let (w, h) = try? r.size() else { return Surface(format: fmt) }
        let s = fmt.sample
        var planes: [[UInt8]?] = []
        for c in 0 ..< cc { planes.append(channelPlane(rec, Int16(c), name)) }
        planes.append(channelPlane(rec, PSDChannelID.transparency, name))
        // A channel that is in the file but could not be decoded leaves the layer empty, as the
        // warning says. Filling in for it would paint an opaque black layer over the document.
        let ids = (0 ..< Int16(cc)).map { $0 } + [PSDChannelID.transparency]
        if zip(ids, planes).contains(where: { $1 == nil && rec.channel($0) != nil }) { return Surface(format: fmt) }
        // Only decoded channel data justifies a buffer: the decoders bound their output by the
        // bytes in the file, but a bare rectangle can declare 300000² pixels in a few bytes (#755).
        if planes.allSatisfy({ $0 == nil }) {
            warn("layer \"\(name)\": no channel data for its \(w)x\(h) bounds; treated as empty")
            return Surface(format: fmt)
        }
        var fill = [[UInt8]](repeating: PSDPixels.zeroSample(s), count: cc)
        fill.append(PSDPixels.maxSample(s))
        var invert = [Bool](repeating: cmyk, count: cc)
        invert.append(false)
        var bytes = PSDPixels.interleave(planes, fill, w * h, s, invert)
        if fmt.mode == .lab, s == .u16 { PSDPixels.lab16Chroma(&bytes, cc + 1, toDoc: true) }
        var surf = Surface(format: fmt, rect: PSDImport.pixelRect(r), interleaved: bytes)
        surf.prune()
        return surf
    }

    mutating func recordMask(_ rec: PSDLayerRecord, _ name: String) -> LayerMask? {
        guard let m = rec.layerMask else { return nil }
        let id: Int16, rect: PSDRect, def: UInt8, flags: UInt8
        if let real = PSDImport.selectedRealMask(rec) {
            (id, rect, def, flags) = (PSDChannelID.realUserMask, real.rect, real.background, real.flags)
        } else {
            guard rec.channel(PSDChannelID.userMask) != nil else { return nil }
            (id, rect, def, flags) = (PSDChannelID.userMask, m.rect, m.defaultColor, m.flags)
        }
        var surface = Surface(format: maskFmt, defaultPixel: [Float(def) / 255])
        if !rect.isEmpty, let (w, h) = try? rect.size(), let plane = channelPlane(rec, id, name) {
            let s = maskFmt.sample
            let bytes = PSDPixels.interleave([plane], [PSDPixels.zeroSample(s)], w * h, s, [false])
            surface.writeInterleaved(PSDImport.pixelRect(rect), bytes)
            surface.prune()
        }
        let p = m.parameters
        return LayerMask(surface: surface, enabled: flags & 2 == 0, linked: flags & 1 == 0,
                         density: p?.userDensity.map { Float($0) / 255 } ?? 1,
                         feather: p?.userFeather.map { Float($0) } ?? 0)
    }

    /// The filter mask of the smart object whose `placed` id is `placed`, from the `FEid` cache.
    mutating func filterMask(_ placed: String, _ stack: SmartMap.FilterStack, _ name: String) -> LayerMask? {
        guard let item = filterEffects.first(where: { $0.id == placed }) else { return nil }
        do {
            return try SmartMap.maskFromItem(item, maskFmt.sample, stack)
        } catch {
            warn("layer \"\(name)\": \(error); the filter mask was ignored")
            return nil
        }
    }

    mutating func applyCommon(_ l: inout Layer, _ rec: PSDLayerRecord, blendOverride: PSDBlendMode?) {
        l.visible = rec.isVisible
        l.opacity = Float(rec.opacity) / 255
        l.fillOpacity = Float(rec.fillOpacity) / 255
        l.clipped = rec.clipping != 0
        let key = (blendOverride ?? rec.blendMode).key
        if let b = BlendMode(psdKey: key.string) {
            l.blend = b
        } else {
            warn("layer \"\(l.name)\": unknown blend mode \"\(key.string)\"; using Normal")
            l.blend = .normal
        }
        if case let .protection(v)? = rec.block("lspf")?.typed { l.locks = Blocks.locksFromLspf(v) }
        if rec.flags.contains(.transparencyProtected) { l.locks.transparency = true }
        if case let .sheetColor(v)? = rec.block("lclr")?.typed { l.label = Blocks.labelFromIndex(v) }
        // `lmfx` (multiple instances per kind) supersedes `lfx2` when present; it stays in
        // `psdBlocks`, `lfx2` in `Effects.psdRaw`. Groups store their effects under `lfxs`.
        let single = rec.block("lfx2") ?? rec.block("lfxs")
        if let fx = rec.block("lmfx") ?? single {
            let data = [UInt8](fx.data)
            let parsed = EffectsMap.parseLfx2(data) ?? (Blocks.effectsEnabled(data), [])
            l.effects = Effects(enabled: parsed.enabled, items: parsed.items, psdRaw: single.map { [UInt8]($0.data) }, reference: nil)
        } else if let fx = rec.block("lrFX"), !rec.sectionType.isFolder, let parsed = EffectsMap.parseLrfx([UInt8](fx.data)) {
            // Legacy effects only on non-group layers (Photoshop ignores them on groups).
            l.effects = Effects(enabled: parsed.enabled, items: parsed.items, psdRaw: nil, reference: nil)
        }
        // Effects reference point (`fxrp`: two f64, x then y); also left in `psdBlocks`.
        if let b = rec.block("fxrp"), b.data.count >= 16 {
            var r = BEReader([UInt8](b.data))
            if let x = try? r.f64(), let y = try? r.f64() { l.effects.reference = SIMD2(x, y) }
        }
        // Advanced Blending channel restrictions (`brst`); also kept in `psdBlocks`.
        if let b = rec.block("brst") { l.excludedChannels = Blocks.parseBrst([UInt8](b.data)) }
        // Advanced Blending (`knko`, `infx`, `clbl`, `tsly`, `lmgm`, `vmgm`).
        l.advanced = Blocks.advancedFromBlocks { k in rec.block(k).map { [UInt8]($0.data) } }
        // Blend If lives in the layer record's blending ranges.
        l.blendIf = Blocks.blendIfFromRanges(rec.blendingRanges)
        l.psdId = rec.layerID
        l.mask = recordMask(rec, l.name)
    }

    static func preservedBlocks(_ rec: PSDLayerRecord) -> [PSDLayerBlock] {
        rec.blocks.filter { !PSDImport.regenerated.contains($0.key) }.map { PSDLayerBlock(key: $0.key.psdKey, data: [UInt8]($0.data)) }
    }

    var adjustChannels: AdjustMap.Channels {
        switch fmt.mode {
        case .rgb: .rgb
        case .grayscale: .gray
        case .cmyk: .cmyk
        case .lab: .lab
        default: .other
        }
    }

    mutating func layerFromRecord(_ rec: PSDLayerRecord) -> Layer {
        let name = rec.displayName
        let fillKey = (["SoCo", "GdFl", "PtFl"] as [FourCC]).first { rec.block($0) != nil }
        let vectorKey = (["vsms", "vmsk"] as [FourCC]).first { rec.block($0) != nil }
        let adjKey = AdjustMap.adjustmentKeys.first { rec.block($0) != nil }
        let smartKey = (["SoLd", "PlLd", "SoLE"] as [FourCC]).first { rec.block($0) != nil }
        let blocks = Importer.preservedBlocks(rec)
        func principal(_ k: FourCC) -> [UInt8]? { blocks.first { $0.key == k.psdKey }?.data }
        func data(_ k: FourCC) -> [UInt8]? { rec.block(k).map { [UInt8]($0.data) } }
        var fillCache: FillCache?
        let content: LayerContent
        if let k = adjKey {
            let d = data(k) ?? []
            let adj = AdjustMap.parse(k, d, data("CgEd"), adjustChannels)
            // Kept verbatim for saving, but it renders as nothing: say so (#1763).
            if case .unsupported = adj {
                let why = AdjustMap.unreadableReason(k, d).map { " (\($0))" } ?? ""
                warn("layer \"\(name)\": its \(AdjustMap.label(k)) settings could not be read\(why); the layer is kept as saved but has no effect")
            }
            content = .adjustment(adj)
        } else if let d = data("TySh") {
            // Typed model from TySh/EngineData; Photoshop's pixels stay the cache.
            var t = PSDText.textLayer(fromTySh: d, dpi: dpi) ?? {
                let (text, transform) = Blocks.parseTySh(d) ?? ("", .identity)
                var t = TextLayer(text: text)
                t.transform = transform
                return t
            }()
            if let txt2 {
                PSDText.applyTxt2(&t, tysh: d, txt2: txt2)
                PSDText.applyTxt2Frame(&t, tysh: d, txt2: txt2)
            }
            // Photoshop's pixels are the cache only when the file has some: ag-psd, GIMP and
            // other writers leave type layers without image data (Photoshop re-renders them on
            // open); such a layer is rendered from its model at the end of the import. When the
            // engine text itself is blank, Photoshop draws nothing either: keep the empty pixels.
            let cache = recordSurface(rec, name)
            let drawn = !cache.contentBounds.isEmpty || PSDText.engineTextIsBlank(d)
            t.cache = drawn ? cache : nil
            t.psdRaw = principal("TySh")
            content = .text(t)
        } else if let k = smartKey {
            let raw = data(k) ?? []
            let (id, transform) = Blocks.parseSmart(k, raw)
            let contentsId: SmartContentsId
            if id.isEmpty {
                contentsId = .fresh()
            } else if let c = smartContents[id] {
                contentsId = c
            } else {
                contentsId = .fresh()
                smartContents[id] = contentsId
            }
            // Smart filters (`filterFX` in the placed-layer data) and their mask (`FEid`).
            let placed = (data("SoLd") ?? data("SoLE")).flatMap(SmartMap.parseSold)
            let stack = placed?.stack ?? SmartMap.FilterStack()
            var mask: LayerMask?
            if let p = placed, !stack.filters.isEmpty { mask = filterMask(p.placed, stack, name) }
            var so = SmartObject(source: .linked(path: id), transform: transform, cache: recordSurface(rec, name))
            so.contentsId = contentsId
            so.smartFilters = stack.filters
            so.psdRaw = principal(k)
            so.filtersEnabled = stack.enabled
            so.filterMask = mask
            so.warp = Blocks.parsePlacedWarp(k, raw)
            // Distort / Perspective: the fourth corner (the affine `transform` drops it).
            so.perspective = Blocks.parseSmartPerspective(k, raw)
            content = .smart(so)
        } else if let (f, soft) = PSDImport.softShapeFill(rec, hasVector: vectorKey != nil, fillKey: fillKey) {
            // A shape whose vector mask has a density or feather is a fill layer seen through a
            // soft vector mask. A pattern fill keeps the stored pixels as its rendering.
            if !soft, case .pattern = f, !rec.rect.isEmpty { fillCache = FillCache(fill: f, surface: recordSurface(rec, name)) }
            content = .fill(f)
        } else if (vectorKey != nil && (fillKey != nil || rec.block("vstk") != nil)) || rec.block("vscg") != nil {
            let fill = fillKey.flatMap { k in data(k).flatMap { Blocks.parseFill(k, $0) } }
            var sh = ShapeLayer(fill: fill, cache: recordSurface(rec, name), psdRaw: vectorKey.flatMap { principal($0) })
            VectorMap.shapeFromBlocks(&sh, { k in data(k) }, file.header.width, file.header.height, dpi)
            // No stored pixels (32-bit documents, files saved without layer pixels): render the
            // shape from its path and fill, as Photoshop does when it opens the file.
            if (rec.rect.isEmpty || (try? rec.rect.size()) == nil), !sh.path.subpaths.isEmpty || sh.path.inverted {
                let canvas = PixelRect(x0: 0, y0: 0, x1: Int32(clamping: file.header.width), y1: Int32(clamping: file.header.height))
                if let r = options.renderer?.renderShape(sh, format: fmt, canvas: canvas) {
                    sh.cache = r
                } else {
                    warn("layer \"\(name)\": the shape has no stored pixels and no renderer was given; it shows empty until rendered")
                }
            }
            content = .shape(sh)
        } else if let k = fillKey {
            if let f = data(k).flatMap({ Blocks.parseFill(k, $0) }) {
                // Keep Photoshop's rendering of the fill so it composites exactly.
                if !rec.rect.isEmpty { fillCache = FillCache(fill: f, surface: recordSurface(rec, name)) }
                content = .fill(f)
            } else {
                warn("layer \"\(name)\": unreadable \(k.string) fill; imported as pixels")
                content = .raster(recordSurface(rec, name))
            }
        } else {
            content = .raster(recordSurface(rec, name))
        }
        var rendered = false
        switch content {
        case .shape, .text, .smart: rendered = true
        default: break
        }
        var l = Layer(name: name, content: content)
        l.psdBlocks = blocks
        l.fillCache = fillCache
        applyCommon(&l, rec, blendOverride: nil)
        // Mask flag bit 3: the user mask was rendered from vector data. For shape/text/smart
        // layers the cached pixels already include that coverage, so applying it again would
        // double-mask.
        if rendered, PSDImport.selectedRealMask(rec) == nil, let m = rec.layerMask, m.flags & 8 != 0 { l.mask = nil }
        if case .shape = l.content {} else { applyVectorMask(&l, rec) }
        return l
    }

    /// Typed vector mask from `vsms`/`vmsk` (non-shape layers). A user mask that Photoshop
    /// rendered from the vector data (flag bit 3, no separate real mask) is dropped: the
    /// compositor rasterises the vector mask itself.
    mutating func applyVectorMask(_ l: inout Layer, _ rec: PSDLayerRecord) {
        guard let b = rec.block("vsms") ?? rec.block("vmsk"),
              var vm = VectorMap.vectorMaskFromBlock([UInt8](b.data), file.header.width, file.header.height) else { return }
        if let m = rec.layerMask {
            if let p = m.parameters {
                vm.density = p.vectorDensity.map { Float($0) / 255 } ?? 1
                vm.feather = p.vectorFeather.map { Float($0) } ?? 0
            }
            if m.flags & 8 != 0, PSDImport.selectedRealMask(rec) == nil { l.mask = nil }
        }
        l.vectorMask = vm
    }

    /// The layer tree of `nodes` (bottom first). Iterative, with an explicit stack: a recursive
    /// walk needed several KB of stack per group level and a file at the nesting cap overflowed
    /// the 512 KB threads Swift concurrency runs on.
    mutating func build(_ nodes: [PSDLayerNode], _ depth: Int) throws -> [Layer] {
        struct Frame {
            var nodes: [PSDLayerNode]
            var next = 0
            var out: [Layer] = []
            /// The group this frame builds the children of (record index, divider record index).
            var group: (index: Int, divider: Int?)?
            var depth: Int
        }
        let records = file.layers
        var stack = [Frame(nodes: nodes, group: nil, depth: depth)]
        while var top = stack.popLast() {
            guard top.next < top.nodes.count else {
                // Every child is built: the group itself goes into its parent's list.
                guard let g = top.group else { return top.out }
                let l = groupLayer(records[g.index], g.divider, top.out)
                stack[stack.count - 1].out.append(l)
                continue
            }
            let n = top.nodes[top.next]
            top.next += 1
            // A cancelled open stops decoding; the caller discards the partial document.
            try options.interrupt.check()
            switch n {
            case let .layer(index):
                if index >= 0, index < records.count {
                    top.out.append(layerFromRecord(records[index]))
                    done += 1
                    // Layers are 10–95 % of an open (the merged image and channels the rest).
                    options.interrupt.progress(0.1 + 0.85 * Float(done) / Float(max(total, 1)))
                }
                stack.append(top)
            case let .group(index, divider, children):
                guard index >= 0, index < records.count else {
                    stack.append(top)
                    continue
                }
                if top.depth >= maxGroupDepthLimit {
                    warn("group `\(records[index].displayName)` nests deeper than \(maxGroupDepthLimit) groups; its contents were not imported")
                    top.out.append(groupLayer(records[index], divider, []))
                    stack.append(top)
                } else {
                    let childDepth = top.depth + 1
                    stack.append(top)
                    stack.append(Frame(nodes: children, group: (index, divider), depth: childDepth))
                }
            }
        }
        return []
    }

    /// A group layer from its folder record, its divider record and its built children.
    @inline(never)
    mutating func groupLayer(_ rec: PSDLayerRecord, _ divider: Int?, _ kids: [Layer]) -> Layer {
        let records = file.layers
        let sd = rec.sectionDivider
        let expanded = sd.map { $0.kind != .closedFolder } ?? true
        let artboard = CompsMap.artboardKeys.lazy.compactMap { rec.block($0) }.first.flatMap { CompsMap.parseArtboard([UInt8]($0.data)) }
        var l = Layer(name: rec.displayName, content: .group(LayerGroup(children: kids, expanded: expanded, artboard: artboard)))
        l.psdBlocks = Importer.preservedBlocks(rec)
        if let d = divider, d >= 0, d < records.count, let data = PSDImport.dividerBlockData(records[d]) {
            l.psdBlocks.append(PSDLayerBlock(key: PSDImport.dividerKey.psdKey, data: data))
        }
        applyCommon(&l, rec, blendOverride: sd?.blendMode)
        applyVectorMask(&l, rec)
        return l
    }

    /// Sets `Layer.linkGroup` from resource 1026's per-record ids (`nodes` and `layers` correspond).
    static func applyLinkGroups(_ nodes: [PSDLayerNode], _ layers: inout [Layer], _ ids: [UInt16], _ depth: Int = 0) {
        for (k, n) in nodes.enumerated() where k < layers.count {
            if case let .group(_, _, children) = n, depth < maxGroupDepthLimit {
                layers[k].withChildren { applyLinkGroups(children, &$0, ids, depth + 1) }
            }
            let i = n.index
            layers[k].linkGroup = i >= 0 && i < ids.count && ids[i] != 0 ? UInt64(ids[i]) : nil
        }
    }

    mutating func run() throws -> (document: Document, warnings: [String]) {
        let h = file.header
        let mode: ColorMode
        if let m = PSDImport.docMode(h.colorMode) {
            mode = m
        } else {
            warn("unknown color mode \(h.colorMode.code); importing as RGB")
            mode = .rgb
        }
        let layered = [.grayscale, .rgb, .cmyk, .lab].contains(mode) && h.depth != 1
        let multichannel = mode == .multichannel && h.depth != 1
        let depth = layered || multichannel ? PSDPixels.sampleForDepth(h.depth) : .u8
        var doc = Document(name: "Untitled", size: PixelSize(width: Int(h.width), height: Int(h.height)), mode: mode, depth: depth)

        // Resources.
        for r in file.resources {
            let data = [UInt8](r.data)
            let rname = String(decoding: r.name, as: UTF8.self)
            switch r.id {
            case PSDResourceID.resolutionInfo:
                if let ri = try? PSDResolutionInfo(bytes: r.data) {
                    func ppi(_ res: Double, _ unit: UInt16) -> Double { unit == 2 ? res * 2.54 : res }
                    let (x, y) = (ppi(ri.hRes, ri.hResUnit), ppi(ri.vRes, ri.vResUnit))
                    doc.resolutionDpi = Float(x)
                    if let w = unequalResolutionWarning(x, y) { warn(w) }
                }
                doc.metadata.psdResources.append(PSDResource(id: r.id, name: rname, data: data))
            case PSDResourceID.iccProfile: doc.iccProfile = data
            case PSDResourceID.xmp: doc.metadata.xmp = String(decoding: data, as: UTF8.self)
            case PSDResourceID.exif: doc.metadata.exif = data
            case 1032:
                PSDImport.parseGuides(data, &doc)
                doc.metadata.psdResources.append(PSDResource(id: r.id, name: rname, data: data))
            case PSDResourceID.globalAngle, PSDResourceID.globalAltitude:
                if data.count >= 4 {
                    let v = Float(Int32(bitPattern: UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3])))
                    if r.id == PSDResourceID.globalAngle { doc.globalLight.angle = v } else { doc.globalLight.altitude = v }
                }
            case let id where VectorMap.savedPaths.contains(id):
                if let path = VectorMap.pathFromResource(data, h.width, h.height) {
                    doc.paths.append(NamedPath(name: rname, path: path, psdRaw: data))
                } else {
                    doc.metadata.psdResources.append(PSDResource(id: id, name: rname, data: data))
                }
            case VectorMap.workPath:
                doc.workPath = VectorMap.pathFromResource(data, h.width, h.height)
            case VectorMap.clippingPath:
                // Kept raw (layout beyond the name is not modelled); the name is exposed.
                let n = Int(data.first ?? 0)
                let name = data.count >= 1 + n ? String(decoding: data[1 ..< 1 + n], as: UTF8.self) : ""
                doc.clippingPath = ClippingPath(name: name, flatness: 0)
                doc.metadata.psdResources.append(PSDResource(id: r.id, name: rname, data: data))
            case let id where PSDImport.mappedResources.contains(id):
                if PSDImport.rawKeptResources.contains(id) { doc.metadata.psdResources.append(PSDResource(id: id, name: rname, data: data)) }
            default:
                doc.metadata.psdResources.append(PSDResource(id: r.id, name: rname, data: data))
            }
        }
        for b in file.globalBlocks {
            doc.metadata.psdGlobalBlocks.append(PSDGlobalBlock(signature: b.signature.psdKey, key: b.key.psdKey, data: [UInt8](b.data)))
        }
        // A 16/32-bit file whose layer block can't be parsed would otherwise open as a flattened
        // file without a word (#2700). The raw block is kept, but a PSD save writes the
        // document's own layers in its place.
        if let (b, e) = file.unreadableLayerBlock() {
            warn("the layers (\(b.key.string) block) could not be read (\(PCIOError.wrap(e))); only the merged image was opened. Saving as PSD replaces the unreadable layer data")
        }
        doc.patterns = PatternMap.fromGlobalBlocks(doc)
        // Notes (`Anno`) and the measurement scale (resource 1074); raw data stays for export.
        doc.notes = AnnotationsMap.notesFromBlocks(doc)
        if AnnotationsMap.annoUnreadable(doc) {
            warn("the notes (Anno block) could not be read; they are kept unchanged on PSD save unless a note is added")
        }
        if let scale = AnnotationsMap.rawScale(doc) { doc.measurement.scale = scale }

        fmt = doc.pixelFormat
        cc = fmt.mode.colorChannels
        maskFmt = PixelFormat(mode: .grayscale, sample: depth, alpha: false)
        cmyk = fmt.mode == .cmyk
        dpi = doc.resolutionDpi
        txt2 = file.globalBlock("Txt2").flatMap { PSDText.parseTxt2([UInt8]($0.data)) }
        total = file.layers.count
        for b in file.globalBlocks where b.key == "FEid" || b.key == "FXid" {
            // Smart-filter caches can be large: a cancelled open stops between blocks.
            try options.interrupt.check()
            do {
                filterEffects += try PSDFilterEffects(bytes: b.data).items
            } catch {
                warn("smart filter masks (\(b.key.string)) could not be read: \(PCIOError.wrap(error))")
            }
        }
        try options.interrupt.check()

        let (w, hh) = (Int(h.width), Int(h.height))
        let n = w * hh
        let canvas = PixelRect(x0: 0, y0: 0, x1: Int32(clamping: h.width), y1: Int32(clamping: h.height))
        // The merged composite is decoded only when something consumes it: a flattened or
        // multichannel file (it *is* the image), or extra alpha/spot channels behind the colour
        // ones. A normal layered save carries a merged composite nobody reads.
        let extra = Int(h.channels) > cc + (file.mergedHasAlpha ? 1 : 0)
        var merged: Result<[UInt8], Error>?
        if !layered || file.layers.isEmpty || extra {
            let m = Result { try file.decodeMerged() }
            try options.interrupt.check()
            options.interrupt.progress(0.1)
            if case let .failure(e) = m { warn("merged image could not be decoded: \(PCIOError.wrap(e))") }
            merged = m
        }

        if multichannel {
            // Ink channels only (no layers).
            if case let .success(all)? = merged {
                let names = file.resource(1045).map { PSDImport.unicodeNames([UInt8]($0.data)) } ?? []
                Multichannel.importChannels(file, all, &doc, names, &warnings)
            }
            if !file.layers.isEmpty { warn("Multichannel documents have no layers: \(file.layers.count) layer records were not imported") }
        } else if layered {
            // Capped like `build`: a group past the nesting cap keeps no children.
            let tree = file.layerTree(maxDepth: maxGroupDepthLimit)
            doc.layers = try build(tree, 0)
            // Photoshop's Background: the bottom record, a transparency-protected pixel layer
            // stored without a transparency channel (-1). It is also position-locked, whatever its
            // (localized) name and whether or not the file carries an `lspf` block.
            if let rec = file.layers.first, rec.flags.contains(.transparencyProtected), !rec.channels.contains(where: { $0.id == -1 }),
               let bottom = doc.layers.first, case .raster = bottom.content {
                doc.updateLayer(at: [0]) { $0.locks.position = true }
            }
            // Layer › Link Layers: resource 1026 holds one group id per layer record.
            if case let .layerGroupInfo(groups)? = file.resource(PSDResourceID.layerGroupInfo)?.typed {
                var ls = doc.layers
                Importer.applyLinkGroups(tree, &ls, groups)
                doc.layers = ls
            }
            if doc.layers.isEmpty, case let .success(all)? = merged {
                // Flattened file: the merged image becomes the background layer.
                let plane = h.rowBytes * hh
                let alphaIdx: Int? = file.mergedHasAlpha ? cc : nil
                var planes: [[UInt8]?] = (0 ..< cc).map { c in (c + 1) * plane <= all.count ? Array(all[c * plane ..< (c + 1) * plane]) : nil }
                planes.append(alphaIdx.flatMap { a in (a + 1) * plane <= all.count ? Array(all[a * plane ..< (a + 1) * plane]) : nil })
                var fill = [[UInt8]](repeating: PSDPixels.zeroSample(depth), count: cc)
                fill.append(PSDPixels.maxSample(depth))
                var inv = [Bool](repeating: cmyk, count: cc)
                inv.append(false)
                var bytes = PSDPixels.interleave(planes, fill, n, depth, inv)
                if fmt.mode == .lab, depth == .u16 { PSDPixels.lab16Chroma(&bytes, cc + 1, toDoc: true) }
                var s = Surface(format: fmt, rect: canvas, interleaved: bytes)
                if alphaIdx != nil {
                    // Undo Photoshop's white matting of the merged image, a band of tile rows at a time.
                    let white = fmt.components(fromRGBA: SIMD4(1, 1, 1, 1))
                    var y = canvas.y0
                    while y < canvas.y1 {
                        let band = PixelRect(x0: canvas.x0, y0: y, x1: canvas.x1, y1: min(y &+ tileSize, canvas.y1))
                        var vals = s.readRegion(band)
                        var i = 0
                        while i + cc < vals.count {
                            let a = vals[i + cc]
                            for c in 0 ..< cc { vals[i + c] = a <= 0 ? 0 : PSDPixels.unmatte(vals[i + c], a, white[c]) }
                            i += cc + 1
                        }
                        s.writeRegion(band, vals)
                        y = band.y1
                    }
                }
                s.prune()
                var bg = Layer(name: "Background", content: .raster(s))
                if alphaIdx == nil {
                    bg.locks.transparency = true
                    bg.locks.position = true
                }
                doc.layers.append(bg)
            }
        } else {
            if !file.layers.isEmpty {
                warn("\(h.colorMode) documents are imported flattened: \(file.layers.count) layer records were not imported")
            } else {
                warn("\(h.colorMode) \(h.depth)-bit document converted to \(fmt.mode == .rgb ? "Rgb" : "Grayscale") 8-bit for editing")
            }
            let cmd = [UInt8](file.colorModeData)
            if h.colorMode == .indexed, cmd.count >= 768 {
                // Planar palette: 256 reds, 256 greens, 256 blues (the Color Table).
                doc.colorTable = ColorTable(colors: (0 ..< 256).map { SIMD3(cmd[$0], cmd[256 + $0], cmd[512 + $0]) }, transparent: nil)
            } else if h.colorMode == .duotone, !cmd.isEmpty {
                // The duotone ink block is undocumented: keep it raw; the image shows as its gray plate.
                doc.duotone = Duotone(inks: [DuotoneInk(name: "Black", color: .zero)], psdRaw: cmd)
                warn("duotone inks are not interpreted (shown as grayscale)")
            } else if !cmd.isEmpty {
                warn("color mode data is not preserved")
            }
            var rgba: [UInt8]?
            if let img = try? file.compositeRGBA8() {
                rgba = img.data
            } else if case let .success(all)? = merged {
                // Multichannel: show the first channels as RGB.
                let plane = h.rowBytes * hh
                var d = [UInt8](repeating: 255, count: n * 4)
                for c in 0 ..< min(3, Int(h.channels)) where (c + 1) * plane <= all.count {
                    if let p = try? PSDSamples.planeToU8(Array(all[c * plane ..< (c + 1) * plane]), depth: h.depth, width: w, height: hh) {
                        for i in 0 ..< min(n, p.count) { d[i * 4 + c] = p[i] }
                    }
                }
                rgba = d
            }
            if let img = rgba, img.count >= n * 4 {
                var s = Surface(format: fmt)
                var vals: [Float] = []
                vals.reserveCapacity(n * fmt.channels)
                for i in 0 ..< n {
                    vals += fmt.components(fromRGBA: SIMD4(Float(img[i * 4]) / 255, Float(img[i * 4 + 1]) / 255, Float(img[i * 4 + 2]) / 255,
                                                           Float(img[i * 4 + 3]) / 255))
                }
                s.writeRegion(canvas, vals)
                s.prune()
                doc.layers.append(Layer(name: "Background", content: .raster(s)))
            }
        }

        // Extra (alpha / spot) channels of the merged image.
        if layered, case let .success(all)? = merged {
            let first = cc + (file.mergedHasAlpha ? 1 : 0)
            let plane = h.rowBytes * hh
            let allNames = file.resource(1045).map { PSDImport.unicodeNames([UInt8]($0.data)) } ?? []
            // Photoshop lists every extra channel, the merged transparency first when there is one.
            let skip = file.mergedHasAlpha && allNames.count == max(0, Int(h.channels) - cc) ? 1 : 0
            let names = Array(allNames.dropFirst(skip))
            if first < Int(h.channels) {
                for (k, idx) in (first ..< Int(h.channels)).enumerated() {
                    guard (idx + 1) * plane <= all.count else { break }
                    var s = Surface(format: maskFmt)
                    s.writeInterleaved(canvas, PSDPixels.interleave([Array(all[idx * plane ..< (idx + 1) * plane])], [PSDPixels.zeroSample(depth)], n, depth, [false]))
                    s.prune()
                    doc.channels.append(AlphaChannel(name: k < names.count ? names[k] : "Alpha \(k + 1)", surface: s))
                }
            }
            // Channel options (overlay colour, opacity, colour indicates) and spot inks.
            if let r = file.resource(ChannelMap.displayInfo) {
                ChannelMap.applyDisplayInfo([UInt8](r.data), true, skip, &doc.channels)
            } else if let r = file.resource(ChannelMap.displayInfoOld) {
                ChannelMap.applyDisplayInfo([UInt8](r.data), false, skip, &doc.channels)
            }
            // Saved in Quick Mask mode: that channel becomes the document's Quick Mask again.
            if let r = file.resource(ChannelMap.quickMaskInfo), r.data.count >= 2 {
                let id = Int(UInt16(r.data[r.data.startIndex]) << 8 | UInt16(r.data[r.data.startIndex + 1]))
                let k = id - first
                if k >= 0, k < doc.channels.count { doc.quickMask = doc.channels.remove(at: k) }
            }
        }

        // Layer comps (resource 1065 + per-layer `cmls`); the raw data stays for verbatim export.
        let rawComps = doc.metadata.psdResources.first { $0.id == CompsMap.layerComps }?.data
        let comps = CompsMap.decodeComps(rawComps, doc)
        doc.layerComps = comps.comps
        doc.lastAppliedComp = comps.lastApplied
        doc.lastDocumentState = comps.lastDocumentState
        warnings += comps.warnings
        // Slices (resource 1050), after layer ids are known.
        SlicesMap.importSlices(&doc)
        // Character and paragraph styles from the type layers' engine data.
        warnings += TextStylesMap.importStyles(&doc)
        PSDImport.dropRedundantRawResources(&doc, transparency: file.mergedHasAlpha)

        try options.interrupt.check()
        options.interrupt.progress(1)
        return (doc, warnings)
    }
}
