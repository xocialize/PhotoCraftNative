// Port of photocraft-engine (crates/engine/src/adjust_cmds.rs `shadows_highlights`, `shadows_highlights_params`, the Shadows/Highlights case of `adjust_as_filter`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Part of the adjust_cmds port: Image › Adjustments › Shadows/Highlights, photocraft's measured
// edge-aware tone model, run by PCAlgo's `ToneKit.shadowsHighlights` on straight RGBA (so every
// colour model and depth), destructively or recorded as a smart filter on a smart object.

import PCAlgo
import PCDocument
import PCFoundation

extension AdjustCommands {
    /// Rust `f32::clamp`.
    static func shClamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { v < lo ? lo : (v > hi ? hi : v) }

    /// The Shadows/Highlights settings of `p` (photocraft `shadows_highlights_params`).
    static func shadowsHighlightsParams(_ p: JSONValue) -> ShadowsHighlights {
        let d = ShadowsHighlights()
        return ShadowsHighlights(shadowAmount: shClamp(num(p, "shadowAmount", d.shadowAmount), 0, 100),
                                 shadowTone: shClamp(num(p, "shadowTone", d.shadowTone), 0, 100),
                                 shadowRadius: shClamp(num(p, "shadowRadius", d.shadowRadius), 0, 2500),
                                 highlightAmount: shClamp(num(p, "highlightAmount", d.highlightAmount), 0, 100),
                                 highlightTone: shClamp(num(p, "highlightTone", d.highlightTone), 0, 100),
                                 highlightRadius: shClamp(num(p, "highlightRadius", d.highlightRadius), 0, 2500),
                                 color: shClamp(num(p, "color", d.color), -100, 100),
                                 midtone: shClamp(num(p, "midtone", d.midtone), -100, 100),
                                 blackClip: shClamp(num(p, "blackClip", d.blackClip), 0, 50),
                                 whiteClip: shClamp(num(p, "whiteClip", d.whiteClip), 0, 50))
    }

    /// Image › Adjustments › Shadows/Highlights: a smart filter on a smart object, else one
    /// history step on the target's straight RGBA, blended through the selection.
    static func shadowsHighlights(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        if try adjustAsSmartFilter(s, kind: "shadowsHighlights", label: "Shadows/Highlights", p) { return .null }
        let sh = shadowsHighlightsParams(p)
        return try rgbaEdit(s, "Shadows/Highlights", p) { px, r in
            PCAlgo.ToneKit.shadowsHighlights(&px, w: r.width, h: r.height, sh)
        }
    }

    /// Shadows/Highlights re-run from its params as a smart filter (the `adjust_as_filter` case):
    /// applied to a copy of `surf`.
    static func shadowsHighlightsFilter(_ p: JSONValue, _ surf: Surface) -> Surface {
        var out = surf
        let sh = shadowsHighlightsParams(p)
        processSurface(&out, selection: nil) { px, r in PCAlgo.ToneKit.shadowsHighlights(&px, w: r.width, h: r.height, sh) }
        out.prune()
        return out
    }
}
