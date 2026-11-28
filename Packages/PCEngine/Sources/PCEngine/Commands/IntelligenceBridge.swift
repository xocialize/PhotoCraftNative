// Port of photocraft-engine's AI-adjacent commands (crates/engine/src/smartselect_cmds.rs `select.subject`/`select.object`, cutout_cmds.rs `layer.removeBackground`, retouch_cmds/remove.rs `paint.remove`, edit_menu_cmds.rs `edit.contentAwareFill`) onto PCIntelligence, plus the new ids PCIntelligence describes (Generative Fill, Neural Filters, Super Resolution, Auto White Balance, SDR → HDR), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// PCIntelligence describes its 14 operations as data (`IntelligenceCommands.all`: id, label, menu,
// shortcut, params, preconditions, capability, journal, job). This module registers each as a real
// command: the precondition is the descriptor's (evaluated against the session and the provider
// registry, so a missing model greys the menu item out with the registry's reason), and the body
// runs the async operation as a background job against a snapshot, then commits the
// `EditTransaction` it returns as one undo step. Transactions address layers by id, so a job whose
// document changed meanwhile rebases instead of failing. Tier receipts (which backer ran) are in
// every result.

import ColorizeKit
import CoreGraphics
import EraseKit
import ExtractKit
import Foundation
import PCDocument
import PCFoundation
import PCHistory
import PCIntelligence
import PCPaint
import PCPlatform

enum IntelligenceBridge: CommandModule {
    static let name = "intelligence"

    /// The photocraft module each reused id comes from (new ids report "intelligence").
    static func module(of d: CommandDescriptor) -> String {
        guard let src = d.photocraftSource else { return name }
        return (src as NSString).lastPathComponent.replacingOccurrences(of: ".rs", with: "")
    }

    static func register(into r: inout CommandRegistry) {
        for d in IntelligenceCommands.all {
            let run = runner(d.id)
            let fill = d.id == "edit.contentAwareFill"
            var spec = CommandSpec(d.id, d.label, menu: d.menu, shortcut: d.shortcut, params: d.params, module: module(of: d),
                                   journal: d.journal, enabled: { s, p in disabledReason(s, d) ?? (fill ? fillSourceRefusal(s, p) : nil) },
                                   run: run)
            if d.id == "select.objectFinder" { spec.kind = .instant }
            if d.id == "edit.contentAwareFill" {
                spec.params = ##"{"sampling":"auto|rectangular|custom","margin":px?,"area":[x,y,w,h]?,"channel":index|name?,"colorAdaptation":"default|none|high|veryHigh","rotationAdaptation":"none|low|medium|high|full","scale":bool=false,"mirror":bool=false,"output":"current|new|duplicate","seed":u64=1,"quality":"fast|best"="best"} → {layer,filled,window:[x,y,w,h],tier,engine} (quality picks an injected model's tier; PatchMatch, PCIntelligence's classical tier, takes the rest)"##
            }
            r.add(spec)
        }
    }

    static func disabledReason(_ s: Session, _ d: CommandDescriptor) -> String? {
        let ctx = CommandContext(document: s.active?.doc, activeLayer: s.active?.activeLayer, registry: s.intelligence.registry)
        return IntelligenceCommands.disabledReason(d, in: ctx)
    }

    // MARK: Receipts and outcomes

    static func receipt(_ r: TierReceipt) -> [String: JSONValue] {
        var o: [String: JSONValue] = ["tier": .string(r.tier.rawValue), "engine": .string(r.engine)]
        if !r.notes.isEmpty { o["notes"] = .strings(r.notes) }
        if !r.metrics.isEmpty { o["metrics"] = .object(r.metrics.mapValues { .number($0) }) }
        return o
    }

    static func progressHandler(_ ctx: JobContext) -> ProgressHandler {
        { p in ctx.progress(Float(p.fraction), p.stage) }
    }

    static func source(_ p: JSONValue, default all: Bool) -> PixelSource {
        (p["sampleAllLayers"]?.boolValue ?? all) ? .composite : .composite
    }

