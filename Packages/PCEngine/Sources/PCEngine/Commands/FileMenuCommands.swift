// Port of photocraft's File-menu actions that its app shell owns (crates/ui-egui/src/menus.rs `MENU` rows `file.open`, `file.save`, `file.saveAs`, `file.export.exportAs`, `file.export.quickExportAsPng`, `file.clearRecent`, `file.removeRecent`, and their handlers in menus.rs / file_open.rs / lib.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// photocraft's engine leaves Open, Save and Save As to the app (they open dialogs); the native
// engine registers them with the shell's ids so every frontend — menus, shortcuts, the CLI, the
// control channel, MCP — runs the same command with an explicit path. Without a path the app
// shows its own picker and calls back with one.

import Foundation
import PCDocument

enum FileMenuCommands: CommandModule {
    static let name = "ui_file"

    static let hasDoc: CommandEnabled = { s, _ in s.active == nil ? "no document open" : nil }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("file.open", "Open…", menu: ["File"], shortcut: "Cmd+O", params: #"{"path":str} → {document,name,warnings,color}"#,
                          module: name, journal: false) { s, p in
            let path = try FileCommands.strParam(p, "path", "file.open")
            let (i, warnings, color) = try s.openFile(path)
            return ["document": .int(i), "name": .string(s.documents[i].doc.name), "warnings": .strings(warnings), "color": color]
        })
        r.add(CommandSpec("file.save", "Save", menu: ["File"], shortcut: "Cmd+S",
                          params: #"{"path":str? (none: the document's own PSD, PSB or .pcraft file),"quality":0..12?,"tiffLayers":bool?,"tgaBits":24|32?} → {path,warnings,copy,assets?}"#,
                          module: name, enabled: hasDoc) { s, p in
            try save(s, p, "file.save", path: p["path"]?.stringValue)
        })
        r.add(CommandSpec("file.saveAs", "Save As…", menu: ["File"], shortcut: "Cmd+Shift+S",
                          params: #"{"path":str,"quality":0..12?,"tiffLayers":bool?,"tgaBits":24|32?} → {path,warnings,copy,assets?} (the file becomes the document's, unless it is a flat file that can't hold it: a copy)"#,
                          module: name, enabled: hasDoc) { s, p in
            try save(s, p, "file.saveAs", path: try FileCommands.strParam(p, "path", "file.saveAs"))
        })
        r.add(CommandSpec("file.export.exportAs", "Export As…", menu: ["File", "Export"], shortcut: "Cmd+Alt+Shift+W",
                          params: #"{"path":str,"quality":0..12?,"tiffLayers":bool=false,"tgaBits":24|32?} → {path,warnings} (always a copy)"#,
                          module: name, journal: false, enabled: hasDoc) { s, p in
            let path = try FileCommands.strParam(p, "path", "file.export.exportAs")
            let o = try FileCommands.SaveOpts.from(s, p, "file.export.exportAs")
            let r = try s.saveDocument(to: path, quality: o.quality, tiffLayers: o.tiffLayers, tgaBits: o.tgaBits, forceCopy: true)
            return ["path": .string(r.path), "warnings": .strings(r.warnings)]
        })
        r.add(CommandSpec("file.export.quickExportAsPng", "Quick Export as PNG", menu: ["File", "Export"],
                          params: #"{"path":str? (none: next to the document's file, as <name>.png)} → {path,warnings}"#,
                          module: name, journal: false, enabled: hasDoc) { s, p in
            guard let st = s.active else { throw EngineError.noDocument }
            let path: String
            if let given = p["path"]?.stringValue, !given.isEmpty {
                path = given
            } else if let own = st.path {
                path = ((own as NSString).deletingPathExtension) + ".png"
            } else {
                throw EngineError.bad("file.export.quickExportAsPng", "the document has never been saved: pass \"path\"")
            }
            let r = try s.saveDocument(to: path, forceCopy: true)
            return ["path": .string(r.path), "warnings": .strings(r.warnings)]
        })
        r.add(CommandSpec("file.clearRecent", "Clear Recent File List", menu: ["File", "Open Recent"], params: "{}", module: name, journal: false) { s, _ in
            s.setRecent([])
            return .null
        })
        r.add(CommandSpec("file.removeRecent", "Remove from Recent Files", params: #"{"path":str}"#, module: name, journal: false) { s, p in
            guard let path = p["path"]?.stringValue else { throw EngineError.other("file.removeRecent needs a \"path\"") }
            s.setRecent(s.recentFiles.filter { $0 != path })
            return .null
        })
    }

    /// Save / Save As: the document's own layered file, or `path` (photocraft `save_as_with` /
    /// `save_in_place`). The journal records `{path}` so an action replays it.
    static func save(_ s: Session, _ p: JSONValue, _ cmd: String, path: String?) throws -> JSONValue {
        let o = try FileCommands.SaveOpts.from(s, p, cmd)
        let r = try s.saveDocument(to: path, quality: o.quality, tiffLayers: p["tiffLayers"]?.boolValue, tgaBits: o.tgaBits)
        var out: JSONValue = ["path": .string(r.path), "warnings": .strings(r.warnings), "copy": .bool(r.copy)]
        if let assets = r.assets { out = out.setting("assets", assets) }
        return out
    }
}
