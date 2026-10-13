// Layers: the node type of the document tree, its content kinds (pixel, group, adjustment, fill,
// type, shape, smart object), masks, locks and labels.
// Port of photocraft-doc (crates/doc/src/lib.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// Layer order: inside every group (and the root), `children[0]` is the bottom layer, matching
// compositing order and the PSD file order. UIs display the list reversed.
//
// Non-destructive kinds (adjustment, fill, text, shape, smart object) and colour modes beyond RGB
// are part of the model from day one, even where rendering support lands later (architecture
// §1.1). Everything is a value: copying a layer shares its pixel tiles copy-on-write.

import PCFoundation
import simd

/// Layer locks (Layers panel lock buttons). A group's locks apply to its contents
/// (`Document.effectiveLocks`).
public struct Locks: Hashable, Sendable, Codable {
    public var transparency = false
    public var pixels = false
    public var position = false
    public var artboard = false
    public var all = false

    public init(transparency: Bool = false, pixels: Bool = false, position: Bool = false, artboard: Bool = false, all: Bool = false) {
        self.transparency = transparency; self.pixels = pixels; self.position = position; self.artboard = artboard; self.all = all
    }

    public func union(_ o: Locks) -> Locks {
        Locks(transparency: transparency || o.transparency, pixels: pixels || o.pixels, position: position || o.position,
              artboard: artboard || o.artboard, all: all || o.all)
    }

    public var isEmpty: Bool { self == Locks() }
}

/// Photoshop layer colour labels. JSON: the PascalCase name (`"Red"`), stable with photocraft.
public enum LabelColor: String, CaseIterable, Hashable, Sendable, Codable {
    case none = "None"
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case blue = "Blue"
    case violet = "Violet"
    case gray = "Gray"
    case seafoam = "Seafoam"
    case indigo = "Indigo"
    case magenta = "Magenta"
    case fuchsia = "Fuchsia"

    /// Display order, independent of the PSD sheet-colour indices.
    public static let all: [LabelColor] = [.none, .red, .orange, .yellow, .green, .seafoam, .blue, .indigo, .magenta, .fuchsia, .violet, .gray]

    /// Stable, language-independent command and inspection value.
    public var id: String { self == .none ? "none" : rawValue.lowercased() }

    public var label: String { self == .none ? "No Color" : rawValue }

    public init?(id: String) {
        guard let c = LabelColor.all.first(where: { $0.id == id }) else { return nil }
        self = c
    }
}

/// A raster layer mask.
public struct LayerMask: Equatable, Sendable {
    /// Grayscale surface; untouched pixels read as its default (0 = hide, 1 = reveal).
    public var surface: Surface
    public var enabled: Bool
    public var linked: Bool
    public var density: Float
    public var feather: Float

    public init(surface: Surface, enabled: Bool = true, linked: Bool = true, density: Float = 1, feather: Float = 0) {
        self.surface = surface; self.enabled = enabled; self.linked = linked; self.density = density; self.feather = feather
    }

    public static func revealAll() -> LayerMask { LayerMask(surface: Surface(format: .gray8, defaultPixel: [1])) }
    public static func hideAll() -> LayerMask { LayerMask(surface: Surface(format: .gray8, defaultPixel: [0])) }

    /// Effective mask value at a pixel, including density.
    public func value(x: Int32, y: Int32) -> Float {
        if !enabled { return 1 }
        let v = surface.pixel(x: x, y: y).first ?? 1
        return 1 - density * (1 - v)
    }

    /// Effective mask values over `r` (row-major) into `out`, including density; all ones when
    /// disabled.
    public func values(_ r: PixelRect, into out: inout [Float]) {
        let n = r.area
        if !enabled {
            out = [Float](repeating: 1, count: n)
            return
        }
        let ch = surface.channels
        out = [Float](repeating: 0, count: n * ch)
        surface.readRegion(r, into: &out)
        if ch > 1 { out = stride(from: 0, to: out.count, by: ch).map { out[$0] } }
        if density < 1 {
            for i in out.indices { out[i] = 1 - density * (1 - out[i]) }
        }
    }
}

/// Deepest group nesting a document may hold: a layer inside this many nested groups is the
/// deepest legal one. Everything that walks the layer tree recurses once per level; PSD import and
/// the commands that nest layers enforce this up front (`Document.insert`/`move` do here).
public let maxGroupDepthLimit = 100

