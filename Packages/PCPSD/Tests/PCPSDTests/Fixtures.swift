// Where this target's tests find PhotoCraftNative's fixture data (kept outside git, see
// `PhotoCraftNative-Fixtures/README.md`). The convention every package follows:
// - the fixtures root is `PHOTOCRAFT_FIXTURES` when set, else `<PhotoCraftNative>/../PhotoCraftNative-Fixtures`
//   (found from this file's path) when that directory exists, else there is none;
// - a package's own variable (`PCPSD_CORPUS`, `PCPSD_PS_ORACLE`, …) overrides one folder; its
//   default is `<root>/<folder>`;
// - tests that need data are `.enabled(if:)` on it and skip with a reason when it is missing.
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation

enum Fixtures {
    /// The fixtures root, or nil.
    static let root: URL? = {
        if let p = ProcessInfo.processInfo.environment["PHOTOCRAFT_FIXTURES"] { return existing(p) }
        // <PhotoCraftNative>/Packages/PCPSD/Tests/<Target>/Fixtures.swift
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 { url.deleteLastPathComponent() }
        return existing(url.deletingLastPathComponent().appendingPathComponent("PhotoCraftNative-Fixtures").path)
    }()

    /// The directory the environment variable `name` names when it is set, else `<root>/<folder>`;
    /// nil unless it exists.
    static func directory(_ name: String, default folder: String) -> URL? {
        if let p = ProcessInfo.processInfo.environment[name] { return existing(p) }
        return root.flatMap { existing($0.appendingPathComponent(folder).path) }
    }

    /// The file the environment variable `name` names when it is set, else `<root>/<path>`; nil
    /// unless it exists.
    static func file(_ name: String, default path: String) -> URL? {
        let p = ProcessInfo.processInfo.environment[name] ?? root?.appendingPathComponent(path).path
        guard let p, FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }

    static func existing(_ p: String) -> URL? {
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &dir), dir.boolValue else { return nil }
        return URL(fileURLWithPath: p)
    }
}
