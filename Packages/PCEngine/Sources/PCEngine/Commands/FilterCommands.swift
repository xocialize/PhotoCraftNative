// Port of photocraft-engine (crates/engine/src/filters.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// `filter.*` commands (Photoshop's Filter menu) backed by PCAlgo. Every command acts on the active
// pixel layer (or the cached pixels of a smart object, recording a smart filter), a targeted mask
// or channel, respects the selection, runs as a cancellable background job and is one undo step.
// `filter.lastFilter` re-runs the most recent filter command.
//
// This file is also the filter runner the other filter modules share: `paramsFor` maps a command
// id and its dialog-unit params to a PCAlgo filter (photocraft `params_for`, chained here →
// FiltersExtCommands → ColorToAlphaCommands → GalleryCommands, as photocraft chains its modules),
// `runFilter` runs one on the document, and `applyFilterToSurface` re-runs a recorded smart filter.

import Foundation
import PCAlgo
import PCDocument
import PCFoundation

enum FilterCommands: CommandModule {
    static let name = "filters"

    static func register(into r: inout CommandRegistry) {
        r.add(specs())
    }

    // MARK: Params (photocraft's tolerant decoding: defaults and clamps)

    static func f(_ p: JSONValue, _ k: String, _ d: Float) -> Float { p[k]?.doubleValue.map { Float($0) } ?? d }

    /// Clamped like the neighbouring filter params: an out-of-range value saturates instead of
    /// wrapping (`3e9` used to come back as a negative offset).
    static func i(_ p: JSONValue, _ k: String, _ d: Int32) -> Int32 {
        guard let v = p[k]?.doubleValue, !v.isNaN else { return d }
        return Int32(clamping: Int64(max(min(v.rounded(), 9.2e18), -9.2e18)))
    }

    static func b(_ p: JSONValue, _ k: String, _ d: Bool) -> Bool { p[k]?.boolValue ?? d }

    static func s(_ p: JSONValue, _ k: String, _ d: String) -> String { p[k]?.stringValue ?? d }

    /// New calls accept the documented u32 range; legacy records decode through `i`.
    static func seed(_ p: JSONValue) -> UInt32 {
        if let n = p["seed"]?.uint64Value, let v = UInt32(exactly: n) { return v }
        return UInt32(bitPattern: i(p, "seed", 0))
    }

    static func undefined(_ p: JSONValue) -> UndefinedAreas {
        switch s(p, "undefinedAreas", "wrap") {
        case "repeat": .repeat
        case "transparent": .transparent
        default: .wrap
        }
    }

    /// Minimum / Maximum › Preserve (Photoshop's default is Squareness).
    static func preserve(_ p: JSONValue) -> Preserve { s(p, "preserve", "squareness") == "roundness" ? .roundness : .squareness }

