// Port of photocraft-engine (crates/engine/src/file_cmds.rs: Automate — Fit Image, Conditional Mode Change, Batch, `batch_inputs`, `process_files`, `OutputClaims`; Scripts — Image Processor, Load Files into Stack; and smart_cmds.rs `layers_to_smart` for the stacked smart object), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// File › Automate and File › Scripts items that open files, run commands on them and save them.
// Each input opens in a scratch session (default preferences, the caller's registry, services —
// so the automation layer's file sandbox holds — and command gate), is processed and saved into the
// output folder; errors are collected per file. Every nested command runs through
// `Session.execute`, so `Session.authorize` sees it.

import Foundation
import PCAlgo
import PCDocument
import PCFoundation
import PCRender

extension FileCommands {
    // MARK: Fit Image

    static func fitImage(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let (w, h) = (Double(d.doc.size.width), Double(d.doc.size.height))
        let bw = max(f64Param(p, "width") ?? w, 1)
        let bh = max(f64Param(p, "height") ?? h, 1)
        let k = min(bw / w, bh / h)
        if (k > 1 && (p["dontEnlarge"]?.boolValue ?? false)) || ((w * k).rounded() == w && (h * k).rounded() == h) {
            return ["width": .number(w), "height": .number(h), "changed": false]
        }
        let (nw, nh) = (max((w * k).rounded(), 1), max((h * k).rounded(), 1))
        let resample = p["resample"]?.stringValue ?? "bicubic"
        try s.execute("image.imageSize", ["width": .number(nw), "height": .number(nh), "resample": .string(resample)])
        return ["width": .number(nw), "height": .number(nh), "changed": true]
    }

    // MARK: Conditional Mode Change

    static func modeName(_ m: ColorMode) -> String {
        switch m {
        case .bitmap: "bitmap"
        case .grayscale: "grayscale"
        case .duotone: "duotone"
        case .indexed: "indexed"
        case .rgb: "rgb"
        case .cmyk: "cmyk"
        case .lab: "lab"
        case .multichannel: "multichannel"
        }
    }

    static func conditionalModeChange(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.automate.conditionalModeChange"
        let to: String
        switch try strParam(p, "to", cmd).lowercased() {
        case "gray", "grayscale": to = "grayscale"
        case "rgb": to = "rgb"
        case "cmyk": to = "cmyk"
        case "lab": to = "lab"
        case let other: throw EngineError.bad(cmd, "unsupported target mode \"\(other)\" (rgb, grayscale, cmyk, lab)")
        }
        guard let d = s.active else { throw EngineError.noDocument }
        let cur = modeName(d.doc.mode)
        let from: [String]
        switch p["from"] {
        case .array(let a)?:
            from = a.compactMap(\.stringValue).map {
                $0.lowercased().replacingOccurrences(of: "gray", with: "grayscale").replacingOccurrences(of: "grayscalescale", with: "grayscale")
            }
        case .string(let v)? where v != "any": from = [v.lowercased()]
        default: from = ["any"]
        }
        if cur == to || !from.contains(where: { $0 == "any" || $0 == cur }) { return ["changed": false, "mode": .string(cur)] }
        try s.execute("image.mode.\(to)")
        return ["changed": true, "mode": .string(to)]
    }

    // MARK: Batch

