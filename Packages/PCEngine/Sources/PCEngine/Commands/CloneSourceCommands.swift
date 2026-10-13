// Port of photocraft-engine (crates/engine/src/presets/clone_source.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Window › Clone Source: five clone source slots for Clone Stamp and Healing Brush, each with a
// sample point, an offset, W/H scale, rotation and flips, plus the overlay options. The slots are
// session state (`CloneSourceCommands.SourcesKey`). `paint.cloneStamp` / `paint.healingBrush` read
// the active slot when the call names no `source`/`offset`, and always take its transform unless
// the call gives its own (`scale`, `rotation`, `flipH`, `flipV`). The transform maps the
// destination around the anchor (where the stroke started after the source was set) onto the
// source around the sample point: a 200 % width paints the source twice as wide, a 30° rotation
// paints it turned 30° counter-clockwise on screen (Photoshop's sense). The mapping itself is
// PCPaint's `CloneMapping` (photocraft's `Mapping`, ported there).

import Foundation
import PCDocument
import PCFoundation
import PCPaint

enum CloneSourceCommands: CommandModule {
    static let name = "presets::clone_source"
    /// The catalogue's module for these ids (photocraft registers them from `presets`).
    static let m = "presets"

    static let slotCount = 5

    // MARK: State

    /// One clone source slot (photocraft `CloneSource`).
    struct Slot: Hashable, Sendable {
        /// Sample point (document px) set by ⌥-click.
        var source: SIMD2<Double>?
        /// Destination point paired with `source` (first aligned stroke after setting it).
        var anchor: SIMD2<Double>?
        /// Layer the source was set on (informational, like the panel's document/layer line).
        var layer: UInt64?
        /// W and H in percent.
        var scale = SIMD2<Double>(100, 100)
        /// Degrees, counter-clockwise.
        var rotation: Double = 0
        var flipH = false
        var flipV = false
        /// The panel's W/H link (Maintain aspect ratio).
        var linked = false

        var isIdentity: Bool {
            abs(scale.x - 100) < 1e-9 && abs(scale.y - 100) < 1e-9 && abs(remEuclid(rotation, 360)) < 1e-9 && !flipH && !flipV
        }

        /// The panel's Offset X/Y: source − anchor (once a stroke paired them).
        var offset: SIMD2<Double>? {
            guard let s = source, let a = anchor else { return nil }
            return s - a
        }

        func json(_ i: Int) -> JSONValue {
            func pt(_ v: SIMD2<Double>?) -> JSONValue { v.map { [.number($0.x), .number($0.y)] } ?? .null }
            return [
                "index": .int(i), "source": pt(source), "anchor": pt(anchor), "offset": pt(offset),
                "layer": layer.map { .number(Double($0)) } ?? .null,
                "width": .number(scale.x), "height": .number(scale.y), "linked": .bool(linked), "rotation": .number(rotation),
                "flipH": .bool(flipH), "flipV": .bool(flipV),
            ]
        }
    }

    /// The Clone Source overlay options (photocraft `CloneOverlay`).
    struct Overlay: Hashable, Sendable {
        var show = true
        /// Percent.
        var opacity: Float = 100
        /// Clipped to the brush.
        var clipped = true
        var autoHide = true
        var invert = false
        /// normal | darken | lighten | difference
        var blend = "normal"

        /// photocraft's serde form (field names as in Rust: `auto_hide`).
        var json: JSONValue {
            ["show": .bool(show), "opacity": .float(opacity), "clipped": .bool(clipped), "auto_hide": .bool(autoHide), "invert": .bool(invert),
             "blend": .string(blend)]
        }
    }

    /// The panel (photocraft `CloneSources`).
    struct Sources: Hashable, Sendable {
        var slots = [Slot](repeating: Slot(), count: CloneSourceCommands.slotCount)
        var active = 0
        var overlay = Overlay()

        var activeIndex: Int { min(active, CloneSourceCommands.slotCount - 1) }
        var activeSlot: Slot { slots[activeIndex] }
    }

    /// Session state: the slots and overlay (photocraft `s.presets.clone`).
    enum SourcesKey: StateKey {
        static let defaultValue = Sources()
    }

    // MARK: Mapping

    /// Matrix taking destination offsets to source offsets for a slot's W/H, rotation and flips.
    static func transformMatrix(_ scale: SIMD2<Double>, _ rotation: Double, _ flipH: Bool, _ flipV: Bool) -> SIMD4<Double> {
        CloneMapping.transformMatrix(scale: scale, rotation: rotation, flipH: flipH, flipV: flipV)
    }

    static func pt(_ p: JSONValue, _ k: String) -> SIMD2<Double>? {
        guard let a = p[k]?.arrayValue, a.count >= 2, let x = a[0].doubleValue, let y = a[1].doubleValue else { return nil }
        return SIMD2(x, y)
    }

