// Port of photocraft-automation (crates/automation/src/files.rs: `open`, `open_bytes`, `save`, `save_bytes`, `render_png`), plus photocraft-engine's file_cmds path helpers and type_extra_cmds' missing-font warnings that automation uses, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Automation and `pccli` read and write documents through the engine's PCIO glue (`EngineIO`):
// PSD/PSB, `.pcraft` (ZIP or directory bundle), OpenRaster, Krita, Paint.NET, layered TIFF,
// multi-part EXR, SVG, Affinity and every flat format PCPlatform's codecs know. A save composites
// through PCRender and encodes by extension.

import Darwin
import Foundation
import PCDocument
import PCEngine
import PCFormat
import PCFoundation
import PCPlatform

public enum FlatFiles {
    /// The services a call without a session uses (the CLI's one-shot conversions).
    public static let defaultServices = EngineServices()

    /// Result of opening a file (photocraft `files::Opened`).
    public struct Opened: Sendable {
        public var document: Document
        public var warnings: [String]
        /// The source must not become the document's save path (an import-only format).
        public var sourceReadOnly: Bool
    }

    /// Decodes a document read through a filesystem capability (photocraft `open_bytes`).
    public static func open(name: String, data: Data, services: EngineServices = defaultServices) throws -> Opened {
        let r = try EngineIO.importFile(name: name, bytes: [UInt8](data), services: services)
        return Opened(document: r.document, warnings: r.warnings, sourceReadOnly: r.sourceReadOnly)
    }

