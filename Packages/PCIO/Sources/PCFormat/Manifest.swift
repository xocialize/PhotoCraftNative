// `manifest.json` schema. A separate model from PCDocument on purpose: the on-disk schema is
// versioned and migrated independently of in-memory refactors.
//
// Binary payloads never live in JSON. Surfaces reference tiles (`tiles/<blake3>.zst`) and other
// binary data references blobs (`blobs/<blake3>.zst`), both by the BLAKE3 hash of their
// uncompressed bytes (little-endian samples for tiles).
//
// Field names and shapes are serde's, so a manifest photocraft writes decodes here and ours decode
// there: snake_case keys, `null` for absent options (missing ones decode as absent too), tuples as
// JSON arrays, internally tagged `content`/`source` (`"kind": "raster"`), and the same defaults and
// omissions (`skip_serializing_if`).
// Port of photocraft-format (crates/format/src/manifest.rs), MIT OR Apache-2.0, © ArtCraft Team
// and the PhotoCraft contributors.

import PCDocument
import PCFoundation

/// Current manifest version written by this build.
public let pcraftFormatVersion: UInt32 = 1

/// Hex-encoded BLAKE3 hash (64 chars).
public typealias Hash = String

/// A coding key from any string.
struct ManifestKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == ManifestKey {
    /// A required field.
    func req<T: Decodable>(_ key: String, _ type: T.Type = T.self) throws -> T { try decode(T.self, forKey: ManifestKey(key)) }
    /// An `Option` field (missing or null = nil).
    func opt<T: Decodable>(_ key: String, _ type: T.Type = T.self) throws -> T? { try decodeIfPresent(T.self, forKey: ManifestKey(key)) }
    /// A `#[serde(default)]` field.
    func def<T: Decodable>(_ key: String, _ fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: ManifestKey(key)) ?? fallback()
    }
}

extension KeyedEncodingContainer where Key == ManifestKey {
    mutating func put<T: Encodable>(_ key: String, _ value: T) throws { try encode(value, forKey: ManifestKey(key)) }
    /// An `Option` field, written as `null` when absent (as serde does).
    mutating func putOpt<T: Encodable>(_ key: String, _ value: T?) throws {
        if let value { try encode(value, forKey: ManifestKey(key)) } else { try encodeNil(forKey: ManifestKey(key)) }
    }
}

/// A two-element JSON array (a Rust 2-tuple).
public struct ManifestPair<A: Codable & Hashable & Sendable, B: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var a: A
    public var b: B
    public init(_ a: A, _ b: B) { self.a = a; self.b = b }
    public init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        a = try c.decode(A.self)
        b = try c.decode(B.self)
        guard c.isAtEnd else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "expected a 2-element array") }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(a)
        try c.encode(b)
    }
}

/// A three-element JSON array (a Rust 3-tuple).
public struct ManifestTriple<A: Codable & Hashable & Sendable, B: Codable & Hashable & Sendable, C: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var a: A
    public var b: B
    public var c: C
    public init(_ a: A, _ b: B, _ c: C) { self.a = a; self.b = b; self.c = c }
    public init(from decoder: any Decoder) throws {
        var u = try decoder.unkeyedContainer()
        a = try u.decode(A.self)
        b = try u.decode(B.self)
        c = try u.decode(C.self)
        guard u.isAtEnd else { throw DecodingError.dataCorruptedError(in: u, debugDescription: "expected a 3-element array") }
    }
    public func encode(to encoder: any Encoder) throws {
        var u = encoder.unkeyedContainer()
        try u.encode(a)
        try u.encode(b)
        try u.encode(c)
    }
}

public struct Manifest: Codable, Hashable, Sendable {
    public var formatVersion: UInt32
    /// Free-form writer identification, e.g. `photocraft-format 0.1.0`.
    public var generator: String
    public var document: DocM
    /// Optional previews present in the bundle.
    public var thumbnail: String?
    public var composite: String?

