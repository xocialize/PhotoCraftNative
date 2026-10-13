// The document: canvas, colour model and depth, the layer tree and everything stored with it
// (channels, guides, selection, paths, patterns, comps, slices, variables, timeline, metadata).
// Port of photocraft-doc (crates/doc/src/lib.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// A `Document` is a value. Copying one is the snapshot: the layer array and every surface are
// copy-on-write, so a copy costs O(1) up front and later edits copy only the layers and tiles they
// touch (architecture §1 principle 5, "immutable snapshots, copy-on-write tiles").

import PCFoundation

/// Ruler guides in document pixels. Double like the rest of the view geometry: a guide placed in
/// ruler units (1 cm at 300 ppi is 118.110236… px) or read from a PSD's 1/32 px positions keeps its
/// exact place.
public struct Guides: Hashable, Sendable, Codable {
    public var horizontal: [Double]
    public var vertical: [Double]
    /// Guides given their own colour (View › Guides › New Guide… › Color). The rest use the
    /// preference colour.
    public var colors: [GuideColor]

    public init(horizontal: [Double] = [], vertical: [Double] = [], colors: [GuideColor] = []) {
        self.horizontal = horizontal; self.vertical = vertical; self.colors = colors
    }

    public var isEmpty: Bool { horizontal.isEmpty && vertical.isEmpty }

    /// The guide's own colour, if it has one.
    public func color(vertical: Bool, position: Double) -> SIMD3<UInt8>? {
        colors.first { $0.vertical == vertical && $0.position == position }?.rgb
    }

    /// Give the guide at `position` its own colour (nil returns it to the preference colour).
    public mutating func setColor(vertical: Bool, position: Double, rgb: SIMD3<UInt8>?) {
        colors.removeAll { $0.vertical == vertical && $0.position == position }
        if let rgb { colors.append(GuideColor(vertical: vertical, position: position, rgb: rgb)) }
    }

    /// Drop colours whose guide no longer exists (after a guide moved, was deleted or cleared).
    public mutating func pruneColors() {
        let (h, v) = (horizontal, vertical)
        colors.removeAll { c in c.vertical ? !v.contains(c.position) : !h.contains(c.position) }
    }

    enum CodingKeys: String, CodingKey { case horizontal, vertical, colors }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        horizontal = try c.decode([Double].self, forKey: .horizontal)
        vertical = try c.decode([Double].self, forKey: .vertical)
        colors = try c.decode(.colors, or: [])
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(horizontal, forKey: .horizontal)
        try c.encode(vertical, forKey: .vertical)
        if !colors.isEmpty { try c.encode(colors, forKey: .colors) }
    }
}

/// One guide's own colour. It is keyed by orientation and position, not by index, so code that
/// drops or reorders guide positions (crop, artboards, guide layouts) can never move a colour onto
/// another guide: a guide whose entry no longer matches simply uses the preference colour.
public struct GuideColor: Hashable, Sendable, Codable {
    public var vertical: Bool
    public var position: Double
    /// sRGB, 0–255.
    public var rgb: SIMD3<UInt8>

    public init(vertical: Bool, position: Double, rgb: SIMD3<UInt8>) { self.vertical = vertical; self.position = position; self.rgb = rgb }
}

/// Which areas an alpha channel's overlay colour marks (Channel Options › Color Indicates).
public enum ColorIndicates: String, CaseIterable, Hashable, Sendable, Codable {
    /// Colour shows over black (unselected) pixels: Photoshop's default.
    case maskedAreas
    /// Colour shows over white (selected) pixels.
    case selectedAreas
}

/// A spot channel's ink: colour and solidity (0...1).
public struct SpotInk: Hashable, Sendable {
    public var color: PCColor
    public var solidity: Float
    public init(color: PCColor, solidity: Float) { self.color = color; self.solidity = solidity }
}

/// An extra (alpha or spot) channel, also used for the temporary Quick Mask channel.
///
/// The surface is grayscale at the document depth; white = selected (1.0), black = masked.
public struct AlphaChannel: Equatable, Sendable {
    /// Photoshop's default overlay: red at 50 % over masked areas.
    public static let defaultColor = PCColor.rgb(1, 0, 0)

