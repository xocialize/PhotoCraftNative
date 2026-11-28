// Port of photocraft-engine (crates/engine/src/file_cmds.rs: close / revert / save a copy / open as, place, Reveal in Finder, the registry rows), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// File › Close All / Close Others, the document tab's Reveal in Finder, File › Revert, Save a
// Copy, Open As, and Place Embedded / Linked. Placing decodes the file through PCIO (with the
// engine's services), composites it, scales it with PCAlgo's resampler and centres it; an SVG
// source is re-rendered at its placement scale so it stays sharp.

#if canImport(AppKit)
import AppKit
#endif
import Foundation
import PCAlgo
import PCDocument
import PCFormat
import PCFoundation
import PCIO
import PCIOCore
import PCIOFormats

extension FileCommands {
    // MARK: Close

    static func closeAll(_ s: Session) -> JSONValue {
        let n = s.documents.count
        while !s.documents.isEmpty { s.close(s.documents.count - 1) }
        return ["closed": .int(n)]
    }

    static func closeOthers(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let keep = p["document"]?.uint64Value.flatMap({ Int(exactly: $0) }) ?? s.activeIndex else { throw EngineError.noDocument }
        if keep >= s.documents.count { throw EngineError.bad("file.closeOthers", "no document \(keep)") }
        let n = s.documents.count - 1
        for i in stride(from: s.documents.count - 1, through: 0, by: -1) where i != keep { s.close(i) }
        _ = s.setActive(0)
        return ["closed": .int(n)]
    }

    // MARK: Reveal in Finder

    /// The document tab's Reveal in Finder (UI-217-6): the tab's own file in the platform file
    /// manager. `dryRun` answers the program and arguments instead (tests never open Finder).
    static func revealInFinder(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.revealInFinder"
        let i: Int
        if let v = p["document"] {
            guard let n = v.uint64Value.flatMap({ Int(exactly: $0) }) else { throw EngineError.bad(cmd, "`document` must be an index") }
            i = n
        } else {
            guard let a = s.activeIndex else { throw EngineError.noDocument }
            i = a
        }
        guard i < s.documents.count, let path = s.documents[i].path else { throw EngineError.bad(cmd, "document \(i) has no saved file") }
        return try reveal(path, dryRun: p["dryRun"]?.boolValue ?? false)
    }

    /// Shows `path` selected in the file manager: through `NSWorkspace` on macOS, the
    /// `open -R`-style program elsewhere (photocraft `layer_menu_cmds::reveal`). With `dryRun`
    /// nothing is opened and the result is the equivalent program and arguments.
    static func reveal(_ path: String, dryRun: Bool) throws -> JSONValue {
        if dryRun { return try LayerMenuCommands.reveal(path, dryRun: true) }
        #if canImport(AppKit)
        let url = URL(fileURLWithPath: path)
        Task { @MainActor in NSWorkspace.shared.activateFileViewerSelecting([url]) }
        return ["path": .string(path)]
        #else
        return try LayerMenuCommands.reveal(path, dryRun: false)
        #endif
    }

    // MARK: Revert

    /// photocraft `can_revert`: the document has a saved file on disk.
    static let canRevert: CommandEnabled = { s, p in
        if let why = native(s, p) { return why }
        guard let d = s.active else { return "no document open" }
        guard let path = d.path else { return "the document has never been saved" }
        let fs = s.services.fileSystem
        let package = fs.isDirectory(path) && fileExtension(path) == PcraftFormat.fileExtension
        if !fs.exists(path) || (fs.isDirectory(path) && !package) { return "\(path) is not a file on disk" }
        return nil
    }