    public init(formatVersion: UInt32, generator: String, document: DocM, thumbnail: String? = nil, composite: String? = nil) {
        self.formatVersion = formatVersion; self.generator = generator; self.document = document
        self.thumbnail = thumbnail; self.composite = composite
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: ManifestKey.self)
        formatVersion = try c.req("format_version")
        generator = try c.req("generator")
        document = try c.req("document")
        thumbnail = try c.opt("thumbnail")
        composite = try c.opt("composite")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: ManifestKey.self)
        try c.put("format_version", formatVersion)
        try c.put("generator", generator)
        try c.put("document", document)
        try c.putOpt("thumbnail", thumbnail)
        try c.putOpt("composite", composite)
    }
}

public struct DocM: Codable, Hashable, Sendable {
    public var id: UInt64
    public var name: String
    public var size: PixelSize
    public var resolutionDpi: Float
    public var mode: ColorMode
    public var depth: SampleType
    public var iccProfile: Hash?
    /// Bottom-to-top.
    public var layers: [LayerM]
    public var channels: [ChannelM]
    public var guides: Guides
    public var selection: SurfaceM?
    public var metadata: MetadataM
    public var globalLight: GlobalLight
    /// Saved paths (Paths panel).
    public var paths: [NamedPathM] = []
    public var workPath: VectorPath?
    public var clippingPath: ClippingPath?
    /// The temporary Quick Mask channel (saved while Quick Mask mode is on).
    public var quickMask: ChannelM?
    /// Quick Mask was entered with no selection.
    public var quickMaskUnselected = false
    /// Patterns stored with the document.
    public var patterns: [PatternM] = []
    /// Indexed Color palette.
    public var colorTable: ColorTable?
    /// Duotone inks.
    public var duotone: Duotone?
    /// Window › Layer Comps.
    public var layerComps: [LayerCompM] = []
    public var lastAppliedComp: UInt32?
    public var lastDocumentState: LayerCompM?
    /// Image › Variables and Data Sets.
    public var variables = Variables()
    /// Window › Timeline.
    public var timeline: Timeline?
    /// The JPEG quality / WebP encoding File › Save reuses.
    public var fileEncoding = FileEncoding()
    /// Image › Analysis: measurement scale, count groups, ruler.
    public var measurement = MeasurementSettings()
    /// Note tool annotations.
    public var notes: [Note] = []
    /// Character and paragraph styles.
    public var textStyles = TextStyles()
    /// Web slices (user and layer-based; layer ids are remapped on load).
    public var slices = Slices()

    public init(id: UInt64, name: String, size: PixelSize, resolutionDpi: Float, mode: ColorMode, depth: SampleType, iccProfile: Hash?,
                layers: [LayerM], channels: [ChannelM], guides: Guides, selection: SurfaceM?, metadata: MetadataM, globalLight: GlobalLight) {
        self.id = id; self.name = name; self.size = size; self.resolutionDpi = resolutionDpi; self.mode = mode; self.depth = depth
        self.iccProfile = iccProfile; self.layers = layers; self.channels = channels; self.guides = guides; self.selection = selection
        self.metadata = metadata; self.globalLight = globalLight
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: ManifestKey.self)
        id = try c.req("id")
        name = try c.req("name")
        // photocraft's `Size` holds two u32.
        let s = try c.req("size", SizeM.self)
        size = PixelSize(width: Int(s.width), height: Int(s.height))
        resolutionDpi = try c.req("resolution_dpi")
        mode = try c.req("mode")
        depth = try c.req("depth")
        iccProfile = try c.opt("icc_profile")
        layers = try c.req("layers")
        channels = try c.req("channels")
        guides = try c.req("guides")
        selection = try c.opt("selection")
        metadata = try c.req("metadata")
        globalLight = try c.req("global_light")
        paths = try c.def("paths", [])
        workPath = try c.opt("work_path")
        clippingPath = try c.opt("clipping_path")
        quickMask = try c.opt("quick_mask")
        quickMaskUnselected = try c.def("quick_mask_unselected", false)
        patterns = try c.def("patterns", [])
        colorTable = try c.opt("color_table")
        duotone = try c.opt("duotone")
        layerComps = try c.def("layer_comps", [])
        lastAppliedComp = try c.opt("last_applied_comp")
        lastDocumentState = try c.opt("last_document_state")
        variables = try c.def("variables", Variables())
        timeline = try c.opt("timeline")
        fileEncoding = try c.def("file_encoding", FileEncoding())
        measurement = try c.def("measurement", MeasurementSettings())
        notes = try c.def("notes", [])
        textStyles = try c.def("text_styles", TextStyles())
        slices = try c.def("slices", Slices())
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: ManifestKey.self)
        try c.put("id", id)
        try c.put("name", name)
        try c.put("size", SizeM(width: UInt32(clamping: size.width), height: UInt32(clamping: size.height)))
        try c.put("resolution_dpi", resolutionDpi)
        try c.put("mode", mode)
        try c.put("depth", depth)
        try c.putOpt("icc_profile", iccProfile)
        try c.put("layers", layers)
        try c.put("channels", channels)
        try c.put("guides", guides)
        try c.putOpt("selection", selection)
        try c.put("metadata", metadata)
        try c.put("global_light", globalLight)
        try c.put("paths", paths)
        try c.putOpt("work_path", workPath)
        try c.putOpt("clipping_path", clippingPath)
        try c.putOpt("quick_mask", quickMask)
        if quickMaskUnselected { try c.put("quick_mask_unselected", true) }
        try c.put("patterns", patterns)
        try c.putOpt("color_table", colorTable)
        try c.putOpt("duotone", duotone)
        try c.put("layer_comps", layerComps)
        try c.putOpt("last_applied_comp", lastAppliedComp)
        try c.putOpt("last_document_state", lastDocumentState)
        try c.put("variables", variables)
        try c.putOpt("timeline", timeline)
        if !fileEncoding.isEmpty { try c.put("file_encoding", fileEncoding) }
        try c.put("measurement", measurement)
        try c.put("notes", notes)
        try c.put("text_styles", textStyles)
        // The group name (the slices' export base name) is kept even without slices; photocraft
        // skips an empty list and loses it (its reader accepts either).
        if !slices.isEmpty || !slices.groupName.isEmpty { try c.put("slices", slices) }
    }
}