    public var name: String
    public var surface: Surface
    /// Spot colour channels carry their ink colour and solidity.
    public var spot: SpotInk?
    /// Overlay colour shown when the channel is viewed together with the composite.
    public var color: PCColor
    /// Overlay opacity (0...1).
    public var opacity: Float
    public var indicates: ColorIndicates

    public init(name: String, surface: Surface) {
        self.name = name
        self.surface = surface
        spot = nil
        color = AlphaChannel.defaultColor
        opacity = 0.5
        indicates = .maskedAreas
    }

    /// Overlay coverage (0...1, before opacity) for channel value `v`: spot channels show ink where
    /// the channel is white, alpha channels follow `ColorIndicates`.
    public func overlayCoverage(_ v: Float) -> Float {
        spot != nil || indicates == .selectedAreas ? v : 1 - v
    }
}

/// A free-form text entry (PNG tEXt/zTXt/iTXt, TIFF ASCII tags).
public struct MetadataText: Hashable, Sendable {
    public var key: String
    public var value: String
    public init(_ key: String, _ value: String) { self.key = key; self.value = value }
}

/// A raw PSD image resource: (id, name, data).
public struct PSDResource: Hashable, Sendable {
    public var id: UInt16
    public var name: String
    public var data: [UInt8]
    public init(id: UInt16, name: String, data: [UInt8]) { self.id = id; self.name = name; self.data = data }
}

/// A raw PSD global tagged block: (signature, key, data).
public struct PSDGlobalBlock: Hashable, Sendable {
    public var signature: PSDKey
    public var key: PSDKey
    public var data: [UInt8]
    public init(signature: PSDKey, key: PSDKey, data: [UInt8]) { self.signature = signature; self.key = key; self.data = data }
}

/// Metadata carried with a document.
public struct Metadata: Hashable, Sendable {
    public var xmp: String?
    public var exif: [UInt8]?
    /// Free-form image text (PNG tEXt/zTXt/iTXt, TIFF ASCII tags), including duplicate keys.
    public var text: [MetadataText]
    /// Raw PSD image resources not modelled yet, for lossless round-trip.
    public var psdResources: [PSDResource]
    /// Raw PSD global additional-layer-info blocks, e.g. `lnk2` embedded smart-object files,
    /// `Patt` patterns, `Txt2`.
    public var psdGlobalBlocks: [PSDGlobalBlock]

    public init(xmp: String? = nil, exif: [UInt8]? = nil, text: [MetadataText] = [], psdResources: [PSDResource] = [],
                psdGlobalBlocks: [PSDGlobalBlock] = []) {
        self.xmp = xmp; self.exif = exif; self.text = text; self.psdResources = psdResources; self.psdGlobalBlocks = psdGlobalBlocks
    }
}

/// The encoder settings a document's file was opened or saved with: what File › Save and the Save
/// As defaults reuse for that format. Empty for a new document or a file without lossy options.
/// Qualities are on the codecs' 1–100 scale. JSON keys are camelCase and optional.
public struct FileEncoding: Hashable, Sendable, Codable {
    /// JPEG quality (estimated from the file's quantisation tables on open).
    public var jpegQuality: UInt8?
    /// WebP: true lossless (VP8L), false lossy (VP8 at `webpQuality`).
    public var webpLossless: Bool?
    /// Lossy WebP quality.
    public var webpQuality: UInt8?

    public init(jpegQuality: UInt8? = nil, webpLossless: Bool? = nil, webpQuality: UInt8? = nil) {
        self.jpegQuality = jpegQuality; self.webpLossless = webpLossless; self.webpQuality = webpQuality
    }

    public var isEmpty: Bool { self == FileEncoding() }
}

/// Where a layer lives in the tree: child indices from the root down.
public typealias LayerPath = [Int]

/// One entry of `Document.walk()`.
public struct LayerWalkEntry: Sendable {
    public var path: LayerPath
    /// 0 for a root-level layer, 1 inside one group, …
    public var depth: Int
    public var layer: Layer
}

