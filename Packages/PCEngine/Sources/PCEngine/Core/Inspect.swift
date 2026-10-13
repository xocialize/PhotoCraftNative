// Port of photocraft-engine (crates/engine/src/inspect.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// JSON views of engine state for automation, tests and debugging (`session.inspect`,
// `document.inspect`, the control channel's `session.list` / `doc.inspect`). Modules add their own
// sections (channels, layer-mask view, symmetry…) through `DispatchHooks.documentInspectors`.

import PCDocument
import PCFoundation

public enum Inspect {
    public static func session(_ s: Session) -> JSONValue {
        [
            "active": s.activeIndex.map { .int($0) } ?? .null,
            "documents": .array(s.documents.enumerated().map { i, d in
                [
                    "index": .int(i), "name": .string(d.doc.name), "path": d.path.map(JSONValue.string) ?? .null,
                    "width": .int(d.doc.size.width), "height": .int(d.doc.size.height), "dirty": .bool(d.isDirty),
                    "revision": .int(Int(d.revision)),
                ]
            }),
            "foreground": .rgba(s.tools.foreground),
            "background": .rgba(s.tools.background),
        ]
    }

    public static func modeName(_ m: ColorMode) -> String {
        switch m {
        case .bitmap: "Bitmap"
        case .grayscale: "Grayscale"
        case .indexed: "Indexed"
        case .rgb: "Rgb"
        case .cmyk: "Cmyk"
        case .lab: "Lab"
        case .multichannel: "Multichannel"
        case .duotone: "Duotone"
        }
    }

    public static func document(_ d: DocState, registry: CommandRegistry? = nil) -> JSONValue {
        let doc = d.doc
        let selected = d.selectedLayers
        var o: [String: JSONValue] = [
            "name": .string(doc.name), "path": d.path.map(JSONValue.string) ?? .null,
            "width": .int(doc.size.width), "height": .int(doc.size.height),
            "mode": .string(modeName(doc.mode)), "depth": .int(doc.depth.bits), "resolution": .float(doc.resolutionDpi),
            "activeLayer": d.activeLayer.map { .id($0) } ?? .null,
            "selectedLayers": .ids(selected),
            "hasSelection": .bool(doc.selection != nil),
            "selectionBounds": doc.selection.map { .rect($0.contentBounds) } ?? .null,
            "layers": .array(doc.layers.reversed().map { layer($0, selected: Set(selected)) }),
            "history": .strings(d.history.entries),
            "snapshots": .array(d.history.snapshots.map { ["id": .int(Int($0.id)), "name": .string($0.name)] }),
            "canUndo": .bool(d.history.canUndo), "canRedo": .bool(d.history.canRedo),
            "revision": .int(Int(d.revision)),
            "quickMask": .bool(doc.quickMask != nil),
            "layerComps": .array(doc.layerComps.map { ["id": .int(Int($0.id)), "name": .string($0.name)] }),
            "lastAppliedComp": doc.lastAppliedComp.map { .int(Int($0)) } ?? .null,
            "measurement": [
                "scale": .string(doc.measurement.scale.describe),
                "ruler": doc.measurement.ruler.map { r in
                    ["start": .doubles([r.start.x, r.start.y]), "end": .doubles([r.end.x, r.end.y]),
                     "protractor": r.protractor.map { .doubles([$0.x, $0.y]) } ?? .null]
                } ?? .null,
                "count": .int(doc.measurement.countTotal), "countGroups": .int(doc.measurement.countGroups.count),
            ],
            "notes": .array(doc.notes.map { ["author": .string($0.author), "text": .string($0.text), "position": .doubles([$0.position.x, $0.position.y])] }),
            "timeline": doc.timeline.map { t in ["fps": .float(t.fps), "duration": .number(Double(t.duration)), "current": .number(Double(t.current))] } ?? .null,
            "variables": doc.variables.isEmpty ? .null : [
                "defs": .array(doc.variables.defs.map { ["name": .string($0.name), "layer": .id($0.layer)] }),
                "dataSets": .strings(doc.variables.dataSets.map(\.name)),
                "active": doc.variables.active.map { .int(Int($0)) } ?? .null,
            ],
        ]
        for h in registry?.hooks.documentInspectors ?? [] { h(d, &o) }
        return .object(o)
    }

    /// One layer (and its children), top-to-bottom display order.
    public static func layer(_ l: Layer, selected: Set<LayerId> = []) -> JSONValue {
        var v: [String: JSONValue] = [
            "id": .id(l.id), "name": .string(l.name), "kind": .string(l.content.kindName), "visible": .bool(l.visible),
            "labelColor": .string(l.label.id), "opacity": .float(l.opacity), "fill": .float(l.fillOpacity),
            "blend": .string(l.blend.label), "clipped": .bool(l.clipped), "hasMask": .bool(l.mask != nil),
            "hasVectorMask": .bool(l.vectorMask != nil), "vectorMaskEnabled": l.vectorMask.map { .bool($0.enabled) } ?? .null,
            "bounds": l.surface.map { .rect($0.contentBounds) } ?? .null,
            "selected": .bool(selected.contains(l.id)),
            "linkGroup": l.linkGroup.map { .int(Int(truncatingIfNeeded: $0)) } ?? .null,
            "locks": ["transparency": .bool(l.locks.transparency), "pixels": .bool(l.locks.pixels), "position": .bool(l.locks.position),
                      "artboard": .bool(l.locks.artboard), "all": .bool(l.locks.all)],
        ]
        switch l.content {
        case .group(let g):
            v["children"] = .array(g.children.reversed().map { layer($0, selected: selected) })
            v["expanded"] = .bool(g.expanded)
            if let a = g.artboard {
                v["artboard"] = ["rect": .rect(a.rect), "background": .encoded(a.background), "preset": .string(a.preset)]
            }
        case .adjustment(let a):
            v["adjustment"] = .encoded(a)
        case .smart(let sm):
            v["smartFilters"] = .array(sm.smartFilters.map {
                ["command": .string($0.command), "params": $0.params, "visible": .bool($0.visible), "opacity": .float($0.opacity), "blend": .string($0.blend.label)]
            })
            v["smartFiltersEnabled"] = .bool(sm.filtersEnabled)
            switch sm.source {
            case .embedded(let name, _): v["smartSource"] = ["kind": "embedded", "fileName": .string(name)]
            case .linked(let path): v["smartSource"] = ["kind": "linked", "path": .string(path)]
            }
        case .text(let t):
            v["text"] = ["text": .string(t.text), "font": .string(t.fontFamily), "sizePt": .float(t.sizePt)]
        case .fill(let f):
            v["fillContent"] = .encoded(f)
        default:
            break
        }
        if l.excludedChannels != 0 {
            v["channels"] = .array((0..<4).map { .bool(l.excludedChannels & (1 << $0) == 0) })
        }
        if l.advanced != AdvancedBlending() { v["advancedBlending"] = .encoded(l.advanced) }
        if l.blendIf != BlendIf() { v["blendIf"] = .encoded(l.blendIf) }
        if !l.effects.items.isEmpty {
            v["effects"] = ["enabled": .bool(l.effects.enabled), "items": .array(l.effects.items.map { ["kind": .string($0.label), "enabled": .bool($0.isEnabled)] })]
        }
        if let vid = l.video {
            v["video"] = ["frames": .int(vid.frames.count), "fps": .float(vid.fps), "showAltered": .bool(vid.showAltered)]
        }
        return .object(v)
    }
}
