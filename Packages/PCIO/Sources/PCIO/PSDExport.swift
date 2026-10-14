// Document → PSD/PSB, written so Photoshop accepts it.
// Port of photocraft-io (crates/io/src/psd_export.rs; with the export half of lib.rs:
// export_stages for PSD/PSB, and tiff_layers.rs: strip_foreign_order_blocks), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.
//
// photocraft's rule (architecture §8): the PSD writer never composites. The merged image comes
// from the injected `DocumentCompositor`; fill layers whose Photoshop rendering went stale and
// model-only layers come from the injected `LayerContentRenderer`.
//
// Everything imported but unmodelled is written back byte-identical: preserved layer blocks,
// resources and global blocks keep their bytes; adjustment, fill, effects, vector, placed-layer and
// type blocks are reused verbatim while they still decode to the layer's current model and are
// regenerated otherwise.
//
// Beyond photocraft (Photoshop acceptance, photocraft #1281/#2469; see PORT-NOTES): records that
// carry no imported Photoshop blocks get the block set and record shape Photoshop itself writes
// (PCPSD's corpus-verified builder conventions: flags 0x08/0x18, `lnsr`, `clbl`, `infx`, `knko`,
// `lspf`, `lclr`, `fxrp`, cc + 2 blending ranges, group records with the four raw channels), and
// the finished file is checked with PCPSD's `compatibilityIssues()` linter.

import Foundation
import PCDocument
import PCFoundation
import PCFormat
import PCIOCore
import PCIOMaps
import PCIOSmart
import PCIOText
import PCPSD
import enum PCRender.FillLayerRenderer

/// Options for a PSD/PSB export.
public struct PSDExportOptions: Sendable {
    /// Renders the merged composite (the engine wires PCRender in).
    public var compositor: any PCIOCore.DocumentCompositor
    /// Renders fill layers whose Photoshop rendering went stale (nil writes them empty, warned).
    public var renderer: (any LayerContentRenderer)?
    /// Write PSB even when the document fits PSD limits.
    public var forcePSB: Bool
    /// Matte the merged image against white where it is translucent, as Photoshop does (false
    /// keeps straight colour under the alpha: for containers that store the composite with its own
    /// alpha, such as a layered TIFF).
    public var mergedMatte: Bool
    /// Compression of the merged image (32-bit float documents are always written raw).
    public var mergedCompression: PSDCompression
    /// Embed the thumbnail image resource (1036), Preferences › File Handling › Image Previews.
    public var imagePreviews: Bool
    /// Give records without imported Photoshop blocks the block set and shape Photoshop writes
    /// (see the file header). Off reproduces photocraft's records exactly.
    public var photoshopRecordConventions: Bool
    /// Places a smart object's source composite with its transform/warp/perspective, for the
    /// regenerated filter-mask cache (`FEid`); photocraft-algo `warp::place_source` (PCAlgo).
    /// nil: no cache is regenerated (Photoshop re-renders from the source; a filter mask is warned).
    public var placeSource: (@Sendable (_ source: Surface, _ bounds: PixelRect, _ transform: PCAffine, _ perspective: [Double]?, _ warp: Warp?) -> Surface?)?
    /// Encodes the JPEG thumbnail and decodes flat smart-object sources.
    public var codec: any FlatImageCodec
    /// Cancellation and progress.
    public var interrupt: Interrupt

    public init(compositor: any PCIOCore.DocumentCompositor, renderer: (any LayerContentRenderer)? = nil, forcePSB: Bool = false, mergedMatte: Bool = true,
                mergedCompression: PSDCompression = .rle, imagePreviews: Bool = true, photoshopRecordConventions: Bool = true,
                placeSource: (@Sendable (Surface, PixelRect, PCAffine, [Double]?, Warp?) -> Surface?)? = nil,
                codec: any FlatImageCodec = ImageIOCodec(), interrupt: Interrupt = .none) {
        self.compositor = compositor
        self.renderer = renderer
        self.forcePSB = forcePSB
        self.mergedMatte = mergedMatte
        self.mergedCompression = mergedCompression
        self.imagePreviews = imagePreviews
        self.photoshopRecordConventions = photoshopRecordConventions
        self.placeSource = placeSource
        self.codec = codec
        self.interrupt = interrupt
    }
}

public enum PSDExport {
    /// Blocks that define a layer's content as something other than pixels: fill (`SoCo`,
    /// `GdFl`, `PtFl`), placed / smart object (`SoLd`, `PlLd`, `SoLE`), type (`TySh`) and shape
    /// fill (`vscg`). A raster layer never writes them, nor adjustment blocks.
    static let rasterStaleKeys: [FourCC] = ["SoCo", "GdFl", "PtFl", "SoLd", "PlLd", "SoLE", "TySh", "vscg"]
    static let psdMaxFileSize: UInt64 = 2 * 1024 * 1024 * 1024
    static let estimateFixedOverhead: UInt64 = 1024 * 1024
    static let estimateLayerOverhead: UInt64 = 64 * 1024
    /// How deep embedded documents are exported inside each other before a smart object is
    /// written as pixels instead.
    static let maxNesting = 8
    static let linkKeys: [FourCC] = ["lnk2", "lnk3", "lnkD", "lnkE"]
    static let fxKeys: [FourCC] = ["FEid", "FXid"]

    /// The PSD/PSB file model of `doc` and the warnings about anything that could not be
    /// represented (photocraft `document_to_psd_with`). The merged composite comes from
    /// `options.compositor`. When `options.interrupt` is cancelled the model is incomplete; callers
    /// check and discard it.
    public static func file(_ doc: Document, options: PSDExportOptions) -> (file: PSDFile, warnings: [String]) {
        let r = nested(doc, options: options, depth: 0)
        // Regular PSD models only (a layered TIFF's model keeps an un-matted composite).
        if options.mergedMatte, let observe = sweep.observer { observe { try? [UInt8](r.file.serialized()) } }
        return r
    }

    /// What the document holds that PSD export doesn't keep and no other warning names: the
    /// Timeline, Variables and Data Sets, and video layers' frames (only the frame on screen is
    /// written, as a pixel layer).
    static func notKept(_ doc: Document) -> [String] {
        var out: [String] = []
        if doc.timeline != nil { out.append("the Timeline is not kept in PSD/PSB; save as .pcraft to preserve it") }
        if !doc.variables.isEmpty { out.append("Variables and Data Sets are not kept in PSD/PSB; save as .pcraft to preserve them") }
        doc.forEachLayer { _, _, l in
            if let v = l.video {
                out.append("layer \"\(l.name)\": video layer (\(v.count) frame\(v.count == 1 ? "" : "s")) written as a pixel layer of its current frame; save as .pcraft to preserve the video")
            }
        }
        return out
    }

    /// Test sweeps: when set, called with every PSD/PSB this module writes (`export`) or builds
    /// (`file`, serialised on demand), so a test run can hand them to an outside checker (the
    /// Photoshop oracle). Internal; tests install it through `@testable import`.
    static let sweep = SweepHook()

    final class SweepHook: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (@Sendable (_ bytes: () -> [UInt8]?) -> Void)?
        var observer: (@Sendable (_ bytes: () -> [UInt8]?) -> Void)? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// The bytes of `doc` as PSD/PSB, with the thumbnail resource, a validated header and the
    /// export warnings (photocraft `export_stages` for `.psd`/`.psb`). Throws `.cancelled` when
    /// cancelled.
    public static func export(_ doc: Document, options: PSDExportOptions) throws -> ExportResult {
        try options.interrupt.check()
        var (file, warnings) = nested(doc, options: optionsSpanned(options, 0, 0.9), depth: 0)
        // A cancelled conversion stops early with an incomplete model: never write it.
        try options.interrupt.check()
        if !doc.metadata.text.isEmpty { warnings.append("free-form text metadata is not supported by PSD/PSB; it will be dropped") }
        warnings += notKept(doc)
        warnings += stripForeignOrderBlocks(&file)
        if options.imagePreviews {
            do {
                let r = try PSDThumbnail.resource(doc, compositor: options.compositor, codec: options.codec)
                // Beside the other resources Photoshop writes ahead of the version info.
                let at = file.resources.firstIndex { $0.id == PSDResourceID.versionInfo } ?? file.resources.count
                file.resources.insert(r, at: at)
            } catch {
                warnings.append("image preview not saved: \(PCIOError.wrap(error))")
            }
        }
        // Never write a header the reader would refuse (e.g. a zero-sized canvas).
        do { try file.header.validate() } catch { throw PCIOError.wrap(error) }
        let data: Data
        do { data = try file.serialized() } catch { throw PCIOError.wrap(error) }
        options.interrupt.progress(1)
        let bytes = [UInt8](data)
        if let observe = sweep.observer { observe { bytes } }
        return ExportResult(bytes: bytes, warnings: warnings)
    }

    static func optionsSpanned(_ o: PSDExportOptions, _ lo: Float, _ hi: Float) -> PSDExportOptions {
        var o = o
        o.interrupt = o.interrupt.span(lo, hi)
        return o
    }

    /// Drops blocks kept verbatim from a little-endian TIFF (signatures `MIB8`/`46B8`): their data
    /// can't go into a big-endian file (photocraft `tiff_layers::strip_foreign_order_blocks`).
    public static func stripForeignOrderBlocks(_ file: inout PSDFile) -> [String] {
        var warnings: [String] = []
        func foreign(_ b: PSDTaggedBlock) -> Bool { b.signature == "MIB8" || b.signature == "46B8" }
        if var info = file.layerInfo {
            for i in info.layers.indices {
                let name = info.layers[i].displayName
                info.layers[i].blocks.removeAll { b in
                    guard foreign(b) else { return false }
                    warnings.append("layer \"\(name)\": \(b.key.string) block (\(b.data.count) bytes) kept from a little-endian TIFF cannot be written to PSD and was dropped")
                    return true
                }
            }
            file.layerInfo = info
        }
        file.globalBlocks.removeAll { b in
            guard foreign(b) else { return false }
            warnings.append("document: \(b.key.string) block (\(b.data.count) bytes) kept from a little-endian TIFF cannot be written to PSD and was dropped")
            return true
        }
        return warnings
    }

    // MARK: Resources and names

    /// Rust's lossy legacy name: ASCII printable kept, everything else `?`, at most 255 bytes.
    public static func legacyName(_ s: String) -> [UInt8] {
        Array(s.unicodeScalars.map { $0.isASCII && !(($0.value < 0x20) || $0.value == 0x7F) ? UInt8($0.value) : UInt8(ascii: "?") }.prefix(255))
    }

    static func unicodeNamesResource(_ names: [String]) -> [UInt8] {
        var w = BEWriter()
        for n in names { w.unicodeUnits(Array(n.utf16) + [0]) }
        return w.bytes
    }

    /// The extra-channel resources for `channels` (the merged transparency first when
    /// `transparency`): the imported 1006 (names), 1045 (Unicode names) and 1077 (display info)
    /// verbatim while they still describe the channels (Photoshop's own colour space for spot
    /// inks, e.g. CMYK, survives), else regenerated.
    static func channelResources(_ doc: Document, _ channels: [AlphaChannel], transparency: Bool) -> [PSDImageResource] {
        func raw(_ id: UInt16) -> PSDResource? { doc.metadata.psdResources.first { $0.id == id } }
        let names = (transparency ? ["Transparency"] : []) + channels.map(\.name)
        var out: [PSDImageResource] = []
        let legacy = names.map { String(decoding: legacyName($0), as: UTF8.self) }
        if let r = raw(1006), PSDExport.pascalNames(r.data) == legacy {
            out.append(PSDImageResource(id: 1006, data: Data(r.data), name: legacyName(r.name)))
        } else {
            out.append(PSDImageResource(id: 1006, data: Data(pascalNamesResource(names))))
        }
        if let r = raw(1045), PSDImport.unicodeNames(r.data) == names {
            out.append(PSDImageResource(id: 1045, data: Data(r.data), name: legacyName(r.name)))
        } else {
            out.append(PSDImageResource(id: 1045, data: Data(unicodeNamesResource(names))))
        }
        if let r = raw(ChannelMap.displayInfo), displayInfoMatches(r.data, channels, skip: transparency ? 1 : 0) {
            out.append(PSDImageResource(id: ChannelMap.displayInfo, data: Data(r.data), name: legacyName(r.name)))
        } else {
            out.append(PSDImageResource(id: ChannelMap.displayInfo, data: Data(ChannelMap.displayInfo(channels, transparency))))
        }
        return out
    }

    /// The names of a Pascal-string list (resource 1006), as stored bytes read as UTF-8.
    static func pascalNames(_ data: [UInt8]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < data.count {
            let n = Int(data[i])
            guard i + 1 + n <= data.count else { break }
            out.append(String(decoding: data[(i + 1) ..< (i + 1 + n)], as: UTF8.self))
            i += 1 + n
        }
        return out
    }