/// A document.
public struct Document: Equatable, Sendable {
    public var id: DocId
    public var name: String
    public var size: PixelSize
    public var resolutionDpi: Float
    public var mode: ColorMode
    public var depth: SampleType
    public var iccProfile: [UInt8]?
    /// The layer tree's root, bottom-to-top. Any mutation through this property invalidates the
    /// id index; prefer `updateLayer` and the tree helpers, which keep it.
    public var layers: [Layer] { didSet { index = LayerIndex() } }
    public var channels: [AlphaChannel]
    public var guides: Guides
    /// Active selection as a grayscale coverage surface (nil = no selection).
    public var selection: Surface?
    public var metadata: Metadata
    /// Global light used by layer effects (PSD resources 1037/1049).
    public var globalLight: GlobalLight
    /// Saved paths (Paths panel), top to bottom.
    public var paths: [NamedPath]
    /// The (unsaved) work path.
    public var workPath: VectorPath?
    /// Clipping path used on export (names one of `paths`).
    public var clippingPath: ClippingPath?
    /// Select › Edit in Quick Mask Mode: the temporary "Quick Mask" channel while the mode is on.
    /// Part of the document so entering and leaving are history steps (as in Photoshop).
    public var quickMask: AlphaChannel?
    /// Quick Mask was entered with no selection, so an untouched white mask (Color Indicates Masked
    /// Areas) leaves no selection rather than Select All.
    public var quickMaskUnselected: Bool
    /// Patterns stored with the document (PSD `Patt`/`Pat2`/`Pat3`): those its layers use, plus any
    /// imported with it.
    public var patterns: [Pattern]
    /// Indexed Color palette (Image › Mode › Color Table). Set while `mode` is Indexed.
    public var colorTable: ColorTable?
    /// Duotone inks. Set while `mode` is Duotone.
    public var duotone: Duotone?
    /// Window › Layer Comps, top to bottom as listed in the panel.
    public var layerComps: [LayerComp]
    /// Id of the comp applied last (PSD `lastAppliedComp`); nil = the document's own state.
    public var lastAppliedComp: UInt32?
    /// "Last Document State": layer state saved when a comp is applied over the document's own
    /// state, restored by `layerComp.restoreLastDocumentState`. Its id is 0.
    public var lastDocumentState: LayerComp?
    /// Image › Analysis: measurement scale, Count tool groups and the Ruler line.
    public var measurement: MeasurementSettings
    /// Note tool annotations (PSD `Anno`).
    public var notes: [Note]
    /// Character and paragraph styles (Window › Character Styles / Paragraph Styles).
    public var textStyles: TextStyles
    /// Web slices (Slice tool, layer-based slices; PSD resource 1050). Auto slices are derived.
    public var slices: Slices
    /// Image › Variables and Data Sets (data-driven graphics).
    public var variables: Variables
    /// Window › Timeline (nil until a video timeline is created).
    public var timeline: Timeline?
    /// How the document's lossy file was encoded, so a save writes it back the same way.
    public var fileEncoding: FileEncoding

    /// Lazily built `LayerId → LayerPath` index (shared by copies until either changes its tree).
    var index = LayerIndex()

    public init(name: String, size: PixelSize, mode: ColorMode, depth: SampleType) {
        id = .fresh()
        self.name = name
        self.size = size
        resolutionDpi = 72
        self.mode = mode
        self.depth = depth
        iccProfile = nil
        layers = []
        channels = []
        guides = Guides()
        selection = nil
        metadata = Metadata()
        globalLight = GlobalLight()
        paths = []
        workPath = nil
        clippingPath = nil
        quickMask = nil
        quickMaskUnselected = false
        patterns = []
        colorTable = nil
        duotone = nil
        layerComps = []
        lastAppliedComp = nil
        lastDocumentState = nil
        measurement = MeasurementSettings()
        notes = []
        textStyles = TextStyles()
        slices = Slices()
        variables = Variables()
        timeline = nil
        fileEncoding = FileEncoding()
    }

