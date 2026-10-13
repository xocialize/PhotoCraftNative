// The bridge to Adobe Photoshop: every call runs one ExtendScript through `osascript` (`do javascript`)
// under a cross-process lock, with a hard timeout and a recovery check that stops the run instead of
// looping when Photoshop no longer answers (a modal dialog, a licence or sign-in prompt, a hang).

import Darwin
import Foundation
import PCPSD

public enum OracleError: Error, CustomStringConvertible {
    case usage(String)
    case pathNotAllowed(String)
    case scriptMissing(String)
    case photoshopFailed(String)
    case timedOut(script: String, seconds: Double)
    case unresponsive(String)
    case badOutput(String)
    case notRunning
    case crashed(String)
    case documentsOpen([String])
    case quarantined(String, String)
    case modal(String)

    /// Photoshop is gone or blocked: the run must stop rather than go on to the next file.
    public var isFatal: Bool {
        switch self {
        case .unresponsive, .notRunning, .crashed, .documentsOpen, .modal, .timedOut: true
        default: false
        }
    }

    public var description: String {
        switch self {
        case let .usage(s): "usage: \(s)"
        case let .pathNotAllowed(p): "refusing a path outside the allowed roots: \(p)"
        case let .scriptMissing(s): "missing ExtendScript resource \(s).jsx"
        case let .photoshopFailed(s): "Photoshop/osascript error: \(s)"
        case let .timedOut(s, t): "Photoshop did not finish \(s) within \(Int(t)) s"
        case let .unresponsive(s): "Photoshop is not answering scripts (\(s)). A modal dialog, licence or sign-in prompt may be showing: check Photoshop by hand. Stopping."
        case let .badOutput(s): "unparseable script output: \(s.prefix(300))"
        case .notRunning: "Photoshop is not running. ps-oracle never launches it (a launch can bring up sign-in, licence or crash-recovery prompts): start Photoshop by hand. Stopping."
        case let .crashed(s): "Photoshop quit while running a script — it crashed (\(s)). ps-oracle does not relaunch it. Stopping."
        case let .documentsOpen(d): "Photoshop has \(d.count) document(s) open (\(d.prefix(5).joined(separator: ", "))). A run starts only with none open; close them (ps-oracle cleanup closes only ps-oracle's own). Stopping."
        case let .modal(s): "Photoshop showed a modal dialog (\(s)). The run stops at the first modal; no further scripts are sent."
        case let .quarantined(f, r): "\(f) is quarantined (\(r)); it is not opened without --allow-quarantined \"<hypothesis>\""
        }
    }
}

/// Where the oracle may read and write. Everything else is refused before Photoshop sees it.
public struct OracleConfig: Sendable {
    /// The data root (`PS_ORACLE_SCRATCH`; default: PhotoCraftNative's fixtures root): corpora,
    /// measurement batches, `ps-oracle/` reports, `blend-table.json` and `quarantine.json`.
    public var scratch: URL
    public var toolDirectory: URL
    public var timeout: Double
    public var lockPath: String
    public var verbose: Bool

    /// PhotoCraftNative's fixtures root, the default data root: `PHOTOCRAFT_FIXTURES` when set, else
    /// `<PhotoCraftNative>/../PhotoCraftNative-Fixtures`, found from this file's path (it need not
    /// exist yet: the commands that write create it).
    public static func fixturesRoot(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let p = env["PHOTOCRAFT_FIXTURES"], !p.isEmpty { return p }
        // <PhotoCraftNative>/Tools/PhotoshopOracle/Sources/PSOracleKit/Photoshop.swift
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 { url.deleteLastPathComponent() }
        return url.deletingLastPathComponent().appendingPathComponent("PhotoCraftNative-Fixtures").path
    }

    /// The data root for `env`: `PS_ORACLE_SCRATCH` when set, else the fixtures root.
    public static func dataRoot(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let p = env["PS_ORACLE_SCRATCH"], !p.isEmpty { return p }
        return fixturesRoot(env)
    }

