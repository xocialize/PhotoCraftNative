// Compositor `.comp` import (format versions 1–13): a macOS document package holding
// `manifest.json` and `images/` (`<layer id>.png` at 8 or 16 bits, `<layer id>.exr` half floats,
// `<layer id>.mask.png` 8-bit gray masks). `.comp` stays an import format (bridge decision
// AB-D-0131); a document opened from one saves as `.pcraft` or PSD.
//
// Mapping (each documented where it happens):
// - pixel layers: copied exactly when the layer sits one-to-one on whole pixels; a layer Compositor
//   shows scaled, turned, flipped or at a fractional position is a smart object (bridge decision
//   AB-D-0140): its full-resolution image, embedded losslessly, plus the transform, with the pixels
//   drawn as Compositor draws them as its rendered appearance (`TransformedLayers.pixels` keeps
//   the drawn pixels alone);
// - depth: 8-bit layers make an 8-bit document, any 16-bit layer a 16-bit one, any OpenEXR layer
//   a 32-bit linear document (OpenEXR holds linear light, as File › Open treats it);
// - folders are Pass Through groups with their opacity and mask;
// - clipping (`maskSourceID`): a run of layers clipped to the layer right below them in the same
//   folder is a Photoshop clipping group (Compositor composites that run as one stack in the base's
//   blend mode, as Photoshop does); any other link has no Photoshop form and the source's coverage
//   is baked into the clipped layer's mask, with a warning;
// - the 24 blend modes by name; 8 of the 12 adjustment kinds and all 6 effects (CompMap);
// - text and shape metadata become type and shape layers whose pixels stay Compositor's PNG;
// - guides and resolution.
// What has no PCDocument form is listed in `ImportResult.warnings`.
//
// Written from Compositor's IO/ProjectStore.swift, IO/ImageExporter.swift,
// Rendering/LiveMaskRenderer.swift and Document/LayerGroups.swift (MIT, © 2026 Wonder Assembly
// LLC) and docs/project-format.md.

import CoreGraphics
import Foundation
import PCDocument
import PCFoundation
import PCIOCore

public enum CompImport {
    public static let fileExtension = "comp"
    static let manifestName = "manifest.json"
    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    static let exrSignature: [UInt8] = [0x76, 0x2F, 0x31, 0x01]

    /// The files of one package: `manifest.json` and `images/<name>`, read with a size cap.
    public struct Package: Sendable {
        public let name: String
        let read: @Sendable (_ path: String, _ maxBytes: Int) throws(CompError) -> [UInt8]

        public init(name: String, read: @escaping @Sendable (_ path: String, _ maxBytes: Int) throws(CompError) -> [UInt8]) {
            self.name = name
            self.read = read
        }

        /// A package on disk. As Compositor's `ProjectStore.checkFile`: every file must resolve inside
        /// the package, be a regular file and not a symbolic link, and stay under its size cap.
        public static func directory(_ url: URL) -> Package {
            let root = url.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            return Package(name: url.lastPathComponent) { (path: String, maxBytes: Int) throws(CompError) -> [UInt8] in
                let file = url.appendingPathComponent(path)
                guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw .invalid("\(path) lies outside the package") }
                guard let v = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      v.isRegularFile == true, v.isSymbolicLink != true, let size = v.fileSize else {
                    throw path == manifestName ? .invalid("the package has no manifest.json") : .missingImage("\(path) is missing or not a plain file")
                }
                guard size <= maxBytes else { throw .tooLarge("\(path) is \(size) bytes (at most \(maxBytes))") }
                guard let data = try? Data(contentsOf: file) else { throw .missingImage("\(path) can't be read") }
                return [UInt8](data)
            }
        }

