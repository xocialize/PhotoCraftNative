// Port of photocraft-engine (crates/engine/src/exr_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// EXR parts: what a multi-part or channel-grouped EXR file holds, and opening the chosen
// parts / groups as the layers of one document (a Maya/Arnold render writes one part per AOV).
// The query command feeds the File › Open EXR Parts… dialog, the CLI, MCP and the control
// channel alike. Reading and decoding are PCIO's `EXRParts`; the file is read through the
// session's file service.

import PCDocument
import PCIOCore
import PCIOFormats

enum ExrCommands: CommandModule {
    static let name = "exr_cmds"
    static let m = name

    static func kindName(_ k: EXRParts.EntryKind) -> String {
        switch k {
        case .part: "part"
        case .group: "group"
        case .cryptomatte: "cryptomatte"
        }
    }

    /// The parts, channel groups and Cryptomatte layers of the EXR at `path` (photocraft
    /// `entries_json`).
    static func entriesJSON(_ s: Session, _ path: String) throws -> JSONValue {
        let bytes = try FileCommands.readFile(s, path)
        let entries: [EXRParts.Entry]
        do { entries = try EXRParts.entries(bytes) } catch { throw FileCommands.ioError(path, error) }
        return .array(entries.map { e in
            [
                "kind": .string(kindName(e.kind)), "name": .string(e.name), "view": e.view.map(JSONValue.string) ?? .null,
                "width": .int(e.width), "height": .int(e.height), "channels": .int(e.channels), "objects": e.objects.map { .int($0) } ?? .null,
            ]
        })
    }

    static func exrParts(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        try entriesJSON(s, try FileCommands.strParam(p, "path", "file.exrParts"))
    }

    /// Collects `part/<name>` and `group/<name>` boolean params into the selection names (in key
    /// order, as serde's map iterates them).
    static func selected(_ p: JSONValue, _ prefix: String) -> [String] {
        p.members.filter { $0.key.hasPrefix(prefix) && $0.value.boolValue == true }.map { String($0.key.dropFirst(prefix.count)) }.sorted()
    }

    static func openExrParts(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.openExrParts"
        let path = try FileCommands.strParam(p, "path", cmd)
        let view = p["view"]?.stringValue ?? "both"
        if !["both", "left", "right"].contains(view) { throw EngineError.bad(cmd, #"view is "\#(view)"; it is "both", "left" or "right""#) }
        let sel = EXRParts.Selection(parts: selected(p, "part/"), groups: selected(p, "group/"), view: view)
        let precomp = p["precomp"]?.boolValue ?? false
        let bytes = try FileCommands.readFile(s, path)
        let r: ImportResult
        do { r = try EXRParts.importDocument(name: FileCommands.stem(path), bytes: bytes, selection: sel, precomp: precomp) } catch {
            throw FileCommands.ioError(path, error)
        }
        let (i, color) = ColorCommands.openDocument(s, r.document, path: path)
        return ["document": .int(i), "color": color, "warnings": .strings(r.warnings)]
    }

    static func register(into r: inout CommandRegistry) {
        r.add([
            CommandSpec("file.exrParts", "EXR Parts Info", params: #"{"path":str (the EXR file)}"#, module: m, enabled: FileCommands.native, run: exrParts),
            CommandSpec("file.openExrParts", "Open EXR Parts…", menu: ["File"],
                        params: #"{"path":str (the EXR file),"view":"both|left|right"="both","part/<name>":bool (import this part as a layer),"group/<name>":bool (import this channel group as a layer),"precomp":bool=false (add the additive beauty precomp from the AOVs)}"#,
                        module: m, enabled: FileCommands.native, run: openExrParts),
        ])
    }
}