/// A group's content.
public struct LayerGroup: Equatable, Sendable {
    /// Bottom-to-top.
    public var children: [Layer]
    public var expanded: Bool
    /// Set when this (top-level) group is an artboard: children are clipped to its rect.
    public var artboard: Artboard?

    public init(children: [Layer] = [], expanded: Bool = true, artboard: Artboard? = nil) {
        self.children = children; self.expanded = expanded; self.artboard = artboard
    }
}

/// Where a smart object's source comes from.
public enum SmartSource: Hashable, Sendable {
    /// Embedded source file bytes (PSD, PNG, …).
    case embedded(fileName: String, bytes: [UInt8])
    /// A linked file.
    case linked(path: String)
}

/// A filter applied non-destructively: a command id plus its parameters (data, not code).
public struct SmartFilter: Hashable, Sendable, Codable {
    public var command: String
    public var params: JSONValue
    public var blend: BlendMode
    public var opacity: Float
    public var visible: Bool

    public init(command: String, params: JSONValue = .object([:]), blend: BlendMode = .normal, opacity: Float = 1, visible: Bool = true) {
        self.command = command; self.params = params; self.blend = blend; self.opacity = opacity; self.visible = visible
    }
}

/// A smart object: source contents plus placement, smart filters and the rendered appearance.
public struct SmartObject: Equatable, Sendable {
    /// Ordinary layer duplicates share this identity; independent contents receive a fresh one.
    public var contentsId: SmartContentsId
    /// Embedded source file bytes or linked path.
    public var source: SmartSource
    public var transform: PCAffine
    public var smartFilters: [SmartFilter]
    /// Rendered appearance.
    public var cache: Surface?
    /// Data of the PSD placed-layer block (`SoLd`, `PlLd` or `SoLE`). On export it replaces that
    /// entry in `Layer.psdBlocks`.
    public var psdRaw: [UInt8]?
    /// Layer › Smart Filter › Disable Smart Filters turns the whole stack off without touching each
    /// filter's own visibility.
    public var filtersEnabled: Bool
    /// The smart filter mask (one per smart object, as in Photoshop): where the filter stack's
    /// result shows over the unfiltered content.
    public var filterMask: LayerMask?
    /// Edit › Transform › Warp on the smart object, in source-image coordinates; applied before
    /// `transform` when re-rendering from the source, so warping stays lossless.
    public var warp: Warp?
    /// Layer › Smart Objects › Stack Mode: when set, the source's top-level layers are combined per
    /// pixel with this statistic instead of composited.
    public var stackMode: StackMode?
    /// Distort / Perspective (or an imported placement whose corners aren't a parallelogram): the
    /// full projective map from source pixels to document pixels, row-major 3×3 (9 values). It
    /// overrides `transform`, which then holds its affine approximation at the source origin.
    public var perspective: [Double]?

    /// A smart object with no filters and no PSD data.
    public init(source: SmartSource, transform: PCAffine, cache: Surface?) {
        contentsId = .fresh()
        self.source = source
        self.transform = transform
        smartFilters = []
        self.cache = cache
        psdRaw = nil
        filtersEnabled = true
        filterMask = nil
        warp = nil
        stackMode = nil
        perspective = nil
    }

    /// `perspective` as a simd matrix (rows of the 3×3 map), when set and well formed.
    public var perspectiveMatrix: simd_double3x3? {
        guard let p = perspective, p.count == 9 else { return nil }
        return simd_double3x3(rows: [SIMD3(p[0], p[1], p[2]), SIMD3(p[3], p[4], p[5]), SIMD3(p[6], p[7], p[8])])
    }
}

/// What a layer holds.
public enum LayerContent: Equatable, Sendable {
    case raster(Surface)
    case group(LayerGroup)
    case adjustment(Adjustment)
    case fill(Fill)
    case text(TextLayer)
    case shape(ShapeLayer)
    case smart(SmartObject)

    public var kindName: String {
        switch self {
        case .raster: "Pixel"
        case .group: "Group"
        case .adjustment: "Adjustment"
        case .fill: "Fill"
        case .text: "Type"
        case .shape: "Shape"
        case .smart: "Smart Object"
        }
    }

