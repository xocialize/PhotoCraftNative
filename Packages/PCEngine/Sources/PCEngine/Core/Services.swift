// Port of photocraft architecture §11 ("Services injected into Session": FileSystem, Clipboard, FontSource, ModelStore, Clock, Notifier), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// What the session needs from the platform, injected so tests, the CLI, the MCP server and the app
// each supply their own: file access (the automation layer passes a capability-scoped one), the
// system clipboard, the clock, notifications, the renderer (PCRender with PCPlatform's
// rasterizer) and the AI tier (PCIntelligence's provider registry).

import Foundation
import PCDocument
import PCFormat
import PCIntelligence

/// File access for commands that read or write files (place, export, presets).
public protocol FileSystemService: Sendable {
    func read(_ path: String) throws -> Data
    func write(_ path: String, _ data: Data) throws
    func exists(_ path: String) -> Bool
    /// The names of a folder's entries (batch inputs, image sequences); default: unsupported.
    func list(_ dir: String) throws -> [String]
    /// Creates a folder and its parents (export destinations); default: unsupported.
    func createDirectory(_ path: String) throws
    /// Whether `path` is a folder.
    func isDirectory(_ path: String) -> Bool
}

extension FileSystemService {
    public func list(_ dir: String) throws -> [String] { throw EngineError.other("\(dir): listing folders is not available here") }
    public func createDirectory(_ path: String) throws { throw EngineError.other("\(path): creating folders is not available here") }
    public func isDirectory(_ path: String) -> Bool { false }
}

/// The local file system (the app and `pccli run`, which name host paths themselves).
public struct LocalFileSystem: FileSystemService {
    public init() {}
    public func read(_ path: String) throws -> Data {
        do { return try Data(contentsOf: URL(fileURLWithPath: path)) } catch {
            throw EngineError.other("\(path): \(error.localizedDescription)")
        }
    }
    /// Written atomically and durably (temporary file, full sync, rename: photocraft-format's
    /// `atomic_write`), so a crash never leaves half a document.
    public func write(_ path: String, _ data: Data) throws {
        do { try PcraftFormat.atomicWrite(URL(fileURLWithPath: path), [UInt8](data)) } catch {
            throw EngineError.other("\(path): \(error)")
        }
    }
    public func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    public func list(_ dir: String) throws -> [String] {
        do { return try FileManager.default.contentsOfDirectory(atPath: dir).sorted() } catch {
            throw EngineError.other("\(dir): \(error.localizedDescription)")
        }
    }
    public func createDirectory(_ path: String) throws {
        do { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) } catch {
            throw EngineError.other("\(path): \(error.localizedDescription)")
        }
    }
    public func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }
}

/// No file access (untrusted automation without granted roots).
public struct DeniedFileSystem: FileSystemService {
    public init() {}
    public func read(_ path: String) throws -> Data { throw EngineError.other("automation filesystem access is not granted: read authority is absent") }
    public func write(_ path: String, _ data: Data) throws { throw EngineError.other("automation filesystem access is not granted: write authority is absent") }
    public func exists(_ path: String) -> Bool { false }
}

/// The system clipboard (photocraft's Export Clipboard preference); the session keeps its own
/// pixel clipboard either way.
public protocol ClipboardService: Sendable {
    func writeImage(png: Data)
    func readImage() -> Data?
}

/// Everything injected into a session.
public struct EngineServices: Sendable {
    public var fileSystem: any FileSystemService
    public var clipboard: (any ClipboardService)?
    public var clock: @Sendable () -> Date
    /// Status-bar messages (also sent as `SessionEvent.toast`).
    public var notifier: (@Sendable (String) -> Void)?
    /// Composites documents (canvas, exports, thumbnails, AI sources).
    public var renderer: EngineRenderer
    /// The AI tier: one provider slot per capability; the app registers ForgeCore's providers. A
    /// default one has PCAlgo's PatchMatch in its `inpaint` slot (`.classical`).
    public var intelligence: PCIntelligence

    public init(fileSystem: any FileSystemService = LocalFileSystem(), clipboard: (any ClipboardService)? = nil,
                clock: @escaping @Sendable () -> Date = { Date() }, notifier: (@Sendable (String) -> Void)? = nil,
                renderer: EngineRenderer = .shared, intelligence: PCIntelligence? = nil) {
        self.fileSystem = fileSystem
        self.clipboard = clipboard
        self.clock = clock
        self.notifier = notifier
        self.renderer = renderer
        if let intelligence {
            self.intelligence = intelligence
        } else {
            let ai = PCIntelligence(compositor: renderer.intelligenceCompositor)
            // PCAlgo's PatchMatch is the classical inpaint tier (Remove, Content-Aware Fill) until
            // the host registers a model.
            ai.registry.register(inpaint: PatchMatchInpaintProvider(), tier: .classical)
            self.intelligence = ai
        }
    }
}
