// Port of photocraft-engine (crates/engine/src/file_cmds.rs: Export › Layers to Files and Color Lookup Tables, `export_layers_with`, `lut_layers`, `bake_cube`, and the Automate / Scripts / Export registry rows), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Export › Layers to Files writes one file per top-level layer (groups merged), top to bottom
// like Photoshop's numbering, through a write callback so the automation layer can stream the
// same bytes beneath its write root (#3216). Export › Color Lookup Tables bakes the visible
// top-level adjustment stack (or a chosen part of it) against an identity RGB lattice into a
// `.cube` file.

import Foundation
import PCDocument
import PCFoundation

extension FileCommands {
    // MARK: Layers to Files

    static func layersToFiles(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.export.layersToFiles"
        let dir: String
        if let d = try? strParam(p, "dir", cmd) { dir = d } else { dir = try strParam(p, "output", cmd) }
        let names = try exportLayersWith(s, p) { name, bytes in try writeFile(s, join(dir, name), bytes) }
        return ["files": .strings(names.map { join(dir, $0) })]
    }

    /// The bodies of `file.export.layersToFiles`, streamed to `write` as a single-component file
    /// name plus its bytes: one file per exported layer (top to bottom, like Photoshop's
    /// numbering), encoded but never touched as a path. Automation writes exactly these bytes
    /// beneath its write root (#3216), so the two paths cannot drift. Returns the file names
    /// written, in order (photocraft `export_layers_with`).
    public static func exportLayersWith(_ s: Session, _ p: JSONValue, write: (String, [UInt8]) throws -> Void) throws -> [String] {
        let cmd = "file.export.layersToFiles"
        var f = Substring(p["format"]?.stringValue ?? "png")
        while f.hasPrefix(".") { f = f.dropFirst() }
        let format = f.lowercased()
        let visibleOnly = p["visibleOnly"]?.boolValue ?? true
        let save = try SaveOpts.from(s, p, cmd)
        guard let d = s.active else { throw EngineError.noDocument }
        let prefix = p["prefix"]?.stringValue ?? stem(d.doc.name)
        let doc = d.doc
        var written: [String] = []
        // Top-level layers (groups export merged), top to bottom like Photoshop's numbering.
        let layers = doc.layers.reversed().filter { $0.visible || !visibleOnly }
        for (i, l) in layers.enumerated() {
            if case .adjustment = l.content { continue }
            var one = doc
            var only = l
            only.visible = true
            only.clipped = false
            one.layers = [only]
            let name = "\(sanitize(prefix))_\(String(format: "%04d", i))_\(sanitize(l.name)).\(format)"
            let (bytes, _) = try encode(s, one, name, save)
            try write(name, bytes)
            written.append(name)
        }
        return written
    }

    // MARK: Color Lookup Tables