/// photocraft-geom `Size` (two u32).
struct SizeM: Codable {
    var width: UInt32
    var height: UInt32
}

public struct LayerCompM: Codable, Hashable, Sendable {
    public var id: UInt32
    public var name: String
    public var comment = ""
    public var applyVisibility: Bool
    public var applyPosition: Bool
    public var applyAppearance: Bool
    public var states: [CompStateM] = []

    public init(id: UInt32, name: String, comment: String, applyVisibility: Bool, applyPosition: Bool, applyAppearance: Bool, states: [CompStateM]) {
        self.id = id; self.name = name; self.comment = comment; self.applyVisibility = applyVisibility
        self.applyPosition = applyPosition; self.applyAppearance = applyAppearance; self.states = states
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: ManifestKey.self)
        id = try c.req("id")
        name = try c.req("name")
        comment = try c.def("comment", "")
        applyVisibility = try c.req("apply_visibility")
        applyPosition = try c.req("apply_position")
        applyAppearance = try c.req("apply_appearance")
        states = try c.def("states", [])
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: ManifestKey.self)
        try c.put("id", id)
        try c.put("name", name)
        try c.put("comment", comment)
        try c.put("apply_visibility", applyVisibility)
        try c.put("apply_position", applyPosition)
        try c.put("apply_appearance", applyAppearance)
        try c.put("states", states)
    }
}

public struct CompStateM: Codable, Hashable, Sendable {
    /// Layer id (as in `LayerM.id`).
    public var layer: UInt64
    public var visible: Bool?
    public var position: SIMD2<Int32>?
    public var appearance: CompAppearanceM?

    public init(layer: UInt64, visible: Bool?, position: SIMD2<Int32>?, appearance: CompAppearanceM?) {
        self.layer = layer; self.visible = visible; self.position = position; self.appearance = appearance
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: ManifestKey.self)
        layer = try c.req("layer")
        visible = try c.opt("visible")
        position = try c.opt("position", ManifestPair<Int32, Int32>.self).map { SIMD2($0.a, $0.b) }
        appearance = try c.opt("appearance")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: ManifestKey.self)
        try c.put("layer", layer)
        try c.putOpt("visible", visible)
        try c.putOpt("position", position.map { ManifestPair($0.x, $0.y) })
        try c.putOpt("appearance", appearance)
    }
}

public struct CompAppearanceM: Codable, Hashable, Sendable {
    public var blend: BlendMode
    public var opacity: Float
    public var fillOpacity: Float
    public var effects: EffectsM