        /// A package held in memory, keyed by path inside it (`manifest.json`, `images/…`).
        public static func files(name: String, _ files: [String: [UInt8]]) -> Package {
            Package(name: name) { (path: String, maxBytes: Int) throws(CompError) -> [UInt8] in
                guard let b = files[path] else {
                    throw path == manifestName ? .invalid("the package has no manifest.json") : .missingImage("\(path) is missing")
                }
                guard b.count <= maxBytes else { throw .tooLarge("\(path) is \(b.count) bytes (at most \(maxBytes))") }
                return b
            }
        }
    }

    /// Whether `url` is a Compositor package: a directory whose `manifest.json` names the format
    /// (a `.comp` directory without one is reported by the import instead).
    public static func isPackage(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), dir.boolValue else { return false }
        if url.pathExtension.lowercased() == fileExtension { return true }
        guard let data = try? Data(contentsOf: url.appendingPathComponent(manifestName), options: .alwaysMapped), data.count <= CompManifest.maxManifestBytes,
              let header = try? JSONDecoder().decode(Header.self, from: data) else { return false }
        return header.format == CompManifest.formatID
    }

    /// What a pixel layer becomes when Compositor shows it scaled, turned, flipped or at a
    /// fractional position: anywhere its pixels don't land one-to-one on whole document pixels.
    public enum TransformedLayers: Sendable {
        /// A smart object (AB-D-0140): the layer's full-resolution image, embedded losslessly (PNG
        /// at the document's 8 or 16 bits, a float TIFF in a 32-bit document), and the transform,
        /// so the transform stays non-destructive. Its rendered appearance is the pixels drawn as
        /// Compositor draws them.
        case smartObjects
        /// A pixel layer holding those drawn pixels alone; the image's own resolution is lost.
        case pixels
    }

    /// Imports the package at `url`.
    public static func importDocument(contentsOf url: URL, codec: any FlatImageCodec, interrupt: Interrupt = .none,
                                      transformedLayers: TransformedLayers = .smartObjects) throws -> ImportResult {
        try importDocument(.directory(url), codec: codec, interrupt: interrupt, transformedLayers: transformedLayers)
    }

    /// Imports a package. Refusals are `PCIOError.format("Compositor", …)` naming the rule.
    public static func importDocument(_ package: Package, codec: any FlatImageCodec, interrupt: Interrupt = .none,
                                      transformedLayers: TransformedLayers = .smartObjects) throws -> ImportResult {
        do { return try load(package, codec: codec, interrupt: interrupt, transformedLayers: transformedLayers) } catch let e as CompError {
            throw PCIOError.format("Compositor", e.description)
        }
    }

    // MARK: Manifest

    struct Header: Decodable {
        var format: String
        var version: Int
    }

    /// The manifest, checked as `ProjectStore.readPackage` checks it: the header first (so a
    /// newer version reports its number), then the whole record, then every version gate.
    static func manifest(_ bytes: [UInt8]) throws(CompError) -> CompManifest {
        let data = Data(bytes)
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw .invalid("manifest.json is not a Compositor manifest") }
        guard header.format == CompManifest.formatID else { throw .invalid("format is \"\(header.format)\", not \(CompManifest.formatID)") }
        guard CompManifest.supported.contains(header.version) else { throw .version(header.version) }
        let m: CompManifest
        do { m = try JSONDecoder().decode(CompManifest.self, from: data) } catch { throw .invalid("manifest.json: \(describe(error))") }
        try m.validate()
        return m
    }

    static func describe(_ error: any Error) -> String {
        guard let e = error as? DecodingError else { return "\(error)" }
        func path(_ c: [any CodingKey]) -> String { c.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".") }
        switch e {
        case .keyNotFound(let k, let c): return "\(path(c.codingPath + [k])) is missing"
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): return "\(path(c.codingPath)): \(c.debugDescription)"
        @unknown default: return "\(e)"
        }
    }

    // MARK: Assets

    /// A layer's decoded image.
    struct Image {
        var surface: Surface
        var width: Int
        var height: Int
        /// HDR pixels (linear float, from an OpenEXR that passes white).
        var exr: Bool
    }

    /// A mask's 8-bit gray values, row-major.
    struct Mask {
        var values: [Float]
        var width: Int
        var height: Int
    }

    static func decodeAssets(_ m: CompManifest, _ package: Package, _ codec: any FlatImageCodec, _ interrupt: Interrupt) throws -> ([UUID: Image], [UUID: Mask]) {
        var images: [UUID: Image] = [:], masks: [UUID: Mask] = [:]
        var pixels = 0, maskPixels = 0
        let total = max(1, m.layers.reduce(0) { $0 + ($1.imageFile == nil ? 0 : 1) + ($1.maskFile == nil ? 0 : 1) })
        var done = 0
        func budget(_ w: Int, _ h: Int, _ used: inout Int, _ what: String) throws(CompError) {
            guard (1 ... CompManifest.maxSide).contains(w), (1 ... CompManifest.maxSide).contains(h) else {
                throw .tooLarge("\(what) is \(w) × \(h) (at most \(CompManifest.maxSide) px a side)")
            }
            guard w * h <= CompManifest.pixelBudget - used else { throw .tooLarge("more than \(CompManifest.pixelBudget / 1_000_000) MP of \(what.hasSuffix("mask") ? "masks" : "layer images")") }
            used += w * h
        }
        for l in m.layers {
            for isMask in [false, true] {
                guard let file = isMask ? l.maskFile : l.imageFile else { continue }
                try interrupt.check()
                let path = "images/\(file)"
                let bytes = try package.read(path, CompManifest.maxAssetBytes)
                let exr = !isMask && file.hasSuffix(".exr")
                guard bytes.starts(with: exr ? exrSignature : pngSignature) else {
                    throw CompError.missingImage("\(file) is not \(exr ? "an OpenEXR" : "a PNG") file")
                }
                let img: DecodedImage
                do { img = try codec.decode(bytes) } catch { throw CompError.missingImage("\(file) can't be decoded (\(error))") }
                let fmt = img.surface.format
                if isMask {
                    // `LayerMask.isValid`: 8-bit gray without alpha.
                    guard fmt.mode == .grayscale, fmt.sample == .u8, !img.hasAlpha else {
                        throw CompError.invalid("\(file): a mask must be an 8-bit gray PNG without alpha")
                    }
                    try budget(img.width, img.height, &maskPixels, "layer \"\(l.name)\"'s mask")
                    let rect = PixelRect(x: 0, y: 0, width: img.width, height: img.height)
                    masks[l.id] = Mask(values: img.surface.readRGBA(rect).map(\.x), width: img.width, height: img.height)
                } else {
                    try budget(img.width, img.height, &pixels, "layer \"\(l.name)\"'s image")
                    // 16-bit layer images from version 12; OpenEXR (version 13) is gated by its name.
                    if !exr {
                        guard fmt.sample != .f32 else { throw CompError.missingImage("\(file) holds float samples; only OpenEXR layers may") }
                        guard fmt.sample == .u8 || m.version >= 12 else { throw CompError.missingImage("\(file) is 16-bit, which needs version 12") }
                    }
                    var surface = img.surface, hdr = exr
                    if exr, !CompPixels.passesWhite(surface, img.width, img.height) {
                        // `DeepLayer.wideAsset`: an OpenEXR that never passes white is a 16-bit layer.
                        surface = CompPixels.encodedSixteen(surface, img.width, img.height)
                        hdr = false
                    }
                    images[l.id] = Image(surface: surface, width: img.width, height: img.height, exr: hdr)
                }
                done += 1
                interrupt.progress(Float(0.6 * Double(done) / Double(total)))
            }
        }
        return (images, masks)
    }

    // MARK: Import

    static func load(_ package: Package, codec: any FlatImageCodec, interrupt: Interrupt,
                     transformedLayers: TransformedLayers = .smartObjects) throws -> ImportResult {
        let m = try manifest(try package.read(manifestName, CompManifest.maxManifestBytes))
        let (images, masks) = try decodeAssets(m, package, codec, interrupt)
        var b = Builder(m: m, images: images, masks: masks, interrupt: interrupt, transformedLayers: transformedLayers)
        let doc = try b.build(name: package.name)
        interrupt.progress(1)
        return ImportResult(document: doc, warnings: b.warnings.list, sourceReadOnly: true)
    }

    /// Ordered, de-duplicated warnings.
    struct Warnings {
        private(set) var list: [String] = []
        private var seen = Set<String>()
        mutating func add(_ s: String) { if seen.insert(s).inserted { list.append(s) } }
    }

    struct Builder {
        let m: CompManifest
        let images: [UUID: Image]
        let masks: [UUID: Mask]
        let interrupt: Interrupt
        let transformedLayers: TransformedLayers
        var warnings = Warnings()

        let byID: [UUID: CompLayer]
        /// Children of each folder (nil = the root), bottom to top.
        let children: [UUID?: [CompLayer]]
        let canvas: PixelRect
        /// Resampled pixels are kept this far beyond the canvas.
        let limit: PixelRect
        var format = PixelFormat.rgba8
        var maskFormat = PixelFormat.gray8
        var iccProfile: [UInt8]?
        /// Placed pixels and masks, by layer.
        var placed: [UUID: Surface] = [:]
        var placedMasks: [UUID: Surface] = [:]
        /// The full-resolution images (in the document's format) of the layers that become smart objects.
        var smartSources: [UUID: Surface] = [:]
        var coverageCache: [UUID: [Float]] = [:]
        /// Layers clipped to the layer below (Photoshop clipping), and links baked into masks.
        var clipped = Set<UUID>()
        var baked = Set<UUID>()
        /// Clipped adjustment layers Compositor never draws (no clipping stack to apply them in).
        var inert = Set<UUID>()

        init(m: CompManifest, images: [UUID: Image], masks: [UUID: Mask], interrupt: Interrupt, transformedLayers: TransformedLayers = .smartObjects) {
            self.m = m; self.images = images; self.masks = masks; self.interrupt = interrupt; self.transformedLayers = transformedLayers
            byID = Dictionary(m.layers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            children = Dictionary(grouping: m.layers, by: \.parentID)
            canvas = PixelRect(x: 0, y: 0, width: m.width, height: m.height)
            let side = Int32(max(m.width, m.height))
            limit = canvas.outset(by: side)
        }

        // MARK: Hierarchy (`LayerHierarchy.entries`, `LayerOpacity.effective`)

        /// Every layer and folder in drawing order (a folder before what's inside it) with whether
        /// it shows, as Compositor walks them.
        func entries() -> [(layer: CompLayer, visible: Bool)] {
            var out: [(CompLayer, Bool)] = []
            func visit(_ parent: UUID?, _ depth: Int, _ visible: Bool) {
                guard depth <= 64 else { return }
                for l in children[parent] ?? [] {
                    let v = visible && l.isVisible
                    out.append((l, v))
                    if l.group { visit(l.id, depth + 1, v) }
                }
            }
            visit(nil, 0, true)
            return out
        }

        /// A layer's opacity with every enclosing folder's multiplied in.
        func effectiveOpacity(_ l: CompLayer) -> Double {
            var o = l.opacity ?? 1, id = l.parentID, depth = 0
            while let p = id, depth < 64, let f = byID[p] { o *= f.opacity ?? 1; id = f.parentID; depth += 1 }
            return o
        }

        // MARK: Clipping (`LiveMaskRenderer.prepareStacks`)

        /// Compositor draws a run of visible layers clipped to the visible layer right below them,
        /// in the same folder, as one stack composited in the base's mode: Photoshop's clipping
        /// group. Such a run becomes `clipped` when nothing else sits between its layers in the
        /// folder; every other link is baked. A clipped adjustment outside a stack is never drawn.
        mutating func planClipping() {
            let visible = entries().filter { $0.visible && !$0.layer.group }.map(\.layer)
            var stacks: [(base: CompLayer, members: [CompLayer])] = []
            for (i, base) in visible.enumerated() where base.maskSourceID == nil && base.adjustment == nil {
                var members: [CompLayer] = []
                for c in visible.dropFirst(i + 1) {
                    guard c.maskSourceID == base.id, c.parentID == base.parentID else { break }
                    members.append(c)
                }
                if !members.isEmpty { stacks.append((base, members)) }
            }
            for (base, members) in stacks {
                let siblings = children[base.parentID] ?? []
                guard let i0 = siblings.firstIndex(where: { $0.id == base.id }) else { continue }
                let ids = Set(members.map(\.id))
                let last = siblings.lastIndex { ids.contains($0.id) } ?? i0
                // Hidden layers clipped to the same base may sit in the run (Photoshop keeps them in
                // the clipping group); anything else between breaks it.
                guard siblings[(i0 + 1) ... last].allSatisfy({ $0.maskSourceID == base.id }) else { continue }
                var k = last + 1
                for s in siblings[(i0 + 1) ... last] { clipped.insert(s.id) }
                while k < siblings.count, siblings[k].maskSourceID == base.id, !ids.contains(siblings[k].id) { clipped.insert(siblings[k].id); k += 1 }
            }
            let shown = Set(visible.map(\.id))
            for l in m.layers {
                guard let src = l.maskSourceID, !clipped.contains(l.id) else { continue }
                let s = byID[src]?.name ?? src.uuidString
                if l.adjustment != nil {
                    inert.insert(l.id)
                    if shown.contains(l.id) {
                        warnings.add("Adjustment layer \"\(l.name)\" is clipped to \"\(s)\" but not stacked on it, so Compositor never applies it; imported hidden")
                    }
                } else {
                    baked.insert(l.id)
                    warnings.add("Layer \"\(l.name)\" is clipped to \"\(s)\", which is not the visible layer right below it in the same folder: Photoshop clipping can't express that, so \"\(s)\"'s coverage is baked into \"\(l.name)\"'s mask")
                }
            }
        }

        // MARK: Pixels

        mutating func placeAll() throws {
            var hdrLinearized = false
            for l in m.layers {
                try interrupt.check()
                if let img = images[l.id] {
                    var src = img.surface
                    if format.sample == .f32, !img.exr { hdrLinearized = true }
                    src = CompPixels.toDocument(src, format)
                    let p = CompPixels.placeLayer(src, img.width, img.height, l.transform, format: format, limit: limit)
                    if p.resampled, transformedLayers == .smartObjects, l.text == nil, l.shape == nil {
                        // The image keeps every pixel; only its rendered appearance is drawn within the limit.
                        smartSources[l.id] = src
                        if l.transform.sampling == .nearest {
                            warnings.add("Layer \"\(l.name)\": a smart object re-renders with bicubic resampling when its transform changes; Compositor drew it with Nearest Neighbor")
                        }
                    } else {
                        if p.resampled { warnings.add("Layer \"\(l.name)\": its transform (scale, rotation, flip or a fractional position) is applied to the pixels") }
                        if p.cropped { warnings.add("Layer \"\(l.name)\": pixels more than a canvas beyond the canvas were left out") }
                    }
                    placed[l.id] = p.surface
                }
                if let mk = masks[l.id] {
                    // A folder's or adjustment's mask covers its own box and hides everything outside
                    // it (`FolderMaskClip`); a layer's covers its pixels, and an unlinked one keeps its
                    // own placement with the colour most of its edge has beyond it (`LayerMask.placed`).
                    let ownBox = l.group || l.adjustment != nil
                    var t = l.transform
                    if !ownBox, let p = l.maskPlacement, !p.samePlacement(as: l.transform) { t = p }
                    let bg: Float = ownBox ? 0 : edgeMajority(mk)
                    placedMasks[l.id] = CompPixels.placeMask(mk.values, mk.width, mk.height, t, background: bg, format: maskFormat, limit: limit)
                }
            }
            if hdrLinearized {
                warnings.add("OpenEXR layers make this a 32-bit linear document: 8- and 16-bit layers were converted to linear light, and blending happens in linear light where Compositor blends in sRGB")
            }
        }

        /// `LayerMask.background`: white or black, whichever most of the mask's edge is.
        func edgeMajority(_ mk: Mask) -> Float {
            var total: Float = 0, count = 0
            for y in 0 ..< mk.height {
                for x in 0 ..< mk.width where y == 0 || y == mk.height - 1 || x == 0 || x == mk.width - 1 {
                    total += mk.values[y * mk.width + x]; count += 1
                }
            }
            return total * 2 >= Float(count) ? 1 : 0
        }

        /// What a live mask source contributes (`LiveMaskRenderer.coverage`): its pixels' alpha at
        /// its effective opacity, through its own enabled mask and its own source, whether or not it
        /// shows; 8-bit, as Compositor's coverage image is. Over the canvas only.
        mutating func coverage(_ id: UUID, depth: Int = 0) -> [Float] {
            if let c = coverageCache[id] { return c }
            guard depth < 256, let l = byID[id] else { return [Float](repeating: 0, count: canvas.area) }
            var cov: [Float]
            if let s = placed[id] {
                let o = Float(effectiveOpacity(l))
                cov = s.readRGBA(canvas).map { $0.w * o }
            } else {
                cov = [Float](repeating: 0, count: canvas.area)
            }
            if (l.maskEnabled ?? true), let mk = placedMasks[id] {
                let v = mk.readRegion(canvas)
                for i in cov.indices { cov[i] *= v[i] }
            }
            if let src = l.maskSourceID {
                let up = coverage(src, depth: depth + 1)
                for i in cov.indices { cov[i] *= up[i] }
            }
            if l.effects.map({ !$0.isEmpty }) == true {
                warnings.add("Layer \"\(l.name)\" clips other layers through its coverage, which here leaves out its effects")
            }
            cov = cov.map { ($0 * 255).rounded() / 255 }
            coverageCache[id] = cov
            return cov
        }

        // MARK: Layers

        mutating func layerMask(_ l: CompLayer) -> LayerMask? {
            let enabled = l.maskEnabled ?? true, linked = l.maskLinked ?? true
            if baked.contains(l.id), let src = l.maskSourceID {
                let cov = coverage(src)
                var v = cov
                if let mk = placedMasks[l.id] {
                    if enabled {
                        let own = mk.readRegion(canvas)
                        for i in v.indices { v[i] *= own[i] }
                    } else {
                        warnings.add("Layer \"\(l.name)\": its disabled mask was replaced by the baked clipping coverage")
                    }
                }
                var s = Surface(format: maskFormat, defaultPixel: [0])
                s.writeRegion(canvas, v)
                s.prune()
                return LayerMask(surface: s, enabled: true, linked: linked)
            }
            guard let s = placedMasks[l.id] else { return nil }
            return LayerMask(surface: s, enabled: enabled, linked: linked)
        }

        /// Visible pixel and adjustment layers inside `folder`, at any depth.
        func drawableCount(in folder: UUID) -> Int {
            (children[folder] ?? []).reduce(0) { n, c in
                guard c.isVisible else { return n }
                if c.group { return n + drawableCount(in: c.id) }
                return n + 1
            }
        }

        mutating func layers(in parent: UUID?) throws -> [Layer] {
            var out: [Layer] = []
            for r in children[parent] ?? [] {
                try interrupt.check()
                guard let l = try layer(r) else { continue }
                out.append(l)
            }
            return out
        }

        mutating func layer(_ r: CompLayer) throws -> Layer? {
            var l: Layer
            if r.group {
                l = Layer.group(r.name, try layers(in: r.id))
                let masked = r.maskFile != nil && (r.maskEnabled ?? true)
                let what = [(r.opacity ?? 1) < 1 ? "opacity" : nil, masked ? "mask" : nil].compactMap { $0 }
                if !what.isEmpty, drawableCount(in: r.id) > 1 {
                    warnings.add("Folder \"\(r.name)\": its \(what.joined(separator: " and ")) now \(what.count > 1 ? "apply" : "applies") to the folder's combined result (Photoshop's Pass Through); Compositor applied \(what.count > 1 ? "them" : "it") to each layer inside, so layers overlapping inside it can look different")
                }
            } else if let a = r.adjustment {
                var notes: [String] = []
                guard let adj = CompMap.adjustment(a, layer: r.name, warn: { notes.append($0) }) else {
                    warnings.add("\(CompMap.unmappedReason(a)) adjustment layer \"\(r.name)\" is a kind this version doesn't know and was left out: the layers below show without it")
                    return nil
                }
                notes.forEach { warnings.add($0) }
                l = Layer(name: r.name, content: .adjustment(adj))
            } else {
                let surface = placed[r.id] ?? Surface(format: format)
                l = Layer.raster(r.name, surface: surface)
                if let img = images[r.id] {
                    if let text = r.text {
                        let m = r.transform.pixelToDocument(img.width, img.height)
                        let affine = PCAffine(a: m.a, b: m.b, c: m.c, d: m.d, e: m.tx, f: m.ty)
                        l.content = .text(CompMap.text(text, box: (Double(img.width), Double(img.height)), layerToDocument: affine,
                                                       dpi: m_resolution, cache: surface))
                        warnings.add("Type layers keep Compositor's rendered pixels until edited; editing re-sets the text with PhotoCraft's type engine, which can shift it slightly")
                    } else if let shape = r.shape {
                        l.content = .shape(CompMap.shape(shape, r.transform, img.width, img.height, cache: surface))
                    } else if let source = smartSources[r.id] {
                        l.content = .smart(try smartObject(r, source, img, cache: surface))
                    }
                }
                if let e = r.effects, !e.isEmpty {
                    let scale = images[r.id].map { r.transform.width / Double(max(1, $0.width)) } ?? 1
                    l.effects = CompMap.effects(e, scale: scale)
                    warnings.add("Layer effects are drawn by Photoshop's layer-style model (Normal blend, Photoshop's blur shapes); Compositor's own effect renderer differs in the soft edges")
                }
            }
            l.visible = r.isVisible && !(inert.contains(r.id))
            l.opacity = Float(r.opacity ?? 1)
            if !r.group {
                if let mode = CompMap.blendMode(r.blendMode) { l.blend = mode } else {
                    warnings.add("Layer \"\(r.name)\": unknown blend mode \"\(r.blendMode ?? "")\" opened as Normal")
                    l.blend = .normal
                }
            }
            l.clipped = clipped.contains(r.id)
            l.mask = layerMask(r)
            return l
        }

        /// The smart object of a transformed pixel layer (AB-D-0140): `source` (its `img.width` ×
        /// `img.height` image in the document's format) embedded losslessly, placed by the layer's
        /// transform, with `cache` (the pixels drawn as Compositor draws them) as its appearance.
        /// The source decodes to `source` exactly, so a transform back to 100 % gives the image
        /// itself.
        func smartObject(_ r: CompLayer, _ source: Surface, _ img: Image, cache: Surface) throws -> SmartObject {
            let grid = PixelRect(x: 0, y: 0, width: img.width, height: img.height)
            let type: FlatImageType = format.sample == .f32 ? .tiff : .png
            let bytes: [UInt8]
            do {
                bytes = try ImageIOCodec().encode(source, rect: grid, as: type, quality: nil, iccProfile: iccProfile, metadata: FlatMetadata.Metadata(),
                                                  dpi: m_resolution)
            } catch {
                throw CompError.missingImage("layer \"\(r.name)\"'s image can't be embedded in its smart object (\(error))")
            }
            let source = SmartSource.embedded(fileName: Self.sourceFileName(r.name, type), bytes: bytes)
            return SmartObject(source: source, transform: CompPixels.affine(r.transform, img.width, img.height), cache: cache)
        }

        /// The embedded file's name: the layer's, as a file name, with the image type's extension.
        static func sourceFileName(_ layer: String, _ type: FlatImageType) -> String {
            let stem = layer.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }.prefix(200)
            let name = String(stem).trimmingCharacters(in: .whitespaces)
            return (name.isEmpty ? "Layer" : name) + (type == .tiff ? ".tif" : ".png")
        }

        var m_resolution: Double { m.resolution ?? 72 }

        mutating func build(name: String) throws -> Document {
            let hasEXR = images.values.contains { $0.exr }
            let has16 = images.values.contains { !$0.exr && $0.surface.format.sample == .u16 }
            let depth: SampleType = hasEXR ? .f32 : has16 ? .u16 : .u8
            format = PixelFormat(mode: .rgb, sample: depth, alpha: true)
            maskFormat = PixelFormat(mode: .grayscale, sample: depth, alpha: false)
            var doc = Document(name: name, size: PixelSize(width: m.width, height: m.height), mode: .rgb, depth: depth)
            doc.resolutionDpi = Float(m_resolution)
            // Compositor documents are sRGB; OpenEXR ones are linear light with sRGB primaries.
            let space = depth == .f32 ? CGColorSpace.linearSRGB : CGColorSpace.sRGB
            doc.iccProfile = CGColorSpace(name: space)?.copyICCData().map { [UInt8]($0 as Data) }
            iccProfile = doc.iccProfile
            planClipping()
            try placeAll()
            interrupt.progress(0.8)
            doc.layers = try layers(in: nil)
            for g in m.guides ?? [] {
                switch g.axis {
                case .horizontal: doc.guides.horizontal.append(g.position)
                case .vertical: doc.guides.vertical.append(g.position)
                }
            }
            return doc
        }
    }
}