    /// New document with a filled "Background" layer (like File › New). The fill puts one shared
    /// copy-on-write tile at every whole tile (`Surface.fill`), so even a 300 000² canvas costs one
    /// tile of pixels plus its edge tiles, not 360 GB (photocraft #705).
    public static func withBackground(name: String, size: PixelSize, mode: ColorMode, depth: SampleType, fill: PCColor) -> Document {
        var d = Document(name: name, size: size, mode: mode, depth: depth)
        var bg = Layer.raster("Background", format: d.pixelFormat)
        bg.locks.transparency = true
        bg.locks.position = true
        let bounds = d.bounds
        bg.withRaster { s in
            let px = s.format.components(fromRGBA: SIMD4(fill.rgb, fill.alpha))
            s.fill(bounds, with: px)
        }
        d.layers.append(bg)
        return d
    }

    /// Pixel format for new raster layers in this document (Indexed/Multichannel store RGB,
    /// Bitmap/Duotone store Gray; always with alpha).
    public var pixelFormat: PixelFormat {
        let m: ColorMode
        switch mode {
        case .indexed, .multichannel: m = .rgb
        case .bitmap, .duotone: m = .grayscale
        default: m = mode
        }
        return PixelFormat(mode: m, sample: depth, alpha: true)
    }

    /// The canvas rectangle `(0, 0)–(width, height)`.
    public var bounds: PixelRect { PixelRect(size: size) }

    // MARK: Walking and lookup

    /// Nesting depth of the deepest layer: 0 for a root-level layer, 1 inside one group, and so on.
    /// Computed over an explicit stack, so it cannot overflow on any tree it measures.
    public var maxGroupDepth: Int {
        var best = 0
        var stack: [([Layer], Int)] = [(layers, 0)]
        while let (ls, depth) = stack.popLast() {
            if ls.isEmpty { continue }
            best = max(best, depth)
            for l in ls { if let ch = l.children, !ch.isEmpty { stack.append((ch, depth + 1)) } }
        }
        return best
    }

    /// Visits every layer depth-first, bottom-to-top, with its path and depth, without copying the
    /// tree (photocraft `walk`).
    public func forEachLayer(_ body: (LayerPath, Int, Layer) throws -> Void) rethrows {
        var path: LayerPath = []
        func rec(_ ls: [Layer]) throws {
            for (i, l) in ls.enumerated() {
                path.append(i)
                try body(path, path.count - 1, l)
                if let ch = l.children { try rec(ch) }
                path.removeLast()
            }
        }
        try rec(layers)
    }

    /// Depth-first walk yielding `(path, depth, layer)` bottom-to-top.
    public func walk() -> [LayerWalkEntry] {
        var out: [LayerWalkEntry] = []
        forEachLayer { out.append(LayerWalkEntry(path: $0, depth: $1, layer: $2)) }
        return out
    }

    /// Every layer id, in walk order.
    public var allLayerIds: [LayerId] {
        var out: [LayerId] = []
        forEachLayer { _, _, l in out.append(l.id) }
        return out
    }

    public var layerCount: Int { index.map(for: layers).count }

    /// The path of layer `id` (O(1) after the first lookup on an unchanged tree).
    public func path(of id: LayerId) -> LayerPath? {
        guard let p = index.map(for: layers)[id] else { return nil }
        // The index is rebuilt whenever `layers` changes, so this always holds; checked anyway.
        if layer(at: p)?.id == id { return p }
        return LayerIndex.build(layers)[id]
    }

    public func contains(_ id: LayerId) -> Bool { path(of: id) != nil }

    /// The layer at `path`.
    public func layer(at path: LayerPath) -> Layer? {
        guard let first = path.first, first >= 0, first < layers.count else { return nil }
        var cur = layers[first]
        for i in path.dropFirst() {
            guard let ch = cur.children, i >= 0, i < ch.count else { return nil }
            cur = ch[i]
        }
        return cur
    }

    public func layer(_ id: LayerId) -> Layer? { path(of: id).flatMap { layer(at: $0) } }

    /// The locks in force on the layer at `path`: its own and those of every group around it,
    /// since locking a group locks its contents.
    public func locks(at path: LayerPath) -> Locks {
        var out = Locks()
        guard !path.isEmpty else { return out }
        for n in 1...path.count {
            if let l = layer(at: Array(path.prefix(n))) { out = out.union(l.locks) }
        }
        return out
    }