    /// `sampleAllLayers` false: the target layer's own pixels.
    static func pixelSource(_ p: JSONValue, layer: LayerId?, defaultAll: Bool) -> PixelSource {
        if p["sampleAllLayers"]?.boolValue ?? defaultAll { return .composite }
        if let layer { return .layer(layer) }
        return .composite
    }

    static func filterOutput(_ cmd: String, _ p: JSONValue) throws -> FilterOutput {
        guard let v = p["output"]?.stringValue else { return .currentLayer }
        guard let o = FilterOutput(rawValue: v) else { throw EngineError.bad(cmd, "`output` must be currentLayer|newLayer|newLayerMasked") }
        return o
    }

    static func selectionMode(_ p: JSONValue) -> SelectionMode { SelectionMode(parsing: p["mode"]?.stringValue ?? "replace") }

    /// Commits a pixel edit outcome and returns its JSON.
    static func applyPixelEdit(_ s: Session, _ out: PixelEditOutcome) throws -> JSONValue {
        let activeNew = out.layer
        try s.commit(out.transaction, active: .some(activeNew))
        var o = receipt(out.receipt)
        o["layer"] = .id(out.layer)
        o["bounds"] = .rect(out.changedRect)
        if !out.stages.isEmpty {
            o["stages"] = .array(out.stages.map { st in
                var r = receipt(st)
                r["capability"] = .string(st.capability.rawValue)
                return .object(r)
            })
        }
        return .object(o)
    }

    // MARK: Runners

    static func runner(_ id: String) -> CommandRun {
        switch id {
        case "select.subject": return selectSubject
        case "select.object": return selectObject
        case "select.objectFinder": return objectFinder
        case "layer.removeBackground": return removeBackground
        case "paint.remove": return remove
        case "edit.contentAwareFill": return contentAwareFill
        case "edit.generativeFill": return generativeFill
        case "filter.neuralFilters.colorize": return colorize
        case "filter.neuralFilters.photoRestoration": return photoRestoration
        case "filter.neuralFilters.jpegArtifactsRemoval": return jpegArtifacts
        case "filter.neuralFilters.smartPortrait": return smartPortrait
        case "image.superResolution": return superResolution
        case "image.autoWhiteBalance": return autoWhiteBalance
        case "image.sdrToHdr": return sdrToHDR
        default: return { _, _ in throw EngineError.unavailable(id, "no engine runner for this PCIntelligence operation") }
        }
    }

    static func snapshot(_ s: Session) throws -> (Document, LayerId?) {
        guard let st = s.active else { throw EngineError.noDocument }
        return (st.doc, st.activeLayer)
    }

    @Sendable static func selectSubject(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let (doc, active) = try snapshot(s)
        let ai = s.intelligence
        let opts = SubjectOptions(mode: selectionMode(p), maskSample: .u8, quality: ExtractQuality(rawValue: p["quality"]?.stringValue ?? "fast") ?? .fast)
        let src = pixelSource(p, layer: active, defaultAll: true)
        return try s.runAsyncJob("Select Subject", lockDocument: true, work: { ctx in
            try await ai.selectSubject(doc, source: src, options: opts, progress: progressHandler(ctx))
        }, apply: { s, out, _ in try applySelection(s, out) })
    }

    static func applySelection(_ s: Session, _ out: SelectionOutcome) throws -> JSONValue {
        if out.changed, let t = out.transaction { try s.commit(t) }
        var o = receipt(out.receipt)
        o["selected"] = .bool(out.selection != nil)
        o["changed"] = .bool(out.changed)
        o["bounds"] = .rect(out.bounds)
        return .object(o)
    }