    public init(blend: BlendMode, opacity: Float, fillOpacity: Float, effects: EffectsM) {
        self.blend = blend; self.opacity = opacity; self.fillOpacity = fillOpacity; self.effects = effects
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: ManifestKey.self)
        blend = try c.req("blend")
        opacity = try c.req("opacity")
        fillOpacity = try c.req("fill_opacity")
        effects = try c.req("effects")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: ManifestKey.self)
        try c.put("blend", blend)
        try c.put("opacity", opacity)
        try c.put("fill_opacity", fillOpacity)
        try c.put("effects", effects)
    }
}

public struct PatternM: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var width: UInt32
    public var height: UInt32
    public var surface: SurfaceM

    public init(id: String, name: String, width: UInt32, height: UInt32, surface: SurfaceM) {
        self.id = id; self.name = name; self.width = width; self.height = height; self.surface = surface
    }
}

public struct NamedPathM: Codable, Hashable, Sendable {
    public var name: String
    public var path: VectorPath
    public var psdRaw: Hash?

    public init(name: String, path: VectorPath, psdRaw: Hash?) { self.name = name; self.path = path; self.psdRaw = psdRaw }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: ManifestKey.self)
        name = try c.req("name")
        path = try c.req("path")
        psdRaw = try c.opt("psd_raw")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: ManifestKey.self)
        try c.put("name", name)
        try c.put("path", path)
        try c.putOpt("psd_raw", psdRaw)
    }
}

public struct TileRef: Codable, Hashable, Sendable {
    public var tx: Int32
    public var ty: Int32
    public var hash: Hash

    public init(tx: Int32, ty: Int32, hash: Hash) { self.tx = tx; self.ty = ty; self.hash = hash }
}

public struct SurfaceM: Codable, Hashable, Sendable {
    public var format: PixelFormat
    /// Default ("untouched") pixel as hex of its little-endian encoded bytes.
    public var `default`: String
    /// 256×256 tiles, interleaved little-endian samples.
    public var tiles: [TileRef]

    public init(format: PixelFormat, default d: String, tiles: [TileRef]) { self.format = format; self.default = d; self.tiles = tiles }
}

public struct VideoDataM: Codable, Hashable, Sendable {
    public var frames: [SurfaceM]
    /// Optional for backward compatibility with documents saved before original frames were kept.
    public var originalFrames: [SurfaceM]?
    public var source: VideoSource
    public var fps: Float
    public var showAltered = false

    public init(frames: [SurfaceM], originalFrames: [SurfaceM]?, source: VideoSource, fps: Float, showAltered: Bool) {
        self.frames = frames; self.originalFrames = originalFrames; self.source = source; self.fps = fps; self.showAltered = showAltered
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: ManifestKey.self)
        frames = try c.req("frames")
        originalFrames = try c.opt("original_frames")
        source = try c.req("source")
        fps = try c.req("fps")
        showAltered = try c.def("show_altered", false)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: ManifestKey.self)
        try c.put("frames", frames)
        if let originalFrames { try c.put("original_frames", originalFrames) }
        try c.put("source", source)
        try c.put("fps", fps)
        try c.put("show_altered", showAltered)
    }
}

public struct MaskM: Codable, Hashable, Sendable {
    public var surface: SurfaceM
    public var enabled: Bool
    public var linked: Bool
    public var density: Float
    public var feather: Float

    public init(surface: SurfaceM, enabled: Bool, linked: Bool, density: Float, feather: Float) {
        self.surface = surface; self.enabled = enabled; self.linked = linked; self.density = density; self.feather = feather
    }
}

public struct EffectsM: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var items: [Effect]
    public var psdRaw: Hash?
    public var reference: SIMD2<Double>?

    public init(enabled: Bool, items: [Effect], psdRaw: Hash?, reference: SIMD2<Double>?) {
        self.enabled = enabled; self.items = items; self.psdRaw = psdRaw; self.reference = reference
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: ManifestKey.self)
        enabled = try c.req("enabled")
        items = try c.req("items")
        psdRaw = try c.opt("psd_raw")
        reference = try c.opt("reference", ManifestPair<Double, Double>.self).map { SIMD2($0.a, $0.b) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: ManifestKey.self)
        try c.put("enabled", enabled)
        try c.put("items", items)
        try c.putOpt("psd_raw", psdRaw)
        try c.putOpt("reference", reference.map { ManifestPair($0.x, $0.y) })
    }
}

