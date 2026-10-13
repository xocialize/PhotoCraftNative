// Port of photocraft-engine (crates/engine/src/file_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// File-menu commands beyond New/Close, and the file helpers every module that reads or writes
// documents shares: reading and writing through the session's file service (crash-safe writes),
// importing through PCIO (`import`), encoding for a path's format (`encode` / `saveDoc` with
// `SaveOpts`), folder listings for batch commands, and the flattened composite.
//
// The File-menu commands of file_cmds.rs register here and live in the `FileCommands+*.swift`
// parts: Close All / Others, Reveal in Finder, Revert, Save a Copy, Open As, Place Embedded /
// Linked (`+Menu`), File Info (`+Info`), the Automate and Scripts items — Fit Image, Conditional
// Mode Change, Batch, Image Processor, Load Files into Stack (`+Automate`), Flatten All Layer
// Effects / Masks — and Export › Layers to Files / Color Lookup Tables (`+Export`). The document
// guide layouts of file_cmds.rs (View › New Guide Layout, New Guides From Shape, Clear Canvas
// Guides) are `GuideLayoutCommands`'. Commands that touch the file system take explicit paths
// (the UI asks with its own pickers); their byte-level cores (`placeBytes`, `openBytesAs`,
// `exportLayersWith`) are public for the app shell and the automation layer.

import Foundation
import PCDocument
import PCFormat
import PCFoundation
import PCIOCore

public enum FileCommands: CommandModule {
    public static let name = "file_cmds"
    static let m = name

    public static func register(into r: inout CommandRegistry) {
        r.add(menuSpecs())
        r.add(automateSpecs())
        r.add(exportSpecs())
    }

    // MARK: File system (through the session's service)

    /// Every file the engine opens is read here (photocraft `read_file`). A `.pcraft` package (a
    /// folder) reads as its single-file form, so every reader of document bytes (Place, Open As,
    /// batch, notes import) takes one.
    static func readFile(_ s: Session, _ path: String) throws -> [UInt8] {
        if fileExtension(path) == PcraftFormat.fileExtension, s.services.fileSystem.isDirectory(path) {
            let doc = try EngineIO.importPath(path, services: s.services).document
            do { return try PcraftFormat.save(doc) } catch { throw EngineError.other("\(path): \(error)") }
        }
        do { return [UInt8](try s.services.fileSystem.read(path)) } catch { throw EngineError.other("\(path): \(EngineError.wrap(error))") }
    }

    /// Every file the engine writes goes through here: crash-safe for the local file system
    /// (temp file + full sync + rename), so a failed save never destroys the previous file
    /// (photocraft `write_file`).
    static func writeFile(_ s: Session, _ path: String, _ bytes: [UInt8]) throws {
        do { try s.services.fileSystem.write(path, Data(bytes)) } catch { throw EngineError.wrap(error) }
    }

    /// Extensions the batch commands pick up from a folder (photocraft `OPENABLE`).
    static let openable: Set<String> = [
        "pdn", "ora", "psd", "psb", "pcraft", "png", "jpg", "jpeg", "tif", "tiff", "webp", "gif", "bmp", "tga", "exr", "hdr", "qoi", "ico", "pnm", "ppm", "pgm",
        "fits", "fit", "fts", "heic", "heif", "hif", "dng", "cr2", "nef", "nrw", "arw", "pef", "svg", "svgz", "af", "afdesign", "afphoto", "afpub",
    ]

    /// Files of a folder that look like images we can open, sorted by name (photocraft `list_images`).
    static func listImages(_ s: Session, _ dir: String) throws -> [String] {
        let fs = s.services.fileSystem
        let base = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        return try fs.list(dir).map { "\(base)/\($0)" }
            .filter { p in
                guard let ext = fileExtension(p), openable.contains(ext) else { return false }
                // A `.pcraft` package is a folder; no other folder is an image.
                return ext == PcraftFormat.fileExtension || !fs.isDirectory(p)
            }
            .sorted()
    }

    // MARK: Names and formats

    /// The last component of `path` (photocraft `file_name`).
    static func fileName(_ path: String) -> String { DocState.fileName(path) }

    /// The lower-case extension of the file name in `path` (none for `.hidden` or `name`).
    static func fileExtension(_ path: String) -> String? { EngineIO.fileExtension(path) }

    /// photocraft `layered_extension`: PSD, PSB, .pcraft, OpenRaster.
    static func layeredExtension(_ ext: String) -> Bool { EngineIO.layeredExtension(ext) }

    /// Whether a save without a new path may write back to `path` (photocraft `saves_in_place`).
    static func savesInPlace(_ path: String) -> Bool { EngineIO.savesInPlace(path) }

    /// The file name in `path` without its extension (photocraft `stem`).
    static func stem(_ path: String) -> String {
        let n = fileName(path)
        guard let dot = n.lastIndex(of: "."), dot != n.startIndex else { return n }
        return String(n[..<dot])
    }

    /// `name` inside folder `dir` (photocraft `join`).
    static func join(_ dir: String, _ name: String) -> String {
        if dir.isEmpty { return name }
        return dir.hasSuffix("/") || dir.hasSuffix("\\") ? dir + name : "\(dir)/\(name)"
    }

    /// Whether `path` names a document template (.psdt), which opens as a new untitled document
    /// without its path so a save never writes over it (photocraft `is_template`).
    static func isTemplate(_ path: String) -> Bool { fileExtension(path) == "psdt" }

