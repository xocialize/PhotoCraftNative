// Port of photocraft architecture §4.5 (view-models: "Panels (Layers, History, Channels, Paths, Properties, …) read plain structs produced from a snapshot") and of the panel state photocraft-ui-egui derives from `DocState` (layers_panel.rs, history_panel.rs, channels_panel.rs, paths_panel.rs, properties_panel.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Plain values built from a `DocState` (or a `DocSnapshot` on another thread): no references into
// the session, Codable for the control channel, Equatable so a SwiftUI view diffs them cheaply.
// Thumbnails are `ThumbHandle`s; the UI resolves them through `ThumbnailCache`.

import PCDocument
import PCFoundation
import PCRender

/// One row of the Layers panel.
public struct LayerRow: Sendable, Equatable, Codable, Identifiable {
    public struct EffectRow: Sendable, Equatable, Codable {
        public var kind: String
        public var enabled: Bool
    }
    public var id: LayerId
    public var name: String
    public var kind: String
    /// 0 for a root-level layer, 1 inside one group, …
    public var depth: Int
    /// Hidden by a collapsed group above it (or by Isolate Layers).
    public var hiddenInPanel: Bool
    public var visible: Bool
    public var blend: String
    public var opacity: Float
    public var fill: Float
    public var clipped: Bool
    public var locks: Locks
    public var labelColor: String
    public var linked: Bool
    public var isBackground: Bool
    public var isGroup: Bool
    public var expanded: Bool?
    public var isArtboard: Bool
    public var selected: Bool
    public var active: Bool
    public var hasMask: Bool
    public var maskEnabled: Bool?
    public var hasVectorMask: Bool
    public var effectsVisible: Bool
    public var effects: [EffectRow]
    public var smartFilters: Int
    public var thumb: ThumbHandle
    public var maskThumb: ThumbHandle?
}

public struct LayersModel: Sendable, Equatable, Codable {
    /// Top-to-bottom, as the panel lists them.
    public var rows: [LayerRow]
    public var activeLayer: LayerId?
    public var selectedLayers: [LayerId]
}

public struct HistoryRow: Sendable, Equatable, Codable {
    public var index: Int
    public var label: String
    /// The current state (the last one before the redo states).
    public var current: Bool
    /// A redo state (greyed in the panel).
    public var undone: Bool
}

public struct HistoryModel: Sendable, Equatable, Codable {
    public struct SnapshotRow: Sendable, Equatable, Codable { public var id: UInt64; public var name: String }
    public var rows: [HistoryRow]
    public var snapshots: [SnapshotRow]
    public var canUndo: Bool
    public var canRedo: Bool
}

public struct ChannelRow: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case composite, color, alpha, spot, quickMask, layerMask }
    public var kind: Kind
    public var name: String
    public var index: Int?
    public var visible: Bool
    public var targeted: Bool
    public var shortcut: String?
    public var thumb: ThumbHandle?
}

public struct ChannelsModel: Sendable, Equatable, Codable {
    public var rows: [ChannelRow]
}

public struct PathRow: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case work, saved, shape, vectorMask }
    public var kind: Kind
    public var name: String
    public var subpaths: Int
    public var isClippingPath: Bool
}

public struct PathsModel: Sendable, Equatable, Codable {
    public var rows: [PathRow]
}

/// The Properties panel: the active layer's kind-specific settings, else the document's.
public struct PropertiesModel: Sendable, Equatable, Codable {
    public enum Section: String, Sendable, Codable { case document, pixel, adjustment, fill, type, shape, smartObject, group }
    public var section: Section
    public var layer: LayerId?
    public var title: String
    /// `[x, y, width, height]` of the layer's content, when it has pixels.
    public var bounds: [Int]?
    /// The kind's settings as JSON (adjustment params as `layer.setAdjustment` takes them, the
    /// fill, the text, the shape, the mask's density/feather…).
    public var values: JSONValue
}

/// Every panel model of one document.
public struct ViewModels: Sendable, Equatable, Codable {
    public var revision: UInt64
    public var layers: LayersModel
    public var history: HistoryModel
    public var channels: ChannelsModel
    public var paths: PathsModel
    public var properties: PropertiesModel
}

public enum ViewModelBuilder {
    public static func build(_ st: DocState) -> ViewModels {
        ViewModels(revision: st.revision, layers: layers(st), history: history(st), channels: channels(st), paths: paths(st), properties: properties(st))
    }

    // MARK: Layers