public struct FillCacheM: Codable, Hashable, Sendable {
    public var fill: Fill
    public var surface: SurfaceM

    public init(fill: Fill, surface: SurfaceM) { self.fill = fill; self.surface = surface }
}

public struct LayerM: Codable, Hashable, Sendable {
    public var id: UInt64
    public var name: String
    public var visible: Bool
    public var locks: Locks
    public var blend: BlendMode
    public var opacity: Float
    public var fillOpacity: Float
    public var clipped: Bool
    public var mask: MaskM?
    public var vectorMask: VectorMask?
    public var effects: EffectsM
    public var label: LabelColor
    public var content: ContentM
    /// (4-char key as hex, blob)
    public var psdBlocks: [ManifestPair<String, Hash>]
    public var psdId: UInt32?
    public var fillCache: FillCacheM?
    /// Link Layers group (nil = not linked).
    public var linkGroup: UInt64?
    /// Advanced Blending channels left out (bit per colour channel; 0 = all blend).
    public var excludedChannels: UInt32 = 0
    /// Blend If ranges (default = everything blends).
    public var blendIf = BlendIf()
    /// Advanced Blending switches; omitted at Photoshop's defaults.
    public var advanced = AdvancedBlending()
    public var video: VideoDataM?

    public init(id: UInt64, name: String, visible: Bool, locks: Locks, blend: BlendMode, opacity: Float, fillOpacity: Float, clipped: Bool,
                mask: MaskM?, vectorMask: VectorMask?, effects: EffectsM, label: LabelColor, content: ContentM, psdBlocks: [ManifestPair<String, Hash>],
                psdId: UInt32?, fillCache: FillCacheM?, linkGroup: UInt64?, excludedChannels: UInt32, blendIf: BlendIf, advanced: AdvancedBlending,
                video: VideoDataM?) {
        self.id = id; self.name = name; self.visible = visible; self.locks = locks; self.blend = blend; self.opacity = opacity
        self.fillOpacity = fillOpacity; self.clipped = clipped; self.mask = mask; self.vectorMask = vectorMask; self.effects = effects
        self.label = label; self.content = content; self.psdBlocks = psdBlocks; self.psdId = psdId; self.fillCache = fillCache
        self.linkGroup = linkGroup; self.excludedChannels = excludedChannels; self.blendIf = blendIf; self.advanced = advanced; self.video = video
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: ManifestKey.self)
        id = try c.req("id")
        name = try c.req("name")
        visible = try c.req("visible")
        locks = try c.req("locks")
        blend = try c.req("blend")
        opacity = try c.req("opacity")
        fillOpacity = try c.req("fill_opacity")
        clipped = try c.req("clipped")
        mask = try c.opt("mask")
        vectorMask = try c.opt("vector_mask")
        effects = try c.req("effects")
        label = try c.req("label")
        content = try c.req("content")
        psdBlocks = try c.req("psd_blocks")
        psdId = try c.opt("psd_id")
        fillCache = try c.opt("fill_cache")
        linkGroup = try c.opt("link_group")
        excludedChannels = try c.def("excluded_channels", 0)
        blendIf = try c.def("blend_if", BlendIf())
        advanced = try c.def("advanced", AdvancedBlending())
        video = try c.opt("video")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: ManifestKey.self)
        try c.put("id", id)
        try c.put("name", name)
        try c.put("visible", visible)
        try c.put("locks", locks)
        try c.put("blend", blend)
        try c.put("opacity", opacity)
        try c.put("fill_opacity", fillOpacity)
        try c.put("clipped", clipped)
        try c.putOpt("mask", mask)
        try c.putOpt("vector_mask", vectorMask)
        try c.put("effects", effects)
        try c.put("label", label)
        try c.put("content", content)
        try c.put("psd_blocks", psdBlocks)
        try c.putOpt("psd_id", psdId)
        try c.putOpt("fill_cache", fillCache)
        try c.putOpt("link_group", linkGroup)
        if excludedChannels != 0 { try c.put("excluded_channels", excludedChannels) }
        if !blendIf.isDefault { try c.put("blend_if", blendIf) }
        if !advanced.isDefault { try c.put("advanced", advanced) }
        try c.putOpt("video", video)
    }
}