    /// File › Revert: reload the saved file as one history step (undoable, like Photoshop's
    /// "Revert" history state); the document is clean afterwards.
    static func revert(_ s: Session) throws -> JSONValue {
        guard let path = s.active?.path else { throw EngineError.other("the document has never been saved") }
        // Through the open path, which also reads `.pcraft` packages.
        let fresh = try EngineIO.importPath(path, services: s.services).document
        try s.edit("Revert") { doc, active in
            let (id, name) = (doc.id, doc.name)
            doc = fresh
            // Keep the identity (colour state, views and caches are keyed by it) and the tab name.
            doc.id = id
            doc.name = name
            active = doc.topLayer
        }
        let layers = try s.updateActive { st -> Int in
            st.savedRevision = st.revision
            return st.doc.layers.count
        }
        s.publish()
        return ["path": .string(path), "layers": .int(layers)]
    }

    // MARK: Save a Copy

    /// Whether two paths name the same existing file (same device and inode, links followed).
    static func sameFile(_ a: String, _ b: String) -> Bool {
        var x = stat(), y = stat()
        guard stat(a, &x) == 0, stat(b, &y) == 0 else { return false }
        return x.st_dev == y.st_dev && x.st_ino == y.st_ino
    }

    static func saveACopy(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.saveACopy"
        let path = try strParam(p, "path", cmd)
        guard var doc = s.active?.doc else { throw EngineError.noDocument }
        // A copy over the document's own file replaces it, and a flat or lossy format can't be
        // undone, so it takes an explicit `"overwrite": true` (photocraft #7437, `502d055c6`).
        if let own = s.active?.path, sameFile(path, own), p["overwrite"]?.boolValue != true {
            throw EngineError.badParams(
                cmd: cmd, msg: "`path` is the document's own file, so the copy would replace it: choose another path, or pass \"overwrite\": true")
        }
        let opts = try SaveOpts.from(s, p, cmd)
        if p["layers"]?.boolValue == false {
            // "Layers" unchecked in Save a Copy: write the flattened image.
            let px = try flattened(s, doc, doc.pixelFormat)
            doc.layers = [Layer(name: "Background", content: .raster(px))]
        }
        let warnings = try saveDoc(s, doc, path, opts)
        return ["path": .string(path), "warnings": .strings(warnings)]
    }

    // MARK: Open As

    /// Opens a file's bytes, decoding them as the format `as` (Open As) when given; a template
    /// (.psdt) opens untitled without its path (photocraft `open_bytes_as`).
    public static func openBytesAs(_ s: Session, name: String, bytes: [UInt8], as ext: String?, path: String?) throws -> JSONValue {
        var decodeName = name
        if let ext {
            var e = Substring(ext)
            while e.hasPrefix(".") { e = e.dropFirst() }
            decodeName = "\(stem(name)).\(e)"
        }
        let r = try EngineIO.importFile(name: decodeName, bytes: bytes, services: s.services)
        var doc = r.document
        var keep = path
        if let untitled = templateName(s, name) {
            doc.name = untitled
            keep = nil
        } else {
            doc.name = fileName(name)
        }
        // Color Settings policies (preserve / convert / discard the embedded profile).
        let (i, color) = ColorCommands.openDocument(s, doc, path: r.sourceReadOnly ? nil : keep)
        try? s.updateDocument(at: i) { $0.sourceReadOnly = r.sourceReadOnly }
        // Import notes (e.g. how a camera raw was developed, or that only its preview opened).
        return ["document": .int(i), "color": color, "warnings": .strings(r.warnings)]
    }

    static func openAs(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let path = try strParam(p, "path", "file.openAs")
        let bytes = try readFile(s, path)
        let ext = (p["as"] ?? p["format"])?.stringValue
        return try openBytesAs(s, name: path, bytes: bytes, as: ext, path: path)
    }

    /// A PCIO failure as photocraft words it (`"{name}: {error}"`).
    static func ioError(_ name: String, _ error: any Error) -> EngineError {
        if let e = error as? EngineError { return e }
        if let e = error as? PCIOError {
            if case .cancelled = e { return .cancelled }
            return .other("\(name): \(e)")
        }
        return .other("\(name): \(error)")
    }

    // MARK: Place

    /// History label of an embedded place.
    public static let placeEmbeddedLabel = "Place Embedded"