    @Sendable static func selectObject(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "select.object"
        let (doc, active) = try snapshot(s)
        var prompt = ObjectPrompt()
        if let r = p["rect"]?.arrayValue, r.count == 4 {
            let v = r.compactMap(\.doubleValue)
            guard v.count == 4 else { throw EngineError.bad(cmd, "`rect` must be [x,y,w,h]") }
            prompt = .box(x: v[0], y: v[1], width: v[2], height: v[3])
        }
        for pt in p["points"]?.arrayValue ?? [] {
            guard let a = pt.arrayValue, a.count >= 2, let x = a[0].doubleValue, let y = a[1].doubleValue else {
                throw EngineError.bad(cmd, "`points` must be [[x,y,include?],…]")
            }
            prompt.points.append(ObjectPoint(x: x, y: y, include: a.count > 2 ? (a[2].boolValue ?? true) : true))
        }
        if prompt.isEmpty { throw EngineError.bad(cmd, "Object Selection needs a click (`points`) or a box (`rect`)") }
        let ai = s.intelligence
        let mode = selectionMode(p)
        let src = pixelSource(p, layer: active, defaultAll: false)
        let thePrompt = prompt
        return try s.runAsyncJob("Object Selection", lockDocument: true, work: { ctx in
            try await ai.selectObject(doc, prompt: thePrompt, source: src, mode: mode, maskSample: .u8, progress: progressHandler(ctx))
        }, apply: { s, out, _ in try applySelection(s, out) })
    }

    /// Detected objects per document state (the hover preview runs per pointer move).
    struct FinderCache: Sendable {
        var doc: DocId
        var revision: UInt64
        var allLayers: Bool
        var finder: ObjectFinder
    }

    enum FinderCacheKey: StateKey { static let defaultValue: FinderCache? = nil }

    @Sendable static func objectFinder(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "select.objectFinder"
        guard let x = p["x"]?.doubleValue, let y = p["y"]?.doubleValue else { throw EngineError.bad(cmd, "missing `x`/`y`") }
        guard let st = s.active else { throw EngineError.noDocument }
        let all = p["sampleAllLayers"]?.boolValue ?? false
        let finder: ObjectFinder
        if let c = s.state[FinderCacheKey.self], c.doc == st.id, c.revision == st.revision, c.allLayers == all {
            finder = c.finder
        } else {
            let doc = st.doc, ai = s.intelligence
            let src = pixelSource(p, layer: st.activeLayer, defaultAll: false)
            do { finder = try runBlocking { try await ai.objectFinder(doc, source: src) } } catch { throw EngineError.wrap(error) }
            s.state[FinderCacheKey.self] = FinderCache(doc: st.id, revision: st.revision, allLayers: all, finder: finder)
        }
        let o = finder.object(atX: x, y: y)
        return [
            "object": o.map { ["index": .int($0.index), "bounds": .rect($0.bounds)] } ?? .null,
            "objects": .int(finder.objects.count), "tier": .string(finder.receipt.tier.rawValue),
        ]
    }

    @Sendable static func removeBackground(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let (doc, _) = try snapshot(s)
        let id = try s.layerParam(p)
        let ai = s.intelligence
        let src: PixelSource? = (p["sampleAllLayers"]?.boolValue ?? false) ? .composite : nil
        return try s.runAsyncJob("Remove Background", lockDocument: true, work: { ctx in
            try await ai.removeBackground(doc, layer: id, source: src, options: SubjectOptions(), progress: progressHandler(ctx))
        }, apply: { s, out, _ in
            try s.commit(out.transaction, active: .some(out.layer))
            var o = receipt(out.receipt)
            o["layer"] = .id(out.layer)
            o["bounds"] = .rect(out.bounds)
            return .object(o)
        })
    }