/// A layer's content, internally tagged by `kind` (snake_case variant names). Indirect, and coded
/// through one small function per variant, so the stack used per group nesting level stays small
/// (a bundle may nest groups 100 deep).
public indirect enum ContentM: Codable, Hashable, Sendable {
    case raster(surface: SurfaceM)
    case group(GroupM)
    case adjustment(Adjustment)
    case fill(Fill)
    case text(TextM)
    case shape(ShapeM)
    case smart(SmartM)

    public struct GroupM: Hashable, Sendable {
        public var children: [LayerM]
        public var expanded: Bool
        /// Artboard (Layer › New › Artboard).
        public var artboard: Artboard?
        public init(children: [LayerM], expanded: Bool, artboard: Artboard?) { self.children = children; self.expanded = expanded; self.artboard = artboard }
    }

    public struct TextM: Hashable, Sendable {
        public var text: String
        public var fontFamily: String
        public var sizePt: Float
        public var color: PCColor
        public var transform: PCAffine
        public var cache: SurfaceM?
        public var psdRaw: Hash?
        public var runs: [TextRun] = []
        public var paragraphs: [ParagraphRun] = []
        public var shape: TextShape = .point
        public var orientation: TextOrientation = .horizontal
        public var antialias: AntiAlias = .smooth
        public var warp: TextWarp?

        public init(text: String, fontFamily: String, sizePt: Float, color: PCColor, transform: PCAffine, cache: SurfaceM?, psdRaw: Hash?) {
            self.text = text; self.fontFamily = fontFamily; self.sizePt = sizePt; self.color = color; self.transform = transform
            self.cache = cache; self.psdRaw = psdRaw
        }
    }

    public struct ShapeM: Hashable, Sendable {
        public var fill: Fill?
        public var cache: SurfaceM?
        public var psdRaw: Hash?
        public var path = VectorPath()
        public var stroke: ShapeStroke?
        public var live: LiveShape?

        public init(fill: Fill?, cache: SurfaceM?, psdRaw: Hash?, path: VectorPath, stroke: ShapeStroke?, live: LiveShape?) {
            self.fill = fill; self.cache = cache; self.psdRaw = psdRaw; self.path = path; self.stroke = stroke; self.live = live
        }
    }

    public struct SmartM: Hashable, Sendable {
        /// Shared source identity; older bundles did not record it.
        public var contentsId: UInt64?
        public var source: SmartSourceM
        public var transform: PCAffine
        public var smartFilters: [SmartFilter]
        public var cache: SurfaceM?
        public var psdRaw: Hash?
        public var filtersEnabled = true
        public var filterMask: MaskM?
        public var warp: Warp?
        public var stackMode: StackMode?
        /// Distort / Perspective placement (row-major 3×3); absent for affine placements.
        public var perspective: [Double]?

        public init(contentsId: UInt64?, source: SmartSourceM, transform: PCAffine, smartFilters: [SmartFilter], cache: SurfaceM?, psdRaw: Hash?) {
            self.contentsId = contentsId; self.source = source; self.transform = transform; self.smartFilters = smartFilters
            self.cache = cache; self.psdRaw = psdRaw
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: ManifestKey.self)
        let kind = try c.req("kind", String.self)
        switch kind {
        case "raster": self = .raster(surface: try c.req("surface"))
        case "group": self = .group(try ContentM.decodeGroup(c))
        case "adjustment": self = .adjustment(try c.req("adjustment"))
        case "fill": self = .fill(try c.req("fill"))
        case "text": self = .text(try ContentM.decodeText(c))
        case "shape": self = .shape(try ContentM.decodeShape(c))
        case "smart": self = .smart(try ContentM.decodeSmart(c))
        default:
            throw DecodingError.dataCorruptedError(forKey: ManifestKey("kind"), in: c, debugDescription: "unknown variant `\(kind)`")
        }
    }

    @inline(never)
    static func decodeGroup(_ c: KeyedDecodingContainer<ManifestKey>) throws -> GroupM {
        GroupM(children: try c.req("children"), expanded: try c.req("expanded"), artboard: try c.opt("artboard"))
    }

    @inline(never)
    static func decodeText(_ c: KeyedDecodingContainer<ManifestKey>) throws -> TextM {
        var t = TextM(text: try c.req("text"), fontFamily: try c.req("font_family"), sizePt: try c.req("size_pt"), color: try c.req("color"),
                      transform: try c.req("transform"), cache: try c.opt("cache"), psdRaw: try c.opt("psd_raw"))
        t.runs = try c.def("runs", [])
        t.paragraphs = try c.def("paragraphs", [])
        t.shape = try c.def("shape", .point)
        t.orientation = try c.def("orientation", .horizontal)
        t.antialias = try c.def("antialias", .smooth)
        t.warp = try c.opt("warp")
        return t
    }

    @inline(never)
    static func decodeShape(_ c: KeyedDecodingContainer<ManifestKey>) throws -> ShapeM {
        ShapeM(fill: try c.opt("fill"), cache: try c.opt("cache"), psdRaw: try c.opt("psd_raw"), path: try c.def("path", VectorPath()),
               stroke: try c.opt("stroke"), live: try c.opt("live"))
    }

    @inline(never)
    static func decodeSmart(_ c: KeyedDecodingContainer<ManifestKey>) throws -> SmartM {
        var s = SmartM(contentsId: try c.opt("contents_id"), source: try c.req("source"), transform: try c.req("transform"),
                       smartFilters: try c.req("smart_filters"), cache: try c.opt("cache"), psdRaw: try c.opt("psd_raw"))
        s.filtersEnabled = try c.def("filters_enabled", true)
        s.filterMask = try c.opt("filter_mask")
        s.warp = try c.opt("warp")
        s.stackMode = try c.opt("stack_mode")
        if let p = try c.opt("perspective", [Double].self) {
            guard p.count == 9 else {
                throw DecodingError.dataCorruptedError(forKey: ManifestKey("perspective"), in: c, debugDescription: "expected 9 values, got \(p.count)")
            }
            s.perspective = p
        }
        return s
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: ManifestKey.self)
        switch self {
        case .raster(let surface):
            try c.put("kind", "raster")
            try c.put("surface", surface)
        case .group(let g): try ContentM.encodeGroup(g, &c)
        case .adjustment(let a):
            try c.put("kind", "adjustment")
            try c.put("adjustment", a)
        case .fill(let f):
            try c.put("kind", "fill")
            try c.put("fill", f)
        case .text(let t): try ContentM.encodeText(t, &c)
        case .shape(let s): try ContentM.encodeShape(s, &c)
        case .smart(let s): try ContentM.encodeSmart(s, &c)
        }
    }

    @inline(never)
    static func encodeGroup(_ g: GroupM, _ c: inout KeyedEncodingContainer<ManifestKey>) throws {
        try c.put("kind", "group")
        try c.put("children", g.children)
        try c.put("expanded", g.expanded)
        try c.putOpt("artboard", g.artboard)
    }

    @inline(never)
    static func encodeText(_ t: TextM, _ c: inout KeyedEncodingContainer<ManifestKey>) throws {
        try c.put("kind", "text")
        try c.put("text", t.text)
        try c.put("font_family", t.fontFamily)
        try c.put("size_pt", t.sizePt)
        try c.put("color", t.color)
        try c.put("transform", t.transform)
        try c.putOpt("cache", t.cache)
        try c.putOpt("psd_raw", t.psdRaw)
        try c.put("runs", t.runs)
        try c.put("paragraphs", t.paragraphs)
        try c.put("shape", t.shape)
        try c.put("orientation", t.orientation)
        try c.put("antialias", t.antialias)
        try c.putOpt("warp", t.warp)
    }

    @inline(never)
    static func encodeShape(_ s: ShapeM, _ c: inout KeyedEncodingContainer<ManifestKey>) throws {
        try c.put("kind", "shape")
        try c.putOpt("fill", s.fill)
        try c.putOpt("cache", s.cache)
        try c.putOpt("psd_raw", s.psdRaw)
        try c.put("path", s.path)
        try c.putOpt("stroke", s.stroke)
        try c.putOpt("live", s.live)
    }

    @inline(never)
    static func encodeSmart(_ s: SmartM, _ c: inout KeyedEncodingContainer<ManifestKey>) throws {
        try c.put("kind", "smart")
        try c.putOpt("contents_id", s.contentsId)
        try c.put("source", s.source)
        try c.put("transform", s.transform)
        try c.put("smart_filters", s.smartFilters)
        try c.putOpt("cache", s.cache)
        try c.putOpt("psd_raw", s.psdRaw)
        try c.put("filters_enabled", s.filtersEnabled)
        try c.putOpt("filter_mask", s.filterMask)
        try c.putOpt("warp", s.warp)
        try c.putOpt("stack_mode", s.stackMode)
        if let p = s.perspective { try c.put("perspective", p) }
    }
}