    public static func layers(_ st: DocState) -> LayersModel {
        let doc = st.doc
        let selected = Set(st.selectedLayers)
        let isolated = Set(st.view[IsolatedLayersKey.self])
        var rows: [LayerRow] = []
        func visit(_ ls: [Layer], depth: Int, hidden: Bool) {
            for l in ls.reversed() {
                let g = l.group
                var effects: [LayerRow.EffectRow] = []
                for e in l.effects.items { effects.append(.init(kind: e.label, enabled: e.isEnabled)) }
                let smart: Int
                if case .smart(let so) = l.content { smart = so.smartFilters.count } else { smart = 0 }
                rows.append(LayerRow(
                    id: l.id, name: l.name, kind: l.content.kindName, depth: depth,
                    hiddenInPanel: hidden || (!isolated.isEmpty && !isolated.contains(l.id)),
                    visible: l.visible, blend: l.blend.label, opacity: l.opacity, fill: l.fillOpacity, clipped: l.clipped, locks: l.locks,
                    labelColor: l.label.id, linked: l.linkGroup != nil, isBackground: doc.isBackground(l.id), isGroup: g != nil,
                    expanded: g?.expanded, isArtboard: g?.artboard != nil, selected: selected.contains(l.id), active: st.activeLayer == l.id,
                    hasMask: l.mask != nil, maskEnabled: l.mask?.enabled, hasVectorMask: l.vectorMask != nil,
                    effectsVisible: l.effects.enabled, effects: effects, smartFilters: smart,
                    thumb: ThumbnailCache.handle(doc: doc, layer: l), maskThumb: ThumbnailCache.maskHandle(doc: doc, layer: l)))
                if let g { visit(g.children, depth: depth + 1, hidden: hidden || !g.expanded) }
            }
        }
        visit(doc.layers, depth: 0, hidden: false)
        return LayersModel(rows: rows, activeLayer: st.activeLayer, selectedLayers: st.selectedLayers)
    }

    // MARK: History

    public static func history(_ st: DocState) -> HistoryModel {
        let h = st.history
        let past = h.entries
        var rows: [HistoryRow] = past.enumerated().map { HistoryRow(index: $0, label: $1, current: $0 == past.count - 1, undone: false) }
        for (k, label) in h.redoLabels.enumerated() { rows.append(HistoryRow(index: past.count + k, label: label, current: false, undone: true)) }
        return HistoryModel(rows: rows, snapshots: h.snapshots.map { .init(id: $0.id, name: $0.name) }, canUndo: h.canUndo, canRedo: h.canRedo)
    }

    // MARK: Channels

    public static func channels(_ st: DocState) -> ChannelsModel {
        let doc = st.doc, v = st.channelView
        let mode = doc.pixelFormat.mode
        let names = Channels.colorNames(mode)
        var rows: [ChannelRow] = []
        let allColors = v.visibleColors(names.count) == names.count
        rows.append(ChannelRow(kind: .composite, name: Channels.compositeName(mode), index: nil, visible: allColors,
                               targeted: v.target == .composite, shortcut: "Cmd+2", thumb: ThumbnailCache.documentHandle(doc)))
        for (k, n) in names.enumerated() where names.count > 1 {
            rows.append(ChannelRow(kind: .color, name: n, index: k, visible: v.colorVisible(k), targeted: v.target == .color(k),
                                   shortcut: "Cmd+\(k + 3)", thumb: nil))
        }
        if let id = st.activeLayer, let l = doc.layer(id), l.mask != nil {
            rows.append(ChannelRow(kind: .layerMask, name: "\(l.name) Mask", index: nil, visible: st.currentMaskView != nil,
                                   targeted: v.target == .layerMask, shortcut: "Cmd+\\", thumb: ThumbnailCache.maskHandle(doc: doc, layer: l)))
        }
        if doc.quickMask != nil {
            rows.append(ChannelRow(kind: .quickMask, name: "Quick Mask", index: nil, visible: !v.quickMaskHidden, targeted: v.target == .composite,
                                   shortcut: nil, thumb: nil))
        }
        for (i, c) in doc.channels.enumerated() {
            var h = ThumbHandle(doc: doc.id, kind: .channel, layer: nil, channel: i, key: 0)
            h.key = ThumbKeys.hashOf(i) ^ ContentBoundsKey.of(c.surface)
            rows.append(ChannelRow(kind: c.spot != nil ? .spot : .alpha, name: c.name, index: i, visible: v.alphaShown(i), targeted: v.target == .alpha(i),
                                   shortcut: names.count + i + 3 <= 9 ? "Cmd+\(names.count + i + 3)" : nil, thumb: h))
        }
        return ChannelsModel(rows: rows)
    }