    /// Resolve a clone stroke's mapping from its params and the active slot. `first` is the
    /// stroke's first point. With `"aligned"` strokes the slot remembers the anchor so later
    /// strokes keep sampling relative to the original pairing.
    static func mapping(_ s: Session, _ p: JSONValue, first: SIMD2<Double>, _ cmd: String) throws -> CloneMapping {
        let (m, anchor) = try resolve(s, p, first: first, cmd)
        if let a = anchor {
            var st = s.state[SourcesKey.self]
            st.slots[st.activeIndex].anchor = a
            s.state[SourcesKey.self] = st
        }
        return m
    }

    /// `mapping` without remembering anything: the mapping, and the anchor an aligned stroke from
    /// the slot stores (a live preview resolves the same mapping the commit will).
    static func resolve(_ s: Session, _ p: JSONValue, first: SIMD2<Double>, _ cmd: String) throws -> (CloneMapping, SIMD2<Double>?) {
        let aligned = p["aligned"]?.boolValue ?? true
        let slot = s.state[SourcesKey.self].activeSlot
        let explicitTransform = ["scale", "rotation", "flipH", "flipV"].contains { p[$0] != nil }
        let m: SIMD4<Double>
        if explicitTransform {
            var sc = SIMD2<Double>(100, 100)
            if let a = p["scale"]?.arrayValue {
                sc = SIMD2(a.first?.doubleValue ?? 100, a.count > 1 ? (a[1].doubleValue ?? 100) : 100)
            }
            let flag = { (k: String) in p[k]?.boolValue ?? false }
            m = transformMatrix(sc, p["rotation"]?.doubleValue ?? 0, flag("flipH"), flag("flipV"))
        } else {
            m = transformMatrix(slot.scale, slot.rotation, slot.flipH, slot.flipV)
        }
        let anchorParam = pt(p, "anchor")
        if let off = pt(p, "offset") {
            let a = anchorParam ?? first
            return (CloneMapping(source: a + off, anchor: a, m: m), nil)
        }
        if let src = pt(p, "source") {
            return (CloneMapping(source: src, anchor: anchorParam ?? first, m: m), nil)
        }
        guard let src = slot.source else {
            throw EngineError.bad(cmd, "missing `source` ([x,y]) or `offset` ([dx,dy]); or set one with cloneSource.set")
        }
        let anchor = (aligned ? slot.anchor : nil) ?? first
        return (CloneMapping(source: src, anchor: anchor, m: m), aligned ? anchor : nil)
    }

    /// The Clone Source overlay's blend mode applied to one pixel: the source `src` over the image
    /// under the brush `dst`, both straight RGBA. Where the image is transparent the source shows
    /// unchanged; the result keeps the source's alpha. Unknown modes draw as Normal.
    static func overlayBlend(_ mode: String, _ src: SIMD4<Float>, _ dst: SIMD4<Float>) -> SIMD4<Float> {
        let f: (Float, Float) -> Float
        switch mode {
        case "darken": f = { Float.minimum($0, $1) }
        case "lighten": f = { Float.maximum($0, $1) }
        case "difference": f = { abs($0 - $1) }
        default: return src
        }
        let a = min(max(dst.w, 0), 1)
        var out = src
        for c in 0..<3 { out[c] = src[c] + (f(src[c], dst[c]) - src[c]) * a }
        return out
    }

    // MARK: Commands