    /// `locks(at:)` for the layer `id`.
    public func effectiveLocks(_ id: LayerId) -> Locks { path(of: id).map { locks(at: $0) } ?? Locks() }

    /// The Background layer, identified structurally as Photoshop does, never by its name (a file
    /// from a German or Japanese Photoshop names it "Hintergrund" or "背景"): the bottom layer of
    /// the stack, a pixel layer that is not clipped, with transparency and position locked.
    public var background: Layer? {
        guard let first = layers.first, first.hasBackgroundTraits else { return nil }
        return first
    }

    /// Whether `id` is the document's Background layer.
    public func isBackground(_ id: LayerId) -> Bool { background?.id == id }

    /// Mutates the Background layer in place (photocraft `background_mut`); nil without one.
    @discardableResult
    public mutating func updateBackground<R>(_ body: (inout Layer) throws -> R) rethrows -> R? {
        guard background != nil else { return nil }
        return try updateLayer(at: [0], body)
    }

    /// Top-most layer id, useful as the default active layer.
    public var topLayer: LayerId? { layers.last?.id }

    // MARK: In-place mutation

    /// Mutates the layer at `path` in place. Returns nil (without calling `body`) when there is no
    /// such layer. The id index survives when the subtree's structure is unchanged.
    @discardableResult
    public mutating func updateLayer<R>(at path: LayerPath, _ body: (inout Layer) throws -> R) rethrows -> R? {
        guard layer(at: path) != nil else { return nil }
        let saved = index
        var before: [UInt64] = []
        var after: [UInt64] = []
        let result = try Document.mutate(&layers, path[...]) { (l: inout Layer) -> R in
            before = l.structure
            defer { after = l.structure }
            return try body(&l)
        }
        if before == after { index = saved }
        return result
    }

    /// Mutates layer `id` in place (photocraft `layer_mut`). Returns nil when there is no such layer.
    @discardableResult
    public mutating func updateLayer<R>(_ id: LayerId, _ body: (inout Layer) throws -> R) rethrows -> R? {
        guard let p = path(of: id) else { return nil }
        return try updateLayer(at: p, body)
    }

    /// Mutates a pixel layer's surface in place. Returns nil when `id` is missing or not a pixel
    /// layer.
    @discardableResult
    public mutating func withRaster<R>(of id: LayerId, _ body: (inout Surface) throws -> R) rethrows -> R? {
        try updateLayer(id) { try $0.withRaster(body) } ?? nil
    }

    /// Walks `path` into nested children, mutating in place.
    static func mutate<R>(_ ls: inout [Layer], _ path: ArraySlice<Int>, _ body: (inout Layer) throws -> R) rethrows -> R? {
        guard let i = path.first, i >= 0, i < ls.count else { return nil }
        if path.count == 1 { return try body(&ls[i]) }
        return try ls[i].withChildren { try mutate(&$0, path.dropFirst(), body) } ?? nil
    }

    /// Mutates the sibling list holding `path`'s last component (the root list for a root path).
    static func mutateSiblings<R>(_ ls: inout [Layer], parent: ArraySlice<Int>, _ body: (inout [Layer]) throws -> R) rethrows -> R? {
        guard let i = parent.first else { return try body(&ls) }
        guard i >= 0, i < ls.count else { return nil }
        return try ls[i].withChildren { try mutateSiblings(&$0, parent: parent.dropFirst(), body) } ?? nil
    }

    /// Mutates every layer of the tree in place, depth-first bottom-to-top (parents before their
    /// children).
    public mutating func forEachLayerMut(_ body: (inout Layer) throws -> Void) rethrows {
        func rec(_ ls: inout [Layer]) throws {
            for i in ls.indices {
                try body(&ls[i])
                try ls[i].withChildren { try rec(&$0) }
            }
        }
        try rec(&layers)
    }

    // MARK: Structure (photocraft's helpers)

