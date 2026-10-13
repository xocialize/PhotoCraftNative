// Port of photocraft-engine (crates/engine/src/solid_fill_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Editing a Solid Color Fill (the Color Picker opened from a fill layer's thumbnail) is one
// undoable content edit, independent of the layer's masks. RGB picker values are converted into the
// document's mode and keep the fill's alpha; a stored colour (`{mode,c,alpha}`) is kept exactly.

import Foundation
import PCDocument
import PCFoundation

enum SolidFillCommands: CommandModule {
    static let name = "solid_fill_cmds"
    static let m = name
    static let set = "layer.fill.solidColor.set"

    static func register(into r: inout CommandRegistry) {
        r.add(specs())
    }

    static func bad(_ msg: String) -> EngineError { .bad(set, msg) }

    /// photocraft `color_param`: an RGB picker value or a full colour in its stored model. A
    /// three-component RGB value preserves alpha; opening the picker must not make a translucent
    /// fill opaque.
    static func colorParam(_ value: JSONValue, original: PCColor, mode: ColorMode) throws -> PCColor {
        let color: PCColor
        switch value {
        case .string(let s):
            let h = Array((s.hasPrefix("#") ? String(s.dropFirst()) : s).utf8)
            func channel(_ i: Int) -> Float? { LayerStyleCommands.hexPair(h, i).map { Float($0) / 255 } }
            if h.count != 6 && h.count != 8 { throw bad("color must be #rrggbb or #rrggbbaa") }
            guard let r = channel(0), let g = channel(2), let b = channel(4) else { throw bad("invalid hexadecimal color") }
            var alpha = original.alpha
            if h.count == 8 {
                guard let a = channel(6) else { throw bad("invalid alpha") }
                alpha = a
            }
            color = PCColor.rgb(r, g, b, alpha).converted(to: mode)
        case .array(let a) where (3...4).contains(a.count):
            func channel(_ i: Int) -> Float? {
                guard let v = a[i].doubleValue, v.isFinite, (0...1).contains(v) else { return nil }
                return Float(v)
            }
            guard let r = channel(0), let g = channel(1), let b = channel(2) else { throw bad("RGB components must be finite numbers within 0..1") }
            var alpha = original.alpha
            if a.count == 4 {
                guard let x = channel(3) else { throw bad("alpha must be a finite number within 0..1") }
                alpha = x
            }
            color = PCColor.rgb(r, g, b, alpha).converted(to: mode)
        case .object:
            do { color = try value.decode(as: PCColor.self) } catch { throw bad("invalid stored Color") }
        default:
            throw bad("color must be hexadecimal RGB, [r,g,b,a?], or a stored Color")
        }
        let c = color.c
        if ![c.x, c.y, c.z, c.w].allSatisfy(\.isFinite) || !color.alpha.isFinite || !(0...1).contains(color.alpha) {
            throw bad("color must be finite and alpha within 0..1")
        }
        return color
    }

    static func run(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        if p.objectValue == nil || (p["layer"].map { $0.uint64Value == nil } ?? false) {
            throw bad("params must be an object and layer an unsigned id")
        }
        guard let st = s.active else { throw EngineError.noDocument }
        if let document = p["document"], document.uint64Value != st.doc.id.rawValue { throw bad("the target document is no longer active") }
        let id = try s.layerParam(p)
        guard let layer = st.doc.layer(id) else { throw EngineError.noLayer(id) }
        guard case .fill(.solid(let original)) = layer.content else { throw bad("the target must be a Solid Color Fill layer") }
        guard let v = p["color"] else { throw bad("color is required") }
        let color = try colorParam(v, original: original, mode: st.doc.mode)
        if color != original {
            try LayerOps.checkPixelsUnlocked(st.doc, id)
            if st.doc.effectiveLocks(id).transparency && color.alpha != original.alpha { throw bad("the layer's transparency is locked") }
            try s.edit("Solid Color") { doc, _ in
                guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
                doc.updateLayer(id) { $0.content = .fill(.solid(color)) }
            }
        }
        return ["layer": .id(id), "color": .encoded(color)]
    }

    static func specs() -> [CommandSpec] {
        [
            CommandSpec(set, "Solid Color…",
                        params: ##"{"layer":id? (default active),"document":id? (reject a stale dialog),"color":"#rrggbb"|"#rrggbbaa"|[r,g,b,a?]|{mode,c:[f32;4],alpha:f32}}; RGB values without alpha preserve it; stored Color preserves its model and precision"##,
                        module: m, enabled: Pre.hasDoc, run: run),
        ]
    }
}
