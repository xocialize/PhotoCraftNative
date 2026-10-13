// Port of photocraft-engine (crates/engine/src/eraser_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Eraser group's colour-aware tools: Magic Eraser (`paint.magicEraser`, a wand-style region
// erased to transparency) and Background Eraser (`paint.backgroundEraser`, a brush that erases
// colours similar to the one under its hotspot, PCPaint's `BackgroundEraser`). Like Photoshop,
// both turn a Background layer into a normal layer ("Layer 0") first, since the Background can't
// hold transparency. The Magic Eraser paints the background colour on other layers with locked
// transparency; the Background Eraser refuses them. Both respect the selection, work in the
// layer's own colour model and depth, and are one undo step per click / stroke. The Magic
// Eraser's region and erase are PCAlgo's (`Selection.wandRegion`, `MagicEraser.erase`).

import PCAlgo
import PCDocument
import PCFoundation
import PCPaint

enum EraserCommands: CommandModule {
    static let name = "eraser_cmds"
    static let m = "eraser_cmds"

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }

    /// A finite number param clamped to `range`, `d` when absent; non-numbers are an error.
    static func number(_ p: JSONValue, _ cmd: String, _ k: String, _ d: Double, _ range: ClosedRange<Double>) throws -> Double {
        switch p[k] {
        case nil, .null?: return d
        case let v?:
            guard let f = v.doubleValue, f.isFinite else { throw bad(cmd, "`\(k)` must be a number") }
            return min(max(f, range.lowerBound), range.upperBound)
        }
    }

    static func enumParam<T: RawRepresentable>(_ p: JSONValue, _ cmd: String, _ k: String, _ d: T, _ allowed: String) throws -> T where T.RawValue == String {
        switch p[k] {
        case nil, .null?: return d
        case let v?:
            guard let s = v.stringValue, let e = T(rawValue: s) else { throw bad(cmd, "`\(k)` must be one of \(allowed)") }
            return e
        }
    }

    static func activePixelLayer(_ s: Session, _ cmd: String) throws -> LayerId {
        if let why = Pre.hasPixelLayer(s, .null) { throw bad(cmd, why) }
        guard let id = s.active?.activeLayer else { throw bad(cmd, "no active layer") }
        return id
    }

    static func pixelsLocked(_ doc: Document, _ l: Layer) -> EngineError? {
        let locks = doc.effectiveLocks(l.id)
        return locks.pixels || locks.all ? .other("Could not complete your request because the layer \"\(l.name)\" is locked") : nil
    }

    static func damage(_ s: Session, _ dmg: PixelRect, _ erased: Bool) -> JSONValue {
        if !dmg.isEmpty { s.noteDamage(dmg) }
        return ["erased": .bool(erased), "damage": .rect(dmg)]
    }

    /// `paint.magicEraser`: erase the wand region around `(x, y)`.
    static func magicEraser(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "paint.magicEraser"
        func coord(_ k: String) throws -> Double {
            guard let v = p[k]?.doubleValue, v.isFinite, abs(v) < 1e9 else { throw bad(cmd, "missing or invalid `\(k)`") }
            return v
        }
        let (x, y) = (BrushCommands.i32(try coord("x").rounded(.down)), BrushCommands.i32(try coord("y").rounded(.down)))
        let tolerance = Float(try number(p, cmd, "tolerance", 32, 0...255))
        let opacity = Float(try number(p, cmd, "opacity", 100, 1...100)) / 100
        let (antiAlias, contiguous, sampleAll) = (BrushCommands.flag(p, "antiAlias", true), BrushCommands.flag(p, "contiguous", true),
                                                  BrushCommands.flag(p, "sampleAllLayers", false))
        let id = try activePixelLayer(s, cmd)
        guard let d = s.active else { throw EngineError.noDocument }
        if let l = d.doc.layer(id), let e = pixelsLocked(d.doc, l) { throw e }
        // Clicking off the canvas erases nothing (and records no history step).
        if !d.doc.bounds.contains(x: x, y: y) { return damage(s, .empty, false) }
        let (area, img) = try SelectionCommands.sampleRGBA8(s, allLayers: sampleAll)
        guard let region = SelectionCommands.wandRegion(img, area, seed: (x, y), tolerance: tolerance, contiguous: contiguous, antiAlias: antiAlias) else {
            return damage(s, .empty, false)
        }
        let bg = s.tools.background
        let dmg: PixelRect = try s.edit("Magic Eraser") { doc, _ in
            let selection = doc.selection
            // Photoshop converts the Background to a normal layer before erasing to transparency.
            guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
            LayerOps.backgroundToLayer(&doc, id)
            let lock = doc.effectiveLocks(id).transparency
            let r: PixelRect? = doc.withRaster(of: id) { surf in
                // Locked transparency: paint the background colour instead (Photoshop).
                let lockColor = lock ? surf.format.components(fromRGBA: SIMD4(bg.x, bg.y, bg.z, 1)) : nil
                return MagicEraser.erase(&surf, region: region, amount: opacity, selection: selection, lockColor: lockColor)
            }
            guard let r else { throw bad(cmd, "not a pixel layer") }
            return r
        }
        return damage(s, dmg, true)
    }

    /// `paint.backgroundEraser`: a stroke erasing colours similar to the sampled one.
    static func backgroundEraser(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "paint.backgroundEraser"
        let pts = try BrushCommands.parsePoints(p, cmd)
        if pts.contains(where: { !$0.x.isFinite || !$0.y.isFinite || abs($0.x) > 1e7 || abs($0.y) > 1e7 }) {
            throw bad(cmd, "`points` must be finite canvas coordinates")
        }
        let brush = try BrushCommands.resolveBrush(s, p, cmd)
        let bs = BgEraseSettings(sampling: try enumParam(p, cmd, "sampling", Sampling.continuous, "continuous|once|backgroundSwatch"),
                                 limits: try enumParam(p, cmd, "limits", Limits.contiguous, "discontiguous|contiguous|findEdges"),
                                 tolerance: Float(try number(p, cmd, "tolerance", 50, 0...100)) / 100,
                                 protectForeground: BrushCommands.flag(p, "protectForegroundColor", false),
                                 foreground: s.tools.foreground, background: s.tools.background)
        let id = try activePixelLayer(s, cmd)
        guard let d = s.active else { throw EngineError.noDocument }
        guard let l = d.doc.layer(id) else { throw EngineError.noLayer(id) }
        if let e = pixelsLocked(d.doc, l) { throw e }
        if d.doc.effectiveLocks(id).transparency && !d.doc.isBackground(id) {
            throw EngineError.other("Could not use the Background Eraser because the transparency of layer \"\(l.name)\" is locked")
        }
        let stroke = Stroke(brush: brush, points: pts)
        let dmg: PixelRect = try s.edit("Background Eraser") { doc, _ in
            let selection = doc.selection
            LayerOps.backgroundToLayer(&doc, id)
            guard let r = doc.withRaster(of: id, { surf in BackgroundEraser.apply(&surf, stroke, bs, selection: selection) }) else {
                throw bad(cmd, "not a pixel layer")
            }
            return r
        }
        return damage(s, dmg, true)
    }

    static func register(into r: inout CommandRegistry) {
        r.add([
            CommandSpec("paint.magicEraser", "Magic Eraser",
                        params: #"{"x":px,"y":px,"tolerance":0..255=32,"antiAlias":bool=true,"contiguous":bool=true,"sampleAllLayers":bool=false,"opacity":1..100=100}"#,
                        module: m, enabled: Pre.hasPixelLayer, run: magicEraser),
            CommandSpec("paint.backgroundEraser", "Background Eraser",
                        params: #"{"points":[[x,y,pressure?],…],"size":px?,"hardness":0..1?,"brush":{…}?,"preset":name?,"sampling":"continuous|once|backgroundSwatch"="continuous","limits":"discontiguous|contiguous|findEdges"="contiguous","tolerance":0..100=50,"protectForegroundColor":bool=false,"seed":u64?}"#,
                        module: m, enabled: Pre.hasPixelLayer, run: backgroundEraser),
        ])
    }
}