    /// Whether a 1077 resource, read the way the importer reads it, gives `channels` their
    /// current colour, opacity, kind and ink (one record per channel after `skip`).
    static func displayInfoMatches(_ data: [UInt8], _ channels: [AlphaChannel], skip: Int) -> Bool {
        guard data.count >= 4, (data.count - 4) % 13 == 0, (data.count - 4) / 13 == channels.count + skip else { return false }
        var probe = channels
        ChannelMap.applyDisplayInfo(data, true, skip, &probe)
        return zip(probe, channels).allSatisfy { $0.spot == $1.spot && $0.color == $1.color && $0.opacity == $1.opacity && $0.indicates == $1.indicates }
    }

    static func pascalNamesResource(_ names: [String]) -> [UInt8] {
        var v: [UInt8] = []
        for n in names {
            let b = legacyName(n)
            v.append(UInt8(b.count))
            v += b
        }
        return v
    }

    /// The order Photoshop writes image resources in (measured on the corpus: every file follows
    /// it), with the ids it doesn't show placed by kind.
    static let resourceRank: [UInt16: Double] = {
        let ids: [UInt16] = [1028, 1061, 1060, 1082, 1083, 1005, 1062, 1006, 1045, 1077, 1007, 1053, 1022, 1010, 1037, 1049, 1011, 10000, 1013,
                             1016, 1024, 1026, 1072, 1069, 1032, 1054, 1050, 1064, 1065, 1074, 1080, 1039, 1041, 1044, 1036, 1033, 1057, 1058,
                             1088, 1025]
        var r: [UInt16: Double] = [:]
        for (i, id) in ids.enumerated() { r[id] = Double(i) }
        return r
    }()