    // MARK: Paths

    public static func paths(_ st: DocState) -> PathsModel {
        let doc = st.doc
        var rows: [PathRow] = []
        if let l = st.activeLayer.flatMap({ doc.layer($0) }) {
            if case .shape(let sh) = l.content { rows.append(PathRow(kind: .shape, name: "\(l.name) Shape Path", subpaths: sh.path.subpaths.count, isClippingPath: false)) }
            if let vm = l.vectorMask { rows.append(PathRow(kind: .vectorMask, name: "\(l.name) Vector Mask", subpaths: vm.path.subpaths.count, isClippingPath: false)) }
        }
        for p in doc.paths {
            rows.append(PathRow(kind: .saved, name: p.name, subpaths: p.path.subpaths.count, isClippingPath: doc.clippingPath?.name == p.name))
        }
        if let wp = doc.workPath { rows.append(PathRow(kind: .work, name: "Work Path", subpaths: wp.subpaths.count, isClippingPath: false)) }
        return PathsModel(rows: rows)
    }

    // MARK: Properties

    public static func properties(_ st: DocState) -> PropertiesModel {
        let doc = st.doc
        guard let id = st.activeLayer, let l = doc.layer(id) else {
            return PropertiesModel(section: .document, layer: nil, title: "Document", bounds: [0, 0, doc.size.width, doc.size.height], values: [
                "width": .int(doc.size.width), "height": .int(doc.size.height), "resolution": .float(doc.resolutionDpi),
                "mode": .string(Inspect.modeName(doc.mode)), "depth": .int(doc.depth.bits),
            ])
        }
        let b = l.surface.map(\.contentBounds).flatMap { $0.isEmpty ? nil : $0 }
        let bounds = b.map { [Int($0.x0), Int($0.y0), $0.width, $0.height] }
        var values: [String: JSONValue] = ["opacity": .float(l.opacity), "fill": .float(l.fillOpacity), "blend": .string(l.blend.label)]
        if let m = l.mask {
            values["mask"] = ["density": .float(m.density * 100), "feather": .float(m.feather), "enabled": .bool(m.enabled), "linked": .bool(m.linked)]
        }
        if let vm = l.vectorMask {
            values["vectorMask"] = ["density": .float(vm.density * 100), "feather": .float(vm.feather), "enabled": .bool(vm.enabled)]
        }
        let section: PropertiesModel.Section
        switch l.content {
        case .raster: section = .pixel
        case .adjustment(let a):
            section = .adjustment
            values["kind"] = .string(AdjustParams.kind(of: a))
            values["params"] = AdjustParams.toParams(a)
        case .fill(let f):
            section = .fill
            values["fillContent"] = .encoded(f)
        case .text(let t):
            section = .type
            values["text"] = .string(t.text)
            values["font"] = .string(t.fontFamily)
            values["sizePt"] = .float(t.sizePt)
            values["color"] = .rgba(SIMD4(t.color.rgb, t.color.alpha))
        case .shape(let sh):
            section = .shape
            values["fillContent"] = sh.fill.map { .encoded($0) } ?? .null
            values["stroke"] = sh.stroke.map { .encoded($0) } ?? .null
            values["live"] = sh.live.map { .encoded($0) } ?? .null
        case .smart(let so):
            section = .smartObject
            switch so.source {
            case .embedded(let n, _): values["source"] = ["kind": "embedded", "fileName": .string(n)]
            case .linked(let p): values["source"] = ["kind": "linked", "path": .string(p)]
            }
            values["transform"] = .doubles(so.transform.m)
            values["smartFilters"] = .int(so.smartFilters.count)
        case .group(let g):
            section = .group
            values["children"] = .int(g.children.count)
            if let a = g.artboard { values["artboard"] = .rect(a.rect) }
        }
        return PropertiesModel(section: section, layer: id, title: l.name, bounds: bounds, values: .object(values))
    }
}

/// Select › Isolate Layers: the Layers panel lists only these layers (empty = off; view state).
public enum IsolatedLayersKey: StateKey { public static let defaultValue: [LayerId] = [] }

enum ContentBoundsKey {
    static func of(_ s: Surface) -> UInt64 { ContentBounds.fingerprint(s) }
}

extension Session {
    /// Every panel model of the active document (nil without one).
    public func viewModels() -> ViewModels? { active.map(ViewModelBuilder.build) }

    /// Every panel model of document `index`.
    public func viewModels(document index: Int) -> ViewModels? {
        index >= 0 && index < documents.count ? ViewModelBuilder.build(documents[index]) : nil
    }
}