    static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }

    /// One-step presets (no dialog): the history step they record (their own name) and the fixed
    /// parameters, tuned to match the reference app's fixed-strength filters.
    static func preset(_ id: String) -> (String, AnyFilter)? {
        switch id {
        case "filter.blur.blur": ("Blur", AnyFilter(GaussianBlur(radius: 0.6)))
        case "filter.blur.blurMore": ("Blur More", AnyFilter(GaussianBlur(radius: 1.4)))
        case "filter.sharpen.sharpen": ("Sharpen", AnyFilter(UnsharpMask(amount: 60, radius: 0.5, threshold: 0)))
        case "filter.sharpen.sharpenMore": ("Sharpen More", AnyFilter(UnsharpMask(amount: 150, radius: 0.6, threshold: 0)))
        case "filter.sharpen.sharpenEdges": ("Sharpen Edges", AnyFilter(UnsharpMask(amount: 100, radius: 0.8, threshold: 6)))
        case "filter.noise.despeckle": ("Despeckle", AnyFilter(SurfaceBlur(radius: 2, threshold: 12)))
        default: nil
        }
    }

    /// The PCAlgo filter for a filter command id and its JSON params (Photoshop dialog units)
    /// (photocraft `params_for`). Stored smart filters and previews keep this tolerant decoding;
    /// new invocations pass `FilterValidation.validateParams` first.
    static func paramsFor(_ id: String, _ p: JSONValue) -> AnyFilter? {
        if let (_, f) = preset(id) { return f }
        switch id {
        case "filter.blur.gaussianBlur": return AnyFilter(GaussianBlur(radius: clamp(f(p, "radius", 1), 0.1, 1000)))
        case "filter.blur.boxBlur": return AnyFilter(BoxBlur(radius: clamp(f(p, "radius", 1), 1, 2000)))
        case "filter.blur.motionBlur": return AnyFilter(MotionBlur(angle: f(p, "angle", 0), distance: clamp(f(p, "distance", 10), 1, 2000)))
        case "filter.blur.radialBlur":
            let quality: RadialQuality = switch s(p, "quality", "good") {
            case "draft": .draft
            case "best": .best
            default: .good
            }
            return AnyFilter(RadialBlur(amount: clamp(f(p, "amount", 10), 1, 100), method: s(p, "method", "spin") == "zoom" ? .zoom : .spin,
                                        quality: quality, centerX: f(p, "centerX", 0.5), centerY: f(p, "centerY", 0.5)))
        case "filter.blur.surfaceBlur":
            return AnyFilter(SurfaceBlur(radius: clamp(f(p, "radius", 5), 1, 100), threshold: clamp(f(p, "threshold", 15), 2, 255)))
        case "filter.sharpen.unsharpMask":
            return AnyFilter(UnsharpMask(amount: clamp(f(p, "amount", 50), 1, 500), radius: clamp(f(p, "radius", 1), 0.1, 1000),
                                         threshold: clamp(f(p, "threshold", 0), 0, 255)))
        case "filter.sharpen.smartSharpen":
            return AnyFilter(SmartSharpen(amount: clamp(f(p, "amount", 100), 1, 500), radius: clamp(f(p, "radius", 1), 0.1, 64),
                                          reduceNoise: clamp(f(p, "reduceNoise", 10), 0, 100)))
        case "filter.other.highPass": return AnyFilter(HighPass(radius: clamp(f(p, "radius", 10), 0.1, 1000)))
        case "filter.noise.addNoise":
            return AnyFilter(AddNoise(amount: clamp(f(p, "amount", 12.5), 0.1, 400), distribution: s(p, "distribution", "uniform") == "gaussian" ? .gaussian : .uniform,
                                      monochromatic: b(p, "monochromatic", false), seed: seed(p)))
        case "filter.noise.median": return AnyFilter(Median(radius: clamp(f(p, "radius", 1), 1, 500)))
        case "filter.noise.dustAndScratches":
            return AnyFilter(DustAndScratches(radius: clamp(f(p, "radius", 1), 1, 500), threshold: clamp(f(p, "threshold", 0), 0, 255)))
        case "filter.other.minimum": return AnyFilter(Minimum(radius: clamp(f(p, "radius", 1), 0.2, 500), preserve: preserve(p)))
        case "filter.other.maximum": return AnyFilter(Maximum(radius: clamp(f(p, "radius", 1), 0.2, 500), preserve: preserve(p)))
        case "filter.other.offset": return AnyFilter(Offset(horizontal: i(p, "horizontal", 0), vertical: i(p, "vertical", 0), undefined: undefined(p)))
        case "filter.pixelate.mosaic": return AnyFilter(Mosaic(cellSize: clamp(f(p, "cellSize", 10), 2, 200)))
        case "filter.stylize.emboss":
            return AnyFilter(Emboss(angle: f(p, "angle", 135), height: clamp(f(p, "height", 3), 1, 100), amount: clamp(f(p, "amount", 100), 1, 500)))
        case "filter.stylize.findEdges": return AnyFilter(FindEdges())
        case "filter.stylize.solarize": return AnyFilter(Solarize())
        case "filter.distort.twirl": return AnyFilter(Twirl(angle: clamp(f(p, "angle", 50), -999, 999)))
        case "filter.distort.pinch": return AnyFilter(Pinch(amount: clamp(f(p, "amount", 50), -100, 100)))
        case "filter.distort.spherize":
            let mode: SpherizeMode = switch s(p, "mode", "normal") {
            case "horizontalOnly": .horizontalOnly
            case "verticalOnly": .verticalOnly
            default: .normal
            }
            return AnyFilter(Spherize(amount: clamp(f(p, "amount", 100), -100, 100), mode: mode))
        case "filter.distort.wave":
            let type: WaveType = switch s(p, "type", "sine") {
            case "triangle": .triangle
            case "square": .square
            default: .sine
            }
            return AnyFilter(Wave(generators: UInt32(min(max(i(p, "generators", 5), 1), 999)),
                                  wavelengthMin: clamp(f(p, "wavelengthMin", 10), 1, 998), wavelengthMax: clamp(f(p, "wavelengthMax", 120), 2, 999),
                                  amplitudeMin: clamp(f(p, "amplitudeMin", 5), 1, 998), amplitudeMax: clamp(f(p, "amplitudeMax", 35), 1, 999),
                                  waveType: type, undefined: undefined(p), seed: seed(p)))
        case "filter.distort.ripple":
            let size: RippleSize = switch s(p, "size", "medium") {
            case "small": .small
            case "large": .large
            default: .medium
            }
            return AnyFilter(Ripple(amount: clamp(f(p, "amount", 100), -999, 999), size: size))
        case "filter.distort.polarCoordinates":
            return AnyFilter(PolarCoordinates(mode: s(p, "mode", "rectangularToPolar") == "polarToRectangular" ? .polarToRectangular : .rectangularToPolar))
        default:
            return FiltersExtCommands.paramsFor(id, p)
        }
    }

    /// The filter's history-step name: a preset's own, else the filter's.
    static func label(_ id: String, _ f: AnyFilter) -> String { preset(id)?.0 ?? f.filter.label }

    /// Whether the filter's job is to make pixels transparent (photocraft `makes_transparency`).
    static func makesTransparency(_ f: AnyFilter) -> Bool { f.filter is ColorToAlpha }

    // MARK: Running a filter

    /// photocraft `has_filterable_layer`: a targeted channel, or a pixel layer / cached smart object.
    static let hasFilterableLayer: CommandEnabled = { s, _ in
        if Channels.editsChannel(s) { return nil }
        guard let d = s.active else { return "no document open" }
        guard let id = d.activeLayer, let l = d.doc.layer(id) else { return "no active layer" }
        switch l.content {
        case .raster: return nil
        case .smart(let sm) where sm.cache != nil: return nil
        default: return "filters need a pixel layer (active layer is \(l.content.article) \(l.content.kindName) layer)"
        }
    }

    /// Runs filter command `id` on the target (photocraft `run_filter`): validated params, then a
    /// background edit job (one undo step named after the filter).
    static func runFilter(_ s: Session, _ id: String, _ p0: JSONValue) throws -> JSONValue {
        try FilterValidation.validateParams(id, p0)
        let p = FiltersExtCommands.prepare(s, id, p0)
        guard var filter = paramsFor(id, p) else { throw EngineError.other("unknown filter \(id)") }
        try FiltersExtCommands.resolve(s, &filter, p)
        let layer: LayerId
        if let l = p["layer"]?.uint64Value {
            layer = LayerId(l)
        } else {
            guard let a = s.active?.activeLayer else { throw EngineError.other("no active layer") }
            layer = a
        }
        let label = label(id, filter)
        let params = p.removing("__kind")
        let ready = filter
        let services = s.services
        return try s.editJob(label, { doc, _, ctx -> AnyFilter in
            try apply(ready, id: id, params: params, layer: layer, label: label, to: &doc, ctx: ctx, services: services)
        }, finish: { f in ["layer": .id(layer), "filter": .encoded(f)] })
    }

    /// The document edit of `runFilter`: the targeted channel or mask, else the layer's pixels (a
    /// smart object records a smart filter, re-rendered from its source read through `services`).
    static func apply(_ f0: AnyFilter, id: String, params: JSONValue, layer: LayerId, label: String,
                      to doc: inout Document, ctx: JobContext, services: EngineServices? = nil) throws -> AnyFilter {
        let selection = doc.selection
        let selBounds = selection?.contentBounds
        let docBounds = doc.bounds
        let bounds = selBounds.flatMap { $0.isEmpty ? nil : $0 } ?? docBounds
        if Channels.targetOf(params) != .pixels {
            try Channels.withTargetSurface(&doc, layer: layer, params) { surf, _ in
                Channels.materialize(&surf, docBounds)
                let content = docBounds.union(surf.contentBounds)
                let area = outputArea(f0, content: content, bounds: bounds, selectionBounds: selBounds)
                try run(f0, on: &surf, area: area, bounds: bounds, selection: selection, extent: docBounds.union(content), ctx: ctx, label: label)
            }
            return f0
        }
        if makesTransparency(f0) { LayerOps.backgroundToLayer(&doc, layer) }
        guard let l = doc.layer(layer) else { throw EngineError.noLayer(layer) }
        let locks = doc.effectiveLocks(layer)
        if locks.pixels || locks.all {
            throw EngineError.other("Could not complete your request because the layer \"\(l.name)\" is locked")
        }
        if locks.transparency, makesTransparency(f0), case .raster = l.content {
            throw EngineError.other("Could not complete your request because the transparency of layer \"\(l.name)\" is locked")
        }
        var f = f0
        FiltersExtCommands.resolveInLayer(&f, l, bounds: bounds)
        switch l.content {
        case .raster:
            let ready = f
            try doc.withRaster(of: layer) { surf in
                let before = locks.transparency ? surf : nil
                let content = surf.contentBounds
                let area = outputArea(ready, content: content, bounds: bounds, selectionBounds: selBounds)
                try run(ready, on: &surf, area: area, bounds: bounds, selection: selection, extent: docBounds.union(content), ctx: ctx, label: label)
                if let before { keepAlpha(before, &surf) }
            }
            return f
        case .smart:
            let sf = SmartFilter(command: id, params: params, blend: .normal, opacity: 1, visible: true)
            try addSmartFilter(&doc, layer, sf, selection: selection, services: services)
            return f
        default:
            throw EngineError.other("not a pixel layer")
        }
    }

    /// photocraft `output_area`.
    static func outputArea(_ f: AnyFilter, content: PixelRect, bounds: PixelRect, selectionBounds: PixelRect?) -> PixelRect {
        FilterEngine.outputArea(f.filter, content: content, bounds: bounds, selectionBounds: selectionBounds)
    }

    /// Rows of `area` per cancellation check (whole-area filters run in one piece).
    static let bandHeight: Int32 = 1024

    /// Applies `f` to `area` of `surf` (photocraft `apply_in_with`): PCAlgo's tiled runner, in
    /// bands so a cancelled job stops between them. Each band reads the unfiltered pixels.
    static func run(_ f: AnyFilter, on surf: inout Surface, area: PixelRect, bounds: PixelRect, selection: Surface?, extent: PixelRect,
                    ctx: JobContext?, label: String) throws {
        let area = area.intersect(extent)
        if area.isEmpty { return }
        func go<F: Filter>(_ filter: F) throws {
            let whole = filter.halo(bounds: bounds) == .bounds || filter.processesWholeArea || area.height <= bandHeight
            if whole {
                try ctx?.check()
                try FilterEngine.apply(filter, to: &surf, area: area, bounds: bounds, selection: selection, extent: extent)
                ctx?.progress(1, label)
                return
            }
            let original = surf
            var y = area.y0
            while y < area.y1 {
                try ctx?.check()
                let band = PixelRect(x0: area.x0, y0: y, x1: area.x1, y1: min(y + bandHeight, area.y1))
                var work = original
                try FilterEngine.apply(filter, to: &work, area: band, bounds: bounds, selection: selection, extent: extent)
                surf.writeRegion(band, work.readRegion(band))
                y = band.y1
                ctx?.progress(Float(y - area.y0) / Float(area.height), label)
            }
            surf.prune()
        }
        do { try go(f.filter) } catch let e as EngineError { throw e } catch { throw EngineError.other("\(label): \(error)") }
    }

    /// Restores the alpha of every changed tile (a transparency-locked layer keeps its alpha).
    static func keepAlpha(_ old: Surface, _ new: inout Surface) {
        guard old.format == new.format, new.format.alpha else { return }
        var coords = Set<TileCoord>()
        new.forEachTile { c, t in if old.tile(c).map({ $0.generation != t.generation }) ?? true { coords.insert(c) } }
        old.forEachTile { c, _ in if new.tile(c) == nil { coords.insert(c) } }
        let n = new.channels
        for c in coords {
            let r = c.rect
            let o = old.readRegion(r)
            var v = new.readRegion(r)
            var k = n - 1
            while k < v.count { v[k] = o[k]; k += n }
            new.writeRegion(r, v)
        }
        new.prune()
    }

    // MARK: Smart filters

    /// The output of a recorded smart filter on `surf` (photocraft `apply_filter_to_surface`):
    /// warps and lens corrections through their modules, Image › Adjustments through the
    /// adjustment kernels, every other filter through `paramsFor`. nil for unknown ids. `fs` reads
    /// the filter's file inputs (Displace's map): the session's file service when a smart object
    /// re-renders in a session, else the local file system.
    static func applyFilterToSurface(_ id: String, _ params: JSONValue, _ surf: Surface, bounds: PixelRect, selection: Surface?,
                                     canvas: PixelRect, fs: (any FileSystemService)? = nil) -> Surface? {
        if let out = DistortCommands.applyToSurface(id, params, surf, canvas: canvas) { return out }
        if let out = LensCommands.applyToSurface(id, params, surf, canvas: canvas) { return out }
        if id.hasPrefix("image.adjustments.") {
            return AdjustCommands.adjustAsFilter(String(id.dropFirst("image.adjustments.".count)), params, surf)
        }
        guard var f = paramsFor(id, params) else { return nil }
        guard (try? FiltersExtCommands.resolveMapPath(&f, params, fs: fs ?? LocalFileSystem())) != nil else { return nil }
        let content = surf.contentBounds
        let area = outputArea(f, content: content, bounds: bounds, selectionBounds: selection?.contentBounds)
        var out = surf
        guard (try? run(f, on: &out, area: area, bounds: bounds, selection: selection, extent: canvas.union(content), ctx: nil, label: f.filter.label)) != nil else {
            return nil
        }
        return out
    }

    /// Appends a smart filter to smart object `id` (photocraft `smart_cmds::add_smart_filter`): with
    /// a renderable source the selection becomes the filter mask and the object re-renders from
    /// its source; without one the filter runs on the cached pixels (through the selection) and
    /// is recorded. Callers with a session pass its `services` (linked files are read through its
    /// file service); without them only sources held in memory re-render.
    static func addSmartFilter(_ doc: inout Document, _ id: LayerId, _ sf: SmartFilter, selection: Surface?,
                               services: EngineServices? = nil) throws {
        try SmartCommands.addSmartFilter(&doc, id, sf, selection: selection, services: services)
    }

    // MARK: Last Filter

    /// The most recent filter command in the journal, without its `layer` (photocraft `last_filter`).
    static func lastFilter(_ s: Session) -> (String, JSONValue)? {
        guard let inv = s.journal.last(where: { $0.id.hasPrefix("filter.") && paramsFor($0.id, .null) != nil }) else { return nil }
        return (inv.id, inv.params.removing("layer"))
    }

    // MARK: Specs

    static func filterCmd(_ id: String, _ label: String, _ menu: [String], _ params: String) -> CommandSpec {
        CommandSpec(id, label, menu: menu, params: params, module: name, enabled: hasFilterableLayer) { s, p in
            try runFilter(s, id, p)
        }
    }

    static func specs() -> [CommandSpec] {
        [
            filterCmd("filter.blur.gaussianBlur", "Gaussian Blur…", ["Filter", "Blur"], ##"{"radius":0.1..1000=1}"##),
            filterCmd("filter.blur.blur", "Blur", ["Filter", "Blur"], "{}"),
            filterCmd("filter.blur.blurMore", "Blur More", ["Filter", "Blur"], "{}"),
            filterCmd("filter.sharpen.sharpen", "Sharpen", ["Filter", "Sharpen"], "{}"),
            filterCmd("filter.sharpen.sharpenMore", "Sharpen More", ["Filter", "Sharpen"], "{}"),
            filterCmd("filter.sharpen.sharpenEdges", "Sharpen Edges", ["Filter", "Sharpen"], "{}"),
            filterCmd("filter.noise.despeckle", "Despeckle", ["Filter", "Noise"], "{}"),
            filterCmd("filter.blur.boxBlur", "Box Blur…", ["Filter", "Blur"], ##"{"radius":1..2000=1}"##),
            filterCmd("filter.blur.motionBlur", "Motion Blur…", ["Filter", "Blur"], ##"{"angle":-360..360=0,"distance":1..2000=10}"##),
            filterCmd("filter.blur.radialBlur", "Radial Blur…", ["Filter", "Blur"],
                      ##"{"amount":1..100=10,"method":"spin|zoom","quality":"draft|good|best"="good","centerX":0..1=0.5,"centerY":0..1=0.5}"##),
            filterCmd("filter.blur.surfaceBlur", "Surface Blur…", ["Filter", "Blur"], ##"{"radius":1..100=5,"threshold":2..255=15}"##),
            filterCmd("filter.sharpen.unsharpMask", "Unsharp Mask…", ["Filter", "Sharpen"], ##"{"amount":1..500=50,"radius":0.1..1000=1,"threshold":0..255=0}"##),
            filterCmd("filter.sharpen.smartSharpen", "Smart Sharpen…", ["Filter", "Sharpen"], ##"{"amount":1..500=100,"radius":0.1..64=1,"reduceNoise":0..100=10}"##),
            filterCmd("filter.noise.addNoise", "Add Noise…", ["Filter", "Noise"],
                      ##"{"amount":0.1..400=12.5,"distribution":"uniform|gaussian","monochromatic":bool,"seed":u32=0}"##),
            filterCmd("filter.noise.median", "Median…", ["Filter", "Noise"], ##"{"radius":1..500=1}"##),
            filterCmd("filter.noise.dustAndScratches", "Dust & Scratches…", ["Filter", "Noise"], ##"{"radius":1..500=1,"threshold":0..255=0}"##),
            filterCmd("filter.pixelate.mosaic", "Mosaic…", ["Filter", "Pixelate"], ##"{"cellSize":2..200=10}"##),
            filterCmd("filter.stylize.emboss", "Emboss…", ["Filter", "Stylize"], ##"{"angle":-180..180=135,"height":1..100=3,"amount":1..500=100}"##),
            filterCmd("filter.stylize.findEdges", "Find Edges", ["Filter", "Stylize"], "{}"),
            filterCmd("filter.stylize.solarize", "Solarize", ["Filter", "Stylize"], "{}"),
            filterCmd("filter.distort.twirl", "Twirl…", ["Filter", "Distort"], ##"{"angle":-999..999=50}"##),
            filterCmd("filter.distort.pinch", "Pinch…", ["Filter", "Distort"], ##"{"amount":-100..100=50}"##),
            filterCmd("filter.distort.spherize", "Spherize…", ["Filter", "Distort"], ##"{"amount":-100..100=100,"mode":"normal|horizontalOnly|verticalOnly"}"##),
            filterCmd("filter.distort.wave", "Wave…", ["Filter", "Distort"],
                      ##"{"generators":1..999=5,"wavelengthMin":1..998=10,"wavelengthMax":2..999=120,"amplitudeMin":1..998=5,"amplitudeMax":1..999=35,"type":"sine|triangle|square","undefinedAreas":"wrap|repeat","seed":u32=0}"##),
            filterCmd("filter.distort.ripple", "Ripple…", ["Filter", "Distort"], ##"{"amount":-999..999=100,"size":"small|medium|large"}"##),
            filterCmd("filter.distort.polarCoordinates", "Polar Coordinates…", ["Filter", "Distort"], ##"{"mode":"rectangularToPolar|polarToRectangular"}"##),
            filterCmd("filter.other.highPass", "High Pass…", ["Filter", "Other"], ##"{"radius":0.1..1000=10}"##),
            filterCmd("filter.other.minimum", "Minimum…", ["Filter", "Other"], ##"{"radius":0.2..500=1,"preserve":"squareness|roundness"}"##),
            filterCmd("filter.other.maximum", "Maximum…", ["Filter", "Other"], ##"{"radius":0.2..500=1,"preserve":"squareness|roundness"}"##),
            filterCmd("filter.other.offset", "Offset…", ["Filter", "Other"], ##"{"horizontal":px=0,"vertical":px=0,"undefinedAreas":"wrap|repeat|transparent"}"##),
            CommandSpec("filter.lastFilter", "Last Filter", menu: ["Filter"], shortcut: "Cmd+Alt+F", params: "{}", module: name, enabled: { s, p in
                if let why = hasFilterableLayer(s, p) { return why }
                return lastFilter(s) == nil ? "no filter applied yet" : nil
            }) { s, _ in
                guard let (id, params) = lastFilter(s) else { throw EngineError.other("no filter applied yet") }
                return try runFilter(s, id, params)
            },
        ]
    }
}