    public init(environment env: [String: String] = ProcessInfo.processInfo.environment, toolDirectory: URL) {
        scratch = URL(fileURLWithPath: Self.dataRoot(env)).standardizedFileURL.resolvingSymlinksInPath()
        self.toolDirectory = toolDirectory.standardizedFileURL.resolvingSymlinksInPath()
        timeout = Double(env["PS_ORACLE_TIMEOUT"] ?? "") ?? 180
        lockPath = env["PS_ORACLE_LOCK"] ?? scratch.appendingPathComponent("ps-oracle.lock").path
        verbose = env["PS_ORACLE_VERBOSE"] != nil
    }

    public var allowedRoots: [String] { [scratch.path + "/", toolDirectory.path + "/"] }

    /// The canonical absolute path of `path`, or a thrown error when it is outside the allowed roots.
    public func checked(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // Resolve symlinks on the deepest existing ancestor (the file itself may not exist yet).
        var existing = url
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for t in tail { resolved.appendPathComponent(t) }
        let p = resolved.path
        guard allowedRoots.contains(where: { p.hasPrefix($0) }), !p.contains("/../") else { throw OracleError.pathNotAllowed(p) }
        return p
    }
}

/// A cross-process exclusive lock (flock) on a file. A second ps-oracle waits for the first.
///
/// The kernel drops an flock when its holder exits, however it dies, so a crash can never wedge the
/// lock itself. The file's text (the holder's pid) is only a note: it is cleared on release, and a
/// note naming a pid that is no longer alive is reported as stale and overwritten. While waiting,
/// a holder that died without the kernel releasing its lock (cannot normally happen) is detected and
/// the wait gives up instead of hanging.
public final class PhotoshopLock: @unchecked Sendable {
    private let fd: Int32

    static func holderPID(_ text: String) -> pid_t? {
        let parts = text.split(separator: " ")
        guard parts.count >= 2, parts[0] == "pid", let p = Int32(parts[1]) else { return nil }
        return p
    }