    /// One `[id, params]` / `{command, params}` / `{id, params}` step of an action.
    static func parseBatchSteps(_ v: JSONValue) throws -> [CommandInvocation] {
        func bad(_ m: String) -> EngineError { .bad("file.automate.batch", m) }
        guard let arr = v.arrayValue else { throw bad(#""steps" must be an array"#) }
        return try arr.map { st in
            switch st {
            case .array(let a) where !a.isEmpty:
                guard let id = a[0].stringValue else { throw bad("step id must be a string") }
                return CommandInvocation(id, a.count > 1 ? a[1] : .object([:]))
            case .object(let o):
                guard let id = (o["command"] ?? o["id"])?.stringValue else { throw bad(#"step needs "command""#) }
                return CommandInvocation(id, o["params"] ?? .object([:]))
            case .string(let id):
                return CommandInvocation(id, .object([:]))
            default:
                throw bad(#"each step is [id, params] or {"command", "params"}"#)
            }
        }
    }

    /// Inputs of a batch command: `"input"` is a folder or an array of files (photocraft
    /// `batch_inputs`).
    static func batchInputs(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> [String] {
        switch p["input"] ?? p["files"] {
        case .array(let a)?: return a.compactMap(\.stringValue)
        case .string(let dir)?: return try listImages(s, dir)
        default: throw EngineError.bad(cmd, #"missing "input" (folder or array of files)"#)
        }
    }

    /// The output paths a batch run has written, so a later input whose output name matches an
    /// earlier one's (`a.png` and `a.jpg` saved as JPEG, or the same name in two input folders) is
    /// reported instead of silently replacing that result (#420, #422). Names are compared
    /// ignoring case, because macOS and Windows file systems do (photocraft `OutputClaims`).
    public struct OutputClaims: Sendable {
        var claims: [String: String] = [:]

        public init() {}

        /// The error (naming the earlier input) when `out` was already written in this run.
        public func check(_ out: String) -> String? {
            claims[out.lowercased()].map { "not written: \(out) already holds the result of \($0) from this run (same output name)" }
        }

        /// Remember that `input`'s result was written to `out`.
        public mutating func record(_ out: String, _ input: String) { claims[out.lowercased()] = input }
    }

    /// A session to process one batch file in (photocraft's `Session::new()`, so default
    /// preferences and no script events): the caller's registry, its services — the automation
    /// layer's file sandbox holds — and its command gate.
    static func scratchSession(_ s: Session) -> Session {
        let t = Session(registry: s.registry, services: s.services)
        t.authorize = s.authorize
        return t
    }

    /// Opens each input in a scratch session, runs `f` on it and saves it to `output` as `format`
    /// (`"same"` keeps the input's extension). Errors per file are collected, not fatal
    /// (photocraft `process_files`).
    static func processFiles(_ s: Session, _ inputs: [String], output: String, format: String, save: SaveOpts, suffix: String,
                             _ f: (Session) throws -> Void) -> JSONValue {
        var files: [String] = []
        var errors: [JSONValue] = []
        var written = OutputClaims()
        for path in inputs {
            var fmt = Substring(format)
            while fmt.hasPrefix(".") { fmt = fmt.dropFirst() }
            let ext = format == "same" ? (path.components(separatedBy: ".").last ?? "png").lowercased() : fmt.lowercased()
            let out = join(output, "\(stem(path))\(suffix).\(ext)")
            do {
                if let e = written.check(out) { throw EngineError.other(e) }
                let bytes = try readFile(s, path)
                let scratch = scratchSession(s)
                let doc = try `import`(s, fileName(path), bytes)
                scratch.addDocument(doc, path: path)
                try f(scratch)
                guard let d = scratch.active else { throw EngineError.noDocument }
                try saveDoc(s, d.doc, out, save)
                written.record(out, path)
                files.append(out)
            } catch {
                errors.append(["file": .string(path), "error": .string(EngineError.wrap(error).description)])
            }
        }
        return ["files": .strings(files), "errors": .array(errors)]
    }

    static func batch(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.automate.batch"
        guard let stepsValue = p["steps"] ?? p["action"] else { throw EngineError.bad(cmd, #"missing "steps""#) }
        var steps = try parseBatchSteps(stepsValue)
        // Each result goes to the destination folder, which overrides the action's recorded Save /
        // Save As steps (Photoshop's "Override Action 'Save As' Commands"). Recorded view steps
        // (zoom, fit) don't change the output, so they are skipped (#2752).
        steps.removeAll { ActionsCommands.shellSaveCommand($0.id) || ActionsCommands.shellViewCommand($0.id) }
        if let unknown = steps.first(where: { s.registry.spec($0.id) == nil }) {
            throw EngineError.bad(cmd, "unknown command `\(unknown.id)` in the action")
        }
        let inputs = try batchInputs(s, p, cmd)
        let output = try strParam(p, "output", cmd)
        let format = p["format"]?.stringValue ?? "same"
        // Steps that call another action play it from the caller's actions; the playback stack
        // comes along so an action that batches itself is caught as a recursive call.
        let current = ActionsCommands.state(s)
        let list: [ActionsCommands.Action]
        switch p["calledActions"] {
        case nil, .null?:
            list = current.list
        case let v?:
            // A droplet brings the actions it calls (#2794) and runs with those alone.
            do { list = try v.decode(as: [ActionsCommands.Action].self) } catch {
                throw EngineError.bad(cmd, #""calledActions": \#(error)"#)
            }
            if list.count > 4096 { throw EngineError.bad(cmd, #""calledActions" holds more than 4096 actions"#) }
        }
        var actions = ActionsCommands.ActionState(list: list)
        actions.playing = current.playing
        actions.playbackStack = current.playbackStack
        let save = try SaveOpts.from(s, p, cmd)
        let run = steps
        let state = actions
        return processFiles(s, inputs, output: output, format: format, save: save, suffix: "") { scratch in
            scratch.state[ActionsCommands.ActionStateKey.self] = state
            for step in run {
                let r = try scratch.execute(step.id, step.params)
                // A failed step inside a called action makes this file an error, not a saved result.
                if let error = ActionsCommands.nestedFailure(step.id, r) { throw EngineError.other(error) }
            }
        }
    }

    // MARK: Image Processor

    static func imageProcessor(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.scripts.imageProcessor"
        let inputs = try batchInputs(s, p, cmd)
        let output = try strParam(p, "output", cmd)
        let format = p["format"]?.stringValue ?? "jpg"
        let w = sizeParam(p, "width"), h = sizeParam(p, "height")
        let fit: JSONValue? = w == nil && h == nil ? nil : ["width": .number(w ?? 1e9), "height": .number(h ?? 1e9), "dontEnlarge": true]
        let toSRGB = p["convertToSrgb"]?.boolValue ?? false
        var save = try SaveOpts.from(s, p, cmd)
        if save.quality == nil { save.quality = 8 }
        return processFiles(s, inputs, output: output, format: format, save: save, suffix: "") { scratch in
            if toSRGB, let d = scratch.active, d.doc.mode != .rgb { try scratch.execute("image.mode.rgb") }
            if let fp = fit { _ = try fitImage(scratch, fp) }
        }
    }

    // MARK: Load Files into Stack

    static func loadFilesIntoStack(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.scripts.loadFilesIntoStack"
        let paths: [String]
        switch p["paths"] ?? p["input"] {
        case .array(let a)?: paths = a.compactMap(\.stringValue)
        case .string(let dir)?: paths = try listImages(s, dir)
        default: throw EngineError.bad(cmd, #"missing "paths""#)
        }
        guard let firstPath = paths.first else { throw EngineError.bad(cmd, "no files to load") }
        var docs: [(String, Document)] = []
        for path in paths {
            let bytes = try readFile(s, path)
            docs.append((fileName(path), try `import`(s, fileName(path), bytes)))
        }
        let first = docs[0].1
        let w = docs.map(\.1.size.width).max() ?? 1, h = docs.map(\.1.size.height).max() ?? 1
        var stack = Document(name: stem(firstPath), size: PixelSize(width: w, height: h), mode: first.mode, depth: first.depth)
        stack.resolutionDpi = first.resolutionDpi
        stack.iccProfile = first.iccProfile
        let fmt = stack.pixelFormat
        // First file at the bottom, like Photoshop's script.
        for (name, d) in docs { stack.layers.append(Layer(name: name, content: .raster(try flattened(s, d, fmt)))) }
        let n = stack.layers.count
        if p["createSmartObject"]?.boolValue ?? false {
            // "Create Smart Object after Loading Layers": the layers go inside one smart object,
            // ready for Layer › Smart Objects › Stack Mode. Like Photoshop, they sit at the top
            // level of the contents, with no wrapper group.
            let layers = stack.layers
            stack.layers = []
            stack.layers = [try layersToSmart(s, stack, stem(firstPath), layers)]
        }
        let i = s.addDocument(stack)
        return ["document": .int(i), "layers": .int(n)]
    }

    // MARK: Layers to a smart object

    /// A smart-object layer named `name` whose nested document holds `layers` (bottom to top) at
    /// its top level, with no wrapper group (photocraft `smart_cmds::layers_to_smart`, used by Load
    /// Files into Stack and Statistics), with the session's file service.
    static func layersToSmart(_ s: Session, _ doc: Document, _ name: String, _ layers: [Layer]) throws -> Layer {
        try SmartCommands.layersToSmart(doc, name, layers, services: s.services)
    }

    // MARK: Flatten All Layer Effects / Masks

    /// PSD layer blocks that no longer describe a layer once its content is baked to pixels.
    static let effectBakedKeys: [PSDKey] = ["TySh", "SoLd", "PlLd", "SoLE", "vmsk", "vsms", "vogk", "vscg", "vstk"]
    /// PSD vector-mask blocks.
    static let vectorMaskKeys: [PSDKey] = ["vmsk", "vsms"]

    static func hasLiveEffects(_ l: Layer) -> Bool { l.effects.enabled && l.effects.items.contains { $0.isEnabled } }

    /// The layer rendered alone (keeping what `keepEffects` says), as a surface in `fmt`. With
    /// `applyMask` off the layer's pixel and vector masks are left out of the render, so a caller
    /// that keeps them live on the baked raster does not mask the pixels twice (photocraft `bake`).
    static func bake(_ s: Session, _ doc: Document, _ l: Layer, _ fmt: PixelFormat, keepEffects: Bool, applyMask: Bool) throws -> Surface {
        var tmp = l
        tmp.opacity = 1
        tmp.blend = .normal
        tmp.visible = true
        tmp.clipped = false
        if !keepEffects {
            tmp.effects.items.removeAll()
            tmp.fillOpacity = 1
        }
        if !applyMask {
            tmp.mask = nil
            tmp.vectorMask = nil
        }
        // Render over the union of the canvas and the content so off-canvas pixels survive.
        let canvas = doc.bounds
        var area = l.surface.map { $0.contentBounds.union(canvas) } ?? canvas
        if keepEffects { area = area.outset(by: 256) }
        var px = Surface(format: fmt)
        if !area.isEmpty {
            var solo = doc
            solo.layers = [tmp]
            solo.selection = nil
            let buf = try s.services.renderer.render(solo, region: area)
            if buf.px.count == area.width * area.height { px.writeRegion(area, PixelCodec.fromRGBA(fmt, rgba: buf.px)) }
        }
        px.prune()
        return px
    }

    static func flattenAllEffects(_ s: Session) throws -> JSONValue {
        var n = 0
        try s.edit("Flatten All Layer Effects") { doc, _ in
            let fmt = doc.pixelFormat
            for id in doc.walk().map(\.layer.id) {
                guard let l = doc.layer(id) else { continue }
                if !hasLiveEffects(l) { continue }
                if case .group = l.content { continue }
                if case .adjustment = l.content { continue }
                // The pixel and vector masks stay on the layer (baking must not destroy them), so
                // the pixels are baked without them and each mask then applies once to the baked
                // raster.
                let px = try bake(s, doc, l, fmt, keepEffects: true, applyMask: false)
                guard doc.updateLayer(id, { (l: inout Layer) -> Void in
                    l.content = .raster(px)
                    l.effects = Effects()
                    l.fillOpacity = 1
                    l.fillCache = nil
                    l.psdBlocks.removeAll { effectBakedKeys.contains($0.key) }
                }) != nil else { throw EngineError.noLayer(id) }
                n += 1
            }
        }
        return ["flattened": .int(n)]
    }

    static func flattenAllMasks(_ s: Session) throws -> JSONValue {
        var (n, skipped) = (0, 0)
        try s.edit("Flatten All Masks") { doc, _ in
            let fmt = doc.pixelFormat
            for id in doc.walk().map(\.layer.id) {
                guard let l = doc.layer(id) else { continue }
                let masked = (l.mask?.enabled ?? false) || l.vectorMask != nil
                if !masked { continue }
                guard case .raster = l.content else {
                    // Masks on groups, adjustment, type, shape and smart layers have no pixels to
                    // fold into; Photoshop's script leaves them too.
                    skipped += 1
                    continue
                }
                let px = try bake(s, doc, l, fmt, keepEffects: false, applyMask: true)
                guard doc.updateLayer(id, { (l: inout Layer) -> Void in
                    l.content = .raster(px)
                    l.mask = nil
                    l.vectorMask = nil
                    l.psdBlocks.removeAll { vectorMaskKeys.contains($0.key) }
                }) != nil else { throw EngineError.noLayer(id) }
                n += 1
            }
        }
        return ["flattened": .int(n), "skipped": .int(skipped)]
    }
}
