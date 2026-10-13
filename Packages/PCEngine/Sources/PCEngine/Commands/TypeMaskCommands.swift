// Port of photocraft-engine (crates/engine/src/type_mask_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// `type.createSelection`: the Horizontal and Vertical Type Mask tools' result. Typed text becomes
// a selection in the shape of its glyphs (their anti-aliased coverage) instead of a type layer, as
// Photoshop's Type Mask tools do.
//
// The tools edit a temporary type layer in one coalesced history step and commit with
// `{"layer": id, "removeLayer": true}`, so the whole session is one undo step that leaves no
// layer behind. Scripts can skip the layer and pass `type.create`'s keys directly.

import Foundation
import PCDocument
import PCFoundation
import PCPlatform

enum TypeMaskCommands: CommandModule {
    static let name = "type_mask_cmds"
    static let m = name
    static let cmd = "type.createSelection"
    typealias T = TypeCommands

    static func bad(_ msg: String) -> EngineError { .bad(cmd, msg) }

    static func antialias(_ p: JSONValue) throws -> AntiAlias? {
        guard let v = p["antialias"] else { return nil }
        switch v.stringValue {
        case "none"?: return AntiAlias.none
        case "sharp"?: return .sharp
        case "crisp"?: return .crisp
        case "strong"?: return .strong
        case "smooth"?: return .smooth
        default: throw bad("antialias must be none, sharp, crisp, strong or smooth")
        }
    }

    /// Glyph coverage of `t` (0…1 per pixel) over its rendered bounds inside the canvas. The text
    /// colour's own alpha doesn't thin the selection: every run renders opaque.
    static func coverage(_ doc: Document, _ t: TextLayer) -> ([Float], PixelRect) {
        var t = t
        for i in t.runs.indices { t.runs[i].style.color.alpha = 1 }
        let surface = T.fonts { TextEngine.rasterize(t, dpi: Double(doc.resolutionDpi), format: doc.pixelFormat).surface }
        let area = surface.contentBounds.intersect(doc.bounds)
        if area.isEmpty { return ([], .empty) }
        return (surface.readRGBA(area).map(\.w), area)
    }

    /// Coverage of `area`'s mask spread over `to` (which contains `area`), zero elsewhere.
    static func widen(_ m: [Float], _ area: PixelRect, _ to: PixelRect) -> [Float] {
        if area == to { return m }
        let (w, aw) = (to.width, area.width)
        var out = [Float](repeating: 0, count: to.area)
        guard aw > 0 else { return out }
        for y in 0..<(m.count / aw) {
            let start = (Int(area.y0) - Int(to.y0)) * w + y * w + (Int(area.x0) - Int(to.x0))
            guard start >= 0, start + aw <= out.count else { continue }
            out.replaceSubrange(start..<(start + aw), with: m[(y * aw)..<(y * aw + aw)])
        }
        return out
    }

    @Sendable static func createSelection(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let mode: SelectionMath.Mode
        switch p["operation"] {
        case nil, .string("new")?, .string("replace")?: mode = .replace
        case .string("add")?: mode = .add
        case .string("subtract")?: mode = .subtract
        case .string("intersect")?: mode = .intersect
        default: throw bad("operation must be new, add, subtract or intersect")
        }
        let aa = try antialias(p)
        let remove: Bool
        if let v = p["removeLayer"] {
            guard let b = v.boolValue else { throw bad("removeLayer must be true or false") }
            remove = b
        } else {
            remove = false
        }
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        let layer: LayerId?
        switch p["layer"] {
        case nil, .null?: layer = nil
        case let v?:
            guard let id = v.uint64Value else { throw bad("layer must be a layer id") }
            layer = LayerId(id)
        }
        if remove && layer == nil { throw bad("removeLayer needs a layer") }
        var t: TextLayer
        if let id = layer {
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            guard case .text(let tl) = l.content else { throw bad("layer \(id.rawValue) is not a type layer") }
            t = tl
        } else {
            t = try T.newTextLayer(s, p, cmd)
        }
        if let aa { t.antialias = aa }
        let (mask, textArea) = coverage(doc, t)
        let selected = try s.edit("Type Mask") { doc, active -> PixelRect? in
            let old = doc.selection.map { $0.contentBounds.intersect(doc.bounds) } ?? .empty
            // Replace and Intersect leave nothing outside the text; Add and Subtract keep the rest.
            let area: PixelRect
            if (mode == .add || mode == .subtract) && !old.isEmpty {
                area = textArea.isEmpty ? old : old.union(textArea)
            } else {
                area = textArea
            }
            doc.selection = area.isEmpty ? nil : SelectionMath.combine(doc.selection, widen(mask, textArea, area), area, mode)
            if remove, let id = layer {
                let neighbours = LayerMulti.deletionNeighbours(doc, id)
                guard doc.remove(id) != nil else { throw EngineError.noLayer(id) }
                if doc.layers.isEmpty { throw EngineError.other("a document must keep at least one layer") }
                if let current = active, doc.layer(current) == nil {
                    active = neighbours.first { doc.layer($0) != nil }
                }
            }
            return doc.selection.map(\.contentBounds)
        }
        // The Type Mask tools' whole typing session is this one step.
        try s.updateActive { $0.history.setCurrentLabel("Type Mask") }
        return ["selected": .bool(selected != nil), "bounds": selected.map { [.int($0.x0), .int($0.y0), .int($0.x1), .int($0.y1)] } ?? .null]
    }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec(cmd, "Type Mask",
                          params: ##"{"layer":id? (a type layer whose glyphs become the selection),"removeLayer":bool=false (delete that layer in the same step: the Type Mask tools' temporary text),"operation":"new|add|subtract|intersect"="new","antialias":"none|sharp|crisp|strong|smooth"?, …without "layer", type.create's keys: "text","x","y" or "box","orientation","font","size","align",…}"##,
                          module: m, enabled: T.hasDoc, run: createSelection))
    }
}