    /// A `Layer.linkGroup` id no layer uses yet: one above the highest stored id, or, when a loaded
    /// file already holds `UInt64.max`, the smallest free id from 1. Never wraps, so a new link
    /// can't join an unrelated group. nil only if every id is taken.
    public func unusedLinkGroup() -> UInt64? {
        var used: [UInt64] = []
        forEachLayer { _, _, l in if let g = l.linkGroup { used.append(g) } }
        used = Array(Set(used)).sorted()
        guard let last = used.last else { return 1 }
        if last < .max { return last + 1 }
        var free: UInt64 = 1
        for g in used {
            if g > free { break }
            if g == free {
                if free == .max { return nil }
                free += 1
            }
        }
        return free
    }

    /// Insert `layer` directly above the layer `above` (or at the top of the root if nil or
    /// missing). Returns the inserted layer's id.
    @discardableResult
    public mutating func insertAbove(_ above: LayerId?, _ layer: Layer) -> LayerId {
        let id = layer.id
        if let a = above, let p = path(of: a) {
            let idx = p[p.count - 1]
            let inserted: Void? = Document.mutateSiblings(&layers, parent: p.dropLast()) { $0.insert(layer, at: idx + 1) }
            if inserted != nil { return id }
        }
        layers.append(layer)
        return id
    }

    /// Removes layer `id` (with its children) and returns it.
    @discardableResult
    public mutating func remove(_ id: LayerId) -> Layer? {
        guard let p = path(of: id) else { return nil }
        let idx = p[p.count - 1]
        return Document.mutateSiblings(&layers, parent: p.dropLast()) { $0.remove(at: idx) }
    }

    /// Move a layer up (+1) or down (−1) among its siblings. Returns false at the ends.
    @discardableResult
    public mutating func shift(_ id: LayerId, by delta: Int) -> Bool {
        guard let p = path(of: id) else { return false }
        let idx = p[p.count - 1]
        return Document.mutateSiblings(&layers, parent: p.dropLast()) { sib -> Bool in
            let to = idx + delta
            guard to >= 0, to < sib.count else { return false }
            let l = sib.remove(at: idx)
            sib.insert(l, at: to)
            return true
        } ?? false
    }

    /// Next unused "Layer N" name.
    public func nextLayerName(_ base: String) -> String {
        var names = Set<String>()
        forEachLayer { _, _, l in names.insert(l.name) }
        for n in 1...(names.count + 1) where !names.contains("\(base) \(n)") { return "\(base) \(n)" }
        return base
    }

    /// Name for a copy of a layer named `name`, unique in the document: "Layer 1 copy", then
    /// "Layer 1 copy 2", "Layer 1 copy 3"… A name that already ends in "copy" (or "copy N") is
    /// numbered from its root rather than growing another "copy".
    public func copyName(_ name: String) -> String {
        var root = name
        if let r = name.range(of: " copy", options: .backwards) {
            let rest = name[r.upperBound...]
            let digits = rest.dropFirst()
            if rest.isEmpty || (rest.first == " " && !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }) {
                root = String(name[..<r.lowerBound])
            }
        }
        var names = Set<String>()
        forEachLayer { _, _, l in names.insert(l.name) }
        let first = "\(root) copy"
        if !names.contains(first) { return first }
        for n in 2...(names.count + 2) where !names.contains("\(root) copy \(n)") { return "\(root) copy \(n)" }
        return first
    }
}

extension Layer {
    /// This layer's subtree as (id, depth) pairs in walk order: what the id index depends on (a
    /// pre-order list with depths fixes the tree's shape).
    var structure: [UInt64] {
        var out: [UInt64] = [id.rawValue, 0]
        if let ch = children {
            var stack: [(Layer, UInt64)] = ch.reversed().map { ($0, 1) }
            while let (l, d) = stack.popLast() {
                out.append(l.id.rawValue)
                out.append(d)
                if let c = l.children { stack.append(contentsOf: c.reversed().map { ($0, d + 1) }) }
            }
        }
        return out
    }

    /// Whether `other` has the same ids at the same places of its subtree (only the nodes' other
    /// data may differ).
    public func hasSameTreeShape(as other: Layer) -> Bool { structure == other.structure }
}