    /// Opens a document from a host path (photocraft `files::open`): a directory is a `.pcraft`
    /// bundle, anything else is read and decoded.
    public static func open(path: String, services: EngineServices = defaultServices) throws -> Opened {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            do {
                let doc = try PcraftFormat.load(contentsOf: URL(fileURLWithPath: path))
                var d = doc
                d.name = (path as NSString).lastPathComponent
                return Opened(document: d, warnings: [], sourceReadOnly: false)
            } catch {
                throw AutomationError.other("\(path): \(error)")
            }
        }
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.alwaysMapped]) } catch {
            throw AutomationError.io("\(path): \(ControlSecurity.ioMessage(error))")
        }
        return try open(name: (path as NSString).lastPathComponent, data: data, services: services)
    }

    /// Export options (photocraft-io `ExportOptions` as automation sets them).
    public struct ExportOptions: Sendable, Equatable {
        /// JPEG / WebP quality 1…100; a WebP written with a quality is lossy, without one lossless.
        public var quality: Int?
        /// TIFF: keep the layers (Photoshop layer data in the TIFF).
        public var tiffLayers: Bool
        /// TGA bits per pixel, 24 or 32 (nil: 32 with transparency, else 24).
        public var tgaBits: Int?
        public init(quality: Int? = nil, tiffLayers: Bool = false, tgaBits: Int? = nil) {
            self.quality = quality
            self.tiffLayers = tiffLayers
            self.tgaBits = tgaBits
        }
    }

    /// The first port's name for the export options.
    public typealias SaveOptions = ExportOptions

    /// photocraft `tga_bits_param`: `"tgaBits": 24 | 32` (absent or null: automatic); anything
    /// else is a bad parameter of `cmd`.
    public static func tgaBitsParam(_ p: JSONValue, _ cmd: String) throws -> Int? {
        guard let v = p["tgaBits"], v != .null else { return nil }
        if let n = v.uint64Value, n == 24 || n == 32 { return Int(n) }
        throw EngineError.bad(cmd, "`tgaBits` must be 24 or 32, got \(v.serialized())")
    }

    /// The format extension of a save: `format` (leading dots trimmed) or the name's extension.
    static func saveExtension(name: String, format: String?) -> String? {
        if let f = format { return String(f.drop(while: { $0 == "." })).lowercased() }
        return extensionOf(path: name, allowHidden: false)
    }

    /// Encodes `doc` as the format of `name` (or `format`, an extension): photocraft
    /// `save_bytes`, through the engine's `EngineIO`: layered formats and PNG/JPEG/TIFF go through
    /// PCIO, the rest through PCPlatform's codecs (a Targa at the bits asked for). Returns the bytes
    /// and what the format could not hold.
    public static func encode(_ doc: Document, name: String, format: String? = nil, options: ExportOptions = ExportOptions(),
                              renderer: EngineRenderer = .shared) throws -> (Data, [String]) {
        guard let ext = saveExtension(name: name, format: format) else {
            throw AutomationError.badRequest("cannot tell the format of `\(name)`; pass a format")
        }
        if let b = options.tgaBits, b != 24 && b != 32 { throw AutomationError.badRequest("`tgaBits` must be 24 or 32, got \(b)") }
        var services = defaultServices
        services.renderer = renderer
        // A saved native bundle reports its output filename on reopening (photocraft
        // `named_for_output`): the session renames the document only after a successful write.
        var doc = doc
        if ext == "pcraft", let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last { doc.name = String(last) }
        do {
            let r = try EngineIO.export(doc, as: ext, services: services, quality: options.quality.map { Double(min(max($0, 1), 100)) },
                                        tiffLayers: options.tiffLayers, tgaBits: options.tgaBits)
            return (Data(r.bytes), r.warnings)
        } catch let e as EngineError {
            throw e
        } catch {
            throw AutomationError.other("\(name): \(error)")
        }
    }

    /// Saves to a host path, atomically (photocraft `files::save` for a trusted caller).
    public static func save(_ doc: Document, path: String, format: String?, options: ExportOptions,
                            renderer: EngineRenderer = .shared) throws -> [String] {
        let (data, warnings) = try encode(doc, name: path, format: format, options: options, renderer: renderer)
        try atomicWrite(path, data)
        return warnings
    }

    /// Crash-safe replacement of a host file: a failed write never destroys the previous file
    /// (photocraft `atomic_write`).
    public static func atomicWrite(_ path: String, _ data: Data) throws {
        do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) } catch {
            let dir = (path as NSString).deletingLastPathComponent
            throw AutomationError.io("cannot save \(path) in \(dir.isEmpty ? "." : dir): \(ControlSecurity.ioMessage(error)); the original file was not changed")
        }
    }

    /// The flattened document as PNG, scaled to fit `maxSide` (0 = full size): photocraft
    /// `render_png`.
    public static func renderPNG(_ doc: Document, maxSide: Int, renderer: EngineRenderer = .shared) throws -> Data {
        try renderer.png(doc, maxSide: maxSide)
    }

    /// A bridged screenshot reduced to `maxSide` (nearest neighbour), or nil when it already fits
    /// (photocraft `downscale_png`). Decoding is bounded even without downscaling: a compressed
    /// reply's byte limit does not bound its pixels.
    public static func downscalePNG(_ png: Data, maxSide: Int) throws -> Data? {
        var options = DecodeOptions()
        options.limits.maxWidth = 8192
        options.limits.maxHeight = 8192
        options.limits.maxPixels = 16 << 20
        options.limits.maxBytes = 64 << 20
        let img: DecodedImage
        do { img = try ImageCodecs.decode(png, as: .png, options: options) } catch { throw AutomationError.other("\(error)") }
        let (w, h) = (img.size.width, img.size.height)
        if maxSide == 0 || max(w, h) <= maxSide { return nil }
        let s = Float(maxSide) / Float(max(w, h))
        let nw = max(Int(Float(w) * s), 1), nh = max(Int(Float(h) * s), 1)
        let src = img.raster.converted(to: .u8)
        let ch = src.format.channels
        var out = [UInt8](repeating: 0, count: nw * nh * ch)
        for y in 0..<nh {
            for x in 0..<nw {
                let sx = min(Int((Float(x) + 0.5) / s), w - 1), sy = min(Int((Float(y) + 0.5) / s), h - 1)
                let si = (sy * w + sx) * ch, di = (y * nw + x) * ch
                for c in 0..<ch { out[di + c] = src.bytes[si + c] }
            }
        }
        let small = RasterBuffer(width: nw, height: nh, format: src.format, bytes: out)
        do { return try ImageCodecs.encode(small, as: .png) } catch { throw AutomationError.other("\(error)") }
    }

    // MARK: photocraft-engine file_cmds helpers

    /// The last component of `path`, `/` or `\` separated (photocraft `file_name`).
    static func fileName(_ path: String) -> String { DocState.fileName(path) }

    /// The lower-case extension of the file name in `path` (none for `.hidden` or `name`):
    /// photocraft `file_cmds::extension`.
    public static func extensionOf(path: String, allowHidden: Bool = false) -> String? {
        let name = fileName(path)
        guard let dot = name.lastIndex(of: ".") else { return nil }
        let base = name[..<dot], ext = name[name.index(after: dot)...]
        if base.isEmpty || ext.isEmpty { return nil }
        return ext.lowercased()
    }

    /// Whether `ext` names a layered document format: a save to one becomes the document's file
    /// (photocraft `layered_extension`).
    public static func layeredExtension(_ ext: String) -> Bool { ["psd", "psb", "pcraft", "ora"].contains(ext) }

    /// Whether a save without a new path may write back to `path`: layered files only
    /// (photocraft `saves_in_place`).
    public static func savesInPlace(_ path: String) -> Bool { extensionOf(path: path).map(layeredExtension) ?? false }

    /// Whether `path` names a document template (photocraft `is_template`).
    public static func isTemplate(_ path: String) -> Bool { extensionOf(path: path) == "psdt" }

    /// The name a document opened from a template gets: the first "Untitled-N" no open document
    /// has (photocraft `template_name`).
    public static func templateName(_ s: Session, _ path: String) -> String? {
        guard isTemplate(path) else { return nil }
        var i = 1
        while s.documents.contains(where: { $0.doc.name == "Untitled-\(i)" }) { i += 1 }
        return "Untitled-\(i)"
    }

    /// The output paths a batch run has written, compared ignoring case (photocraft
    /// `OutputClaims`).
    public struct OutputClaims: Sendable {
        var claims: [String: String] = [:]
        public init() {}
        /// An error naming the earlier input when `out` was already written in this run.
        public func check(_ out: String) throws {
            if let first = claims[out.lowercased()] {
                throw AutomationError.other("not written: \(out) already holds the result of \(first) from this run (same output name)")
            }
        }
        public mutating func record(_ out: String, input: String) { claims[out.lowercased()] = input }
    }

    // MARK: Missing fonts (photocraft type_extra_cmds)

    /// Font families used by type layers that the font catalogue cannot supply.
    public static func missingFonts(_ doc: Document) -> [String] {
        var texts: [TextLayer] = []
        for e in doc.walk() { if case .text(let t) = e.layer.content { texts.append(t) } }
        if texts.isEmpty { return [] }
        let have = Set(FontCatalog.families().map { $0.lowercased() })
        var out: [String] = []
        for t in texts {
            for r in t.charRuns() {
                let f = r.style.fontFamily
                if !f.isEmpty && !have.contains(f.lowercased()) && !out.contains(f) { out.append(f) }
            }
        }
        return out
    }

    /// Warnings for missing font families in `doc` (photocraft `missing_font_warnings`).
    public static func missingFontWarnings(_ doc: Document) -> [String] {
        missingFonts(doc).map { "font '\($0)' is not installed; text may render using a fallback face" }
    }
}