    /// The first "`base`-N" that isn't `taken` (photocraft `untitled_name`).
    static func untitledName(_ base: String, taken: (String) -> Bool) -> String {
        var i = 1
        while taken("\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }

    /// The name a document opened from `path` gets when `path` is a template: the first
    /// "Untitled-N" no open document has (photocraft `template_name`).
    static func templateName(_ s: Session, _ path: String) -> String? {
        guard isTemplate(path) else { return nil }
        return untitledName("Untitled") { n in s.documents.contains { $0.doc.name == n } }
    }

    /// A file-name-safe version of a layer name (photocraft `sanitize`).
    static func sanitize(_ name: String) -> String {
        let mapped = String(name.map { $0.isLetter || $0.isNumber || "-_ .".contains($0) ? $0 : "_" })
        var t = mapped.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix(".") { t.removeFirst() }
        while t.hasSuffix(".") { t.removeLast() }
        return t.isEmpty ? "layer" : t
    }

    // MARK: Import and export

    /// Imports `bytes` named `name` (photocraft `file_cmds::import`). Auxiliary imports can't show
    /// a preview-only file's warning, so they refuse it.
    static func `import`(_ s: Session, _ name: String, _ bytes: [UInt8]) throws -> Document {
        let r = try EngineIO.importFile(name: name, bytes: bytes, services: s.services)
        if r.previewOnly {
            throw EngineError.other("\(name): only this Affinity file's embedded preview could be read; open it with File › Open to see the warning, or export PSD or PNG from Affinity before using it here")
        }
        return r.document
    }

    /// What a save writes beyond the format (photocraft `SaveOpts`): JPEG/WebP quality on
    /// Photoshop's 0–12 scale, TIFF layers, Targa bits, PSD previews.
    struct SaveOpts: Sendable {
        var quality: Double?
        var tiffLayers = false
        var tgaBits: Int?
        var imagePreviews = true

        /// `quality`, `tiffLayers`, `tgaBits` from command `cmd`'s params; previews from File Handling.
        static func from(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> SaveOpts {
            var o = SaveOpts()
            o.quality = f64Param(p, "quality")
            o.tiffLayers = p["tiffLayers"]?.boolValue ?? false
            o.tgaBits = try tgaBitsParam(p, cmd)
            o.imagePreviews = s.preferences["fileHandling.imagePreviews"]?.stringValue != "never"
            return o
        }
    }

    /// `"tgaBits": 24 | 32` (absent or null: automatic); anything else is a bad parameter.
    static func tgaBitsParam(_ p: JSONValue, _ cmd: String) throws -> Int? {
        guard let v = p["tgaBits"], v != .null else { return nil }
        guard let b = v.uint64Value, b == 24 || b == 32 else { throw EngineError.bad(cmd, "`tgaBits` must be 24 or 32, got \(v.serialized())") }
        return Int(b)
    }

    /// Encodes `doc` for `path`'s extension (photocraft `encode`): PCIO for the layered formats
    /// and PNG/JPEG/TIFF, PCPlatform's codecs for the other flat formats.
    static func encode(_ s: Session, _ doc: Document, _ path: String, _ save: SaveOpts = SaveOpts(), interrupt: Interrupt = .none) throws -> ([UInt8], [String]) {
        // Photoshop's 0–12 JPEG scale → 1–100.
        let q = save.quality.map { (min(max($0, 0), 12) / 12 * 99 + 1).rounded() }
        let r = try EngineIO.export(doc, as: path, services: s.services, quality: q, tiffLayers: save.tiffLayers, imagePreviews: save.imagePreviews,
                                    tgaBits: save.tgaBits, interrupt: interrupt)
        return (r.bytes, r.warnings)
    }

    /// Encodes and writes `doc` to `path` (photocraft `save_doc`); returns the warnings.
    @discardableResult
    static func saveDoc(_ s: Session, _ doc: Document, _ path: String, _ save: SaveOpts = SaveOpts()) throws -> [String] {
        let (bytes, warnings) = try encode(s, doc, path, save)
        try writeFile(s, path, bytes)
        return warnings
    }

    /// The flattened image of `doc` as a surface in `fmt` at the origin (photocraft `flattened`).
    static func flattened(_ s: Session, _ doc: Document, _ fmt: PixelFormat) throws -> Surface {
        try s.services.renderer.compositeToSurface(doc, rect: doc.bounds, format: fmt)
    }

    // MARK: Params

    static func strParam(_ p: JSONValue, _ key: String, _ cmd: String) throws -> String {
        guard let v = p[key]?.stringValue, !v.isEmpty else { throw EngineError.bad(cmd, "missing \"\(key)\"") }
        return v
    }

    static func f64Param(_ p: JSONValue, _ key: String) -> Double? { p[key]?.doubleValue.flatMap { $0.isFinite ? $0 : nil } }

    /// A size parameter; zero or negative means "not set" (dialogs send 0 for empty fields).
    static func sizeParam(_ p: JSONValue, _ key: String) -> Double? { f64Param(p, key).flatMap { $0 > 0 ? $0 : nil } }

    // MARK: Preconditions

    /// photocraft `has_doc`.
    static let hasDoc: CommandEnabled = { s, _ in s.active == nil ? "no document open" : nil }

    /// The file system is reachable (photocraft `native`: only the web build has none).
    static let native: CommandEnabled = { _, _ in nil }

    /// photocraft `native_doc`.
    static let nativeDoc: CommandEnabled = { s, p in native(s, p) ?? hasDoc(s, p) }
}
