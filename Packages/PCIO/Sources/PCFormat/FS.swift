// Small POSIX helpers with Rust `std::fs` semantics (errno-carrying errors, symlink-aware stat),
// shared by directory bundles, atomic saves and autosave.
// Port support for photocraft-format (crates/format/src/{store,atomic,autosave}.rs), MIT OR
// Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation

enum FS {
    enum Kind { case file, directory, symlink, other }

    /// `lstat`: what is at `path` without following a final symlink (nil when nothing is).
    static func lkind(_ path: String) throws(IOError) -> Kind? {
        var st = stat()
        if lstat(path, &st) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw IOError.last(path)
        }
        return kind(st.st_mode)
    }

    /// `stat`: what `path` resolves to (nil when nothing is).
    static func kindFollowing(_ path: String) -> Kind? {
        var st = stat()
        if stat(path, &st) != 0 { return nil }
        return kind(st.st_mode)
    }

    static func kind(_ mode: mode_t) -> Kind {
        switch mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .directory
        case S_IFLNK: .symlink
        default: .other
        }
    }

    static func isDir(_ path: String) -> Bool { kindFollowing(path) == .directory }
    static func isFile(_ path: String) -> Bool { kindFollowing(path) == .file }
    static func exists(_ path: String) -> Bool { kindFollowing(path) != nil }

    /// `fs::create_dir_all`.
    static func createDirAll(_ path: String) throws(IOError) {
        if path.isEmpty || isDir(path) { return }
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty && parent != path { try createDirAll(parent) }
        if mkdir(path, 0o777) != 0 {
            let e = errno
            if e == EEXIST && isDir(path) { return }
            throw IOError(errno: e, "cannot create the folder \(path)")
        }
    }

    /// `fs::canonicalize` (`realpath`).
    static func canonicalize(_ path: String) throws(IOError) -> String {
        guard let p = realpath(path, nil) else { throw IOError.last(path) }
        defer { free(p) }
        return String(cString: p)
    }

    /// `fs::remove_dir_all` (does not follow symlinks).
    static func removeDirAll(_ path: String) throws(IOError) {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            if !exists(path) && (try? lkind(path)) == nil { return }
            throw IOError(.other, "\(path): \(error.localizedDescription)")
        }
    }

    /// `fs::remove_file`.
    static func removeFile(_ path: String) throws(IOError) {
        if unlink(path) != 0 { throw IOError.last(path) }
    }

    /// Entry names of a directory (no `.`/`..`).
    static func list(_ path: String) throws(IOError) -> [String] {
        guard let d = opendir(path) else { throw IOError.last(path) }
        defer { closedir(d) }
        var out: [String] = []
        while let e = readdir(d) {
            let name = withUnsafePointer(to: e.pointee.d_name) { p in
                p.withMemoryRebound(to: CChar.self, capacity: Int(e.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { out.append(name) }
        }
        return out
    }

    /// Modification time of `path` (without following a final symlink), as seconds since 1970.
    static func modified(_ path: String) -> Double? {
        var st = stat()
        if lstat(path, &st) != 0 { return nil }
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    }

    /// Reads a whole file.
    static func read(_ path: String) throws(IOError) -> [UInt8] {
        try FileRead.readFile(URL(fileURLWithPath: path))
    }

    static func join(_ a: String, _ b: String) -> String { (a as NSString).appendingPathComponent(b) }
}
