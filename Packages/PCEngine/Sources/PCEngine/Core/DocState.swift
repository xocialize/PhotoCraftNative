// Port of photocraft-engine (crates/engine/src/lib.rs `DocState`, `ToolState`, `fix_selection`, `restore_target`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Per-document editing state and app-wide tool state. photocraft keeps every module's view state
// as a field of `DocState`/`Session`; here modules keep theirs in a typed `StateStore` (a key per
// module), so a module ported later adds state without touching the core.

import PCDocument
import PCFoundation
import PCHistory
import PCPaint

/// A key into a `StateStore`: a type naming one module's state and its default.
public protocol StateKey {
    associatedtype Value: Sendable
    static var defaultValue: Value { get }
}

/// Typed module state, keyed by `StateKey` types (like SwiftUI's environment values).
public struct StateStore: Sendable {
    private var values: [ObjectIdentifier: any Sendable] = [:]

    public init() {}

    public subscript<K: StateKey>(_ key: K.Type) -> K.Value {
        get { (values[ObjectIdentifier(key)] as? K.Value) ?? K.defaultValue }
        set { values[ObjectIdentifier(key)] = newValue }
    }

    /// Drops a module's state (back to its default).
    public mutating func reset<K: StateKey>(_ key: K.Type) { values[ObjectIdentifier(key)] = nil }
}

/// Per-document editing state.
public struct DocState: Sendable {
    public var doc: Document
    public var history: History
    /// The primary ("key") layer: what single-layer commands act on. Always a member of
    /// `selectedLayers` when set.
    public var activeLayer: LayerId?
    /// Every selected layer in the Layers panel, in selection order. Selecting is not a history
    /// step, but undo and redo restore the layers each state targeted.
    public var selectedLayerIds: [LayerId]
    /// Anchor of ⇧-click range selection.
    public var layerAnchor: LayerId?
    public var path: String?
    /// A document whose source must not become its Save path (an imported preview).
    public var sourceReadOnly: Bool
    /// Increments on every change; UIs re-render when it moves.
    public var revision: UInt64
    public var savedRevision: UInt64
    /// Area changed by the latest revision (nil = assume everything changed).
    public var lastDamage: PixelRect?
    /// Coalescing key of the latest history step (`"coalesce"` param).
    public var coalesce: String?
    /// The transaction the latest step committed (nil after undo/redo or a non-edit change).
    public var lastTransaction: EditTransaction?
    /// Module view state (Channels-panel target, isolated layers, collapsed effects, floating
    /// selection, colour samplers, symmetry…): not history, not saved with the document.
    public var view = StateStore()

    public init(doc: Document, path: String? = nil, maxStates: Int = 50, maxBytes: Int = 0) {
        let active = doc.topLayer
        var h = History(maxStates: maxStates)
        h.maxBytes = maxBytes
        h.setCurrentLayers(LayerTarget(active: active, selected: active.map { [$0] } ?? []))
        self.doc = doc
        history = h
        activeLayer = active
        selectedLayerIds = active.map { [$0] } ?? []
        layerAnchor = active
        self.path = path
        sourceReadOnly = false
        revision = 1
        savedRevision = 1
        lastDamage = nil
        coalesce = nil
        lastTransaction = nil
    }

    public var id: DocId { doc.id }

    /// The selected layers in bottom-to-top document order, always including the active layer
    /// (photocraft `selected_layers`): stale ids are skipped, and an active layer outside the set
    /// makes the selection just that layer.
    public var selectedLayers: [LayerId] {
        guard let active = activeLayer else { return [] }
        let set = Set(selectedLayerIds.contains(active) ? selectedLayerIds : [active])
        return doc.allLayerIds.filter { set.contains($0) }
    }

    public func isLayerSelected(_ id: LayerId) -> Bool {
        activeLayer == id || (activeLayer.map { selectedLayerIds.contains($0) } ?? false && selectedLayerIds.contains(id))
    }