    /// The Remove tool: the strokes become a hole mask (rendered with a hard round brush of the
    /// given size; closed loops filled), then PCIntelligence fills it.
    @Sendable static func remove(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "paint.remove"
        let (doc, _) = try snapshot(s)
        let id = try s.layerParam(p)
        var strokes: [[[Double]]] = []
        func parse(_ v: JSONValue) throws -> [[Double]] {
            guard let a = v.arrayValue else { throw EngineError.bad(cmd, "a stroke is [[x,y,pressure?],…]") }
            return try a.map { pt in
                guard let q = pt.arrayValue, q.count >= 2, let x = q[0].doubleValue, let y = q[1].doubleValue else {
                    throw EngineError.bad(cmd, "a point is [x,y,pressure?]")
                }
                return [x, y, q.count > 2 ? (q[2].doubleValue ?? 1) : 1]
            }
        }
        if let pts = p["points"] { strokes.append(try parse(pts)) }
        for st in p["strokes"]?.arrayValue ?? [] { strokes.append(try parse(st)) }
        strokes = strokes.filter { !$0.isEmpty }
        if strokes.isEmpty { throw EngineError.bad(cmd, "missing `points` or `strokes`") }
        let size = Float(min(max(p["size"]?.doubleValue ?? Double(s.tools.brush.size), 1), 5000))
        let hardness = Float(min(max(p["hardness"]?.doubleValue ?? Double(s.tools.brush.hardness * 100), 0), 100)) / 100
        let closeLoops = p["closeLoops"]?.boolValue ?? true
        var brush = BrushSettings()
        brush.size = size
        brush.hardness = hardness
        brush.spacing = 0.1
        brush.pressureSize = false
        brush.color = SIMD4(1, 1, 1, 1)
        var hole = Surface(format: .graya8)
        for st in strokes {
            let pts = st.map { StrokePoint($0[0], $0[1], Float($0[2])) }
            renderStroke(&hole, brush, pts)
            // A loop whose ends meet (within the brush) is filled inside.
            if closeLoops, st.count > 2, let a = st.first, let b = st.last, hypot(a[0] - b[0], a[1] - b[1]) <= Double(size) {
                let poly = VectorPath([Subpath.polygon(st.map { ($0[0], $0[1]) })])
                let area = doc.bounds
                let cov = VectorRasterizer.fillCoverage(poly, rect: area)
                if cov.contains(where: { $0 > 0 }) {
                    var px = hole.readRegion(area)
                    for i in 0..<area.area where cov[i] > 0 { px[i * 2] = 1; px[i * 2 + 1] = max(px[i * 2 + 1], cov[i]) }
                    hole.writeRegion(area, px)
                }
            }
        }
        // The hole as gray coverage (the stroke's alpha).
        var mask = Surface(format: .gray8)
        let hb = hole.contentBounds
        if !hb.isEmpty {
            let px = hole.readRegion(hb)
            mask.writeRegion(hb, stride(from: 0, to: px.count, by: 2).map { px[$0 + 1] })
        }
        let ai = s.intelligence
        let src: PixelSource? = (p["sampleAllLayers"]?.boolValue ?? false) ? .composite : nil
        let opts = RemoveOptions(newLayer: p["newLayer"]?.boolValue ?? false)
        let holeMask = mask
        return try s.runAsyncJob("Remove Tool", lockDocument: true, work: { ctx in
            try await ai.remove(doc, layer: id, hole: holeMask, source: src, options: opts, progress: progressHandler(ctx))
        }, apply: { s, out, _ in
            var r = try applyPixelEdit(s, out)
            r = r.setting("damage", .rect(out.changedRect))
            return r
        })
    }

    /// The alpha channel `"channel"` names (an index or a name), for custom sampling.
    static func fillChannel(_ doc: Document, _ p: JSONValue) -> Surface? {
        p["channel"].flatMap { v in
            if let i = v.uint64Value, Int(i) < doc.channels.count { return doc.channels[Int(i)].surface }
            if let n = v.stringValue { return doc.channels.first { $0.name == n }?.surface }
            return nil
        }
    }

    /// Why Content-Aware Fill can't run: its selection leaves no 7 × 7 patch of unselected pixels in the area the
    /// fill samples from, so there's nothing to make the fill from (it came back black; Photoshop and Compositor
    /// refuse). Params the runner rejects pass here, for it to explain.
    static func fillSourceRefusal(_ s: Session, _ p: JSONValue) -> String? {
        guard let doc = s.active?.doc, let sel = doc.selection else { return nil }
        let canvas = doc.bounds
        let hole = sel.contentBounds.intersect(canvas)
        if hole.isEmpty { return nil }
        let sampling: ContentAwareFillOptions.Sampling
        switch p["sampling"]?.stringValue ?? "auto" {
        case "auto": sampling = .auto
        case "rectangular": sampling = .rectangular(margin: p["margin"]?.intValue)
        case "custom":
            if let r = Params.rect(p["area"]) { sampling = .custom(r) }
            else if let m = fillChannel(doc, p) { sampling = .custom(m.contentBounds) }
            else { return nil }
        default: return nil
        }
        if unselectedPatch(sel, hole, sampling.window(hole: hole, canvas: canvas)) { return nil }
        return "Not enough unselected pixels to make the fill from: select less, leaving some of the image around the selection"
    }