/// Where a smart object's source is, internally tagged by `kind`.
public enum SmartSourceM: Codable, Hashable, Sendable {
    case embedded(fileName: String, blob: Hash)
    case linked(path: String)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: ManifestKey.self)
        let kind = try c.req("kind", String.self)
        switch kind {
        case "embedded": self = .embedded(fileName: try c.req("file_name"), blob: try c.req("blob"))
        case "linked": self = .linked(path: try c.req("path"))
        default: throw DecodingError.dataCorruptedError(forKey: ManifestKey("kind"), in: c, debugDescription: "unknown variant `\(kind)`")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: ManifestKey.self)
        switch self {
        case let .embedded(fileName, blob):
            try c.put("kind", "embedded")
            try c.put("file_name", fileName)
            try c.put("blob", blob)
        case .linked(let path):
            try c.put("kind", "linked")
            try c.put("path", path)
        }
    }
}

public struct ChannelM: Codable, Hashable, Sendable {
    public var name: String
    public var surface: SurfaceM
    /// Spot ink: (colour, solidity).
    public var spot: ManifestPair<PCColor, Float>?
    /// Channel Options overlay colour (older files: Photoshop's red).
    public var color = AlphaChannel.defaultColor
    public var opacity: Float = 0.5
    public var indicates = ColorIndicates.maskedAreas

