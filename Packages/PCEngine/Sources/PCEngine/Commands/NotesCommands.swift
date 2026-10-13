// Port of photocraft-engine (crates/engine/src/notes_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Note tool annotations (Window › Notes, File › Import › Notes…). Notes are document data
// (`Note`), saved in `.pcraft` and as the PSD `Anno` block; each change is one history step.

import Foundation
import PCDocument
import PCFoundation

enum NotesCommands: CommandModule {
    static let name = "notes_cmds"
    static let m = "notes_cmds"

    static let hasDoc: CommandEnabled = { s, _ in s.active == nil ? "no document open" : nil }

    static let hasNotes: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return d.doc.notes.isEmpty ? "the document has no notes" : nil
    }

    /// PDF-style date (`D:YYYYMMDDhhmmssZ`) as Photoshop stores in notes; empty without a clock.
    static func pdfDate(_ s: Session) -> String {
        let iso = AnalysisCommands.nowISO(s.services.clock())
        if iso.count < 19 { return "" }
        return "D:" + String(iso.prefix(19).filter { $0.isASCII && $0.isNumber }) + "Z"
    }

    static func noteJSON(_ i: Int, _ n: Note) -> JSONValue {
        let c = n.color.rgb
        return [
            "index": .int(i), "author": .string(n.author), "text": .string(n.text), "color": .floats([c.x, c.y, c.z]),
            "position": .doubles([n.position.x, n.position.y]), "open": .bool(n.open), "modified": .string(n.modified),
        ]
    }

    static func listJSON(_ d: Document) -> JSONValue {
        ["notes": .array(d.notes.enumerated().map { noteJSON($0.offset, $0.element) })]
    }

    static func colorOf(_ p: JSONValue) -> PCColor? {
        guard p["color"] != nil else { return nil }
        let c = Params.color(p, "color", SIMD4(1, 1, 0.51, 1))
        return .rgb(c.x, c.y, c.z)
    }

    static func indexOf(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> Int {
        guard let d = s.active else { throw EngineError.noDocument }
        let n = d.doc.notes.count
        guard let i = p["index"]?.uint64Value else { throw EngineError.bad(cmd, "pass `index`") }
        guard i < UInt64(n) else { throw EngineError.bad(cmd, "no note \(i) (the document has \(n))") }
        return Int(i)
    }

    static func add(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "notes.add"
        guard let x = p["x"]?.doubleValue, let y = p["y"]?.doubleValue else { throw EngineError.bad(cmd, "pass `x` and `y`") }
        if !x.isFinite || !y.isFinite { throw EngineError.bad(cmd, "coordinates must be finite") }
        var n = Note(author: p["author"]?.stringValue ?? "", text: p["text"]?.stringValue ?? "", position: SIMD2(x, y),
                     popup: SIMD4(x + 20, y + 20, x + 260, y + 160), open: p["open"]?.boolValue ?? true, modified: pdfDate(s))
        if let c = colorOf(p) { n.color = c }
        let i = try s.edit("New Note") { d, _ -> Int in
            d.notes.append(n)
            return d.notes.count - 1
        }
        guard let d = s.active, i < d.doc.notes.count else { throw EngineError.noDocument }
        return ["index": .int(i), "note": noteJSON(i, d.doc.notes[i])]
    }

    static func set(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "notes.set"
        let i = try indexOf(s, p, cmd)
        guard let d = s.active else { throw EngineError.noDocument }
        let old = d.doc.notes[i]
        var n = old
        if let t = p["text"]?.stringValue { n.text = t }
        if let a = p["author"]?.stringValue { n.author = a }
        if let c = colorOf(p) { n.color = c }
        if let o = p["open"]?.boolValue { n.open = o }
        let (x, y) = (p["x"]?.doubleValue, p["y"]?.doubleValue)
        if x != nil || y != nil {
            let (nx, ny) = (x ?? n.position.x, y ?? n.position.y)
            if !nx.isFinite || !ny.isFinite { throw EngineError.bad(cmd, "coordinates must be finite") }
            let (dx, dy) = (nx - n.position.x, ny - n.position.y)
            n.position = SIMD2(nx, ny)
            // The popup travels with its icon.
            n.popup = SIMD4(n.popup.x + dx, n.popup.y + dy, n.popup.z + dx, n.popup.w + dy)
        }
        if n == old { return ["index": .int(i), "note": noteJSON(i, n), "changed": false] }
        // Content edits update the modification date (opening/closing the popup doesn't).
        if n.text != old.text || n.author != old.author { n.modified = pdfDate(s) }
        let label = n.position != old.position ? "Move Note" : "Edit Note"
        let out = noteJSON(i, n)
        try s.edit(label) { d, _ in
            guard i < d.notes.count else { throw EngineError.bad(cmd, "no note \(i) (the document has \(d.notes.count))") }
            d.notes[i] = n
        }
        return ["index": .int(i), "note": out, "changed": true]
    }

    static func delete(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        if p["all"]?.boolValue == true {
            let n = s.active?.doc.notes.count ?? 0
            try s.edit("Delete All Notes") { d, _ in d.notes.removeAll() }
            return ["deleted": .int(n), "remaining": 0]
        }
        let i = try indexOf(s, p, "notes.delete")
        try s.edit("Delete Note") { d, _ in
            guard i < d.notes.count else { throw EngineError.bad("notes.delete", "no note \(i) (the document has \(d.notes.count))") }
            d.notes.remove(at: i)
        }
        return ["deleted": 1, "remaining": .int(s.active?.doc.notes.count ?? 0)]
    }

    static func list(_ s: Session) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        return listJSON(d.doc)
    }

    /// File › Import › Notes…: append the notes of another PSD or `.pcraft` file (read through the
    /// session's file service, imported by PCIO). Notes outside the canvas are pulled inside, as
    /// Photoshop does when sizes differ (photocraft `import`).
    static func importFile(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.import.notes"
        guard let path = p["path"]?.stringValue else { throw EngineError.bad(cmd, "pass `path` (.psd, .psb or .pcraft)") }
        let bytes = try FileCommands.readFile(s, path)
        return try importNotesFrom(s, name: FileCommands.fileName(path), bytes: bytes)
    }

    /// File › Import › Notes… from file bytes (what a file picker returns; photocraft
    /// `import_notes_from`).
    static func importNotesFrom(_ s: Session, name: String, bytes: [UInt8]) throws -> JSONValue {
        let src = try FileCommands.import(s, name, bytes)
        return try importNotes(s, name: name, from: src)
    }

    /// The notes of `src` (the document named `name`) appended to the active document.
    static func importNotes(_ s: Session, name: String, from src: Document) throws -> JSONValue {
        if src.notes.isEmpty { throw EngineError.other("\(name) has no notes") }
        guard let d = s.active else { throw EngineError.noDocument }
        let (w, h) = (Double(d.doc.size.width), Double(d.doc.size.height))
        var notes = src.notes
        for i in notes.indices {
            let p = notes[i].position
            let (nx, ny) = (min(max(p.x, 0), max(w - 16, 0)), min(max(p.y, 0), max(h - 20, 0)))
            let (dx, dy) = (nx - p.x, ny - p.y)
            notes[i].position = SIMD2(nx, ny)
            let q = notes[i].popup
            notes[i].popup = SIMD4(q.x + dx, q.y + dy, q.z + dx, q.w + dy)
        }
        let count = notes.count
        try s.edit("Import Notes") { d, _ in d.notes.append(contentsOf: notes) }
        guard let after = s.active else { throw EngineError.noDocument }
        return listJSON(after.doc).setting("imported", .int(count))
    }

    static func register(into r: inout CommandRegistry) {
        r.add([
            CommandSpec("notes.add", "New Note",
                        params: ##"{"x":px,"y":px,"text":str="","author":str="","color":"#rrggbb"|[r,g,b]=pale yellow,"open":bool=true}"##,
                        module: m, enabled: hasDoc) { s, p in try add(s, p) },
            CommandSpec("notes.set", "Edit Note",
                        params: ##"{"index":n,"text":str?,"author":str?,"color":"#rrggbb"|[r,g,b]?,"x":px?,"y":px?,"open":bool?}"##,
                        module: m, enabled: hasNotes) { s, p in try set(s, p) },
            CommandSpec("notes.delete", "Delete Note", params: #"{"index":n}|{"all":true}"#,
                        module: m, enabled: hasNotes) { s, p in try delete(s, p) },
            CommandSpec("notes.list", "Notes", params: "{} → notes (index, author, text, colour, position, open, modified)",
                        module: m, journal: false, enabled: hasDoc) { s, _ in try list(s) },
            CommandSpec("file.import.notes", "Notes…", menu: ["File", "Import"], params: #"{"path":".psd|.psb|.pcraft with notes"}"#,
                        module: m, enabled: hasDoc) { s, p in try importFile(s, p) },
        ])
    }
}