    /// Whether `window` holds a `side × side` square of pixels `sel` doesn't select at all (`content`: the
    /// selection's bounds). Read a band of rows at a time, and only when the selection leaves no such strip along
    /// the window's edges.
    static func unselectedPatch(_ sel: Surface, _ content: PixelRect, _ window: PixelRect, side: Int32 = 7) -> Bool {
        if window.width < Int(side) || window.height < Int(side) { return false }
        let c = content.intersect(window)
        if c.isEmpty || c.x0 - window.x0 >= side || window.x1 - c.x1 >= side || c.y0 - window.y0 >= side || window.y1 - c.y1 >= side {
            return true
        }
        // Per column, how many rows running down to this one are unselected.
        let w = window.width
        var run = [Int32](repeating: 0, count: w)
        var y = window.y0
        while y < window.y1 {
            let band = PixelRect(x0: window.x0, y0: y, x1: window.x1, y1: min(window.y1, y + 64))
            let cov = sel.coverage(band)
            for row in 0..<band.height {
                var across: Int32 = 0
                for x in 0..<w {
                    run[x] = cov[row * w + x] > 0 ? 0 : run[x] + 1
                    across = run[x] >= side ? across + 1 : 0
                    if across >= side { return true }
                }
            }
            y = band.y1
        }
        return false
    }

    /// Edit › Content-Aware Fill (photocraft `content_aware_fill_as`) through PCIntelligence's
    /// inpaint slot: PCAlgo's PatchMatch (`.classical`, with photocraft's sampling and adaptation
    /// options) unless the host registered a model.
    @Sendable static func contentAwareFill(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "edit.contentAwareFill"
        let (doc, _) = try snapshot(s)
        let id = try s.layerParam(p)
        var opts = ContentAwareFillOptions()
        var patch = InpaintOptions()
        let customMask = fillChannel(doc, p)
        switch p["sampling"]?.stringValue ?? "auto" {
        case "auto":
            opts.sampling = .auto
            patch.sampling = .auto
        case "rectangular":
            opts.sampling = .rectangular(margin: p["margin"]?.intValue)
        case "custom":
            if let r = Params.rect(p["area"]) {
                opts.sampling = .custom(r)
                patch.sampling = .mask([])
            } else if let m = customMask {
                opts.sampling = .custom(m.contentBounds)
                patch.sampling = .mask([])
            } else {
                throw EngineError.bad(cmd, "custom sampling needs `area` [x,y,w,h] or `channel` (alpha channel index or name)")
            }
        case let o: throw EngineError.bad(cmd, "unknown sampling `\(o)` (auto|rectangular|custom)")
        }
        if let o = p["output"]?.stringValue {
            guard let f = FillOutput(rawValue: o) else { throw EngineError.bad(cmd, "`output` must be current|new|duplicate") }
            opts.output = f
        }
        if let q = p["quality"]?.stringValue {
            guard let qq = InpaintQuality(rawValue: q) else { throw EngineError.bad(cmd, "`quality` must be fast|best") }
            opts.quality = qq
        }
        // photocraft's `FillOptions` params (unknown levels read as the defaults, as PCAlgo's
        // `colorLevel` / `rotationLevel` read them).
        patch.colorAdaptation = InpaintOptions.ColorAdaptation(rawValue: p["colorAdaptation"]?.stringValue ?? "default") ?? .default
        patch.rotationAdaptation = InpaintOptions.RotationAdaptation(rawValue: p["rotationAdaptation"]?.stringValue ?? "none") ?? .none
        patch.scale = p["scale"]?.boolValue ?? false
        patch.mirror = p["mirror"]?.boolValue ?? false
        patch.seed = p["seed"]?.uint64Value ?? 1
        // A custom area or channel limits what PatchMatch copies from, within the window.
        if case .mask = patch.sampling, let sel = doc.selection {
            let hb = sel.contentBounds.intersect(doc.bounds)
            let window: PixelRect
            if case .custom(let r) = opts.sampling { window = r.union(hb).outset(by: 4).intersect(doc.bounds) } else { window = hb }
            let area = Params.rect(p["area"])
            var mk = [Bool](repeating: false, count: window.area)
            let cov = customMask?.coverage(window)
            for y in 0..<window.height {
                for x in 0..<window.width {
                    let i = y * window.width + x
                    if let area { mk[i] = area.contains(x: window.x0 + Int32(x), y: window.y0 + Int32(y)) } else { mk[i] = (cov?[i] ?? 0) > 0.5 }
                }
            }
            patch.sampling = .mask(mk)
        }
        opts.inpaint = patch
        let ai = s.intelligence
        let theOpts = opts
        return try s.runAsyncJob("Content-Aware Fill", lockDocument: true, work: { ctx in
            try await ai.contentAwareFill(doc, layer: id, options: theOpts, progress: progressHandler(ctx))
        }, apply: { s, out, _ in
            var r = try applyPixelEdit(s, out)
            r = r.setting("filled", .bool(!out.changedRect.isEmpty))
            return r
        })
    }

