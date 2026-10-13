// Port of photocraft-engine (crates/engine/src/smartselect_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Smart selection commands: Quick Selection, Select and Mask (Refine Edge) and Focus Area. The
// algorithms are PCAlgo's (`QuickSelection`, `FocusArea`, `Matting`, `EdgeBrush`); these commands
// pick the pixels to analyse (the active layer or the composite), run them, and store the result
// as the selection (or a mask / new layer / new document). Select › Subject and Object Selection
// are registered by the AI tier (PCIntelligence's bridge), not by this module.

import PCAlgo
import PCDocument
import PCFoundation

enum SmartSelectCommands: CommandModule {
    static let name = "smartselect_cmds"
    static let m = "smartselect_cmds"

    // MARK: Preconditions and params

    static let hasDoc: CommandEnabled = { s, _ in s.active == nil ? "no document open" : nil }

    static let hasSelectionOrMask: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        if d.doc.selection != nil { return nil }
        if let id = d.activeLayer, d.doc.layer(id)?.mask != nil { return nil }
        return "no selection or layer mask"
    }

    static func f(_ p: JSONValue, _ k: String, _ d: Float) -> Float { p[k]?.doubleValue.map { Float($0) } ?? d }
    static func b(_ p: JSONValue, _ k: String, _ d: Bool) -> Bool { p[k]?.boolValue ?? d }
    /// Rust `f32::clamp`.
    static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { v < lo ? lo : (v > hi ? hi : v) }

    static func mode(_ p: JSONValue, _ fallback: String) -> SelectionMode {
        let m = p["mode"]?.stringValue ?? fallback
        return SelectionMode.parse(m == "new" ? "replace" : m)
    }

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }

    // MARK: Samplers

    /// Composite of all visible layers (photocraft `CompositeSampler`): straight RGBA from the
    /// engine's renderer; a region that fails to composite reads as transparent.
    struct CompositeSampler: SegmentSampler {
        let doc: Document
        let renderer: EngineRenderer

        func rgba(_ r: PixelRect) -> [SIMD4<Float>] {
            if r.isEmpty { return [] }
            guard let px = try? renderer.render(doc, region: r).px, px.count == r.area else {
                return [SIMD4<Float>](repeating: .zero, count: r.area)
            }
            return px
        }
    }

    /// A sampler over `layer`'s pixels in `doc`, or the composite with `allLayers` (or when the
    /// layer has no pixels) — photocraft `with_doc_sampler`.
    static func docSampler(_ doc: Document, _ layer: LayerId?, allLayers: Bool, renderer: EngineRenderer) -> any SegmentSampler {
        if !allLayers, let surf = layer.flatMap({ doc.layer($0) })?.surface { return SurfaceSegmentSampler(surf) }
        return CompositeSampler(doc: doc, renderer: renderer)
    }

    /// Runs `f` with a sampler over the active layer (or the composite) and the active document.
    static func withSampler<R>(_ s: Session, _ allLayers: Bool, _ f: (any SegmentSampler, Document) throws -> R) throws -> R {
        guard let d = s.active else { throw EngineError.noDocument }
        return try f(docSampler(d.doc, d.activeLayer, allLayers: allLayers, renderer: s.services.renderer), d.doc)
    }

    /// Stores `region` combined with the current selection by `m` as one history step. Finding
    /// nothing never destroys work: the selection (and history) is left alone and the caller gets
    /// `changed: false`, whatever the mode.
    static func apply(_ s: Session, _ label: String, _ region: SelectionRegion?, _ m: SelectionMode) throws -> JSONValue {
        guard let region else {
            guard let d = s.active else { throw EngineError.noDocument }
            return ["selected": .bool(d.doc.selection != nil), "changed": false]
        }
        let selected = try s.edit(label) { doc, _ in
            doc.selection = Selection.combineRegion(doc.selection, region, mode: m)
            return doc.selection != nil
        }
        return ["selected": .bool(selected), "changed": true, "bounds": .rect(region.bbox)]
    }

    static func points(_ p: JSONValue) -> [SIMD2<Float>] {
        (p["points"]?.arrayValue ?? []).compactMap { q in
            guard let a = q.arrayValue, a.count >= 2, let x = a[0].doubleValue, let y = a[1].doubleValue else { return nil }
            return SIMD2(Float(x), Float(y))
        }
    }

    // MARK: Quick Selection

    /// Auto-Enhance for Quick Selection: a light edge refinement that flows the edge towards
    /// image edges and removes blockiness.
    static let enhance = RefineParams(radius: 4, smartRadius: true, smooth: 15, feather: 0, contrast: 25, shiftEdge: 0)

    static func quickSelection(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let pts = points(p)
        if pts.isEmpty { throw bad("select.quick", "needs at least one point") }
        let size = clamp(f(p, "size", 30), 1, 5000)
        let m: SelectionMode
        switch p["mode"]?.stringValue ?? "add" {
        case "subtract": m = .subtract
        case "replace", "new": m = .replace
        default: m = .add
        }
        let enhanceEdge = b(p, "enhanceEdge", false)
        let region = try withSampler(s, b(p, "sampleAllLayers", false)) { smp, doc -> SelectionRegion? in
            let canvas = doc.bounds
            guard let r = QuickSelection.quickSelect(smp, canvas: canvas, points: pts, size: size) else { return nil }
            return enhanceEdge ? Matting.refineMask(smp, mask: Matting.regionReader(r), content: r.bbox, canvas: canvas, enhance) : r
        }
        return try apply(s, "Quick Selection", region, m)
    }

    // MARK: Focus Area

    static func focusArea(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let range = clamp(f(p, "range", 0.5), 0, 1), noise = clamp(f(p, "noise", 0), 0, 1)
        let region = try withSampler(s, b(p, "sampleAllLayers", true)) { smp, doc in
            FocusArea.select(smp, canvas: doc.bounds, range: range, noise: noise)
        }
        return try apply(s, "Focus Area", region, mode(p, "replace"))
    }

    // MARK: Select and Mask

    static func refineParams(_ p: JSONValue) -> RefineParams {
        RefineParams(radius: clamp(f(p, "radius", 0), 0, 250), smartRadius: b(p, "smartRadius", false), smooth: clamp(f(p, "smooth", 0), 0, 100),
                     feather: clamp(f(p, "feather", 0), 0, 1000), contrast: clamp(f(p, "contrast", 0), 0, 100),
                     shiftEdge: clamp(f(p, "shiftEdge", 0), -100, 100))
    }

    /// Most Refine Edge Brush strokes, and points across them, one Select and Mask takes.
    static let maxStrokes = 4096
    static let maxStrokePoints = 100_000

    /// Rust's `{}` of an `f32` (`1`, `5000`, `0.5`).
    static func display(_ v: Float) -> String { v == v.rounded() && abs(v) < 1e15 ? "\(Int64(v))" : "\(v)" }

    /// The Refine Edge Brush strokes of `refineStrokes`:
    /// `[{"points":[[x,y],…],"size":px,"mode":"add|subtract"}]`, in painting order.
    static func refineStrokes(_ p: JSONValue) throws -> [EdgeStroke] {
        let cmd = "select.refineEdge"
        guard let v = p["refineStrokes"], v != .null else { return [] }
        guard let list = v.arrayValue else { throw bad(cmd, "refineStrokes must be an array of strokes") }
        if list.count > maxStrokes { throw bad(cmd, "refineStrokes holds more than \(maxStrokes) strokes") }
        var total = 0
        var strokes: [EdgeStroke] = []
        strokes.reserveCapacity(list.count)
        for stroke in list {
            guard let o = stroke.objectValue else {
                throw bad(cmd, #"each refineStrokes entry must be {"points":[[x,y],…],"size":px,"mode":"add|subtract"}"#)
            }
            guard let pts = o["points"]?.arrayValue, !pts.isEmpty else { throw bad(cmd, "each stroke needs a non-empty points array") }
            total = total.addingReportingOverflow(pts.count).overflow ? Int.max : total + pts.count
            if total > maxStrokePoints { throw bad(cmd, "refineStrokes holds more than \(maxStrokePoints) points") }
            var points: [SIMD2<Float>] = []
            points.reserveCapacity(pts.count)
            for pt in pts {
                let ok = { (v: Double) in v.isFinite && abs(v) <= 1e7 }
                guard let xy = pt.arrayValue, xy.count == 2, let x = xy[0].doubleValue, let y = xy[1].doubleValue, ok(x), ok(y) else {
                    throw bad(cmd, "stroke points must be [x,y] pairs of finite numbers")
                }
                points.append(SIMD2(Float(x), Float(y)))
            }
            let range = EdgeBrush.sizeRange
            let size: Float
            if let sv = o["size"] {
                guard let s = sv.doubleValue, s.isFinite, s >= Double(range.lowerBound), s <= Double(range.upperBound) else {
                    throw bad(cmd, "stroke size must be \(display(range.lowerBound))..\(display(range.upperBound)) px")
                }
                size = Float(s)
            } else {
                size = 30
            }
            let add: Bool
            switch o["mode"] {
            case nil: add = true
            case .some(let mv):
                switch mv.stringValue {
                case "add": add = true
                case "subtract": add = false
                default: throw bad(cmd, "stroke mode must be add|subtract")
                }
            }
            strokes.append(EdgeStroke(points: points, size: size, add: add))
        }
        if EdgeBrush.sweptArea(strokes) > EdgeBrush.maxSweptArea { throw bad(cmd, "refineStrokes paint too large an area") }
        return strokes
    }

    static let outputs = ["selection", "layerMask", "newLayer", "newLayerWithMask", "newDocument", "newDocumentWithMask"]

    /// Select and Mask: refines the selection edge, then outputs to the selection, a layer mask on
    /// the active layer, a new layer or a new document (each with or without a mask).
    /// Decontaminating colours needs new pixels, so it upgrades `selection` / `layerMask` output
    /// to `newLayerWithMask` (as Photoshop does). New-layer outputs hide the source layer;
    /// new-document outputs leave the source document untouched.
    static func refineEdge(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let params = refineParams(p)
        let strokes = try refineStrokes(p)
        let decontaminate = b(p, "decontaminate", false)
        let amount = clamp(f(p, "amount", 100), 0, 100)
        guard let d0 = s.active else { throw EngineError.noDocument }
        let active0 = d0.activeLayer.flatMap { d0.doc.layer($0) != nil ? $0 : nil }
        let defaultOutput = d0.doc.selection == nil && active0.flatMap({ d0.doc.layer($0)?.mask }) != nil ? "layerMask" : "selection"
        var output = p["output"]?.stringValue ?? defaultOutput
        if !outputs.contains(output) {
            throw bad("select.refineEdge", "output must be selection|layerMask|newLayer|newLayerWithMask|newDocument|newDocumentWithMask")
        }
        if decontaminate && (output == "selection" || output == "layerMask") { output = "newLayerWithMask" }
        let region = try withSampler(s, b(p, "sampleAllLayers", false)) { smp, doc -> SelectionRegion? in
            let maskSurf = active0.flatMap { doc.layer($0)?.mask?.surface }
            guard let sel = doc.selection ?? maskSurf else { return nil }
            let brush = EdgeBrush(strokes, canvas: doc.bounds)
            return Matting.refineMaskBrushed(smp, mask: Matting.surfaceReader(sel), content: sel.contentBounds, canvas: doc.bounds, params, brush: brush)
        }
        guard let d = s.active else { throw EngineError.noDocument }
        let active = d.activeLayer.flatMap { d.doc.layer($0) != nil ? $0 : nil }
        switch output {
        case "selection":
            let selected = try s.edit("Select and Mask") { doc, _ in
                doc.selection = region.map(Matting.regionSurface)
                return doc.selection != nil
            }
            return ["output": .string(output), "selected": .bool(selected)]
        case "layerMask":
            guard let id = active else { throw EngineError.other("no active layer") }
            try s.edit("Select and Mask") { doc, _ in
                let surface = region.map(Matting.regionSurface) ?? Surface(format: .gray8)
                guard doc.updateLayer(id, { $0.mask = LayerMask(surface: surface) }) != nil else { throw EngineError.noLayer(id) }
                doc.selection = nil
            }
            return ["output": .string(output), "layer": .id(id), "selected": false]
        default:
            guard let id = active else { throw EngineError.other("no active layer") }
            guard let srcLayer = d.doc.layer(id) else { throw EngineError.noLayer(id) }
            guard let src = srcLayer.surface else {
                throw EngineError.other("the active layer is \(srcLayer.content.article) \(srcLayer.content.kindName) layer without pixels")
            }
            let name = d.doc.copyName(srcLayer.name)
            let reg = region ?? SelectionRegion(bbox: .empty, mask: [])
            let pixels = decontaminate ? Matting.decontaminate(src, alpha: reg, radius: params.radius, amount: amount) : src
            let withMask = output == "newLayerWithMask" || output == "newDocumentWithMask"
            let content = withMask ? pixels : Matting.maskedCopy(pixels, alpha: reg)
            let mask = withMask ? LayerMask(surface: Matting.regionSurface(reg)) : nil
            if output.hasPrefix("newDocument") {
                // Same canvas, colour mode, depth and profile, so the pixels need no conversion.
                var doc = Document(name: "Untitled", size: d.doc.size, mode: d.doc.mode, depth: d.doc.depth)
                doc.resolutionDpi = d.doc.resolutionDpi
                doc.iccProfile = d.doc.iccProfile
                doc.colorTable = d.doc.colorTable
                doc.duotone = d.doc.duotone
                var layer = Layer(name: srcLayer.name, content: .raster(content))
                layer.mask = mask
                let layerId = layer.id
                doc.layers.append(layer)
                let i = s.addDocument(doc)
                return ["output": .string(output), "document": .int(i), "layer": .id(layerId), "selected": false]
            }
            let newId = try s.edit("Select and Mask") { doc, act in
                var layer = Layer(name: name, content: .raster(content))
                layer.mask = mask
                let nid = doc.insertAbove(id, layer)
                _ = doc.updateLayer(id) { $0.visible = false }
                doc.selection = nil
                act = nid
                return nid
            }
            return ["output": .string(output), "layer": .id(newId), "selected": false]
        }
    }

    // MARK: Registration

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("select.quick", "Quick Selection",
                          params: ##"{"points":[[x,y],…],"size":px=30,"mode":"add|subtract|replace"="add","sampleAllLayers":bool=false,"enhanceEdge":bool=false}"##,
                          module: m, enabled: hasDoc, run: quickSelection))
        r.add(CommandSpec("select.refineEdge", "Refine Edge",
                          params: ##"{"radius":px=0,"smartRadius":bool=false,"smooth":0..100=0,"feather":px=0,"contrast":0..100=0,"shiftEdge":-100..100=0,"decontaminate":bool=false,"amount":0..100=100,"output":"selection|layerMask|newLayer|newLayerWithMask|newDocument|newDocumentWithMask"="selection","sampleAllLayers":bool=false,"refineStrokes":[{"points":[[x,y],…],"size":px=30,"mode":"add|subtract"="add"},…]=[]} (refineStrokes: the Refine Edge Brush, in painting order: add refines the painted area from the image, subtract keeps the original edge there)"##,
                          module: m, enabled: hasSelectionOrMask, run: refineEdge))
        r.add(CommandSpec("select.focusArea", "Focus Area…", menu: ["Select"],
                          params: ##"{"range":0..1=0.5,"noise":0..1=0,"sampleAllLayers":bool=true,"mode":"replace|add|subtract|intersect"="replace"}"##,
                          module: m, enabled: hasDoc, run: focusArea))
    }
}