    public var isDirty: Bool { revision != savedRevision }

    /// The targeted layers, as history stores them with each state.
    public var layerTarget: LayerTarget { LayerTarget(active: activeLayer, selected: selectedLayerIds) }

    /// Records a save of the current revision to `path` (layered saves only): the document takes
    /// the file's name. File identity is not a history step (photocraft `DocState::saved_to`).
    public mutating func savedTo(_ path: String) {
        let name = DocState.fileName(path)
        if doc.name != name { doc.name = name }
        self.path = path
        savedRevision = revision
    }

    /// The last component of `path`, `/` or `\\` separated (photocraft `file_name`).
    public static func fileName(_ path: String) -> String {
        String(path.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? Substring(path))
    }

    /// photocraft `fix_selection`: drop deleted layers from the selection, and collapse to the
    /// active layer when a command made a non-member active.
    mutating func fixSelection() {
        guard let active = activeLayer else {
            selectedLayerIds.removeAll()
            return
        }
        if !selectedLayerIds.contains(active) {
            selectedLayerIds = [active]
        } else {
            let live = Set(doc.allLayerIds)
            var seen = Set<LayerId>()
            selectedLayerIds = selectedLayerIds.filter { live.contains($0) && seen.insert($0).inserted }
        }
        if let a = layerAnchor, !selectedLayerIds.contains(a) { layerAnchor = active }
    }

    /// photocraft `fix_active`: a missing active layer becomes the top layer.
    mutating func fixActive() {
        if activeLayer.map({ doc.layer($0) == nil }) ?? true { activeLayer = doc.topLayer }
        fixSelection()
    }

    /// photocraft `restore_target`: undo/redo target the layers the restored state targeted, as far
    /// as they still exist. Deselect Layers is a valid target (#3042).
    mutating func restoreTarget(_ layers: LayerTarget) {
        if layers.active == nil && layers.selected.isEmpty {
            activeLayer = nil
            selectedLayerIds.removeAll()
            layerAnchor = nil
            return
        }
        if let a = layers.active, doc.layer(a) != nil {
            activeLayer = a
            selectedLayerIds = layers.selected
        }
        fixActive()
    }
}

/// App-wide tool state commands read (foreground colour, brush…).
public struct ToolState: Sendable {
    /// Photoshop's colour pair for a layer mask that has none yet: white foreground, black
    /// background.
    public static let maskColors: (SIMD4<Float>, SIMD4<Float>) = (SIMD4(1, 1, 1, 1), SIMD4(0, 0, 0, 1))

    public var foreground = SIMD4<Float>(0, 0, 0, 1)
    public var background = SIMD4<Float>(1, 1, 1, 1)
    public var brush: BrushSettings
    /// Brush presets (built-ins plus user presets).
    public var presets: [BrushPreset]
    /// Bumped whenever `presets` changes.
    public var presetsRevision: UInt64 = 0
    /// Name of the preset the current brush was last picked from.
    public var currentPreset: String?
    /// A layer mask is the edit target.
    public var maskTargeted = false
    /// The colour pair of the edit target that isn't current (photocraft #2166).
    public var otherColors: (SIMD4<Float>, SIMD4<Float>) = ToolState.maskColors

    public init() {
        var b = BrushSettings()
        // Photoshop's Brush tool starts at 10 % Smoothing.
        b.smoothing.amount = 0.1
        brush = b
        presets = BrushPresets.builtin()
    }

    /// Switch the edit target between layer pixels and a layer mask, swapping the colour pairs as
    /// Photoshop does. Returns whether the target changed.
    @discardableResult
    public mutating func targetMask(_ mask: Bool) -> Bool {
        if maskTargeted == mask { return false }
        maskTargeted = mask
        let (fg, bg) = otherColors
        otherColors = (foreground, background)
        foreground = fg
        background = bg
        return true
    }
}