    @Sendable static func generativeFill(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let (doc, active) = try snapshot(s)
        let prompt = p["prompt"]?.stringValue ?? ""
        let ai = s.intelligence
        let src: PixelSource = (p["sampleAllLayers"]?.boolValue ?? true) ? .composite : (active.map { .layer($0) } ?? .composite)
        return try s.runAsyncJob("Generative Fill", lockDocument: true, work: { ctx in
            try await ai.generativeFill(doc, above: active, prompt: prompt, source: src, progress: progressHandler(ctx))
        }, apply: { s, out, _ in try applyPixelEdit(s, out) })
    }

    @Sendable static func colorize(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "filter.neuralFilters.colorize"
        let (doc, _) = try snapshot(s)
        let id = try s.layerParam(p)
        var opts = ColorizeOptions(output: try filterOutput(cmd, p))
        if let v = p["variant"]?.stringValue {
            guard let vv = ColorizeVariant(rawValue: v) else { throw EngineError.bad(cmd, "`variant` must be fast|best|artistic") }
            opts.variant = vv
        }
        let ai = s.intelligence
        let theOpts = opts
        return try s.runAsyncJob("Colorize", lockDocument: true, work: { ctx in
            try await ai.colorize(doc, layer: id, options: theOpts, progress: progressHandler(ctx))
        }, apply: { s, out, _ in try applyPixelEdit(s, out) })
    }

    @Sendable static func photoRestoration(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "filter.neuralFilters.photoRestoration"
        let (doc, _) = try snapshot(s)
        let id = try s.layerParam(p)
        func unit(_ k: String) -> Float { Float(min(max(p[k]?.doubleValue ?? 0.5, 0), 1)) }
        let opts = PhotoRestorationOptions(scratchReduction: unit("scratchReduction"), noiseReduction: unit("noiseReduction"),
                                           enhanceFace: unit("enhanceFace"), output: try filterOutput(cmd, p))
        let ai = s.intelligence
        return try s.runAsyncJob("Photo Restoration", lockDocument: true, work: { ctx in
            try await ai.photoRestoration(doc, layer: id, options: opts, progress: progressHandler(ctx))
        }, apply: { s, out, _ in try applyPixelEdit(s, out) })
    }

