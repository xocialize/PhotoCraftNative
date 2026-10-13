// Port of photocraft-engine (crates/engine/src/brush_preset_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Organising brush presets (the Brushes panel's drag and drop and context menus): rename, move a
// preset within or between groups and folders, move, rename and delete whole groups and folders.
// Groups are the panel's top-level folders (`BrushPreset.group`); a group can hold nested folders
// (`BrushPreset.folder`, a path inside the group). The library order is the panel order: groups
// appear in order of their first preset, and a group's folders and presets in order of their
// first preset too. A built-in that is renamed or moved to another group becomes the user's preset.

import Foundation
import PCDocument
import PCPaint

enum BrushPresetCommands: CommandModule {
    static let name = "brush_preset_cmds"
    static let m = "brush_preset_cmds"

    /// Longest preset or group name accepted.
    static let maxName = 255
    /// Deepest folder path accepted inside a group (photocraft-psd's `.abr` reader limit).
    static let maxFolderDepth = 32

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }
    static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func chars(_ s: String) -> Int { s.unicodeScalars.count }

    static func text(_ p: JSONValue, _ k: String, _ cmd: String) throws -> String {
        guard let v = p[k]?.stringValue.map(trim), !v.isEmpty else { throw bad(cmd, "missing `\(k)`") }
        if chars(v) > maxName { throw bad(cmd, "`\(k)` is longer than \(maxName) characters") }
        return v
    }

    /// A group name param: may be empty (the ungrouped presets), never absurdly long.
    static func groupParam(_ p: JSONValue, _ k: String, _ cmd: String) throws -> String? {
        switch p[k] {
        case nil, .null?: return nil
        case .string(let g)? where chars(g) <= maxName: return trim(g)
        default: throw bad(cmd, "`\(k)` must be a group name (string, at most \(maxName) characters)")
        }
    }

    /// A folder path param (`["Outer", "Inner"]`, inside the group): nil when absent or null.
    static func folderParam(_ p: JSONValue, _ cmd: String) throws -> [String]? {
        let err = bad(cmd, "`folder` must be a list of at most \(maxFolderDepth) folder names (non-empty strings of at most \(maxName) characters)")
        switch p["folder"] {
        case nil, .null?: return nil
        case .array(let a)? where a.count <= maxFolderDepth:
            return try a.map { v in
                guard let n = v.stringValue.map(trim), !n.isEmpty, chars(n) <= maxName else { throw err }
                return n
            }
        default: throw err
        }
    }

    /// Is `x` in folder `f` of group `g`, directly or below it?
    static func inFolder(_ x: BrushPreset, _ g: String, _ f: [String]) -> Bool {
        x.group == g && x.folder.starts(with: f)
    }

    /// The subfolders directly inside folder `parent` of group `g`, in panel order.
    static func subfolderOrder(_ presets: [BrushPreset], _ g: String, _ parent: [String]) -> [String] {
        var out: [String] = []
        for x in presets where inFolder(x, g, parent) && x.folder.count > parent.count {
            let n = x.folder[parent.count]
            if !out.contains(n) { out.append(n) }
        }
        return out
    }

    static func indexOf(_ presets: [BrushPreset], _ name: String) -> Int? {
        presets.firstIndex { BrushCommands.eqi($0.name, name) }
    }

    static func find(_ s: Session, _ p: JSONValue, _ k: String, _ cmd: String) throws -> Int {
        let name = try text(p, k, cmd)
        guard let i = indexOf(s.tools.presets, name) else { throw bad(cmd, "no brush preset named `\(name)`") }
        return i
    }

    /// Groups in panel order (first appearance).
    static func groupOrder(_ presets: [BrushPreset]) -> [String] {
        var out: [String] = []
        for p in presets where !out.contains(p.group) { out.append(p.group) }
        return out
    }

    static func positionInGroup(_ presets: [BrushPreset], _ i: Int) -> Int {
        guard i < presets.count else { return 0 }
        let g = presets[i].group
        return presets[..<i].filter { $0.group == g }.count
    }

    /// A non-negative integer `index` param (nil when absent or null); huge ones (`u64::MAX`)
    /// clamp to the end.
    static func indexParam(_ p: JSONValue, _ cmd: String) throws -> Int? {
        switch p["index"] {
        case nil, .null?: return nil
        case .number(let n)? where n.isFinite && n >= 0 && n == n.rounded():
            return n >= 9.2e18 ? Int.max : Int(n)
        default: throw bad(cmd, "`index` must be a non-negative integer")
        }
    }

    static func changed(_ s: Session) { BrushCommands.presetsChanged(s) }

    static func rename(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "brush.presets.rename"
        let i = try find(s, p, "name", cmd)
        let new = try text(p, "newName", cmd)
        if let j = indexOf(s.tools.presets, new), j != i { throw bad(cmd, "a brush preset named `\(new)` already exists") }
        guard i < s.tools.presets.count else { throw bad(cmd, "no such preset") }
        let old = s.tools.presets[i].name
        if old != new {
            let wasCurrent = s.tools.currentPreset.map { BrushCommands.eqi($0, old) } ?? false
            s.tools.presets[i].name = new
            s.tools.presets[i].builtin = false
            if wasCurrent { s.tools.currentPreset = new }
            changed(s)
        }
        return ["name": .string(new)]
    }

    static func movePreset(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "brush.presets.move"
        let i = try find(s, p, "name", cmd)
        var before: Int?
        if let v = p["before"], v != .null {
            let b = try find(s, p, "before", cmd)
            if b == i { throw bad(cmd, "`before` names the preset being moved") }
            before = b
        }
        let index = try indexParam(p, cmd)
        let folder = try folderParam(p, cmd)
        let group = try groupParam(p, "group", cmd)
        var lib = s.tools.presets
        guard i < lib.count else { throw bad(cmd, "no such preset") }
        let moving = lib[i]
        let beforePr = before.flatMap { $0 < lib.count ? lib[$0] : nil }
        let target = group ?? beforePr?.group ?? moving.group
        // The folder: as given, else `before`'s, else its own when it stays in its group.
        let targetFolder: [String] = folder ?? beforePr?.folder ?? (moving.group == target ? moving.folder : [])
        if let b = beforePr {
            if b.group != target { throw bad(cmd, "`before` is not in group `\(target)`") }
            if b.folder != targetFolder { throw bad(cmd, "`before` is not in that folder") }
        }
        let beforeName = beforePr?.name
        var pr = lib.remove(at: i)
        if pr.group != target || pr.folder != targetFolder {
            pr.group = target
            pr.folder = targetFolder
            // A built-in moved elsewhere is the user's now (built-ins regenerate in their own group).
            pr.builtin = false
        }
        let members = lib.indices.filter { lib[$0].group == target }
        // Appended: after the folder's last preset (or the group's, for a new folder).
        let end = (lib.lastIndex { inFolder($0, target, targetFolder) } ?? members.last).map { $0 + 1 } ?? lib.count
        var pos: Int
        if let n = beforeName {
            pos = indexOf(lib, n) ?? lib.count
        } else if let n = index {
            let k = n
            pos = k < members.count ? members[k] : (members.last.map { $0 + 1 } ?? lib.count)
        } else {
            pos = end
        }
        pos = min(pos, lib.count)
        let name = pr.name
        lib.insert(pr, at: pos)
        let at = positionInGroup(lib, pos)
        s.tools.presets = lib
        changed(s)
        return ["name": .string(name), "group": .string(target), "folder": .strings(targetFolder), "index": .int(at)]
    }

    static func groupBlock(_ s: Session, _ g: String, _ cmd: String) throws {
        if !s.tools.presets.contains(where: { $0.group == g }) { throw bad(cmd, "no brush preset group named `\(g)`") }
    }

    /// The group and (possibly empty) folder path a group command acts on; both must exist.
    static func targetFolder(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> (String, [String]) {
        guard let g = try groupParam(p, "group", cmd) else { throw bad(cmd, "missing `group`") }
        try groupBlock(s, g, cmd)
        let f = try folderParam(p, cmd) ?? []
        if !s.tools.presets.contains(where: { inFolder($0, g, f) }) {
            throw bad(cmd, "no folder `\(f.joined(separator: "/"))` in brush preset group `\(g)`")
        }
        return (g, f)
    }

    /// Move folder `f` (non-empty) of group `g` among its sibling folders, as a block.
    static func moveFolder(_ s: Session, _ p: JSONValue, _ g: String, _ f: [String], _ cmd: String) throws -> JSONValue {
        guard let leaf = f.last else { throw bad(cmd, "missing `folder`") }
        let parent = Array(f.dropLast())
        let siblings = subfolderOrder(s.tools.presets, g, parent)
        var before: String?
        switch p["before"] {
        case nil, .null?: before = nil
        case .string(let b)? where b == leaf: throw bad(cmd, "`before` names the folder being moved")
        case .string(let b)? where siblings.contains(b): before = b
        default: throw bad(cmd, "`before` must name a folder next to the one being moved")
        }
        let index = try indexParam(p, cmd)
        let lib = s.tools.presets
        // Where the block sits among the other presets (its place when nothing else is in the parent).
        let start = lib.firstIndex { inFolder($0, g, f) } ?? 0
        let block = lib.filter { inFolder($0, g, f) }
        var rest = lib.filter { !inFolder($0, g, f) }
        func sibling(_ name: String) -> [String] { parent + [name] }
        func first(_ name: String) -> Int { rest.firstIndex { inFolder($0, g, sibling(name)) } ?? rest.count }
        let others = siblings.filter { $0 != leaf }
        func parentEnd() -> Int { rest.lastIndex { inFolder($0, g, parent) }.map { $0 + 1 } ?? start }
        let pos: Int
        if let b = before {
            pos = first(b)
        } else if let n = index {
            let k = n
            pos = k < others.count ? first(others[k]) : parentEnd()
        } else {
            pos = parentEnd()
        }
        rest.insert(contentsOf: block, at: min(pos, rest.count))
        s.tools.presets = rest
        changed(s)
        let at = subfolderOrder(s.tools.presets, g, parent).firstIndex(of: leaf) ?? 0
        return ["group": .string(g), "folder": .strings(f), "index": .int(at)]
    }

    /// Where `into` puts a folder: `.some(nil)` = the top level (it becomes a group),
    /// `.some((group, folder))` = inside that folder of that group (`[]`: directly in the group).
    typealias Dest = (String, [String])?

    static func intoParam(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> Dest? {
        let into: JSONValue
        switch p["into"] {
        case nil, .null?: return .none
        case let v? where v.objectValue != nil: into = v
        default: throw bad(cmd, "`into` must be an object {group?, folder?}")
        }
        guard let g = try groupParam(into, "group", cmd) else {
            if let f = try folderParam(into, cmd), !f.isEmpty { throw bad(cmd, "`into.folder` needs `into.group`") }
            return .some(.none)
        }
        try groupBlock(s, g, cmd)
        let f = try folderParam(into, cmd) ?? []
        if !s.tools.presets.contains(where: { inFolder($0, g, f) }) {
            throw bad(cmd, "no folder `\(f.joined(separator: "/"))` in brush preset group `\(g)`")
        }
        return .some((g, f))
    }

    /// Move folder `f` of group `g` (the whole group when `f` is empty) into `dest`, keeping its
    /// content and the order of its presets: Photoshop's drag of a folder onto another folder. It
    /// lands at the end of the destination, or before the sibling folder (group at the top level)
    /// named by `before`.
    static func moveInto(_ s: Session, _ p: JSONValue, _ g: String, _ f: [String], _ dest: Dest, _ cmd: String) throws -> JSONValue {
        if let v = p["index"], v != .null { throw bad(cmd, "`index` can't be combined with `into` (use `before`)") }
        let leaf: String
        if let l = f.last {
            leaf = l
        } else if g.isEmpty {
            throw bad(cmd, "the ungrouped presets are not a folder that can be moved")
        } else {
            leaf = g
        }
        func moving(_ x: BrushPreset) -> Bool { inFolder(x, g, f) }
        func restOf(_ x: BrushPreset) -> [String] { x.folder.count >= f.count ? Array(x.folder[f.count...]) : [] }
        var before: String?
        switch p["before"] {
        case nil, .null?: before = nil
        case .string(let b)?: before = trim(b)
        default: throw bad(cmd, "`before` must be a folder name")
        }
        // The destination's own folders and groups, without the one being moved.
        let others = s.tools.presets.filter { !moving($0) }
        let newGroup: String, newPrefix: [String], siblings: [String]
        if let d = dest {
            let (dg, df) = d
            if dg == g && df.starts(with: f) { throw bad(cmd, "`into` names the folder being moved or one of its own folders") }
            newGroup = dg
            newPrefix = df + [leaf]
            siblings = subfolderOrder(others, dg, df)
        } else {
            if f.isEmpty { throw bad(cmd, "`into`: the group is already at the top level") }
            newGroup = leaf
            newPrefix = []
            siblings = groupOrder(others)
        }
        if siblings.contains(leaf) { throw bad(cmd, "a folder named `\(leaf)` already exists there") }
        if let b = before, !siblings.contains(b) { throw bad(cmd, "`before`: no folder named `\(b)` there") }
        let deepest = s.tools.presets.filter(moving).map { newPrefix.count + restOf($0).count }.max() ?? 0
        if deepest > maxFolderDepth { throw bad(cmd, "folders can be nested at most \(maxFolderDepth) deep") }
        let lib = s.tools.presets
        var block = lib.filter { inFolder($0, g, f) }
        var rest = lib.filter { !inFolder($0, g, f) }
        for i in block.indices {
            let tail = restOf(block[i])
            block[i].group = newGroup
            block[i].folder = newPrefix + tail
            block[i].builtin = false
        }
        let pos: Int?
        if let d = dest {
            if let b = before {
                pos = rest.firstIndex { inFolder($0, d.0, d.1 + [b]) }
            } else {
                pos = rest.lastIndex { inFolder($0, d.0, d.1) }.map { $0 + 1 }
            }
        } else if let b = before {
            pos = rest.firstIndex { $0.group == b }
        } else {
            pos = nil
        }
        rest.insert(contentsOf: block, at: min(pos ?? rest.count, rest.count))
        s.tools.presets = rest
        changed(s)
        let folder = Array(newPrefix.dropLast())
        let at = dest == nil ? groupOrder(s.tools.presets).firstIndex(of: newGroup) : subfolderOrder(s.tools.presets, newGroup, folder).firstIndex(of: leaf)
        return ["group": .string(newGroup), "folder": .strings(newPrefix), "index": .int(at ?? 0)]
    }

    static func moveGroup(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "brush.presets.moveGroup"
        let (g, f) = try targetFolder(s, p, cmd)
        if let dest = try intoParam(s, p, cmd) { return try moveInto(s, p, g, f, dest, cmd) }
        if !f.isEmpty { return try moveFolder(s, p, g, f, cmd) }
        let before = try groupParam(p, "before", cmd)
        if let b = before {
            try groupBlock(s, b, cmd)
            if b == g { throw bad(cmd, "`before` names the group being moved") }
        }
        let index = try indexParam(p, cmd)
        let lib = s.tools.presets
        let block = lib.filter { $0.group == g }
        var rest = lib.filter { $0.group != g }
        let order = groupOrder(rest)
        func first(_ name: String) -> Int { rest.firstIndex { $0.group == name } ?? rest.count }
        let pos: Int
        if let b = before {
            pos = first(b)
        } else if let n = index {
            let k = n
            pos = k < order.count ? first(order[k]) : rest.count
        } else {
            pos = rest.count
        }
        rest.insert(contentsOf: block, at: min(pos, rest.count))
        s.tools.presets = rest
        changed(s)
        let at = groupOrder(s.tools.presets).firstIndex(of: g) ?? 0
        return ["group": .string(g), "index": .int(at)]
    }

    static func renameGroup(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "brush.presets.renameGroup"
        let (g, f) = try targetFolder(s, p, cmd)
        let new = try text(p, "newName", cmd)
        if let leaf = f.last {
            let parent = Array(f.dropLast())
            if new != leaf {
                if subfolderOrder(s.tools.presets, g, parent).contains(new) { throw bad(cmd, "a folder named `\(new)` already exists there") }
                let depth = parent.count
                for i in s.tools.presets.indices where inFolder(s.tools.presets[i], g, f) {
                    if depth < s.tools.presets[i].folder.count { s.tools.presets[i].folder[depth] = new }
                    s.tools.presets[i].builtin = false
                }
                changed(s)
            }
            return ["group": .string(g), "folder": .strings(parent + [new])]
        }
        if new != g && s.tools.presets.contains(where: { $0.group == new }) { throw bad(cmd, "a group named `\(new)` already exists") }
        if new != g {
            for i in s.tools.presets.indices where s.tools.presets[i].group == g {
                s.tools.presets[i].group = new
                s.tools.presets[i].builtin = false
            }
            changed(s)
        }
        return ["group": .string(new)]
    }

    static func deleteGroup(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "brush.presets.deleteGroup"
        let (g, f) = try targetFolder(s, p, cmd)
        let before = s.tools.presets.count
        s.tools.presets.removeAll { inFolder($0, g, f) }
        if let c = s.tools.currentPreset, !s.tools.presets.contains(where: { BrushCommands.eqi($0.name, c) }) { s.tools.currentPreset = nil }
        changed(s)
        return ["deleted": .int(before - s.tools.presets.count), "count": .int(s.tools.presets.count)]
    }

    static func register(into r: inout CommandRegistry) {
        r.add([
            CommandSpec("brush.presets.rename", "Rename Brush", params: #"{"name":string,"newName":string} → {name}"#, module: m, run: rename),
            CommandSpec("brush.presets.move", "Move Brush",
                        params: #"{"name":string,"group":string?=its group ("" = ungrouped),"folder":[name]? (nested folder names in the group, outermost first; [] = the group itself)=before's folder, else its own if it stays in its group, else [],"before":name? (preset to land before, in that folder) | "index":n? (position in the group)=end of the folder} → {name, group, folder, index}"#,
                        module: m, run: movePreset),
            CommandSpec("brush.presets.moveGroup", "Move Brush Group",
                        params: #"{"group":string,"folder":[name]? (move this nested folder instead),"into":{"group":string?,"folder":[name]?}? (move it inside that folder of that group, [] = directly in the group; no group = out to the top level as a group of its own; the folder keeps its content),"before":group? (or sibling folder name, in its new place with `into`) | "index":n? (group or sibling folder position, without `into`)=end} → {group, folder?, index}"#,
                        module: m, run: moveGroup),
            CommandSpec("brush.presets.renameGroup", "Rename Brush Group",
                        params: #"{"group":string,"folder":[name]? (rename this nested folder instead),"newName":string} → {group, folder?}"#,
                        module: m, run: renameGroup),
            CommandSpec("brush.presets.deleteGroup", "Delete Brush Group",
                        params: #"{"group":string,"folder":[name]? (delete this nested folder instead)} → {deleted, count}"#,
                        module: m, run: deleteGroup),
        ])
    }
}