    /// English indefinite article for this layer kind ("an" for Adjustment, "a" for all others).
    public var article: String {
        if case .adjustment = self { return "an" }
        return "a"
    }

    /// A content value that holds no buffers, swapped in while a payload is mutated in place so
    /// the payload stays uniquely referenced (no copy-on-write copies of its tiles or children).
    static let placeholder = LayerContent.adjustment(.invert)
}

/// A preserved PSD additional-layer-info block: (key, data).
public struct PSDLayerBlock: Hashable, Sendable {
    public var key: PSDKey
    public var data: [UInt8]
    public init(key: PSDKey, data: [UInt8]) { self.key = key; self.data = data }
}

/// One node of the layer tree.
public struct Layer: Equatable, Sendable, Identifiable {
    public var id: LayerId
    public var name: String
    public var visible: Bool
    public var locks: Locks
    public var blend: BlendMode
    /// Layer opacity (applies to content and effects).
    public var opacity: Float
    /// Fill opacity (applies to content but not effects).
    public var fillOpacity: Float
    /// Clipped to the layer below (clipping mask).
    public var clipped: Bool
    public var mask: LayerMask?
    /// Vector mask (Layer › Vector Mask), applied together with `mask`. Shape layers keep their
    /// outline in `ShapeLayer.path` instead.
    public var vectorMask: VectorMask?
    public var effects: Effects
    public var label: LabelColor
    public var content: LayerContent
    /// Preserved PSD additional-layer-info blocks for lossless round-trip of anything not modelled
    /// above: vector masks, blending options, layer version, and the original adjustment/fill
    /// blocks (the PSD writer reuses an adjustment or fill block verbatim while it still decodes to
    /// the layer's current parameters, so Levels/Curves/Hue-Sat extras survive). Keys regenerated
    /// from the fields above (`luni`, `lyid`, `lsct`, `lsdk`, `iOpa`, `lspf`, `lclr`, `lfx2`) are
    /// not stored.
    public var psdBlocks: [PSDLayerBlock]
    /// PSD layer id (`lyid`), kept so ids stay stable across round trips. Cleared by `duplicate`.
    public var psdId: UInt32?
    /// Photoshop-rendered pixels for fill layers (see `FillCache`).
    public var fillCache: FillCache?
    /// Layer › Link Layers: layers sharing a link group move together. nil = not linked.
    public var linkGroup: UInt64?
    /// Blending Options › Advanced Blending › Channels: bit `i` set = colour channel `i` of the
    /// document's mode (R, G, B / C, M, Y, K / L, a, b / Gray) is left out of blending, so the
    /// backdrop's value is kept there. 0 = every channel blends (the default). PSD `brst`.
    public var excludedChannels: UInt32
    /// Blending Options › Blend If: value ranges of this layer and of the layers beneath it outside
    /// which the layer's pixels are hidden. Default = everything blends.
    public var blendIf: BlendIf
    /// Blending Options › Advanced Blending: knockout, blend interior effects / clipped layers as
    /// group, transparency shapes layer, layer / vector mask hides effects.
    public var advanced: AdvancedBlending
    /// Layer › Video Layers frame stack (nil for a normal layer).
    public var video: VideoData?

    public init(name: String, content: LayerContent) {
        id = .fresh()
        self.name = name
        visible = true
        locks = Locks()
        blend = .normal
        opacity = 1
        fillOpacity = 1
        clipped = false
        mask = nil
        vectorMask = nil
        effects = Effects(enabled: true)
        label = .none
        self.content = content
        psdBlocks = []
        psdId = nil
        fillCache = nil
        linkGroup = nil
        excludedChannels = 0
        blendIf = BlendIf()
        advanced = AdvancedBlending()
        video = nil
    }

    /// An empty pixel layer.
    public static func raster(_ name: String, format: PixelFormat) -> Layer { Layer(name: name, content: .raster(Surface(format: format))) }

    /// A pixel layer holding `surface`.
    public static func raster(_ name: String, surface: Surface) -> Layer { Layer(name: name, content: .raster(surface)) }

    /// A group (Pass Through, expanded) holding `children` bottom-to-top.
    public static func group(_ name: String, _ children: [Layer]) -> Layer {
        var l = Layer(name: name, content: .group(LayerGroup(children: children)))
        l.blend = .passThrough
        return l
    }