    @Sendable static func jpegArtifacts(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "filter.neuralFilters.jpegArtifactsRemoval"
        let (doc, _) = try snapshot(s)
        let id = try s.layerParam(p)
        var strength = ArtifactStrength.medium
        if let v = p["strength"]?.stringValue {
            guard let st = ArtifactStrength(rawValue: v) else { throw EngineError.bad(cmd, "`strength` must be low|medium|high") }
            strength = st
        }
        let output = try filterOutput(cmd, p)
        let ai = s.intelligence
        let theStrength = strength
        return try s.runAsyncJob("JPEG Artifacts Removal", lockDocument: true, work: { ctx in
            try await ai.jpegArtifactsRemoval(doc, layer: id, strength: theStrength, output: output, progress: progressHandler(ctx))
        }, apply: { s, out, _ in try applyPixelEdit(s, out) })
    }

    @Sendable static func smartPortrait(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "filter.neuralFilters.smartPortrait"
        let (doc, _) = try snapshot(s)
        let id = try s.layerParam(p)
        let strength = Float(min(max(p["faceRestore"]?.doubleValue ?? 1, 0), 1))
        let output = try filterOutput(cmd, p)
        let ai = s.intelligence
        return try s.runAsyncJob("Smart Portrait", lockDocument: true, work: { ctx in
            try await ai.restoreFaces(doc, layer: id, strength: strength, output: output, progress: progressHandler(ctx))
        }, apply: { s, out, _ in try applyPixelEdit(s, out) })
    }

    @Sendable static func superResolution(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.superResolution"
        let (doc, active) = try snapshot(s)
        guard let f = p["factor"]?.intValue ?? 2 as Int?, (2...8).contains(f) else { throw EngineError.bad(cmd, "`factor` must be 2..8") }
        let src: PixelSource = (p["sampleAllLayers"]?.boolValue ?? true) ? .composite : (active.map { .layer($0) } ?? .composite)
        let ai = s.intelligence
        return try s.runAsyncJob("Super Resolution", lockDocument: false, work: { ctx in
            try await ai.superResolution(doc, source: src, factor: f, progress: progressHandler(ctx))
        }, apply: { s, out, _ in
            let i = s.addDocument(out.document)
            var o = receipt(out.receipt)
            o["document"] = .int(i)
            o["width"] = .int(out.document.size.width)
            o["height"] = .int(out.document.size.height)
            // PCIntelligence's upscale receipt names the factor the provider applied `appliedScale` (AB-T-0337).
            o["appliedFactor"] = .number(out.receipt.metrics["appliedScale"] ?? Double(f))
            return .object(o)
        })
    }

    @Sendable static func autoWhiteBalance(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.autoWhiteBalance"
        let (doc, _) = try snapshot(s)
        let id = try s.layerParam(p)
        let output = try filterOutput(cmd, p)
        let ai = s.intelligence
        return try s.runAsyncJob("Auto White Balance", lockDocument: true, work: { ctx in
            try await ai.autoWhiteBalance(doc, layer: id, output: output, progress: progressHandler(ctx))
        }, apply: { s, out, _ in
            var r = try applyPixelEdit(s, out)
            if let k = out.receipt.metrics["kelvin"] { r = r.setting("kelvin", .number(k)) }
            if let t = out.receipt.metrics["tint"] { r = r.setting("tint", .number(t)) }
            return r
        })
    }

    @Sendable static func sdrToHDR(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let (doc, active) = try snapshot(s)
        let opts = HDRExpansionOptions(diffuseWhiteNits: p["diffuseWhite"]?.doubleValue ?? 203, deband: p["deband"]?.boolValue ?? true,
                                       dither: p["dither"]?.boolValue ?? true)
        let src: PixelSource = (p["sampleAllLayers"]?.boolValue ?? true) ? .composite : (active.map { .layer($0) } ?? .composite)
        let ai = s.intelligence
        return try s.runAsyncJob("SDR to HDR", lockDocument: false, work: { ctx in
            try await ai.sdrToHDR(doc, source: src, options: opts, progress: progressHandler(ctx))
        }, apply: { s, out, _ in
            let i = s.addDocument(out.document)
            var o = receipt(out.receipt)
            o["document"] = .int(i)
            if let peak = out.receipt.metrics["peakNits"] { o["peakNits"] = .number(peak) }
            return .object(o)
        })
    }
}