    /// `resources` in Photoshop's order; ids outside the table follow the id that preceded them in
    /// the imported list (`kept`), else go after the paths (2000–2999) at the end.
    static func photoshopResourceOrder(_ resources: [PSDImageResource], kept: [PSDResource]) -> [PSDImageResource] {
        var keptRank: [UInt16: Double] = [:]
        var previous = -1.0
        for (i, r) in kept.enumerated() {
            if let known = resourceRank[r.id] { previous = known } else if keptRank[r.id] == nil { keptRank[r.id] = previous + 0.001 * Double(i + 1) / Double(kept.count + 1) }
        }
        func rank(_ id: UInt16) -> Double {
            if let r = resourceRank[id] { return r }
            if let r = keptRank[id] { return r }
            if (2000 ... 2999).contains(id) { return 100 + Double(id) / 10000 }
            return 200 + Double(id) / 100_000
        }
        return resources.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element.id), rank(b.element.id))
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// The IPTC (1028) and print-output (1082) resources Photoshop writes into every file, with
    /// its default contents (written under `photoshopRecordConventions` when the document holds
    /// none of its own).
    public static let photoshopDefaultResources: [PSDImageResource] = [
        PSDImageResource(id: PSDResourceID.iptc, data: Data([0x1C, 0x02, 0x00, 0x00, 0x02, 0x00, 0x00])),
        PSDImageResource(id: PSDResourceID.printInformation, data: PSDBuilder.photoshopPrintOutput.serialized()),
    ]

    // MARK: Blend modes Photoshop accepts

    /// The blend mode written for `blend` on a layer (`group`: a group record) of a document in
    /// `fmt`: itself when Photoshop accepts it there, else the nearest it accepts (PCPSD's measured
    /// table, `PSDBlendMode.nearestAllowed`). Photoshop 27.11 refuses a file with any other mode
    /// ("open options are incorrect") and raises a modal for pass-through on a pixel layer.
    static func photoshopBlend(_ blend: BlendMode, group: Bool, _ fmt: PixelFormat) -> PSDBlendMode {
        PSDBlendMode.nearestAllowed(PSDBlendMode(key: FourCC(blend.psdKey)), mode: psdMode(fmt.mode), depth: PSDPixels.psdDepth(fmt.sample), isGroup: group)
    }

    /// A generated layer block 4-aligned the way Photoshop writes it (PCPSD `fourAligned()`, zero
    /// pad inside the length). `shmd` pads each item's data instead, as Photoshop does: a metadata
    /// list followed by loose bytes doesn't parse.
    static func fourAligned(_ b: PSDTaggedBlock) -> PSDTaggedBlock {
        guard b.data.count % 4 != 0 else { return b }
        if b.key == "shmd", var items = try? PSDMetadataItem.parse(b.data) {
            for i in items.indices { items[i].data += Data(count: (4 - items[i].data.count % 4) % 4) }
            var out = b
            out.data = PSDMetadataItem.serialize(items)
            if out.data.count % 4 == 0 { return out }
        }
        return b.fourAligned()
    }

    static func documentKind(_ mode: ColorMode, _ sample: SampleType) -> String {
        let bits = sample == .f32 ? "32-bit" : sample == .u16 ? "16-bit" : "8-bit"
        let m = switch mode {
        case .grayscale: "Grayscale"
        case .cmyk: "CMYK"
        case .lab: "Lab"
        default: "RGB"
        }
        return "\(bits) \(m)"
    }

    /// Whether a kept ResolutionInfo (1005) still says `dpi` on both axes.
    static func resolutionMatches(_ data: [UInt8], _ dpi: Float) -> Bool {
        guard let ri = try? PSDResolutionInfo(bytes: Data(data)) else { return false }
        func ppi(_ res: Double, _ unit: UInt16) -> Double { unit == 2 ? res * 2.54 : res }
        return abs(ppi(ri.hRes, ri.hResUnit) - Double(dpi)) < 1e-3 && abs(ppi(ri.vRes, ri.vResUnit) - Double(dpi)) < 1e-3
    }

    /// Whether a kept grid-and-guides resource (1032) holds exactly the document's guides.
    static func guidesMatch(_ data: [UInt8], _ doc: Document) -> Bool {
        var probe = Document(name: "", size: doc.size, mode: doc.mode, depth: doc.depth)
        PSDImport.parseGuides(data, &probe)
        return probe.guides.horizontal == doc.guides.horizontal && probe.guides.vertical == doc.guides.vertical
    }

    static func guidesResource(_ doc: Document, grid: [UInt8]? = nil) -> [UInt8] {
        var w = BEWriter()
        w.u32(1)
        // The grid cycle (1/32 px) of the imported resource, else Photoshop's default.
        if let g = grid, g.count >= 12 {
            w.put(Array(g[4 ..< 12]))
        } else {
            w.u32(576)
            w.u32(576)
        }
        w.u32(UInt32(doc.guides.horizontal.count + doc.guides.vertical.count))
        for (list, dir) in [(doc.guides.vertical, UInt8(0)), (doc.guides.horizontal, UInt8(1))] {
            for p in list {
                w.i32(roundCast(p * 32))
                w.u8(dir)
            }
        }
        return w.bytes
    }

    /// Path resources: saved paths (2000+), the work path (1025) and the clipping path name
    /// (2999), the last only when the imported one doesn't already name the clipping path.
    static func pathResources(_ doc: Document, _ warnings: inout [String]) -> [PSDImageResource] {
        var out: [PSDImageResource] = []
        let (w, h) = (UInt32(clamping: doc.size.width), UInt32(clamping: doc.size.height))
        let maxPaths = Int(VectorMap.savedPaths.upperBound - VectorMap.savedPaths.lowerBound) + 1
        if doc.paths.count > maxPaths { warnings.append("only \(maxPaths) saved paths fit in PSD; the rest were dropped") }
        for (i, p) in doc.paths.prefix(maxPaths).enumerated() {
            let data: [UInt8]
            if let r = p.psdRaw, VectorMap.pathFromResource(r, w, h) == p.path {
                data = r
            } else {
                data = [UInt8](VectorMap.pathToRecords(p.path, w, h).serialized())
            }
            out.append(PSDImageResource(id: VectorMap.savedPaths.lowerBound + UInt16(i), data: Data(data), name: legacyName(p.name)))
        }
        if let wp = doc.workPath {
            out.append(PSDImageResource(id: VectorMap.workPath, data: VectorMap.pathToRecords(wp, w, h).serialized()))
        }
        let rawName = doc.metadata.psdResources.first { $0.id == VectorMap.clippingPath }.map { r -> String in
            let n = Int(r.data.first ?? 0)
            return r.data.count >= 1 + n ? String(decoding: r.data[1 ..< 1 + n], as: UTF8.self) : ""
        }
        if let c = doc.clippingPath, rawName != c.name {
            // Pascal name, then flatness as 16.16 fixed (best effort).
            let name = legacyName(c.name)
            var data = [UInt8(name.count)] + name
            var bw = BEWriter()
            bw.u32(satCast(Double(max(c.flatness, 0)) * 65536))
            data += bw.bytes
            out.append(PSDImageResource(id: VectorMap.clippingPath, data: Data(data)))
        }
        return out
    }

    /// Whether an imported (unmodelled) resource still describes the document and is written back.
    static func keepImportedResource(_ doc: Document, _ id: UInt16, _ data: [UInt8]) -> Bool {
        if !AnnotationsMap.keepResource(doc, id) { return false }
        if id == VectorMap.clippingPath {
            let n = Int(data.first ?? 0)
            let rawName = data.count >= 1 + n ? String(decoding: data[1 ..< 1 + n], as: UTF8.self) : ""
            return doc.clippingPath?.name == rawName
        }
        return true
    }

    /// A document-level tagged block, padded to a multiple of 4 as Photoshop writes them (#200).
    static func globalBlock(_ signature: FourCC, _ key: FourCC, _ data: [UInt8]) -> PSDTaggedBlock {
        PSDTaggedBlock(key: key, data: Data(data), signature: signature, padding: [UInt8](repeating: 0, count: (4 - data.count % 4) % 4))
    }

    /// Merged-transparency ("matte") global blocks. The export writes its own (see `run()`).
    static let matteKeys: Set<FourCC> = ["Mtrn", "Mt16", "Mt32"]

    /// The signature a kept tagged block is written with. `8B64` exists only in PSB files: a PSD
    /// with an `8B64` block is refused by Photoshop ("not compatible with this version", 27.11).
    static func blockSignature(_ sig: FourCC, _ version: PSDVersion) -> FourCC {
        version == .psd && sig == "8B64" ? "8BIM" : sig
    }

    // MARK: Size estimate and version

    static func estimateEncodedSize(_ raw: UInt64, _ rows: UInt64, _ structural: UInt64) -> UInt64? {
        let (a, o1) = raw.addingReportingOverflow(63)
        if o1 { return nil }
        let (b, o2) = raw.addingReportingOverflow(a / 64)
        let (r8, o3) = rows.multipliedReportingOverflow(by: 8)
        let (c, o4) = b.addingReportingOverflow(r8)
        let (d, o5) = c.addingReportingOverflow(structural)
        if o2 || o3 || o4 { return nil }
        return o5 ? UInt64.max : d
    }

    static func addPlaneEstimate(_ raw: inout UInt64, _ rows: inout UInt64, _ w: UInt64, _ h: UInt64, _ ch: UInt64, _ bps: UInt64) -> Bool {
        let (wh, o1) = w.multipliedReportingOverflow(by: h)
        let (whc, o2) = wh.multipliedReportingOverflow(by: ch)
        let (bytes, o3) = whc.multipliedReportingOverflow(by: bps)
        let (pr, o4) = h.multipliedReportingOverflow(by: ch)
        let (r1, o5) = raw.addingReportingOverflow(bytes)
        let (r2, o6) = rows.addingReportingOverflow(pr)
        if o1 || o2 || o3 || o4 || o5 || o6 { return false }
        raw = r1
        rows = r2
        return true
    }

    /// An estimate of the encoded file size (photocraft `estimate_psd_size`); nil on overflow.
    public static func estimatePSDSize(_ doc: Document) -> UInt64? {
        var raw: UInt64 = 0, rows: UInt64 = 0
        var structural = estimateFixedOverhead
        let w = UInt64(max(0, doc.size.width)), h = UInt64(max(0, doc.size.height))
        func add(_ v: Int) -> Bool {
            let (s, o) = structural.addingReportingOverflow(UInt64(max(0, v)))
            structural = s
            return !o
        }
        if doc.mode == .multichannel {
            let channels = UInt64(min(max(doc.channels.count, 1), 56))
            let bytes = UInt64(doc.depth == .f32 ? SampleType.u16.bytes : doc.depth.bytes)
            guard addPlaneEstimate(&raw, &rows, w, h, channels, bytes) else { return nil }
        } else {
            let fmt = doc.pixelFormat
            let cc = UInt64(fmt.mode.colorChannels)
            let bps = UInt64(fmt.sample.bytes)
            var ok = true
            doc.forEachLayer { _, _, layer in
                guard ok else { return }
                ok = add(Int(estimateLayerOverhead)) && add(layer.name.utf8.count)
                for b in layer.psdBlocks { ok = ok && add(b.data.count) }
                var surface: Surface?
                if case let .fill(f) = layer.content {
                    var fw = w, fh = h
                    if let c = layer.fillCache, c.fill == f {
                        let r = c.surface.contentBounds
                        fw = max(fw, UInt64(r.width))
                        fh = max(fh, UInt64(r.height))
                    }
                    ok = ok && addPlaneEstimate(&raw, &rows, fw, fh, cc + 1, bps)
                } else {
                    surface = layer.surface
                }
                if let s = surface {
                    let r = s.contentBounds
                    ok = ok && addPlaneEstimate(&raw, &rows, UInt64(r.width), UInt64(r.height), cc + 1, bps)
                }
                if let m = layer.mask {
                    let r = m.surface.contentBounds
                    ok = ok && addPlaneEstimate(&raw, &rows, UInt64(r.width), UInt64(r.height), 1, bps)
                }
                if case let .smart(sm) = layer.content, case let .embedded(_, bytes) = sm.source { ok = ok && add(bytes.count) }
            }
            if !ok { return nil }
            let maxExtra = max(0, 56 - (fmt.mode.colorChannels + 1))
            var extra = min(doc.channels.count, maxExtra)
            if doc.quickMask != nil, extra < maxExtra { extra += 1 }
            guard addPlaneEstimate(&raw, &rows, w, h, cc + 1 + UInt64(extra), bps) else { return nil }
            for ch in doc.channels.prefix(extra) { guard add(ch.name.utf8.count) else { return nil } }
        }
        guard add(doc.iccProfile?.count ?? 0), add(doc.metadata.xmp?.utf8.count ?? 0), add(doc.metadata.exif?.count ?? 0) else { return nil }
        for r in doc.metadata.psdResources { guard add(r.name.utf8.count), add(r.data.count) else { return nil } }
        for b in doc.metadata.psdGlobalBlocks { guard add(b.data.count) else { return nil } }
        return estimateEncodedSize(raw, rows, structural)
    }

    static func exceedsPSDSizeLimit(_ estimated: UInt64?) -> Bool { estimated.map { $0 > psdMaxFileSize } ?? true }

    static func psdSizeExceedsLimit(_ doc: Document) -> Bool { exceedsPSDSizeLimit(estimatePSDSize(doc)) }

    static func psdVersion(_ doc: Document, forcePSB: Bool, sizeExceedsLimit: Bool) -> PSDVersion {
        let big = doc.size.width > 30_000 || doc.size.height > 30_000
        return forcePSB || big || sizeExceedsLimit ? .psb : .psd
    }

    static func psdMode(_ m: ColorMode) -> PSDColorMode {
        switch m {
        case .grayscale: .grayscale
        case .cmyk: .cmyk
        case .lab: .lab
        default: .rgb
        }
    }

    static func q255(_ v: Float) -> UInt8 { v.isNaN ? 0 : UInt8((min(max(v, 0), 1) * 255).rounded()) }

    static func psdRect(_ r: PixelRect) -> PSDRect { PSDRect(top: r.y0, left: r.x0, bottom: r.y1, right: r.x1) }

    /// PSD mask parameters for a user mask's and a vector mask's (density, feather); nil when every
    /// value is the default (density 1, feather 0).
    static func maskParameters(_ user: (Float, Float)?, _ vector: (Float, Float)?) -> PSDMaskParameters? {
        func density(_ v: (Float, Float)?) -> UInt8? { v.flatMap { $0.0 < 1 ? q255($0.0) : nil } }
        func feather(_ v: (Float, Float)?) -> Double? { v.flatMap { $0.1 != 0 ? Double($0.1) : nil } }
        var p = PSDMaskParameters(flags: 0, userDensity: density(user), userFeather: feather(user), vectorDensity: density(vector), vectorFeather: feather(vector))
        p.flags = (p.userDensity != nil ? 1 : 0) | (p.userFeather != nil ? 2 : 0) | (p.vectorDensity != nil ? 4 : 0) | (p.vectorFeather != nil ? 8 : 0)
        return p.flags != 0 ? p : nil
    }

    /// Resource 1026 (Layer › Link Layers): one u16 group id per layer record, in emit order (a
    /// group's bounding divider, its children, then the group). Imported ids that fit in a u16
    /// are kept; otherwise groups are renumbered by first appearance. nil when nothing is linked.
    static func linkGroupResource(_ layers: [Layer]) -> [UInt8]? {
        var per: [UInt64?] = []
        func walk(_ ls: [Layer]) {
            for l in ls {
                if let g = l.group {
                    per.append(nil)
                    walk(g.children)
                }
                per.append(l.linkGroup)
            }
        }
        walk(layers)
        if per.allSatisfy({ $0 == nil }) { return nil }
        let fits = per.compactMap { $0 }.allSatisfy { (1 ... UInt64(UInt16.max)).contains($0) }
        var seen: [UInt64] = []
        var w = BEWriter()
        for g in per {
            guard let g else { w.u16(0); continue }
            if fits { w.u16(UInt16(g)); continue }
            let i: Int
            if let k = seen.firstIndex(of: g) { i = k } else { seen.append(g); i = seen.count - 1 }
            w.u16(UInt16(clamping: i + 1))
        }
        return w.bytes
    }

    /// Block keys a smart object's `psdRaw` may be written under, in priority order: `PlLd` holds a
    /// `plcL` structure, `SoLd`/`SoLE` a `soLD` one; writing one under the other's key makes the
    /// block unreadable (#200).
    static func smartKeys(_ data: [UInt8]?) -> [FourCC] {
        guard let d = data, d.count >= 4 else { return ["SoLd", "PlLd", "SoLE"] }
        switch Array(d[0 ..< 4]) {
        case Array("plcL".utf8): return ["PlLd"]
        case Array("soLD".utf8): return ["SoLd", "SoLE"]
        default: return ["SoLd", "PlLd", "SoLE"]
        }
    }

    /// Whether the layer's effects still equal what its preserved `lmfx`/`lfx2` decodes to; nil
    /// when there is nothing preserved or it can't be decoded.
    static func effectsUnchanged(_ l: Layer) -> Bool? {
        guard let src = l.psdBlocks.first(where: { $0.key == FourCC("lmfx").psdKey })?.data ?? l.effects.psdRaw,
              let (m, items) = EffectsMap.parseLfx2(src) else { return nil }
        return m == l.effects.enabled && items == l.effects.items
    }

    static func contentsUuid(_ contentsId: SmartContentsId, _ bytes: [UInt8]) -> String {
        var h = BLAKE3()
        h.update(withUnsafeBytes(of: contentsId.rawValue.littleEndian) { Array($0) })
        h.update(bytes)
        return uuidShape(h.finalize())
    }

    /// The 8-4-4-4-12 hex form of the first 16 bytes of a hash.
    static func uuidShape(_ h: [UInt8]) -> String {
        let x = h.prefix(16).map { String(format: "%02x", $0) }.joined()
        let c = Array(x)
        return String(c[0 ..< 8]) + "-" + String(c[8 ..< 12]) + "-" + String(c[12 ..< 16]) + "-" + String(c[16 ..< 20]) + "-" + String(c[20 ..< 32])
    }

    // MARK: Conversion

    /// `document_to_psd_with` for a document embedded `depth` smart objects deep.
    static func nested(_ doc: Document, options: PSDExportOptions, depth: Int) -> (file: PSDFile, warnings: [String]) {
        var r: (file: PSDFile, warnings: [String])
        if doc.mode == .multichannel {
            r = Multichannel.documentToPSD(doc, options: options)
        } else {
            var ex = Exporter(doc: doc, options: options, depth: depth)
            r = ex.run()
        }
        r.warnings += sanitizeKnownRefusals(&r.file)
        return r
    }

    /// Kept blocks Photoshop 27.11 refuses a whole file for (PCPSD's rules, each measured by the
    /// Photoshop oracle), repaired or dropped before writing, each with a warning:
    /// - a linked-file item labelled with a kind it isn't laid out as (`linkedFileKindMismatch`):
    ///   relabelled with the kind it reads as;
    /// - a `PlLd`/`SoLd`/`SoLE` that doesn't parse (`placedLayerDataUnreadable`): dropped;
    /// - a `SoLd`/`SoLE` holding only `Idnt` and `Trnf` whose id no linked-file item carries
    ///   (`placedLayerWithoutLinkedData`): completed with Photoshop's placement keys (it then
    ///   opens as a missing link);
    /// - a `SoCo` that is empty or doesn't parse (`fillLayerDataUnreadable`): dropped.
    static func sanitizeKnownRefusals(_ file: inout PSDFile) -> [String] {
        var warnings: [String] = []
        let linkKeys: Set<FourCC> = ["lnk2", "lnk3", "lnkD", "lnkE"]
        var linkedIDs = Set<String>()
        for g in file.globalBlocks.indices where linkKeys.contains(file.globalBlocks[g].key) {
            guard var files = try? PSDLinkedFiles(bytes: file.globalBlocks[g].data) else { continue }
            var changed = false
            for n in files.items.indices where files.items[n].strictInfo == nil && files.items[n].raw.count >= 4 {
                let own = String(decoding: files.items[n].raw.prefix(4), as: UTF8.self)
                for kind in ["liFD", "liFE", "liFA"] where kind != own {
                    var raw = [UInt8](files.items[n].raw)
                    raw.replaceSubrange(0 ..< 4, with: Array(kind.utf8))
                    let item = PSDLinkedFile(raw: Data(raw), padding: files.items[n].padding)
                    guard let info = item.strictInfo else { continue }
                    files.items[n] = item
                    changed = true
                    warnings.append("linked file \"\(info.fileName)\" was labelled \(own) but stored as \(kind); written as \(kind) (Photoshop refuses the file otherwise)")
                    break
                }
            }
            if changed { file.globalBlocks[g].data = files.serialized() }
            for item in files.items {
                let raw = [UInt8](item.raw)
                guard raw.count > 8, raw.count >= 9 + Int(raw[8]) else { continue }
                linkedIDs.insert(String(decoding: raw[9 ..< 9 + Int(raw[8])], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0")))
            }
        }
        let placedKeys: Set<FourCC> = ["PlLd", "SoLd", "SoLE"]
        for i in file.layers.indices {
            var rec = file.layers[i]
            let name = rec.displayName
            var changed = false
            let unreadable = rec.blocks.filter { placedKeys.contains($0.key) && (try? $0.checkStructure()) == nil }.map(\.key)
            if !unreadable.isEmpty {
                rec.blocks.removeAll { unreadable.contains($0.key) }
                changed = true
                warnings.append("layer \"\(name)\": its \(unreadable.map(\.string).joined(separator: "/")) placed-layer data could not be read and was not saved (Photoshop refuses the file with it)")
            }
            if let j = rec.blocks.firstIndex(where: { $0.key == "SoLd" || $0.key == "SoLE" }),
               let so = try? PSDPlacedLayerData(bytes: rec.blocks[j].data),
               let uid = so.uniqueID?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")), !linkedIDs.contains(uid),
               let full = SmartMap.completedPlacedData([UInt8](rec.blocks[j].data)) {
                rec.blocks[j].data = Data(full)
                rec.blocks[j].padding = nil
                changed = true
                warnings.append("layer \"\(name)\": its smart object's file is missing and its placement data was incomplete; the placement was completed (Photoshop shows a missing link)")
            }
            if let soco = rec.block("SoCo"), soco.data.isEmpty || (try? PSDFillSetting(key: "SoCo", bytes: soco.data)) == nil {
                rec.blocks.removeAll { $0.key == "SoCo" }
                changed = true
                warnings.append("layer \"\(name)\": its solid-colour fill data could not be read and was not saved (Photoshop refuses the file with it)")
            }
            if changed { file.layers[i] = rec }
        }
        return warnings
    }
}

/// An embedded smart-object source as written to `lnk2`.
struct SmartSourceInfo: Sendable {
    var uuid: String
    /// Pixel size of the source document.
    var size: SIMD2<Double>
    var dpi: Double
}

/// Smart-object state collected while emitting layers, written into the global blocks at the end.
struct SmartOut {
    var depth = 0
    /// The document's preserved global blocks (embedded files and filter caches from PSD import).
    var globals: [PSDGlobalBlock] = []
    /// uuids of the files in the preserved linked-layer blocks.
    var known: Set<String> = []
    /// uuids the layers reference.
    var used: Set<String> = []
    /// Unreferenced preserved files may be dropped (every smart layer's file id is known).
    var pruneOK = true
    /// Files to embed.
    var add: [Linked.LinkedFile] = []
    /// Sources converted so far, by contents identity and bytes hash (`.failure` = can't embed).
    var converted: [String: Result<SmartSourceInfo, PCIOError>] = [:]
    /// Each placed layer has its own id, even when it duplicates an imported layer.
    var placedUsed: Set<String> = []
    /// Original instances reserve their imported placement regardless of layer order.
    var placedOwners: [String: LayerId] = [:]
    /// Legacy records without a placed id stay unchanged for the original instance.
    var unplacedOwners: [SmartContentsId: LayerId] = [:]
    /// The imported identity that keeps each original linked UUID.
    var linkedContents: [String: SmartContentsId] = [:]
    /// Independent copies of preserved linked items, keyed by (uuid, contents id), sorted on write.
    var linkedCopies: [String: (sortKey: String, block: PSDGlobalBlock)] = [:]
    /// Embedded documents decoded while converting them, by uuid (for the filter caches).
    var docs: [String: Document] = [:]
    /// Source composites (document pixel format, source space) by uuid; nil = unreadable.
    var composites: [String: (Surface, PixelRect)?] = [:]
    /// Preserved `FEid` items.
    var oldFX: [PSDFilterEffectsItem] = []
    /// Placed ids whose preserved `FEid` item stays.
    var keepFX: Set<String> = []
    /// Regenerated `FEid` items.
    var newFX: [PSDFilterEffectsItem] = []

    init() {}

    init(_ doc: Document, depth: Int) {
        self.depth = depth
        globals = doc.metadata.psdGlobalBlocks
        for g in globals where PSDExport.linkKeys.contains(FourCC(g.key)) { known.formUnion(Linked.blockUuids(g.data)) }
        for g in globals where PSDExport.fxKeys.contains(FourCC(g.key)) {
            if let fx = try? PSDFilterEffects(bytes: Data(g.data)) { oldFX += fx.items }
        }
        // Duplicating a layer clears psdId and gives it a newer runtime id.
        var layers: [Layer] = []
        doc.forEachLayer { _, _, l in layers.append(l) }
        layers.sort { a, b in (a.psdId == nil ? 1 : 0, a.id) < (b.psdId == nil ? 1 : 0, b.id) }
        for layer in layers {
            guard case let .smart(sm) = layer.content, case let .linked(path) = sm.source,
                  let placed = sm.psdRaw.flatMap(SmartMap.parseSold), placed.idnt == path else { continue }
            if linkedContents[path] == nil { linkedContents[path] = sm.contentsId }
            if placed.placed.isEmpty {
                if unplacedOwners[sm.contentsId] == nil { unplacedOwners[sm.contentsId] = layer.id }
            } else if placedOwners[placed.placed] == nil {
                placedOwners[placed.placed] = layer.id
            }
        }
    }

    /// `FEid` data padded to 4 bytes inside the block length: Photoshop counts the padding in the
    /// length and can't open a file whose `FEid` is padded outside it.
    static func paddedFX(_ fx: PSDFilterEffects) -> [UInt8] {
        var d = [UInt8](fx.serialized())
        d += [UInt8](repeating: 0, count: (4 - d.count % 4) % 4)
        return d
    }

    /// The document's global blocks with the linked-layer files and filter caches brought up to
    /// date: unreferenced files dropped (when every reference is known), new files appended,
    /// filter caches kept or regenerated per smart object. Unchanged blocks stay byte-identical.
    func finish(_ blocks: [PSDGlobalBlock]) -> [PSDGlobalBlock] {
        let keep: (String) -> Bool = { u in !pruneOK || used.contains(u) }
        var out: [PSDGlobalBlock] = []
        var added = false
        var fxPlaced = false
        for b in blocks {
            let key = FourCC(b.key)
            if PSDExport.linkKeys.contains(key) {
                let addHere: [Linked.LinkedFile] = !added && key == "lnk2" ? add : []
                if key == "lnk2" { added = true }
                switch Linked.rebuildBlock(b.data, keep, addHere) {
                case nil: out.append(b)
                case let d? where d.isEmpty: break
                case let d?: out.append(PSDGlobalBlock(signature: b.signature, key: b.key, data: d))
                }
            } else if PSDExport.fxKeys.contains(key) {
                guard var fx = try? PSDFilterEffects(bytes: Data(b.data)) else {
                    out.append(b)
                    continue
                }
                let before = fx.items.count
                fx.items.removeAll { !keepFX.contains($0.id) }
                let fresh = !fxPlaced && !newFX.isEmpty
                if fresh {
                    fx.items += newFX
                    fxPlaced = true
                }
                if fx.items.count == before && !fresh {
                    out.append(b)
                } else if !fx.items.isEmpty {
                    out.append(PSDGlobalBlock(signature: b.signature, key: b.key, data: SmartOut.paddedFX(fx)))
                }
            } else {
                out.append(b)
            }
        }
        if !added && !add.isEmpty {
            out.append(PSDGlobalBlock(signature: "8BIM", key: "lnk2", data: add.flatMap(Linked.encodeLinkedFile)))
        }
        for (_, copy) in linkedCopies.sorted(by: { $0.value.sortKey < $1.value.sortKey }) {
            if let i = out.firstIndex(where: { $0.signature == copy.block.signature && $0.key == copy.block.key }) {
                out[i].data += copy.block.data
            } else {
                out.append(copy.block)
            }
        }
        if !fxPlaced && !newFX.isEmpty {
            out.append(PSDGlobalBlock(signature: "8BIM", key: "FEid", data: SmartOut.paddedFX(PSDFilterEffects(version: 3, items: newFX))))
            if !out.contains(where: { FourCC($0.key) == "FMsk" }) {
                // Filter mask overlay: RGB red at 50 %, Photoshop's default.
                out.append(PSDGlobalBlock(signature: "8BIM", key: "FMsk", data: [0, 0, 255, 255, 0, 0, 0, 0, 0, 0, 0, 50]))
            }
        }
        return out
    }
}

/// The export state (photocraft `Ex`).
struct Exporter {
    let doc: Document
    let options: PSDExportOptions
    var fmt: PixelFormat
    var dpi: Float
    var textStyles: TextStyles
    var maskFmt: PixelFormat
    var cc: Int
    var cmyk: Bool
    var version: PSDVersion = .psd
    var nextId: UInt32 = 0
    /// PSD ids assigned to document layers (kept from `psdId` when unique).
    var layerIds: [LayerId: UInt32] = [:]
    /// The generated `Txt2` object number of each type layer.
    var textIndex: [LayerId: Int32] = [:]
    var canvas: PixelRect
    var records: [PSDLayerRecord] = []
    var warnings: [String] = []
    var guides: Guides
    /// Layer comps to regenerate into each layer's `cmls`; nil = preserved data still matches.
    var comps: (comps: [LayerComp], last: LayerComp?)?
    var smart: SmartOut
    var patterns: [Pattern]

    init(doc: Document, options: PSDExportOptions, depth: Int) {
        // A pattern fill or style whose pattern the document lacks gets a placeholder pattern
        // (Photoshop refuses the file without its pattern data).
        var doc = doc
        let missingPatterns = PatternMap.addMissingPatterns(&doc)
        self.doc = doc
        self.options = options
        warnings += missingPatterns
        fmt = doc.pixelFormat
        // Photoshop has no 32-bit CMYK or Lab mode (a file in either is refused): write 16-bit.
        if fmt.sample == .f32, fmt.mode == .cmyk || fmt.mode == .lab {
            fmt = PixelFormat(mode: fmt.mode, sample: .u16, alpha: fmt.alpha)
            warnings.append("Photoshop has no 32-bit \(fmt.mode == .cmyk ? "CMYK" : "Lab") mode; the document was written as 16-bit")
        }
        dpi = doc.resolutionDpi
        textStyles = doc.textStyles
        maskFmt = PixelFormat(mode: .grayscale, sample: fmt.sample, alpha: false)
        cc = fmt.mode.colorChannels
        cmyk = fmt.mode == .cmyk
        canvas = doc.bounds
        guides = doc.guides
        comps = CompsMap.compsUnchanged(doc) ? nil : (doc.layerComps, doc.lastDocumentState)
        smart = SmartOut(doc, depth: depth)
        patterns = doc.patterns
    }

    var compression: PSDCompression { fmt.sample == .f32 ? .zipPrediction : .rle }
    var depthBits: UInt16 { PSDPixels.psdDepth(fmt.sample) }

    func encode(_ id: Int16, _ plane: [UInt8], _ w: Int, _ h: Int) -> PSDChannel {
        // Photoshop writes empty layer/mask channels as just the raw compression code.
        let c: PSDCompression = w == 0 || h == 0 ? .raw : compression
        if let ch = try? PSDChannel.encode(id: id, compression: c, decoded: plane, width: w, height: h, depth: depthBits, version: version) { return ch }
        if let ch = try? PSDChannel.encode(id: id, compression: .raw, decoded: plane, width: w, height: h, depth: depthBits, version: version) { return ch }
        return PSDChannel(id: id, compression: .raw, data: Data(plane))
    }

    func emptyChannels() -> [PSDChannel] { (Int16(-1) ..< Int16(cc)).map { encode($0, [], 0, 0) } }

    /// `s` in the document's pixel format (a depth change is exact; a model change goes through
    /// sRGB and is warned, as photocraft's `Surface::convert`).
    mutating func inFormat(_ s: Surface, _ target: PixelFormat, _ name: String) -> Surface {
        if s.format == target { return s }
        if s.format.mode == target.mode, s.format.alpha == target.alpha { return s.converted(to: target) }
        warnings.append("layer \"\(name)\": pixels converted from \(s.format.mode)/\(s.format.sample) to \(target.mode)/\(target.sample)")
        var out = Surface(format: target)
        let r = s.contentBounds
        if r.isEmpty { return out }
        let rgba = s.readRGBA(r)
        var vals: [Float] = []
        vals.reserveCapacity(r.area * target.channels)
        for p in rgba { vals += target.components(fromRGBA: p) }
        out.writeRegion(r, vals)
        out.prune()
        return out
    }

    mutating func pixelChannels(_ s0: Surface, _ name: String) -> (PSDRect, [PSDChannel]) {
        let s = inFormat(s0, fmt, name)
        let r = s.contentBounds
        if r.isEmpty { return (.zero, emptyChannels()) }
        var bytes = s.readInterleaved(r)
        if fmt.mode == .lab, fmt.sample == .u16 { PSDPixels.lab16Chroma(&bytes, cc + 1, toDoc: false) }
        var invert = [Bool](repeating: cmyk, count: cc)
        invert.append(false)
        let planes = PSDPixels.deinterleave(bytes, cc + 1, fmt.sample, invert)
        let (w, h) = (r.width, r.height)
        // Alpha (-1) first, then the colour channels; each compressed on its own thread.
        let order: [(Int16, Int)] = [(-1, cc)] + (0 ..< cc).map { (Int16($0), $0) }
        let me = self
        let ch = PSDPixels.parMap(order) { me.encode($0.0, planes[$0.1], w, h) }
        return (PSDExport.psdRect(r), ch)
    }

    func mask(_ m: LayerMask, _ vector: (Float, Float)?) -> (PSDMaskData, PSDChannel) {
        let s = m.surface.format == maskFmt ? m.surface
            : (m.surface.format.mode == .grayscale && !m.surface.format.alpha ? m.surface.converted(to: maskFmt) : Exporter.grayMask(m.surface, maskFmt))
        let def = s.defaultPixelValue.first ?? 0
        let r = s.contentBounds
        let plane = r.isEmpty ? [] : PSDPixels.deinterleave(s.readInterleaved(r), 1, maskFmt.sample, [false])[0]
        var flags: UInt8 = 0
        if !m.linked { flags |= PSDLayerMask.flagRelative }
        if !m.enabled { flags |= PSDLayerMask.flagDisabled }
        let parameters = PSDExport.maskParameters((m.density, m.feather), vector)
        if parameters != nil { flags |= PSDLayerMask.flagParameters }
        let pm = PSDLayerMask(rect: r.isEmpty ? .zero : PSDExport.psdRect(r), defaultColor: PSDExport.q255(def), flags: flags,
                              parameters: parameters, real: nil, trailing: parameters == nil ? [0, 0] : [], realFirst: true)
        return (.mask(pm), encode(PSDChannelID.userMask, plane, r.width, r.height))
    }

    /// A mask surface in another layout reduced to one gray channel.
    static func grayMask(_ s: Surface, _ target: PixelFormat) -> Surface {
        var out = Surface(format: target, defaultPixel: [s.defaultPixelValue.first ?? 0])
        let r = s.tileBounds
        if r.isEmpty { return out }
        let ch = s.format.channels
        let v = s.readRegion(r)
        out.writeRegion(r, stride(from: 0, to: v.count, by: ch).map { v[$0] })
        out.prune()
        return out
    }

    /// Ids for section dividers: above every layer id.
    mutating func freshId() -> UInt32 {
        nextId &+= 1
        return nextId
    }

    mutating func layerId(_ l: Layer) -> UInt32 { layerIds[l.id] ?? freshId() }


    mutating func record(_ l: Layer, _ extra: [PSDTaggedBlock], _ pixels: Surface?) -> PSDLayerRecord {
        let id = layerId(l)
        var (rect, channels): (PSDRect, [PSDChannel])
        if let s = pixels { (rect, channels) = pixelChannels(s, l.name) } else { (rect, channels) = (.zero, emptyChannels()) }
        var maskData = PSDMaskData.none
        // Vector mask density/feather live in the mask parameters, with or without a user mask.
        let vector = l.vectorMask.map { ($0.density, $0.feather) }
        if let m = l.mask {
            let (md, ch) = mask(m, vector)
            maskData = md
            channels.append(ch)
        } else if let parameters = PSDExport.maskParameters(nil, vector) {
            // Parameters only: no user mask channel, so nothing hides on re-import.
            maskData = .mask(PSDLayerMask(rect: .zero, defaultColor: 255, flags: PSDLayerMask.flagParameters, parameters: parameters, real: nil,
                                          trailing: [], realFirst: true))
        }
        var flags = PSDLayerFlags()
        let conventions = options.photoshopRecordConventions
        if conventions { flags.setPixelDataIrrelevant(l.isGroup) }
        flags.isHidden = !l.visible
        if l.locks.transparency { flags.insert(.transparencyProtected) }
        var blocks: [PSDTaggedBlock] = [.unicodeName(l.name), .layerID(id)]
        let lspf = Blocks.lspfFromLocks(l.locks)
        // Photoshop writes `lspf` and `lclr` into every record and `iOpa` only below 100 %.
        if lspf != 0 || conventions { blocks.append(.protection(lspf)) }
        if l.label != .none || conventions { blocks.append(.sheetColor(Blocks.labelIndex(l.label))) }
        // A solid colour fill has no alpha in PSD (`SoCo`): a translucent colour becomes the layer's
        // fill opacity, which Photoshop applies to the fill alone.
        var fillOpacity = l.fillOpacity
        if case let .fill(.solid(c)) = l.content, c.alpha < 1 { fillOpacity *= max(c.alpha, 0) }
        if !conventions || fillOpacity < 1 { blocks.append(.fillOpacity(PSDExport.q255(fillOpacity))) }
        // Effects: the original lfx2 while the effects are unchanged (or could not be decoded at
        // all); otherwise regenerated.
        let fx = l.effects
        for effect in fx.items {
            let modes: [BlendMode]
            switch effect {
            case let .dropShadow(s), let .innerShadow(s): modes = [s.common.blend]
            case let .outerGlow(g), let .innerGlow(g): modes = [g.common.blend]
            case let .stroke(s): modes = [s.common.blend]
            case let .colorOverlay(o): modes = [o.common.blend]
            case let .gradientOverlay(o): modes = [o.common.blend]
            case let .patternOverlay(o): modes = [o.common.blend]
            case let .satin(s): modes = [s.common.blend]
            case let .bevelEmboss(b): modes = [b.highlight.blend, b.shadow.blend]
            }
            for m in modes where !m.hasPSDEquivalent {
                warnings.append("layer \"\(l.name)\", \(effect.label): \(m.label) has no PSD equivalent and was written as Normal; save as .pcraft to preserve it")
            }
        }
        var lfx2: [UInt8]?
        let unchanged = PSDExport.effectsUnchanged(l)
        if (unchanged == true || unchanged == nil), let raw = fx.psdRaw {
            lfx2 = raw
        } else if unchanged == true, fx.psdRaw == nil {
            // Photoshop wrote these effects in `lmfx` alone (multiple instances), which is kept
            // while it still says what the effects are: no `lfx2` beside it.
        } else if !fx.items.isEmpty {
            lfx2 = EffectsMap.writeLfx2(fx.enabled, fx.items)
        }
        if let d = lfx2 { blocks.append(PSDTaggedBlock(key: l.isGroup ? "lfxs" : "lfx2", bytes: d)) }
        blocks += extra
        // Photoshop writes every layer block with its length a multiple of 4, the pad inside the
        // length (all 12,949 blocks of its files), and refuses a file whose `grdm` isn't (measured
        // with Photoshop 27.11). Blocks written here are padded so; blocks kept verbatim from the
        // file (`psdBlocks`, and the raw effects, type, smart-object and shape data) keep their
        // bytes, an odd one gaining its pad byte (readers such as psd-tools do not skip a pad after
        // an odd length, #200).
        var kept = Set(l.psdBlocks.map(\.data))
        if let r = l.effects.psdRaw { kept.insert(r) }
        switch l.content {
        case let .text(t): if let r = t.psdRaw { kept.insert(r) }
        case let .smart(sm): if let r = sm.psdRaw { kept.insert(r) }
        case let .shape(sh): if let r = sh.psdRaw { kept.insert(r) }
        default: break
        }
        for i in blocks.indices where blocks[i].padding == nil {
            if kept.contains([UInt8](blocks[i].data)) {
                if blocks[i].data.count % 2 == 1 { blocks[i].data.append(0) }
            } else {
                blocks[i] = PSDExport.fourAligned(blocks[i])
            }
        }
        if conventions { blocks = Exporter.photoshopOrder(blocks, group: l.isGroup, artboard: l.group?.artboard != nil, reference: fxReference(l, rect)) }
        if !l.blend.hasPSDEquivalent {
            warnings.append("layer \"\(l.name)\": \(l.blend.label) has no PSD equivalent and was written as Normal; save as .pcraft to preserve it")
        }
        var ranges = Blocks.rangesFromBlendIf(l.blendIf, cc)
        // Photoshop writes cc + 2 blending-range entries (40 bytes for RGB).
        if conventions, l.blendIf.isDefault { ranges = .full(channels: cc + 1) }
        // Only modes Photoshop accepts in this document (it refuses the file otherwise): the
        // nearest one, with a warning, as PCPSD's builder substitutes.
        var blend = PSDExport.photoshopBlend(l.blend, group: l.isGroup, fmt)
        let artboard = l.group?.artboard != nil
        if artboard {
            // Photoshop's artboards are Normal (record and section divider; ps-corpus
            // `artboard-blend.psd`); the warning comes from `emit`.
            blend = PSDBlendMode(key: "norm")
        } else if blend.key.string != l.blend.psdKey, l.blend.hasPSDEquivalent {
            let to = BlendMode(psdKey: blend.key.string)?.label ?? blend.key.string
            warnings.append(l.blend == .passThrough
                ? "layer \"\(l.name)\": Pass Through applies to groups only; written as \(to)"
                : "layer \"\(l.name)\": Photoshop has no \(l.blend.label) blend mode in \(PSDExport.documentKind(fmt.mode, fmt.sample)) documents; written as \(to)")
        }
        // Photoshop keeps a group's mode in its section divider and writes Normal in the record of
        // a Pass Through group (ps-corpus `group-passthrough.psd`, `artboard-blend.psd`).
        if conventions, l.isGroup, blend.key == "pass" { blend = PSDBlendMode(key: "norm") }
        return PSDLayerRecord(rect: rect, channels: channels, blendMode: blend, opacity: PSDExport.q255(l.opacity),
                              clipping: l.clipped ? 1 : 0, flags: flags, filler: 0, mask: maskData, blendingRanges: ranges,
                              name: PSDExport.legacyName(l.name), blocks: blocks, extraTrailing: [])
    }

    /// The order Photoshop writes a record's blocks in, measured on the corpus (474 records):
    /// content-defining blocks first (adjustment, fill, `vscg`, effects, `TySh`, vector mask,
    /// origination), then `luni lnsr lyid iOpa clbl infx knko lsct lspf lclr shmd PlLd SoLd vstk
    /// sn2P artb fxrp lyvr` (`artb` before `fxrp`: ps-corpus `artboard-blend.psd`). Keys Photoshop's corpus doesn't show are placed after the block that
    /// preceded them.
    static let photoshopRank: [FourCC: Double] = {
        let keys: [FourCC] = AdjustMap.adjustmentKeys + ["clrL", "CgEd", "SoCo", "GdFl", "PtFl", "vscg", "lmfx", "lfx2", "lfxs", "lrFX", "TySh",
                                                          "vmsk", "vsms", "vogk", "luni", "lnsr", "lyid", "iOpa", "clbl", "infx", "knko",
                                                          "tsly", "lmgm", "vmgm", "brst", "lsct", "lspf", "lclr", "shmd", "cmls", "PlLd",
                                                          "SoLd", "SoLE", "vstk", "sn2P", "artb", "artd", "abdd", "fxrp", "lyvr"]
        var r: [FourCC: Double] = [:]
        for (i, k) in keys.enumerated() where r[k] == nil { r[k] = Double(i) }
        return r
    }()

    /// A record's blocks with the defaults Photoshop writes into every plain layer (when missing:
    /// `lnsr`, `clbl`, `infx`, `knko`, `fxrp`; groups `lnsr` and `fxrp`) and in Photoshop's order
    /// (`photoshopRank`), so every record shape written occurs in Photoshop's own files.
    static func photoshopOrder(_ blocks: [PSDTaggedBlock], group: Bool, artboard: Bool = false, reference: SIMD2<Double>) -> [PSDTaggedBlock] {
        var all = blocks
        func has(_ k: FourCC) -> Bool { all.contains { $0.key == k } }
        // Photoshop names an artboard's source `artb`, a group's `lset`, a layer's `layr`.
        if !has("lnsr") { all.append(.nameSource(artboard ? "artb" : group ? "lset" : "layr")) }
        if !group {
            if !has("clbl") { all.append(.blendClippedAsGroup(true)) }
            if !has("infx") { all.append(.blendInteriorElements(false)) }
            if !has("knko") { all.append(.knockout(0)) }
        }
        if !has("fxrp") {
            var w = BEWriter()
            w.f64(reference.x)
            w.f64(reference.y)
            all.append(PSDTaggedBlock(key: "fxrp", bytes: w.bytes))
        }
        var ranked: [(rank: Double, index: Int, block: PSDTaggedBlock)] = []
        var previous = -1.0
        for (i, b) in all.enumerated() {
            let r = photoshopRank[b.key] ?? (previous + 0.001)
            ranked.append((r, i, b))
            previous = r
        }
        return ranked.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.index < $1.index }.map(\.block)
    }

    /// The effects reference point to write when the layer has none: its pixel bounds' top-left,
    /// which is what "no reference" means to the compositor.
    func fxReference(_ l: Layer, _ rect: PSDRect) -> SIMD2<Double> {
        l.effects.reference ?? SIMD2(Double(rect.left), Double(rect.top))
    }

    /// Content blocks for `l`: preserved raw blocks (with `psdRaw` overrides) plus regenerated
    /// adjustment/fill blocks. A preserved adjustment or fill block is reused verbatim while it
    /// still decodes to the layer's current parameters; otherwise it is regenerated.
    mutating func contentBlocks(_ l: Layer) -> [PSDTaggedBlock] {
        var raw: RawBlocks = l.psdBlocks.map { (FourCC($0.key), $0.data) }.filter { !PSDImport.regenerated.contains($0.0) && $0.0 != PSDImport.dividerKey }
        // A stale multi-effects block would override the regenerated lfx2.
        if PSDExport.effectsUnchanged(l) == false { raw.removeAll { $0.key == "lmfx" } }
        var regenerated: RawBlocks = []
        // `keys` is in the importer's priority order (`psdRaw` came from the first key present),
        // not file order: Photoshop writes `PlLd` before `SoLd` (#200).
        func setPrincipal(_ raw: inout RawBlocks, _ keys: [FourCC], _ data: [UInt8]?) {
            guard let d = data else { return }
            if let i = RawBlockList.firstIndex(raw, keys) {
                raw[i].data = d
            } else if let k = keys.first {
                raw.append((k, d))
            }
        }
        func fillRule(_ raw: inout RawBlocks, _ regenerated: inout RawBlocks, _ f: Fill) {
            let keep = raw.contains { ["SoCo", "GdFl", "PtFl"].contains($0.key) && Blocks.parseFill($0.key, $0.data) == f }
            if !keep {
                raw.removeAll { ["SoCo", "GdFl", "PtFl"].contains($0.key) }
                // Photoshop pads layer-level blocks to a multiple of 4 inside the length.
                var (key, data) = Blocks.writeFill(f)
                data += [UInt8](repeating: 0, count: (4 - data.count % 4) % 4)
                regenerated.append((key, data))
            }
        }
        switch l.content {
        case let .adjustment(a):
            let channels: AdjustMap.Channels
            switch fmt.mode {
            case .rgb: channels = .rgb
            case .grayscale: channels = .gray
            case .cmyk: channels = .cmyk
            case .lab: channels = .lab
            default: channels = .other
            }
            let cged = RawBlockList.get(raw, "CgEd")
            var keep = raw.contains { k, d in
                // A previously saved PhotoCraft v2 Photo Filter block may be 18 bytes: Photoshop
                // requires four-byte alignment, so that legacy record is repaired on re-save.
                let legacyPhfl = k == "phfl" && d.starts(with: [0, 2]) && d.count % 4 != 0
                return !legacyPhfl && AdjustMap.adjustmentKeys.contains(k) && AdjustMap.parse(k, d, cged, channels) == a
            }
            // A Gradient Map whose stops are unchanged keeps the file's own block with Reverse and
            // Dither updated in place.
            if !keep, case .gradientMap = a, let i = raw.firstIndex(where: { $0.key == "grdm" }) {
                var d = raw[i].data
                if AdjustMap.retargetGradientMap(&d, a, channels) {
                    raw[i].data = d
                    keep = true
                }
            }
            if !keep {
                raw.removeAll { AdjustMap.adjustmentKeys.contains($0.key) || $0.key == "CgEd" }
                let w = AdjustMap.write(a)
                if let f = a.asFilter {
                    // No live filter layer in Photoshop (AB-T-0258): the record stays, as an empty
                    // pixel layer; the merged image still shows the filter.
                    warnings.append("layer \"\(l.name)\": \(f.label) adjustment layer has no PSD equivalent; written as an empty pixel layer (its mask, opacity and blend mode kept), so Photoshop shows the layers below it unfiltered; save as .pcraft to preserve it")
                } else if w.isEmpty {
                    warnings.append("layer \"\(l.name)\": \(a.label) adjustment is not yet written to PSD")
                }
                // Photoshop's `clrL` descriptor has no interpolation setting.
                if case let .colorLookup(c) = a, c.tetrahedral {
                    warnings.append("layer \"\(l.name)\": Color Lookup tetrahedral interpolation is saved as trilinear (PSD has no interpolation setting)")
                }
                // Photoshop 27.11 opens a Color Lookup written with its table as `LUT3DFileData`
                // (and an empty `profile`) as an empty pixel layer (oracle C′); its own table
                // layers carry the colour profile it builds from the table, which PCIO doesn't
                // write yet. (With no table chosen, Photoshop's own block is written: it opens.)
                if let first = w.first, first.key == "clrL", first.data != AdjustMap.photoshopEmptyLookup {
                    warnings.append("layer \"\(l.name)\": Photoshop opens this Color Lookup as an empty pixel layer (PCIO doesn't write the table's colour profile yet); PCIO reads it back")
                }
                regenerated += w
            }
        case let .fill(f):
            fillRule(&raw, &regenerated, f)
        case let .shape(sh):
            if let f = sh.fill { fillRule(&raw, &regenerated, f) }
            VectorMap.shapeBlocks(sh, &raw, UInt32(canvas.width), UInt32(canvas.height), dpi)
        case let .text(t):
            // Text layers without PSD data (created here) get a generated TySh, and so do layers
            // whose EngineData Photoshop can't open (hand-built or third-party: it crashes
            // Photoshop 27.11 on open); Photoshop's own, complete EngineData is kept.
            let complete = t.psdRaw.flatMap { try? PSDTypeTool(bytes: Data($0)) }.map { $0.missingPhotoshopStructures().isEmpty } ?? false
            let generated: [UInt8]? = complete ? nil : PSDText.buildTySh(t, dpi: dpi, ink: nil)
            let src = complete ? t.psdRaw : generated
            // Character/paragraph style sheets from the document's styles.
            let styled = src.flatMap { TextStylesMap.exportTySh($0, t, textStyles, dpi: dpi) }
            // `TextIndex` names the layer's object in the document's `Txt2`; duplicate or
            // out-of-range file values are renumbered (#1348). An unchanged preserved TySh stays
            // byte for byte.
            let idx = textIndex[l.id] ?? 0
            let rewrite = styled ?? generated ?? src.flatMap { PSDText.textIndex($0) != idx ? $0 : nil }
            let fresh = rewrite.flatMap { PSDText.setTextIndex($0, idx) }
            setPrincipal(&raw, ["TySh"], fresh ?? styled ?? src)
            if !raw.contains(where: { $0.key == "TySh" }) {
                warnings.append("layer \"\(l.name)\": text layer written as pixels (no TySh data)")
            }
        case let .smart(sm):
            let parsed = sm.psdRaw.flatMap(SmartMap.parseSold)
            if sm.psdRaw != nil, parsed == nil {
                // Placed-layer data we don't parse (`PlLd` only): kept verbatim.
                smart.pruneOK = false
                setPrincipal(&raw, PSDExport.smartKeys(sm.psdRaw), sm.psdRaw)
            } else {
                smartBlocks(l, sm, parsed, &raw)
            }
        case .raster:
            // A pixel layer carries no content-defining blocks: one left over from before
            // Rasterize would make a reader reopen the layer as that kind and discard the pixels.
            // A shape stroke (`vstk`) beside a vector mask makes a shape too; without one,
            // Photoshop keeps it on pixel layers. A vector mask (`vmsk`/`vsms`, `vogk`) stays.
            let masked = l.vectorMask != nil
            raw.removeAll { PSDExport.rasterStaleKeys.contains($0.key) || AdjustMap.adjustmentKeys.contains($0.key) || $0.key == "CgEd" || ($0.key == "vstk" && masked) }
        case .group:
            break
        }
        // Effects reference point: written from the field (in place, keeping block order).
        if let r = l.effects.reference {
            var w = BEWriter()
            w.f64(r.x)
            w.f64(r.y)
            if let i = raw.firstIndex(where: { $0.key == "fxrp" }) { raw[i].data = w.bytes } else { raw.append(("fxrp", w.bytes)) }
        } else {
            raw.removeAll { $0.key == "fxrp" }
        }
        // Advanced Blending channel restrictions: written from the field (in place).
        if let data = Blocks.brstData(l.excludedChannels) {
            if let i = raw.firstIndex(where: { $0.key == "brst" }) { raw[i].data = data } else { raw.append(("brst", data)) }
        } else {
            raw.removeAll { $0.key == "brst" }
        }
        // Advanced Blending: written from the field (in place when the block was imported).
        Blocks.putAdvanced(l.advanced, &raw)
        if case .shape = l.content {} else { vectorMaskBlock(l, &raw) }
        CompsMap.artboardBlock(guides, l, &raw)
        if let (c, last) = comps {
            // Ids are assigned to every layer before emitting.
            let id = layerIds[l.id] ?? 0
            CompsMap.setCmls(&raw, CompsMap.writeCmls(c, last, l, id))
        }
        return (regenerated + raw).map { PSDTaggedBlock(key: $0.key, bytes: $0.data) }
    }

    /// Keeps, regenerates or removes the `vmsk`/`vsms` block of a non-shape layer.
    func vectorMaskBlock(_ l: Layer, _ raw: inout RawBlocks) {
        let (w, h) = (UInt32(canvas.width), UInt32(canvas.height))
        let pos = raw.firstIndex { $0.key == "vsms" || $0.key == "vmsk" }
        switch (l.vectorMask, pos) {
        case (nil, .some):
            raw.removeAll { $0.key == "vsms" || $0.key == "vmsk" }
        case (nil, nil):
            break
        case let (vm?, i?) where VectorMap.vectorMaskBlockMatches(raw[i].data, vm, w, h):
            break
        case let (vm?, i):
            let data = VectorMap.vectorMaskBytes(vm, w, h)
            if let i { raw[i].data = data } else { raw.append(("vmsk", data)) }
        }
    }

    /// Placed-layer blocks (`PlLd` + `SoLd`) of a smart object, its embedded file (`lnk2`) and
    /// filter cache (`FEid`). An imported placed layer that nothing changed is written verbatim;
    /// otherwise the blocks are regenerated (from the imported descriptor where the source is the
    /// same). Without a source that can be embedded the layer is written as pixels.
    mutating func smartBlocks(_ l: Layer, _ sm: SmartObject, _ template: SmartMap.Placed?, _ raw: inout RawBlocks) {
        let src: SmartSourceInfo
        do {
            src = try smartSource(sm, template)
        } catch {
            raw.removeAll { ["SoLd", "PlLd", "SoLE"].contains($0.key) }
            let msg: String
            if case let .unsupported(m) = error { msg = m } else { msg = "\(error)" }
            warnings.append("layer \"\(l.name)\": smart object written as pixels (\(msg))")
            return
        }
        smart.used.insert(src.uuid)
        var stack = SmartMap.FilterStack()
        stack.enabled = sm.filtersEnabled
        stack.filters = sm.smartFilters
        stack.maskEnabled = sm.filterMask.map(\.enabled) ?? true
        stack.maskLinked = sm.filterMask.map(\.linked) ?? false
        let sameSource = template.flatMap { $0.idnt == src.uuid ? $0 : nil }
        let unchanged = sameSource.flatMap { t in sm.psdRaw.map { placedUnchanged(t, $0, sm, stack) } } ?? false
        var placed: String
        if let t = sameSource, t.placed.isEmpty, unchanged, smart.unplacedOwners[sm.contentsId] == l.id {
            placed = ""
        } else if let t = sameSource, smart.placedOwners[t.placed] == l.id, smart.placedUsed.insert(t.placed).inserted {
            placed = t.placed
        } else {
            let seed = "\(src.uuid):\(l.id.rawValue)"
            var suffix: UInt64 = 0
            while true {
                let s = suffix == 0 ? seed : "\(seed):\(suffix)"
                let id = SmartMap.uuidFrom(Array(s.utf8))
                if smart.placedOwners[id] == nil, smart.placedUsed.insert(id).inserted {
                    placed = id
                    break
                }
                suffix += 1
            }
        }
        if let t = sameSource, let data = sm.psdRaw, t.placed == placed, unchanged {
            let keys: [FourCC] = raw.contains(where: { $0.key == "SoLd" }) ? ["SoLd"] : ["SoLE", "SoLd"]
            if let i = RawBlockList.firstIndex(raw, keys) { raw[i].data = data } else { raw.append(("SoLd", data)) }
            if !stack.filters.isEmpty { smart.keepFX.insert(t.placed) }
            return
        }
        var size = sameSource.flatMap { SmartMap.storedSize($0.descriptor) } ?? src.size
        if !(size.x > 0 && size.y > 0) { size = Exporter.sizeFromLayer(sm) }
        var localWarnings: [String] = []
        let fxDesc: PSDDescriptor? = stack.filters.isEmpty ? nil : SmartMap.filterFX(stack, l.name, &localWarnings)
        let spec = SmartMap.PlacedSpec(idnt: src.uuid, placed: placed, transform: sm.transform, perspective: sm.perspective, size: size, dpi: src.dpi,
                                       warp: sm.warp, filterFX: fxDesc)
        let sold = SmartMap.soldBytes(sameSource?.descriptor, spec, &localWarnings)
        let plld = SmartMap.plldBytes(spec, &localWarnings)
        var deduped: [String] = []
        for w in localWarnings where deduped.last != w { deduped.append(w) }
        let key: FourCC = sameSource != nil && raw.contains(where: { $0.key == "SoLE" }) && !raw.contains(where: { $0.key == "SoLd" }) ? "SoLE" : "SoLd"
        raw.removeAll { $0.key != key && ($0.key == "SoLd" || $0.key == "SoLE") }
        RawBlockList.upsert(&raw, "PlLd", plld, before: key)
        RawBlockList.upsert(&raw, key, sold)
        if !stack.filters.isEmpty {
            let bounds = sm.cache.map { $0.contentBounds.union(canvas) } ?? canvas
            var item: PSDFilterEffectsItem?
            if sm.stackMode == nil, let (img, imgBounds) = sourceComposite(src.uuid) {
                if let place = options.placeSource, let unfiltered = place(img, imgBounds, sm.transform, sm.perspective, sm.warp) {
                    item = SmartMap.feidItem(placed, unfiltered, sm.filterMask, bounds, fmt)
                } else {
                    deduped.append("smart filter mask was not re-rendered for PSD export (no source placement available)")
                }
            }
            if let item {
                smart.newFX.append(item)
            } else if sm.filterMask != nil {
                // Without the unfiltered pixels Photoshop re-renders from the source itself; only
                // the filter mask has nowhere to go.
                warnings.append("layer \"\(l.name)\": the smart filter mask was not written to PSD")
            }
        }
        warnings += deduped.map { $0.hasPrefix("layer ") ? $0 : "layer \"\(l.name)\": \($0)" }
    }

    /// Whether an imported placed layer still says what the smart object is: transform, warp,
    /// filter stack and filter mask as stored.
    func placedUnchanged(_ t: SmartMap.Placed, _ data: [UInt8], _ sm: SmartObject, _ stack: SmartMap.FilterStack) -> Bool {
        if t.transform != sm.transform || Blocks.parsePlacedWarp("SoLd", data) != sm.warp || (t.stack ?? SmartMap.FilterStack()) != stack { return false }
        if stack.filters.isEmpty { return true }
        guard let old = smart.oldFX.first(where: { $0.id == t.placed }) else { return sm.filterMask == nil }
        // An all-white (or unreadable, warned on import) mask is no mask: `maskFromItem` returns
        // nil for it, which is not a failure.
        let m: LayerMask?
        do { m = try SmartMap.maskFromItem(old, maskFmt.sample, stack) } catch { return sm.filterMask == nil }
        return m == sm.filterMask
    }

    /// The source size of a smart object whose file we can't decode: its rendered bounds taken
    /// back through the inverse transform (the source's top-left is the origin).
    static func sizeFromLayer(_ sm: SmartObject) -> SIMD2<Double> {
        guard let r = sm.cache.map(\.contentBounds), !r.isEmpty, let inv = sm.transform.inverse else { return SIMD2(1, 1) }
        var w = 1.0, h = 1.0
        for (x, y) in [(r.x0, r.y0), (r.x1, r.y0), (r.x1, r.y1), (r.x0, r.y1)] {
            let p = inv.apply(PCPoint(Double(x), Double(y)))
            w = max(w, p.x.rounded())
            h = max(h, p.y.rounded())
        }
        return SIMD2(w, h)
    }

    /// Size and resolution of a smart-object source file (PSD/PSB header, `.pcraft`, or any image).
    func sourceGeometry(_ name: String, _ bytes: [UInt8]) throws -> (SIMD2<Double>, Double) {
        if bytes.starts(with: Array("8BPS".utf8)) {
            var r = BEReader(bytes, at: 14)
            let h = Double(try r.u32()), w = Double(try r.u32())
            return (SIMD2(w, h), 72)
        }
        let d = try DocumentIO.importFile(name: name, bytes: bytes, options: IOOptions(codec: options.codec)).document
        return (SIMD2(Double(d.size.width), Double(d.size.height)), Double(d.resolutionDpi))
    }

    /// The `lnk2` file a smart object's source is written as: a preserved embedded file, or a new
    /// one (a `.pcraft` source becomes a PSB of the nested document; image files are embedded as
    /// they are; a linked file is read and embedded).
    mutating func smartSource(_ sm: SmartObject, _ template: SmartMap.Placed?) throws(PCIOError) -> SmartSourceInfo {
        switch sm.source {
        case let .linked(path) where smart.known.contains(path) || template?.idnt == path:
            // A file of the imported document, or one its placed-layer data names (a missing link
            // stays a smart object, as in Photoshop).
            let stored = template.flatMap { $0.idnt == path ? SmartMap.storedSize($0.descriptor) : nil }
            var geometry: (SIMD2<Double>, Double)?
            if let s = stored {
                geometry = (s, Double(dpi))
            } else {
                var meta = Metadata()
                meta.psdGlobalBlocks = smart.globals
                if let f = Linked.findLinkedFile(meta, path) { geometry = try? sourceGeometry(f.fileName, f.bytes) }
            }
            let (size, sdpi) = geometry ?? (Exporter.sizeFromLayer(sm), Double(dpi))
            if smart.linkedContents[path] == nil { smart.linkedContents[path] = sm.contentsId }
            let original = smart.linkedContents[path]
            // An absent Idnt is not a shared-source identity; import treats each as fresh.
            let uuid: String
            if path.isEmpty || original == sm.contentsId {
                uuid = path
            } else {
                uuid = PSDExport.contentsUuid(sm.contentsId, Array(path.utf8))
                let key = "\(path)\u{0}\(sm.contentsId.rawValue)"
                if smart.linkedCopies[key] == nil {
                    var copy: PSDGlobalBlock?
                    for g in smart.globals where PSDExport.linkKeys.contains(FourCC(g.key)) {
                        if let d = Linked.copyItem(g.data, path, uuid) {
                            copy = PSDGlobalBlock(signature: g.signature, key: g.key, data: d)
                            break
                        }
                    }
                    guard let c = copy else { throw .unsupported("the linked source \(path) has no readable record to copy independently") }
                    smart.linkedCopies[key] = (String(format: "%@\u{0}%020llu", path, sm.contentsId.rawValue), c)
                }
            }
            return SmartSourceInfo(uuid: uuid, size: size, dpi: sdpi)
        case let .linked(path):
            guard let data = FileManager.default.contents(atPath: path) else { throw .unsupported("the linked file \(path) can't be read") }
            let name = (path as NSString).lastPathComponent
            warnings.append("the linked smart object \(name) was embedded (PSD export keeps no external links)")
            return try embed(sm.contentsId, name, [UInt8](data))
        case let .embedded(fileName, bytes):
            return try embed(sm.contentsId, fileName, bytes)
        }
    }

    /// The composite of the source `uuid` in the document's pixel format, its top-left at the
    /// origin; decoded once.
    mutating func sourceComposite(_ uuid: String) -> (Surface, PixelRect)? {
        if let c = smart.composites[uuid] { return c }
        var d = smart.docs[uuid]
        if d == nil {
            var file = smart.add.first { $0.uuid == uuid }
            if file == nil {
                var meta = Metadata()
                meta.psdGlobalBlocks = smart.globals + smart.linkedCopies.values.map(\.block)
                file = Linked.findLinkedFile(meta, uuid)
            }
            if let f = file { d = try? DocumentIO.importFile(name: f.fileName, bytes: f.bytes, options: IOOptions(codec: options.codec)).document }
        }
        var result: (Surface, PixelRect)?
        if let sd = d, let px = try? options.compositor.composite(sd, rect: sd.bounds) {
            // The composite comes in the source's own format; bring it into this document's.
            var s = Surface(format: sd.pixelFormat)
            s.writeRegion(sd.bounds, px)
            s.prune()
            if s.format != fmt {
                var out = Surface(format: fmt)
                let rgba = s.readRGBA(sd.bounds)
                var vals: [Float] = []
                vals.reserveCapacity(rgba.count * fmt.channels)
                for p in rgba { vals += fmt.components(fromRGBA: p) }
                out.writeRegion(sd.bounds, vals)
                out.prune()
                s = out
            }
            result = (s, sd.bounds)
        }
        smart.composites[uuid] = .some(result)
        return result
    }

    /// Adds `bytes` as an embedded file (converted to PSB when it is a `.pcraft` bundle), once per
    /// contents identity and bytes. Equal bytes in independent objects stay independent.
    mutating func embed(_ contentsId: SmartContentsId, _ fileName: String, _ bytes: [UInt8]) throws(PCIOError) -> SmartSourceInfo {
        let key = "\(contentsId.rawValue):\(BLAKE3.hex(bytes))"
        if let r = smart.converted[key] { return try r.get() }
        let r = Result { () throws(PCIOError) -> SmartSourceInfo in try convertSource(contentsId, fileName, bytes) }
        smart.converted[key] = r
        return try r.get()
    }

    mutating func convertSource(_ contentsId: SmartContentsId, _ fileName: String, _ bytes: [UInt8]) throws(PCIOError) -> SmartSourceInfo {
        let name: String, data: [UInt8], size: SIMD2<Double>, sdpi: Double
        var nestedDoc: Document?
        if PcraftFormat.isPcraft(bytes) {
            if smart.depth >= PSDExport.maxNesting { throw .unsupported("smart objects nest more than \(PSDExport.maxNesting) deep") }
            let d: Document
            do { d = try PcraftFormat.load(bytes) } catch { throw .unsupported("its contents can't be read: \(error)") }
            var o = options
            o.forcePSB = true
            o.imagePreviews = false
            o.interrupt = .none
            let (file, ws) = PSDExport.nested(d, options: o, depth: smart.depth + 1)
            do { data = [UInt8](try file.serialized()) } catch { throw .unsupported("its contents can't be written: \(error)") }
            let stem = (fileName as NSString).deletingPathExtension
            warnings += ws.map { "smart object \(stem): \($0)" }
            name = "\(stem).psb"
            size = SIMD2(Double(d.size.width), Double(d.size.height))
            sdpi = Double(d.resolutionDpi)
            nestedDoc = d
        } else {
            // Formats we can't decode (vector PDF/AI…) are still embedded; their size comes from the layer.
            let g = (try? sourceGeometry(fileName, bytes)) ?? (SIMD2(0, 0), Double(dpi))
            (name, data, size, sdpi) = (fileName, bytes, g.0, g.1)
        }
        let uuid = PSDExport.contentsUuid(contentsId, data)
        if let d = nestedDoc { smart.docs[uuid] = d }
        if !smart.known.contains(uuid), !smart.add.contains(where: { $0.uuid == uuid }) {
            smart.add.append(Linked.LinkedFile(uuid: uuid, fileName: name, bytes: data))
        }
        return SmartSourceInfo(uuid: uuid, size: size, dpi: sdpi)
    }

    /// Pixels for a fill layer: Photoshop's cached rendering while valid, otherwise PCRender's
    /// `FillLayerRenderer`, which gives exactly the pixels the compositor draws for the fill (in
    /// the document's own model, laid out in the frame its masks give it, unmasked, at the
    /// document's depth). A solid colour's alpha is written as the layer's fill opacity (`SoCo`
    /// has no alpha, see `record`), so its pixels are the opaque colour, as Photoshop's are.
    func fillPixels(_ l: Layer, _ f: Fill) -> Surface {
        var f = f
        if case var .solid(c) = f, c.alpha < 1 {
            c.alpha = 1
            f = .solid(c)
        }
        if let c = l.fillCache, c.fill == f { return c.surface }
        return FillLayerRenderer.render(l, fill: f, canvas: canvas, patterns: patterns, format: fmt)
    }

    /// Writes the records of `layers` (and their groups' children). Returns false once cancelled.
    mutating func emit(_ layers: [Layer], _ tick: () -> Bool) -> Bool {
        for l in layers {
            let extra = contentBlocks(l)
            switch l.content {
            case let .group(g):
                let id = freshId()
                records.append(dividerRecord(id, PSDImport.dividerBlocks(l)))
                if !emit(g.children, tick) { return false }
                let kind: PSDSectionType = g.expanded ? .openFolder : .closedFolder
                // An artboard is Normal in Photoshop (ps-corpus `artboard-blend.psd`).
                if g.artboard != nil, l.blend != .normal {
                    warnings.append("artboard \"\(l.name)\": Photoshop composites artboards as Normal; written as Normal (was \(l.blend.label))")
                }
                let lsct = PSDTaggedBlock.sectionDivider(kind, blendMode: g.artboard != nil ? PSDBlendMode(key: "norm") : PSDExport.photoshopBlend(l.blend, group: true, fmt),
                                                         subType: options.photoshopRecordConventions ? 0 : nil)
                records.append(record(l, [lsct] + extra, nil))
            case let .raster(s):
                records.append(record(l, extra, s))
            case let .adjustment(a):
                // Photoshop has no such adjustment in this mode/depth and opens the layer as an
                // empty pixel layer; the block is still written, so PCIO reads it back.
                if let key = AdjustMap.psdKey(a), !AdjustMap.photoshopOffers(key, mode: fmt.mode, depth: fmt.sample) {
                    warnings.append("layer \"\(l.name)\": Photoshop has no \(AdjustMap.label(key)) adjustment in \(PSDExport.documentKind(fmt.mode, fmt.sample)) documents; it opens the layer as an empty pixel layer")
                }
                records.append(record(l, extra, nil))
            case let .fill(f):
                let px = fillPixels(l, f)
                records.append(record(l, extra, px))
            case let .text(t):
                records.append(record(l, extra, t.cache))
            case let .shape(sh):
                records.append(record(l, extra, sh.cache))
            case let .smart(sm):
                records.append(record(l, extra, sm.cache))
            }
            if !tick() { return false }
        }
        return true
    }

    /// A group's bounding divider record (`</Layer group>`), with the divider blocks imported from
    /// the file (`PSDImport.dividerKey`) when there are any.
    func dividerRecord(_ id: UInt32, _ kept: [PSDTaggedBlock]) -> PSDLayerRecord {
        var blocks: [PSDTaggedBlock] = [.unicodeName("</Layer group>"), .layerID(id), .sectionDivider(.boundingDivider)] + kept
        var flags = PSDLayerFlags()
        var ranges = PSDBlendingRanges.full(channels: cc)
        if options.photoshopRecordConventions {
            if !blocks.contains(where: { $0.key == "lspf" }) { blocks.append(.protection(0)) }
            if !blocks.contains(where: { $0.key == "lclr" }) { blocks.append(.sheetColor(0)) }
            blocks = Exporter.photoshopOrder(blocks, group: true, reference: .zero)
            flags.setPixelDataIrrelevant(true)
            ranges = .full(channels: cc + 1)
        }
        // As in `record`: generated blocks 4-aligned, kept ones verbatim (odd ones gain a pad byte).
        let verbatim = Set(kept.map(\.data))
        for i in blocks.indices where blocks[i].padding == nil {
            if verbatim.contains(blocks[i].data) {
                if blocks[i].data.count % 2 == 1 { blocks[i].data.append(0) }
            } else {
                blocks[i] = PSDExport.fourAligned(blocks[i])
            }
        }
        return PSDLayerRecord(channels: emptyChannels(), flags: flags, blendingRanges: ranges, name: Array("</Layer group>".utf8), blocks: blocks)
    }

    mutating func run() -> (file: PSDFile, warnings: [String]) {
        let sample = fmt.sample
        let big = doc.size.width > 30_000 || doc.size.height > 30_000
        let sizeExceeds = !options.forcePSB && !big && PSDExport.psdSizeExceedsLimit(doc)
        version = PSDExport.psdVersion(doc, forcePSB: options.forcePSB, sizeExceedsLimit: sizeExceeds)
        if big && !options.forcePSB {
            warnings.append("document exceeds 30000 px; written as PSB")
        } else if sizeExceeds && !options.forcePSB {
            warnings.append("estimated encoded size exceeds 2 GB; written as PSB")
        }
        if fmt.mode != doc.mode { warnings.append("\(doc.mode.serdeName) document written as \(fmt.mode.serdeName)") }
        // Assign layer ids up front (stable across round trips): keep unique `psdId`s, number the
        // rest after them; dividers come after all.
        var walk: [Layer] = []
        doc.forEachLayer { _, _, l in walk.append(l) }
        var used = Set<UInt32>()
        for l in walk { if let id = l.psdId, used.insert(id).inserted { layerIds[l.id] = id } }
        var next: UInt32 = 1
        for l in walk where layerIds[l.id] == nil {
            while used.contains(next) { next &+= 1 }
            used.insert(next)
            layerIds[l.id] = next
        }
        nextId = used.max() ?? 0
        // Text objects' number in the generated `Txt2` (#1348): a preserved `TySh` keeps the
        // number it already names, new layers get the next free number.
        var usedTxt = Set<Int32>()
        var nextTxt: Int32 = 0
        for l in walk {
            guard case let .text(t) = l.content else { continue }
            if let i = t.psdRaw.flatMap(PSDText.textIndex), usedTxt.insert(i).inserted {
                textIndex[l.id] = i
            } else {
                while usedTxt.contains(nextTxt) { nextTxt += 1 }
                usedTxt.insert(nextTxt)
                textIndex[l.id] = nextTxt
            }
        }
        // Progress: one unit per layer record, then the merged composite (#3389).
        let units = Float(walk.count) + 2
        let layersShare = Float(walk.count) / units
        var doneUnits: Float = 0
        let interrupt = options.interrupt
        _ = emit(doc.layers) {
            doneUnits += 1
            interrupt.progress(doneUnits / units)
            return !interrupt.isCancelled
        }

        // Merged composite, rendered and encoded in bands.
        let mergedEnd = layersShare + (1 - layersShare) * 0.8
        let merged = MergedImage.planes(doc, fmt: fmt, compositor: options.compositor, matte: options.mergedMatte,
                                        interrupt: interrupt.span(layersShare, mergedEnd))
        var planes = merged.planes
        if case let .failure(e) = merged.status { warnings.append("the merged image could not be rendered (\(e)); it was written white") }
        let n = doc.size.width * doc.size.height
        if !merged.hasAlpha { planes.removeSubrange(min(planes.count, cc * n * sample.bytes)...) }
        let maxExtra = 56 - cc - (merged.hasAlpha ? 1 : 0)
        if doc.channels.count > maxExtra { warnings.append("only \(maxExtra) alpha channels fit in PSD; the rest were dropped") }
        var extra = Array(doc.channels.prefix(maxExtra))
        // Saved in Quick Mask mode: the mask is written as the last extra channel and flagged by
        // resource 1022, as Photoshop does.
        var quickMaskId: UInt16?
        if let q = doc.quickMask {
            if extra.count < maxExtra {
                extra.append(q)
                quickMaskId = UInt16(cc + (merged.hasAlpha ? 1 : 0) + extra.count - 1)
            } else {
                warnings.append("Quick Mask was dropped because the PSD channel limit was reached")
            }
        }
        for a in extra {
            let s = a.surface.format == maskFmt ? a.surface : (a.surface.format.mode == .grayscale && !a.surface.format.alpha ? a.surface.converted(to: maskFmt) : Exporter.grayMask(a.surface, maskFmt))
            planes += PSDPixels.deinterleave(s.readInterleaved(canvas), 1, sample, [false])[0]
        }
        let channels = UInt16(cc + (merged.hasAlpha ? 1 : 0) + extra.count)
        let header = PSDHeader(version: version, width: UInt32(doc.size.width), height: UInt32(doc.size.height), channels: channels,
                               depth: PSDPixels.psdDepth(sample), colorMode: PSDExport.psdMode(fmt.mode))
        let mcomp: PSDCompression = sample == .f32 ? .raw : options.mergedCompression
        let imageData = (try? PSDImageData.encode(mcomp, decoded: planes, header: header))
            ?? (try? PSDImageData.encode(.raw, decoded: planes, header: header))
            ?? PSDImageData(compression: .raw, data: Data(planes))

        // Resources.
        func raw(_ id: UInt16) -> PSDResource? { doc.metadata.psdResources.first { $0.id == id } }
        func rawResource(_ r: PSDResource) -> PSDImageResource { PSDImageResource(id: r.id, data: Data(r.data), name: PSDExport.legacyName(r.name)) }
        var resources = [
            raw(PSDResourceID.resolutionInfo).flatMap { PSDExport.resolutionMatches($0.data, doc.resolutionDpi) ? rawResource($0) : nil }
                ?? PSDImageResource(id: PSDResourceID.resolutionInfo, data: PSDResolutionInfo(dpi: Double(doc.resolutionDpi)).serialized()),
            PSDImageResource(id: PSDResourceID.globalAngle, data: Data(Exporter.be32(roundCast(doc.globalLight.angle)))),
            PSDImageResource(id: PSDResourceID.globalAltitude, data: Data(Exporter.be32(roundCast(doc.globalLight.altitude)))),
        ]
        if let icc = doc.iccProfile { resources.append(PSDImageResource(id: PSDResourceID.iccProfile, data: Data(icc))) }
        if let r = raw(1032), PSDExport.guidesMatch(r.data, doc) {
            resources.append(rawResource(r))
        } else if !doc.guides.isEmpty || raw(1032) != nil {
            resources.append(PSDImageResource(id: 1032, data: Data(PSDExport.guidesResource(doc, grid: raw(1032)?.data))))
        }
        if extra.isEmpty, merged.hasAlpha {
            // Only the merged transparency: Photoshop's own names and options for it, as imported.
            for id: UInt16 in [1006, 1045, ChannelMap.displayInfo, ChannelMap.displayInfoOld] { if let r = raw(id) { resources.append(rawResource(r)) } }
        }
        if !extra.isEmpty {
            // One entry per extra channel, the merged transparency included (one short, Photoshop
            // refuses the file with "unexpected end-of-file").
            resources += PSDExport.channelResources(doc, extra, transparency: merged.hasAlpha)
        }
        if let id = quickMaskId { resources.append(PSDImageResource(id: ChannelMap.quickMaskInfo, data: Data([UInt8(id >> 8), UInt8(id & 0xFF), 0]))) }
        resources += PSDExport.pathResources(doc, &warnings)
        if let groups = PSDExport.linkGroupResource(doc.layers) {
            resources.append(PSDImageResource(id: PSDResourceID.layerGroupInfo, data: Data(groups)))
        } else if let r = raw(PSDResourceID.layerGroupInfo), r.data.allSatisfy({ $0 == 0 }), r.data.count == records.count * 2 {
            // Photoshop writes one (zero) id per record even when nothing is linked.
            resources.append(rawResource(r))
        }
        // The pixels are saved as they are shown: never let a reader rotate them again. The XMP
        // and EXIF resolution follow the ResolutionInfo resource (#1691).
        let ppi: (Float, Float)? = doc.resolutionDpi > 0 ? (doc.resolutionDpi, doc.resolutionDpi) : nil
        if let x = doc.metadata.xmp { resources.append(PSDImageResource(id: PSDResourceID.xmp, data: Data(MetadataExport.exportXmp(x, ppi).utf8))) }
        if let e = doc.metadata.exif { resources.append(PSDImageResource(id: PSDResourceID.exif, data: Data(MetadataExport.exportExif(e, ppi)))) }

        // Photoshop's layout (ps-corpus): 8-bit layers in the section, merged transparency as a
        // negative layer count; 16/32-bit layers in a global `Lr16`/`Lr32` block with a positive
        // count, preceded by an empty `Mt16`/`Mt32` matte block when the merged image has alpha.
        // Photoshop 27.11 refuses `Lr16`/`Lr32` written before the matte block (PCPSD
        // `layerInfoBeforeMatteBlock`), so the matte block is regenerated first and a kept one
        // (another writer's `Mtrn`, or one that no longer matches the merged alpha) is dropped.
        let hasLayers = !records.isEmpty
        let deep = sample == .u16 || sample == .f32
        let matteKey: FourCC? = hasLayers && deep && merged.hasAlpha ? (sample == .u16 ? "Mt16" : "Mt32") : nil
        var globalBlocks: [PSDTaggedBlock] = []
        if let k = matteKey { globalBlocks.append(PSDExport.globalBlock("8BIM", k, [])) }
        let preserved = smart.finish(AnnotationsMap.exportBlocks(doc, PatternMap.exportGlobalBlocks(doc, depth: sample)))
        if !doc.metadata.psdGlobalBlocks.allSatisfy(PatternMap.isReadable) {
            warnings.append("an unreadable pattern block was dropped (Photoshop refuses a file whose pattern data it cannot read)")
        }
        // The type layers' `Txt2` (one object per `TextIndex`; the auto-kern modes live there).
        // Photoshop 27.11 refuses files with a `Txt2` written by `PSDText.buildTxt2` ("General
        // Photoshop error"; the files open once it is dropped, and type files without `Txt2` open
        // fine). Until the offending field is known the export writes no generated `Txt2`: the
        // file's own block is kept only while the text is unmodified, which is when regenerating
        // it gives back the file's bytes (`buildTxt2` returns `previous` itself then). Optical
        // kerning, which only `Txt2` can say, is written as Metrics with a warning.
        var textLayers: [(index: Int32, layer: TextLayer)] = []
        var opticalNames: [String] = []
        for l in walk {
            guard case let .text(t) = l.content else { continue }
            textLayers.append((textIndex[l.id] ?? 0, t))
            if PSDText.needsTxt2([(0, t)]) { opticalNames.append(l.name) }
        }
        let previous = preserved.first { FourCC($0.key) == "Txt2" }?.data
        let txt2: [UInt8]? = previous.flatMap { p in PSDText.buildTxt2(textLayers, previous: p) == p ? p : nil }
        if previous != nil, txt2 == nil { warnings.append("the document's Txt2 text data was dropped: it no longer matches the type layers, and PCIO does not write Txt2 (Photoshop rebuilds it)") }
        if txt2 == nil, !opticalNames.isEmpty {
            warnings.append("type layers \(opticalNames.map { "\"\($0)\"" }.joined(separator: ", ")): Optical kerning is written as Metrics (it lives only in Txt2, which PCIO does not write)")
        }
        var txt2Written = false
        for b in preserved {
            let key = FourCC(b.key)
            if key == "Txt2" {
                // The file's own block, unchanged, at its own place; never a second one.
                if let t = txt2, !txt2Written { globalBlocks.append(PSDExport.globalBlock("8BIM", "Txt2", t)) }
                txt2Written = true
                continue
            }
            // A kept layer block (one the import could not read, #2700) describes layers the
            // document doesn't have: a second `Lr16`/`Lr32` would contradict the written layers.
            if !records.isEmpty && ["Lr16", "Lr32", "Layr"].contains(key) { continue }
            if PSDExport.matteKeys.contains(key) { continue }
            globalBlocks.append(PSDExport.globalBlock(PSDExport.blockSignature(FourCC(b.signature), version), key, b.data))
        }
        let compsResource: [UInt8]?? = comps != nil ? .some(CompsMap.writeCompsResource(doc)) : nil
        let (slicesResource, slicesWarning) = SlicesMap.exportResource(doc, layerIds)
        if let w = slicesWarning { warnings.append(w) }
        for r in doc.metadata.psdResources {
            // Kept copies of mapped resources were written (or regenerated) above.
            if PSDImport.rawKeptResources.contains(r.id) { continue }
            // Layer comps and slices: the preserved resource while unchanged, else regenerated.
            if r.id == CompsMap.layerComps && compsResource != nil { continue }
            if r.id == SlicesMap.slices && slicesResource != nil { continue }
            if !PSDExport.keepImportedResource(doc, r.id, r.data) { continue }
            resources.append(PSDImageResource(id: r.id, data: Data(r.data), name: PSDExport.legacyName(r.name)))
        }
        if let d = AnnotationsMap.freshScaleResource(doc) { resources.append(PSDImageResource(id: AnnotationsMap.measurementScale, data: Data(d))) }
        if case let .some(.some(d)) = compsResource { resources.append(PSDImageResource(id: CompsMap.layerComps, data: Data(d))) }
        if case let .some(.some(d)) = slicesResource { resources.append(PSDImageResource(id: SlicesMap.slices, data: Data(d))) }
        if options.photoshopRecordConventions {
            // Photoshop writes IPTC (record version only) and its print-output descriptor into
            // every file; with the pair ImageIO labels the merged alpha premultiplied, so Preview
            // and QuickLook show transparent composites right (PCPSD `PSDBuilder`).
            for r in PSDExport.photoshopDefaultResources where !resources.contains(where: { $0.id == r.id }) { resources.append(r) }
        }
        resources.append(PSDVersionInfo.resource(hasRealMergedData: true))
        resources = PSDExport.photoshopResourceOrder(resources, kept: doc.metadata.psdResources)

        var placement = PSDLayerInfoPlacement.section
        if hasLayers, deep {
            placement = .globalBlock(index: matteKey == nil ? 0 : 1, signature: "8BIM", key: sample == .u16 ? "Lr16" : "Lr32",
                                     padding: nil, longLengthOverride: nil)
        }
        var layerInfo: PSDLayerInfo?
        if hasLayers {
            var info = PSDLayerInfo(mergedAlpha: merged.hasAlpha && !deep, layers: records, padding: nil)
            // Photoshop pads the layer info to 4 bytes (an even pad misaligns readers after a
            // global `Lr16`/`Lr32` block, #200).
            if (try? info.pad(to: 4, version: version)) == nil { info.padding = nil }
            layerInfo = info
        }
        // 32-bit files carry Photoshop's HDR toning records as Color Mode Data (#291).
        let file = PSDFile(header: header, colorModeData: PSDHDRToning.colorModeData(depth: header.depth), resources: resources,
                           layerInfo: layerInfo, layerInfoPlacement: placement,
                           globalLayerMask: hasLayers || !globalBlocks.isEmpty ? PSDGlobalLayerMask() : nil, globalBlocks: globalBlocks,
                           imageData: imageData)
        return (file, warnings)
    }

    static func be32(_ v: Int32) -> [UInt8] {
        let u = UInt32(bitPattern: v)
        return [UInt8(u >> 24), UInt8(u >> 16 & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u & 0xFF)]
    }
}