    /// photocraft `has_adjustments`.
    static let hasAdjustments: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return d.doc.layers.contains { l in
            if case .adjustment = l.content { return l.visible }
            return false
        } ? nil : "the document has no visible adjustment layers to export"
    }

    static func isAdjustment(_ l: Layer) -> Bool {
        if case .adjustment = l.content { return true }
        return false
    }

    /// Adjustment layers that can be represented as an RGB-only LUT, in document stack order. A
    /// LUT has no spatial coordinates, so masks and clipping geometry are stripped at bake time.
    /// Group adjustments need their enclosing group's compositing and are not silently flattened
    /// as independent layers (photocraft `lut_layers`).
    static func lutLayers(_ doc: Document, _ ids: [LayerId]?) throws -> [Layer] {
        let cmd = "file.export.colorLookupTables"
        var selected: [LayerId] = []
        if let ids {
            if ids.isEmpty { throw EngineError.bad(cmd, "select at least one adjustment layer") }
            for id in ids {
                if selected.contains(id) { throw EngineError.bad(cmd, "duplicate layer id \(id.rawValue)") }
                guard let layer = doc.layer(id) else { throw EngineError.noLayer(id) }
                if !isAdjustment(layer) { throw EngineError.bad(cmd, "layer \(id.rawValue) is not an adjustment layer") }
                if !layer.visible { throw EngineError.bad(cmd, "layer \(id.rawValue) is hidden") }
                if !doc.layers.contains(where: { $0.id == id }) {
                    throw EngineError.bad(cmd, "layer \(id.rawValue) is nested in a group; export top-level adjustment layers")
                }
                selected.append(id)
            }
        }
        let layers = doc.layers.filter { $0.visible && isAdjustment($0) && (ids == nil || selected.contains($0.id)) }
        if layers.isEmpty { throw EngineError.bad(cmd, "no visible adjustment layers to export") }
        return layers
    }

    /// Bakes the chosen adjustment stack against an identity RGB lattice into `.cube` text. Source
    /// order always follows the document stack (photocraft `bake_cube_layers`).
    static func bakeCubeLayers(_ s: Session, _ size: Int, _ title: String, _ layers: [Layer]) throws -> String {
        let n = size
        let (w, h) = (n * n, n)
        var lattice = Document(name: "lut", size: PixelSize(width: w, height: h), mode: .rgb, depth: .f32)
        let fmt = lattice.pixelFormat
        let step = 1 / Float(n - 1)
        var rgba: [SIMD4<Float>] = []
        rgba.reserveCapacity(w * h)
        for g in 0 ..< n {
            for b in 0 ..< n {
                for r in 0 ..< n { rgba.append(SIMD4(Float(r) * step, Float(g) * step, Float(b) * step, 1)) }
            }
        }
        var surf = Surface(format: fmt)
        surf.writeRegion(PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h)), PixelCodec.fromRGBA(fmt, rgba: rgba))
        lattice.layers.append(Layer(name: "Lattice", content: .raster(surf)))
        for l in layers {
            var a = l
            // Masks and clipping are spatial; a LUT is the adjustment stack's colour mapping.
            a.mask = nil
            a.vectorMask = nil
            a.clipped = false
            lattice.layers.append(a)
        }
        let out = try s.services.renderer.render(lattice, region: lattice.bounds).px
        guard out.count == w * h else { throw EngineError.other("compositing the lookup table failed") }
        var text = "TITLE \"\(title.replacingOccurrences(of: "\"", with: "'"))\"\n# Created by Photocraft\nLUT_3D_SIZE \(n)\nDOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n"
        // .cube order: red changes fastest, then green, then blue.
        func c(_ v: Float) -> String { String(format: "%.6f", Double(min(max(v, 0), 1))) }
        for b in 0 ..< n {
            for g in 0 ..< n {
                for r in 0 ..< n {
                    let px = out[g * w + b * n + r]
                    text += "\(c(px.x)) \(c(px.y)) \(c(px.z))\n"
                }
            }
        }
        return text
    }

    /// The `.cube` of every visible top-level adjustment layer (photocraft `bake_cube`).
    public static func bakeCube(_ s: Session, _ doc: Document, size: Int, title: String) throws -> String {
        try bakeCubeLayers(s, min(max(size, 2), AdjustCommands.LutFile.maxSize), title, doc.layers.filter { $0.visible && isAdjustment($0) })
    }

    /// Exports either the whole visible stack (the default), the Layers panel's current selection,
    /// or an explicit list supplied by scripts / CLI / automation.
    static func colorLookupTables(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.export.colorLookupTables"
        guard let d = s.active else { throw EngineError.noDocument }
        let maxSize = AdjustCommands.LutFile.maxSize
        let size: UInt64
        switch p["size"] {
        case nil, .null?: size = 33
        case let v?:
            guard let n = v.uint64Value else { throw EngineError.bad(cmd, "size must be an integer") }
            size = n
        }
        if !(2 ... UInt64(maxSize)).contains(size) { throw EngineError.bad(cmd, "size must be 2..=\(maxSize)") }
        let scope: String
        switch p["scope"] {
        case nil, .null?: scope = "all"
        case .string(let v)?: scope = v
        default: throw EngineError.bad(cmd, "scope must be all or selected")
        }
        if scope != "all" && scope != "selected" { throw EngineError.bad(cmd, "scope must be all or selected") }
        if p["layers"] != nil && scope == "selected" { throw EngineError.bad(cmd, "use either layers or scope=selected, not both") }
        let explicit: [LayerId]?
        if let v = p["layers"] {
            guard let a = v.arrayValue else { throw EngineError.bad(cmd, "layers must be an array of layer IDs") }
            explicit = try a.map { id in
                guard let n = id.uint64Value else { throw EngineError.bad(cmd, "layer IDs must be unsigned integers") }
                return LayerId(n)
            }
        } else if scope == "selected" {
            explicit = d.selectedLayers
        } else {
            explicit = nil
        }
        let layers = try lutLayers(d.doc, explicit)
        let title = p["title"]?.stringValue ?? stem(d.doc.name)
        let cube = try bakeCubeLayers(s, Int(size), title, layers)
        if let path = p["path"]?.stringValue {
            try writeFile(s, path, Array(cube.utf8))
            return ["path": .string(path), "size": .int(size), "layerCount": .int(layers.count)]
        }
        return ["cube": .string(cube), "size": .int(size), "layerCount": .int(layers.count)]
    }

    // MARK: Registry

    static func automateSpecs() -> [CommandSpec] {
        [
            CommandSpec("file.automate.fitImage", "Fit Image…", menu: ["File", "Automate"],
                        params: #"{"width":px,"height":px,"dontEnlarge":bool=false,"resample":"automatic|preserveDetails|bicubicSmoother|bicubicSharper|bicubicAutomatic|bicubic|nearest|bilinear|lanczos"="bicubic"}"#,
                        module: m, enabled: hasDoc, run: fitImage),
            CommandSpec("file.automate.conditionalModeChange", "Conditional Mode Change…", menu: ["File", "Automate"],
                        params: #"{"from":["rgb","grayscale","cmyk","lab","indexed","bitmap",…]|"any"="any","to":"rgb|grayscale|cmyk|lab"}"#,
                        module: m, enabled: hasDoc, run: conditionalModeChange),
            CommandSpec("file.automate.batch", "Batch…", menu: ["File", "Automate"],
                        params: #"{"steps":[[commandId,params]|{"command":id,"params":{}}…] (a recorded action),"input":folder|[paths],"output":folder,"format":"same|png|jpg|psd|tiff|…"="same","quality":0..12?,"tiffLayers":bool=false,"tgaBits":24|32?,"calledActions":[{"name","steps"}…]? (the actions Play Action steps call; default: the session's)} → {files, errors} (an input whose output name was already written in the run goes to errors)"#,
                        module: m, enabled: native, run: batch),
            CommandSpec("file.scripts.imageProcessor", "Image Processor…", menu: ["File", "Scripts"],
                        params: #"{"input":folder|[paths],"output":folder,"format":"jpg|png|psd|tiff|…"="jpg","quality":0..12=8,"tiffLayers":bool=false,"tgaBits":24|32?,"width":px?,"height":px? (fit, never enlarge),"convertToSrgb":bool=false} → {files, errors} (an input whose output name was already written in the run goes to errors)"#,
                        module: m, enabled: native, run: imageProcessor),
            CommandSpec("file.scripts.loadFilesIntoStack", "Load Files into Stack…", menu: ["File", "Scripts"],
                        params: #"{"paths":[str]|folder,"createSmartObject":bool=false} → new document with one layer per file (inside one smart object with createSmartObject)"#,
                        module: m, enabled: native, run: loadFilesIntoStack),
            CommandSpec("file.scripts.flattenAllLayerEffects", "Flatten All Layer Effects", menu: ["File", "Scripts"], params: "{}", module: m,
                        enabled: hasDoc) { s, _ in try flattenAllEffects(s) },
            CommandSpec("file.scripts.flattenAllMasks", "Flatten All Masks", menu: ["File", "Scripts"],
                        params: "{} (pixel layers; masks on other layer kinds are left)", module: m, enabled: hasDoc) { s, _ in try flattenAllMasks(s) },
        ]
    }

    static func exportSpecs() -> [CommandSpec] {
        [
            CommandSpec("file.export.layersToFiles", "Layers to Files…", menu: ["File", "Export"],
                        params: #"{"dir":folder,"format":"png|jpg|psd|tiff|…"="png","prefix":str=document name,"visibleOnly":bool=true,"quality":0..12?,"tiffLayers":bool=false,"tgaBits":24|32?} → {files}"#,
                        module: m, enabled: nativeDoc, run: layersToFiles),
            CommandSpec("file.export.colorLookupTables", "Color Lookup Tables…", menu: ["File", "Export"],
                        params: #"{"path":str? (.cube; omit to return the text),"size":2..129=33,"title":str?,"scope":"all|selected"="all","layers":[id,…]?} (selected layer IDs use original document stacking; masks are spatial and omitted)"#,
                        module: m, enabled: hasAdjustments, run: colorLookupTables),
        ]
    }
}