    public init(name: String, surface: SurfaceM, spot: ManifestPair<PCColor, Float>?, color: PCColor, opacity: Float, indicates: ColorIndicates) {
        self.name = name; self.surface = surface; self.spot = spot; self.color = color; self.opacity = opacity; self.indicates = indicates
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: ManifestKey.self)
        name = try c.req("name")
        surface = try c.req("surface")
        spot = try c.opt("spot")
        color = try c.def("color", AlphaChannel.defaultColor)
        opacity = try c.def("opacity", 0.5)
        indicates = try c.def("indicates", .maskedAreas)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: ManifestKey.self)
        try c.put("name", name)
        try c.put("surface", surface)
        try c.putOpt("spot", spot)
        try c.put("color", color)
        try c.put("opacity", opacity)
        try c.put("indicates", indicates)
    }
}

public struct MetadataM: Codable, Hashable, Sendable {
    public var xmp: String?
    public var exif: Hash?
    public var text: [ManifestPair<String, String>] = []
    /// (id, name, blob)
    public var psdResources: [ManifestTriple<UInt16, String, Hash>] = []
    /// (signature hex, key hex, blob)
    public var psdGlobalBlocks: [ManifestTriple<String, String, Hash>] = []

    public init(xmp: String? = nil, exif: Hash? = nil, text: [ManifestPair<String, String>] = [], psdResources: [ManifestTriple<UInt16, String, Hash>] = [],
                psdGlobalBlocks: [ManifestTriple<String, String, Hash>] = []) {
        self.xmp = xmp; self.exif = exif; self.text = text; self.psdResources = psdResources; self.psdGlobalBlocks = psdGlobalBlocks
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: ManifestKey.self)
        xmp = try c.opt("xmp")
        exif = try c.opt("exif")
        text = try c.def("text", [])
        psdResources = try c.req("psd_resources")
        psdGlobalBlocks = try c.req("psd_global_blocks")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: ManifestKey.self)
        try c.putOpt("xmp", xmp)
        try c.putOpt("exif", exif)
        if !text.isEmpty { try c.put("text", text) }
        try c.put("psd_resources", psdResources)
        try c.put("psd_global_blocks", psdGlobalBlocks)
    }
}