    /// Places a file's bytes as a smart object layer, centred, and (with Preferences ▸ General ▸
    /// Resize Image During Place, on by default) scaled down to fit when larger than the canvas.
    /// `linked` makes it a linked smart object referring to that path instead of embedding the
    /// bytes. With Preferences ▸ General ▸ Always Create Smart Objects When Placing off, an
    /// embedded place lands as a plain pixel layer (an explicit `"smartObject": false` asks for
    /// one) (photocraft `place_bytes`).
    public static func placeBytes(_ s: Session, name: String, bytes: [UInt8], linked: String?, _ p: JSONValue) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let (cw, ch) = (Double(d.doc.size.width), Double(d.doc.size.height))
        let fmt = d.doc.pixelFormat
        let vector = SVGImport.isSVG(bytes)
        // The glue's options with Preferences ▸ File Handling ▸ Rasterize SVG Groups Deeper Than
        // (`EngineIO.importFile` has no parameter for it).
        var opts = EngineIO.options(s.services)
        opts.maxSVGGroupDepth = max(s.preferences["fileHandling.rasterizeSvgGroupsDeeperThan"]?.intValue ?? 100, 0)
        let imported: ImportResult
        do { imported = try DocumentIO.importFile(name: name, bytes: bytes, options: opts) } catch { throw ioError(name, error) }
        if imported.previewOnly {
            throw EngineError.other("\(name): only this Affinity file's embedded preview could be read; open it with File › Open to see the warning, or export PSD or PNG from Affinity before using it here")
        }
        let src = imported.document
        let (w, h) = (Double(src.size.width), Double(src.size.height))
        // The implicit `fit` is Preferences ▸ General ▸ Resize Image During Place (on by default).
        let fit = p["fit"]?.boolValue ?? (s.preferences["general.resizeImageDuringPlace"]?.boolValue ?? true)
        let scale: Double
        if let k = f64Param(p, "scale") {
            scale = max(k / 100, 1e-4)
        } else if fit && (w > cw || h > ch) {
            scale = min(cw / w, ch / h)
        } else {
            scale = 1
        }
        var center = (cw / 2, ch / 2)
        if let c = p["center"]?.arrayValue, c.count == 2 { center = (c[0].doubleValue ?? cw / 2, c[1].doubleValue ?? ch / 2) }
        let dx = (center.0 - w * scale / 2).rounded(), dy = (center.1 - h * scale / 2).rounded()
        var px = try flattened(s, src, fmt)
        if abs(scale - 1) > 1e-9 { px = Resample.resizeSurface(px, sx: scale, sy: scale, filter: .bicubic) }
        px = Resample.translateSurface(px, dx: clampI32(dx), dy: clampI32(dy))
        // Preferences ▸ General ▸ Always Create Smart Objects When Placing (on by default): off, an
        // embedded place lands as a plain pixel layer. A linked place is always a smart object.
        let smart = linked != nil
            || (p["smartObject"]?.boolValue ?? (s.preferences["general.alwaysCreateSmartObjectsWhenPlacing"]?.boolValue ?? true))
        let source: SmartSource = linked.map { .linked(path: $0) } ?? .embedded(fileName: fileName(name), bytes: bytes)
        let layerName = stem(name)
        let label = linked != nil ? "Place Linked" : placeEmbeddedLabel
        let transform = PCAffine(a: scale, b: 0, c: 0, d: scale, e: dx, f: dy)
        let placed = px
        let services = s.services
        let id = try s.edit(label) { doc, active -> LayerId in
            let layer: Layer
            if smart {
                var so = SmartObject(source: source, transform: transform, cache: placed)
                // A vector source (SVG) renders at its placement scale instead of as a resampled raster.
                if vector, let sharp = try SmartCommands.render(doc, so, services: services) { so.cache = sharp }
                layer = Layer(name: layerName, content: .smart(so))
            } else {
                layer = Layer(name: layerName, content: .raster(placed))
            }
            let id = doc.insertAbove(active, layer)
            active = id
            return id
        }
        return ["layer": .id(id), "scale": .number(scale * 100), "bounds": .doubles([dx, dy, dx + w * scale, dy + h * scale]),
                "smartObject": .bool(smart)]
    }

    static func place(_ s: Session, _ p: JSONValue, linked: Bool) throws -> JSONValue {
        let cmd = linked ? "file.placeLinked" : "file.placeEmbedded"
        let path = try strParam(p, "path", cmd)
        let bytes = try readFile(s, path)
        return try placeBytes(s, name: path, bytes: bytes, linked: linked ? path : nil, p)
    }

    /// A coordinate rounded into `Int32` (saturating).
    static func clampI32(_ v: Double) -> Int32 {
        guard v.isFinite else { return 0 }
        return Int32(min(max(v.rounded(), -2_147_483_648), 2_147_483_647))
    }

    // MARK: Registry

    static func menuSpecs() -> [CommandSpec] {
        [
            CommandSpec("file.closeAll", "Close All", menu: ["File"], shortcut: "Cmd+Alt+W", params: "{}", module: m, enabled: hasDoc) { s, _ in
                closeAll(s)
            },
            CommandSpec("file.closeOthers", "Close Others", menu: ["File"], shortcut: "Cmd+Alt+P",
                        params: #"{"document":index? (the one to keep; default active)}"#, module: m, enabled: hasDoc, run: closeOthers),
            // The document tab's menu (UI-217-6): the tab's own file in the platform file manager.
            // Not a Photoshop menu-bar item; enabled when the target document has a saved path.
            CommandSpec("file.revealInFinder", "Reveal in Finder", params: #"{"document":index? (default active),"dryRun":bool=false}"#, module: m,
                        enabled: nativeDoc, run: revealInFinder),
            CommandSpec("file.revert", "Revert", menu: ["File"], shortcut: "F12", params: "{} (reloads the saved file as one undoable step)", module: m,
                        enabled: canRevert) { s, _ in try revert(s) },
            CommandSpec("file.saveACopy", "Save a Copy…", menu: ["File"], shortcut: "Cmd+Alt+S",
                        params: #"{"path":str (format from the extension),"quality":0..12? (JPEG),"layers":bool=true,"overwrite":bool=false (replace the document's own file),"tiffLayers":bool=false (TIFF: keep the layers; flat by default),"tgaBits":24|32? (TGA: 32 writes the alpha channel, or else the transparency, as the alpha; unset, 32 with an alpha channel or transparency, else 24)}"#,
                        module: m, enabled: nativeDoc, run: saveACopy),
            CommandSpec("file.openAs", "Open As…", menu: ["File"], shortcut: "Cmd+Alt+Shift+O",
                        params: #"{"path":str,"as":"psd|png|jpg|tiff|…"? (decode as this format)}"#, module: m, enabled: native, run: openAs),
            CommandSpec("file.placeEmbedded", "Place Embedded…", menu: ["File"],
                        params: #"{"path":str,"scale":%? (default: fit when larger than the canvas),"fit":bool? (default: Preferences > General > Resize Image During Place),"smartObject":bool? (default: Preferences > General > Always Create Smart Objects When Placing),"center":[x,y]?}"#,
                        module: m, enabled: nativeDoc) { s, p in try place(s, p, linked: false) },
            CommandSpec("file.placeLinked", "Place Linked…", menu: ["File"],
                        params: #"{"path":str,"scale":%?,"fit":bool? (default: Preferences > General > Resize Image During Place),"center":[x,y]?}"#,
                        module: m, enabled: nativeDoc) { s, p in try place(s, p, linked: true) },
            CommandSpec("file.fileInfo", "File Info…", menu: ["File"], shortcut: "Cmd+Alt+Shift+I",
                        params: #"{"title":str?,"author":str?,"authorTitle":str?,"description":str?,"keywords":[str]|"a; b"?,"copyright":str?,"copyrightStatus":"unknown|copyrighted|publicDomain"?,"copyrightUrl":str?} (no keys: read; the result also has read-only "camera":{"make","model","dateTaken","exposure","fNumber","iso","focalLength","focalLength35mm","lens"}, present keys only)"#,
                        module: m, enabled: hasDoc, run: fileInfo),
        ]
    }
}
