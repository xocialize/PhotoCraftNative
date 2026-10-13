// Port of photocraft-engine (crates/engine/src/installed_profiles.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// ICC profiles installed in the operating system, as Photoshop lists them in Print › Printer
// Profile, View › Proof Setup › Custom and Edit › Convert to Profile: printer and paper profiles a
// user installs appear by their description, and the commands take the file's path. ColorSync's
// own iteration (`ColorSyncIterateInstalledProfiles`) lists them; `scan(dirs:)` walks folders the
// way photocraft does (also the fallback when ColorSync lists nothing).
//
// `edit.installedProfiles` lists them for agents; dialogs call `installed()`.

@preconcurrency import ColorSync
import Foundation
import PCDocument
import PCPlatform
import Synchronization

public enum InstalledProfilesCommands: CommandModule {
    public static let name = "installed_profiles"
    static let m = "installed_profiles"

    /// One installed profile.
    public struct Installed: Hashable, Sendable {
        /// The file, as the profile commands take it.
        public var path: String
        public var description: String
        public var deviceClass: ProfileClass
        public var colorSpace: ProfileColorSpace

        /// Whether a document can be assigned, converted or proofed to it (device and colour-space
        /// profiles in RGB, CMYK or Gray).
        public var isDestination: Bool {
            [.input, .display, .output, .colorSpace].contains(deviceClass) && [.rgb, .cmyk, .gray].contains(colorSpace)
        }
    }

    /// Folders scanned at most this deep (macOS keeps profiles in vendor subfolders).
    static let maxDepth = 3
    /// At most this many files are parsed per scan.
    static let maxFiles = 1000
    /// Larger files are not profiles anyone prints with.
    static let maxBytes = 32 << 20

    /// The operating system's colour profile folders.
    public static func profileDirs() -> [String] {
        var v = ["/System/Library/ColorSync/Profiles", "/Library/ColorSync/Profiles"]
        if let home = ProcessInfo.processInfo.environment["HOME"] { v.append((home as NSString).appendingPathComponent("Library/ColorSync/Profiles")) }
        return v
    }

    /// Every profile under `dirs` that parses, sorted by description; unreadable or malformed files
    /// are skipped.
    public static func scan(dirs: [String]) -> [Installed] {
        var files: [String] = []
        for d in dirs { collect(d, 0, &files) }
        return sorted(files.compactMap(readOne))
    }

    static func sorted(_ list: [Installed]) -> [Installed] {
        var out = list.sorted { a, b in
            let (x, y) = (a.description.lowercased(), b.description.lowercased())
            return x != y ? x < y : a.path < b.path
        }
        // Consecutive duplicates of one file.
        var i = 1
        while i < out.count {
            if out[i].path == out[i - 1].path { out.remove(at: i) } else { i += 1 }
        }
        return out
    }

    static func collect(_ dir: String, _ depth: Int, _ files: inout [String]) {
        if depth > maxDepth || files.count >= maxFiles { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for e in entries {
            if files.count >= maxFiles { return }
            let path = (dir as NSString).appendingPathComponent(e)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                collect(path, depth + 1, &files)
            } else {
                let ext = (e as NSString).pathExtension.lowercased()
                if ext == "icc" || ext == "icm" { files.append(path) }
            }
        }
    }

    static func readOne(_ path: String) -> Installed? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber, size.intValue <= maxBytes,
              let data = FileManager.default.contents(atPath: path), let p = try? ICCProfile(data: data) else { return nil }
        let d = p.profileDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = d.isEmpty ? ((path as NSString).lastPathComponent as NSString).deletingPathExtension : d
        return Installed(path: path, description: description, deviceClass: p.deviceClass, colorSpace: p.colorSpace)
    }

    /// The profile files ColorSync reports installed.
    static func colorSyncFiles() -> [String] {
        final class Box: @unchecked Sendable { var paths: [String] = [] }
        let box = Box()
        var err: Unmanaged<CFError>?
        ColorSyncIterateInstalledProfiles({ dict, info in
            guard let info, let dict = dict as? [String: Any] else { return true }
            let b = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            if b.paths.count >= InstalledProfilesCommands.maxFiles { return false }
            if let u = dict["com.apple.ColorSync.ProfileURL"] as? URL { b.paths.append(u.path) }
            return true
        }, nil, Unmanaged.passUnretained(box).toOpaque(), &err)
        err?.release()
        return box.paths
    }

    /// How long a listing is reused: dialogs ask every frame, and a newly installed profile shows
    /// up within this long.
    static let fresh: TimeInterval = 10
    private static let cache = Mutex<(Date, [Installed])?>(nil)

    /// The installed profiles (cached; see `fresh`).
    public static func installed() -> [Installed] {
        if let (at, list) = cache.withLock({ $0 }), Date().timeIntervalSince(at) < fresh { return list }
        var list = sorted(colorSyncFiles().compactMap(readOne))
        if list.isEmpty { list = scan(dirs: profileDirs()) }
        let l = list
        cache.withLock { $0 = (Date(), l) }
        return list
    }

    static func classId(_ c: ProfileClass) -> String {
        switch c {
        case .input: "input"
        case .display: "display"
        case .output: "output"
        case .link: "deviceLink"
        case .colorSpace: "colorSpace"
        case .abstract: "abstract"
        case .namedColor: "namedColor"
        case .unknown: "unknown"
        }
    }

    static func spaceId(_ c: ProfileColorSpace) -> String { ColorCommands.spaceName(c).lowercased() }

    static func list(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "edit.installedProfiles"
        let classes = ["any", "input", "display", "output", "deviceLink", "colorSpace", "abstract", "namedColor"]
        var cls = "any"
        if let v = p["class"], v != .null {
            guard let c = v.stringValue, classes.contains(c) else {
                throw EngineError.bad(cmd, "class is any|input|display|output|deviceLink|colorSpace|abstract|namedColor, not \(v.serialized())")
            }
            cls = c
        }
        var space = "any"
        if let v = p["colorSpace"], v != .null {
            guard let c = v.stringValue, ["any", "rgb", "cmyk", "gray"].contains(c) else {
                throw EngineError.bad(cmd, "colorSpace is any|rgb|cmyk|gray, not \(v.serialized())")
            }
            space = c
        }
        let profiles: [JSONValue] = installed()
            .filter { cls == "any" || classId($0.deviceClass) == cls }
            .filter { space == "any" || spaceId($0.colorSpace) == space }
            .map { ["path": .string($0.path), "description": .string($0.description), "class": .string(classId($0.deviceClass)),
                    "colorSpace": .string(spaceId($0.colorSpace))] }
        return ["profiles": .array(profiles), "dirs": .strings(profileDirs())]
    }

    public static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("edit.installedProfiles", "Installed Profiles",
                          params: #"{"class":"any|input|display|output|deviceLink|colorSpace|abstract|namedColor"="any","colorSpace":"any|rgb|cmyk|gray"="any"} → {profiles: [{path, description, class, colorSpace}], dirs} (the OS profile folders; pass a path as any command's "profile")"#,
                          module: m, journal: false, run: list))
    }
}