    /// Whether the layer has the Background's own properties: an unclipped pixel layer with
    /// transparency and position locked. Only the bottom layer of a document with them is the
    /// Background: use `Document.background` / `Document.isBackground` to identify it.
    public var hasBackgroundTraits: Bool {
        guard case .raster = content else { return false }
        return locks.transparency && locks.position && !clipped
    }

    public var isGroup: Bool {
        if case .group = content { return true }
        return false
    }

    /// The group content, when this is a group.
    public var group: LayerGroup? {
        if case .group(let g) = content { return g }
        return nil
    }

    /// The children (bottom-to-top) of a group; nil for other kinds.
    public var children: [Layer]? { group?.children }

    /// Mutates a group's children in place (they stay uniquely referenced, so nothing is copied).
    /// Returns nil, without calling `body`, for non-groups.
    @discardableResult
    public mutating func withChildren<R>(_ body: (inout [Layer]) throws -> R) rethrows -> R? {
        guard case .group(var g) = content else { return nil }
        content = LayerContent.placeholder
        defer { content = .group(g) }
        return try body(&g.children)
    }

    /// Mutates a group's content in place. Returns nil for non-groups.
    @discardableResult
    public mutating func withGroup<R>(_ body: (inout LayerGroup) throws -> R) rethrows -> R? {
        guard case .group(var g) = content else { return nil }
        content = LayerContent.placeholder
        defer { content = .group(g) }
        return try body(&g)
    }

    /// The pixels shown for this layer: a pixel layer's surface, or the rendered cache of a type,
    /// shape or smart object layer (photocraft `surface()`).
    public var surface: Surface? {
        switch content {
        case .raster(let s): s
        case .text(let t): t.cache
        case .shape(let s): s.cache
        case .smart(let s): s.cache
        default: nil
        }
    }

    /// A pixel layer's surface (nil for other kinds).
    public var rasterSurface: Surface? {
        if case .raster(let s) = content { return s }
        return nil
    }

    /// Mutates a pixel layer's surface in place (photocraft `surface_mut()`): only the tiles
    /// touched are copied, and only if a snapshot shares them. Returns nil for other kinds.
    @discardableResult
    public mutating func withRaster<R>(_ body: (inout Surface) throws -> R) rethrows -> R? {
        guard case .raster(var s) = content else { return nil }
        content = LayerContent.placeholder
        defer { content = .raster(s) }
        return try body(&s)
    }

    /// Mutates a type layer's content in place (its cache stays uniquely referenced). nil for other
    /// kinds.
    @discardableResult
    public mutating func withText<R>(_ body: (inout TextLayer) throws -> R) rethrows -> R? {
        guard case .text(var t) = content else { return nil }
        content = LayerContent.placeholder
        defer { content = .text(t) }
        return try body(&t)
    }

    /// Mutates a shape layer's content in place. nil for other kinds.
    @discardableResult
    public mutating func withShape<R>(_ body: (inout ShapeLayer) throws -> R) rethrows -> R? {
        guard case .shape(var s) = content else { return nil }
        content = LayerContent.placeholder
        defer { content = .shape(s) }
        return try body(&s)
    }

    /// Mutates a smart object in place. nil for other kinds.
    @discardableResult
    public mutating func withSmartObject<R>(_ body: (inout SmartObject) throws -> R) rethrows -> R? {
        guard case .smart(var s) = content else { return nil }
        content = LayerContent.placeholder
        defer { content = .smart(s) }
        return try body(&s)
    }

    /// The adjustment of an adjustment layer.
    public var adjustment: Adjustment? {
        if case .adjustment(let a) = content { return a }
        return nil
    }

    /// The fill of a fill layer.
    public var fill: Fill? {
        if case .fill(let f) = content { return f }
        return nil
    }

    /// The artboard of an artboard group.
    public var artboard: Artboard? {
        get { group?.artboard }
        set { withGroup { $0.artboard = newValue } }
    }

    /// Deep copy with fresh ids (for Duplicate Layer); PSD layer ids are cleared.
    public func duplicate() -> Layer {
        var l = self
        l.reassignIds()
        return l
    }

    mutating func reassignIds() {
        id = .fresh()
        psdId = nil
        withChildren { ch in for i in ch.indices { ch[i].reassignIds() } }
    }
}