    static func index(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> Int {
        guard let i = p["index"]?.uint64Value else { return s.state[SourcesKey.self].active }
        guard i < UInt64(slotCount) else { throw EngineError.bad(cmd, "index \(i) out of range (0..\(slotCount))") }
        return Int(i)
    }

    static func list(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let c = s.state[SourcesKey.self]
        return ["active": .int(c.active), "sources": .array(c.slots.enumerated().map { $1.json($0) }), "overlay": c.overlay.json]
    }

    static func select(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "cloneSource.select"
        guard let i = p["index"]?.uint64Value else { throw EngineError.bad(cmd, "missing `index`") }
        guard i < UInt64(slotCount) else { throw EngineError.bad(cmd, "index \(i) out of range (0..\(slotCount))") }
        s.state[SourcesKey.self].active = Int(i)
        return s.state[SourcesKey.self].activeSlot.json(Int(i))
    }

    static func set(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "cloneSource.set"
        let i = try index(s, p, cmd)
        let activeLayer = s.active?.activeLayer?.rawValue
        var st = s.state[SourcesKey.self]
        var slot = st.slots[i]
        if let src = pt(p, "source") {
            // A new sample point re-pairs with the next stroke.
            slot.source = src
            slot.anchor = nil
            slot.layer = p["layer"]?.uint64Value ?? activeLayer
        }
        if let off = pt(p, "offset") {
            // Offset X/Y fields: keep the anchor (or the source as anchor) and move the source.
            guard let a = slot.anchor ?? slot.source else { throw EngineError.bad(cmd, "set a `source` before an offset") }
            slot.anchor = a
            slot.source = a + off
        }
        if let a = p["scale"]?.arrayValue {
            slot.scale = SIMD2(a.first?.doubleValue ?? 100, a.count > 1 ? (a[1].doubleValue ?? 100) : 100)
        }
        if let b = p["linked"]?.boolValue { slot.linked = b }
        let before = slot.scale
        let w = p["width"]?.doubleValue, h = p["height"]?.doubleValue
        if let w { slot.scale.x = w }
        if let h { slot.scale.y = h }
        // Linked W/H keep their ratio: the field that was not given follows the one that was.
        if slot.linked {
            switch (w, h) {
            case (let w?, nil) where abs(before.x) > 1e-9: slot.scale.y = before.y * w / before.x
            case (nil, let h?) where abs(before.y) > 1e-9: slot.scale.x = before.x * h / before.y
            default: break
            }
        }
        if !(1...1000).contains(abs(slot.scale.x)) || !(1...1000).contains(abs(slot.scale.y)) {
            slot.scale = SIMD2(clampR(slot.scale.x, 1, 1000), clampR(slot.scale.y, 1, 1000))
        }
        if let r = p["rotation"]?.doubleValue { slot.rotation = remEuclid(r + 180, 360) - 180 }
        if let b = p["flipH"]?.boolValue { slot.flipH = b }
        if let b = p["flipV"]?.boolValue { slot.flipV = b }
        if p["clear"]?.boolValue == true { slot = Slot() }
        st.slots[i] = slot
        if p["select"]?.boolValue ?? true { st.active = i }
        s.state[SourcesKey.self] = st
        return slot.json(i)
    }

    static func resetTransform(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let i = try index(s, p, "cloneSource.resetTransform")
        var st = s.state[SourcesKey.self]
        st.slots[i].scale = SIMD2(100, 100)
        st.slots[i].rotation = 0
        st.slots[i].flipH = false
        st.slots[i].flipV = false
        s.state[SourcesKey.self] = st
        return st.slots[i].json(i)
    }

    static func overlay(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        var o = s.state[SourcesKey.self].overlay
        // As photocraft, the fields before a bad `blend` are kept.
        defer { s.state[SourcesKey.self].overlay = o }
        if let b = p["show"]?.boolValue { o.show = b }
        if let v = p["opacity"]?.doubleValue { o.opacity = clampR(Float(v), 0, 100) }
        if let b = p["clipped"]?.boolValue { o.clipped = b }
        if let b = p["autoHide"]?.boolValue { o.autoHide = b }
        if let b = p["invert"]?.boolValue { o.invert = b }
        if let m = p["blend"]?.stringValue {
            guard ["normal", "darken", "lighten", "difference"].contains(m) else {
                throw EngineError.bad("cloneSource.overlay", "unknown overlay mode `\(m)` (normal|darken|lighten|difference)")
            }
            o.blend = m
        }
        return o.json
    }

    static func register(into r: inout CommandRegistry) {
        r.add([
            CommandSpec("cloneSource.list", "Clone Sources",
                        params: "{} → {active,sources:[{index,source,anchor,offset,layer,width,height,linked,rotation,flipH,flipV}],overlay}",
                        module: m, journal: false, run: list),
            CommandSpec("cloneSource.select", "Select Clone Source", params: #"{"index":0..4}"#, module: m, run: select),
            CommandSpec("cloneSource.set", "Set Clone Source",
                        params: #"{"index":0..4?=active,"source":[x,y]? (⌥-click; re-pairs with the next stroke),"offset":[dx,dy]?,"width":%?,"height":%?|"scale":[w%,h%]?,"linked":bool? (W/H link: a lone width or height scales the other by the same factor),"rotation":deg?,"flipH":bool?,"flipV":bool?,"layer":id?,"clear":bool?,"select":bool=true}"#,
                        module: m, run: set),
            CommandSpec("cloneSource.resetTransform", "Reset Transform", params: #"{"index":0..4?=active}"#, module: m, run: resetTransform),
            CommandSpec("cloneSource.overlay", "Clone Source Overlay",
                        params: #"{"show":bool?,"opacity":0..100?,"clipped":bool?,"autoHide":bool?,"invert":bool?,"blend":"normal|darken|lighten|difference"?}"#,
                        module: m, run: overlay),
        ])
    }

    // MARK: Numerics (Rust semantics)

    static func remEuclid(_ a: Double, _ b: Double) -> Double {
        let r = a.truncatingRemainder(dividingBy: b)
        return r < 0 ? r + abs(b) : r
    }

    /// Rust `f64::clamp` (NaN stays NaN).
    static func clampR(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v < lo ? lo : (v > hi ? hi : v) }
    static func clampR(_ v: Float, _ lo: Float, _ hi: Float) -> Float { v < lo ? lo : (v > hi ? hi : v) }
}