    static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    public init(path: String, log: (String) -> Void) throws {
        fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw OracleError.photoshopFailed("cannot open lock file \(path): errno \(errno)") }
        let note = (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            log("waiting for the Photoshop lock (\(path)) held by \(note.isEmpty ? "another process" : note)…")
            var told = false
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                if !told, let h = Self.holderPID((try? String(contentsOfFile: path, encoding: .utf8)) ?? ""), !Self.isAlive(h) {
                    told = true
                    // flock is released by the kernel on exit, so this means another process holds
                    // it without updating the note: keep waiting, but say so once.
                    log("lock note names pid \(h), which is not running; still waiting for the current holder")
                }
                usleep(500_000)
            }
        } else if let h = Self.holderPID(note), h != getpid(), !Self.isAlive(h) {
            log("stale lock note from pid \(h) (not running); taking over")
        }
        let text = "pid \(getpid()) since \(ISO8601DateFormatter().string(from: Date()))\n"
        _ = ftruncate(fd, 0)
        _ = lseek(fd, 0, SEEK_SET)
        _ = text.withCString { write(fd, $0, strlen($0)) }
    }

    deinit {
        _ = ftruncate(fd, 0)
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// Runs a child process with a hard timeout; output goes through temporary files, so a large report
/// can never block on a full pipe.
enum ProcessRunner {
    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }

    static func run(_ executable: String, _ arguments: [String], timeout: Double, tempDirectory: URL) throws -> Result {
        let id = UUID().uuidString
        let outURL = tempDirectory.appendingPathComponent("ps-oracle-\(id).out")
        let errURL = tempDirectory.appendingPathComponent("ps-oracle-\(id).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.standardOutput = try FileHandle(forWritingTo: outURL)
        p.standardError = try FileHandle(forWritingTo: errURL)
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while p.isRunning {
            if Date() > deadline {
                timedOut = true
                p.terminate()
                let grace = Date().addingTimeInterval(3)
                while p.isRunning, Date() < grace { usleep(50_000) }
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                break
            }
            usleep(20_000)
        }
        p.waitUntilExit()
        let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return Result(status: p.terminationStatus, stdout: out, stderr: err, timedOut: timedOut)
    }
}

/// One Photoshop session: the lock is held from `init` until the object is released.
public final class Photoshop: @unchecked Sendable {
    public let config: OracleConfig
    private let lock: PhotoshopLock
    private let log: (String) -> Void
    private let tempDirectory: URL
    public private(set) var calls = 0

    public private(set) var quarantine: Quarantine
    /// The caller's hypothesis for opening quarantined files (nil: refuse them).
    public var quarantineOverride: String?

    public init(config: OracleConfig, log: @escaping (String) -> Void, preflight: Bool = true) throws {
        self.config = config
        self.log = log
        try FileManager.default.createDirectory(at: config.scratch, withIntermediateDirectories: true)
        tempDirectory = config.scratch.appendingPathComponent("ps-oracle-tmp")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        quarantine = Quarantine(scratch: config.scratch)
        lock = try PhotoshopLock(path: config.lockPath, log: log)
        if preflight { try self.preflight() }
    }

    /// Before a run: Photoshop is up, answers a script, and has no documents open.
    public func preflight() throws {
        guard Self.isRunning else { throw OracleError.notRunning }
        let p = try run("ping", [:], timeout: 30, recover: false)
        guard p["ok"] as? Bool == true else { throw OracleError.unresponsive("ping: \(p)") }
        let docs = (p["documents"] as? [[String: Any]]) ?? []
        if !docs.isEmpty {
            let names = docs.map { ($0["path"] as? String) ?? ($0["name"] as? String ?? "?") }
            throw OracleError.documentsOpen(names)
        }
    }

    /// Refuses a quarantined file unless a hypothesis was given (then logs it).
    public func admit(_ file: URL) throws {
        if quarantine.entry(for: file) == nil, let f = try? PSDFile(contentsOf: file) {
            if let why = CrashSignatures.match(f) ?? TypeSizeScreen.violation(f) ?? LinterScreen.violation(f) {
                quarantine(file, reason: why)
            } else if let table = BlendTable.load(config.scratch) {
                if let why = table.violation(f) { quarantine(file, reason: why) }
            } else {
                throw OracleError.usage("no measured blend-mode table: run `ps-oracle blend-table` before opening files")
            }
        }
        guard let e = quarantine.entry(for: file) else { return }
        guard let why = quarantineOverride else { throw OracleError.quarantined(file.lastPathComponent, e.reason) }
        log("opening QUARANTINED \(file.lastPathComponent) (\(e.reason)) to test: \(why)")
    }

    /// Records that `file` crashed or hung Photoshop.
    public func quarantine(_ file: URL, reason: String) {
        do { try quarantine.add(file, reason: reason) } catch { log("could not write the quarantine list: \(error)") }
        log("quarantined \(file.lastPathComponent): \(reason)")
    }

    /// Scripts that also need the content builders (`builders.jsx`, the C.* helpers).
    static let includes: [String: [String]] = ["corpus": ["builders"], "measure-m1": ["builders", "measure-common"], "measure-m2": ["builders", "measure-common"], "measure-m3": ["builders", "measure-common"], "lut-probe": ["builders"]]

    /// The ExtendScript source of `name` (a JSX resource) with `lib.jsx`, its includes and the
    /// arguments prepended.
    public static func script(_ name: String, arguments: [String: Any]) throws -> String {
        guard let libURL = Bundle.module.url(forResource: "lib", withExtension: "jsx", subdirectory: "JSX"),
              let url = Bundle.module.url(forResource: name, withExtension: "jsx", subdirectory: "JSX") else {
            throw OracleError.scriptMissing(name)
        }
        var extra = ""
        for inc in includes[name] ?? [] {
            guard let u = Bundle.module.url(forResource: inc, withExtension: "jsx", subdirectory: "JSX") else { throw OracleError.scriptMissing(inc) }
            extra += (try String(contentsOf: u, encoding: .utf8)) + "\n"
        }
        let args = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        // U+2028/2029 are legal in JSON but end a line in ES3 string literals.
        let argText = String(decoding: args, as: UTF8.self).replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "var ARGS = \(argText);\n" + (try String(contentsOf: libURL, encoding: .utf8)) + "\n" + extra + (try String(contentsOf: url, encoding: .utf8))
    }

    /// Runs a JSX resource and returns its raw result string.
    public func runRaw(_ name: String, _ arguments: [String: Any], timeout: Double? = nil, recover: Bool = true) throws -> String {
        var args = arguments
        args["allowedRoots"] = config.allowedRoots
        return try runSource(try Self.script(name, arguments: args), label: name, timeout: timeout, recover: recover)
    }

    /// Runs a script file of the caller's (debugging aid) with `lib.jsx` and the arguments prepended.
    public func runFile(_ url: URL, _ arguments: [String: Any], timeout: Double? = nil) throws -> String {
        var args = arguments
        args["allowedRoots"] = config.allowedRoots
        guard let libURL = Bundle.module.url(forResource: "lib", withExtension: "jsx", subdirectory: "JSX") else { throw OracleError.scriptMissing("lib") }
        let argText = String(decoding: try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]), as: UTF8.self)
        let source = "var ARGS = \(argText);\n" + (try String(contentsOf: libURL, encoding: .utf8)) + "\n" + (try String(contentsOf: url, encoding: .utf8))
        return try runSource(source, label: url.lastPathComponent, timeout: timeout, recover: true)
    }

    /// Whether Photoshop is running. `osascript … tell application` would launch it otherwise.
    /// Asks the kernel (libproc: every pid's executable path) rather than NSRunningApplication,
    /// whose list goes stale in a command-line process that never runs the main run loop (it once
    /// reported a live Photoshop as gone mid-sweep).
    public static var isRunning: Bool {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return true }   // cannot tell: do not claim Photoshop is gone
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size)) }
        guard got > 0 else { return true }
        var path = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(got)) where pid > 0 {
            let len = proc_pidpath(pid, &path, UInt32(path.count))
            guard len > 0 else { continue }
            let p = String(decoding: path.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if p.contains("/Adobe Photoshop"), p.hasSuffix(".app/Contents/MacOS/" + (p.split(separator: "/").last.map(String.init) ?? "")), p.contains(".app/Contents/MacOS/Adobe Photoshop") {
                return true
            }
        }
        return false
    }

    func runSource(_ source: String, label name: String, timeout: Double?, recover: Bool) throws -> String {
        guard Self.isRunning else { throw OracleError.notRunning }
        let t = timeout ?? config.timeout
        calls += 1
        let as_ = [
            "-e", "on run argv",
            "-e", "with timeout of \(Int(t) + 30) seconds",
            "-e", "tell application id \"com.adobe.Photoshop\" to do javascript (item 1 of argv)",
            "-e", "end timeout",
            "-e", "end run",
            source,
        ]
        let started = Date()
        let r = try ProcessRunner.run("/usr/bin/osascript", as_, timeout: t, tempDirectory: tempDirectory)
        if config.verbose { log(String(format: "  [ps] %@ %.2fs", name, Date().timeIntervalSince(started))) }
        if r.timedOut {
            if !Self.isRunning { throw OracleError.crashed("timed out and Photoshop is gone") }
            // A modal dialog (despite DialogModes.NO) blocks `do javascript` until someone answers
            // it. Sending more scripts would queue behind it: stop here.
            _ = recover
            throw OracleError.timedOut(script: name, seconds: t)
        }
        guard r.status == 0 else {
            let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            // -609 "connection is invalid" / -600 "not running": Photoshop died under the script.
            if err.contains("(-609)") || err.contains("(-600)") || !Self.isRunning {
                throw OracleError.crashed(err)
            }
            // -1712: the Apple event timed out — Photoshop is blocked.
            if err.contains("-1712") {
                throw OracleError.unresponsive(err)
            }
            throw OracleError.photoshopFailed(err.isEmpty ? "osascript exit \(r.status)" : err)
        }
        return r.stdout.trimmingCharacters(in: .newlines)
    }

    /// Runs a JSX resource whose result is a JSON object.
    public func run(_ name: String, _ arguments: [String: Any], timeout: Double? = nil, recover: Bool = true) throws -> [String: Any] {
        let raw = try runRaw(name, arguments, timeout: timeout, recover: recover)
        guard let data = raw.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OracleError.badOutput(raw)
        }
        if obj["ok"] as? Bool == false {
            let err = obj["error"] as? String ?? ""
            let number = (obj["errorNumber"] as? Int) ?? Int(obj["errorNumber"] as? Double ?? 0)
            // A dialog was shown and dismissed (cancel): the file raised a modal.
            if number == 8007 || err.lowercased().contains("cancel") { throw OracleError.modal(err) }
            if err.hasPrefix("ps-oracle: documents open") { throw OracleError.documentsOpen([err]) }
        }
        return obj
    }

    public func ping() throws -> [String: Any] { try run("ping", [:], timeout: 30) }

    public func cleanup() throws -> [String: Any] { try run("cleanup", [:], timeout: 60) }
}
