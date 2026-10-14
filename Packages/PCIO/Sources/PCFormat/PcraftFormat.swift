// The native, lossless `.pcraft` document bundle (photocraft architecture §9).
//
//   manifest.json            versioned document tree (see `Manifest`)
//   tiles/<blake3>.zst       content-addressed 256×256 tiles (zstd, little-endian samples)
//   blobs/<blake3>.zst       content-addressed binary data (ICC, EXIF, PSD blocks, smart objects)
//   thumb.png                optional thumbnail (caller-rendered)
//   composite/preview.png    optional flattened preview (caller-rendered)
//
// A bundle is either a ZIP archive (STORE entries) or a directory with the same layout. Saving is
// incremental: `PcraftWriter` remembers what it wrote, and (up to a budget) what it compressed, so
// only new tiles are encoded. Directory saves verify existing content-addressed objects once per
// writer and folder, rechecking files whose size or modification time changes; they replace
// damaged or missing objects and garbage-collect unreferenced ones. A ZIP file is written entry by
// entry into its temporary file and read entry by entry through its central directory, so it is
// never in memory whole.
//
// This module sits next to the compositor, so it does not render: callers pass previews in
// `SaveOptions`.
// Port of photocraft-format (crates/format/src/lib.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.

import Foundation
import PCDocument
import PCIOCore

/// Straight RGBA, 8 bits per sample, row-major (photocraft-raster `Rgba8Image`).
public struct RGBA8Image: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var data: [UInt8]

    public init(width: Int, height: Int, data: [UInt8]) { self.width = width; self.height = height; self.data = data }

    /// A transparent image.
    public init(width: Int, height: Int) { self.init(width: width, height: height, data: [UInt8](repeating: 0, count: max(0, width * height * 4))) }
}

/// Previews to embed. The format cannot render (it sits beside the compositor), so callers
/// provide them.
public struct SaveOptions: Sendable {
    public var thumbnail: RGBA8Image?
    public var composite: RGBA8Image?

    public init(thumbnail: RGBA8Image? = nil, composite: RGBA8Image? = nil) { self.thumbnail = thumbnail; self.composite = composite }
}

/// Limits applied while loading untrusted bundles.
public struct LoadOptions: Sendable {
    /// Default `maxCanvasSide`: Photoshop's PSB limit, as for PSD and File › New.
    public static let defaultMaxCanvasSide: UInt32 = 300_000
    /// Default `maxCanvasPixels`: the full 300000 × 300000 PSB canvas. File › New, Canvas Size,
    /// Image Size and PSB import all reach it, and a document that can be created and saved must
    /// reopen. Loading stays proportional to the file: layers, masks and channels are sparse tiles
    /// read under the byte budgets, so a huge declared canvas with no content allocates nothing.
    public static let defaultMaxCanvasPixels: UInt64 = UInt64(defaultMaxCanvasSide) * UInt64(defaultMaxCanvasSide)

    /// Maximum size of `manifest.json`.
    public var maxManifestBytes = 256 << 20
    /// Maximum size of one decompressed blob.
    public var maxBlobBytes = 1 << 30
    /// Maximum total decompressed tile + blob bytes.
    public var maxTotalBytes: UInt64 = 16 << 30
    /// Keep document and layer ids from the file (the id counter is advanced past them). When
    /// false, fresh ids are assigned.
    public var preserveIds = true
    /// Longest canvas side the manifest may declare.
    public var maxCanvasSide = defaultMaxCanvasSide
    /// Most canvas pixels the manifest may declare. A canvas is a few bytes of JSON, but the
    /// compositor, thumbnails and display textures work in proportion to its area, so a caller
    /// handling untrusted files (a previewer, a batch job) may lower it.
    public var maxCanvasPixels = defaultMaxCanvasPixels

    public init(maxManifestBytes: Int = 256 << 20, maxBlobBytes: Int = 1 << 30, maxTotalBytes: UInt64 = 16 << 30, preserveIds: Bool = true,
                maxCanvasSide: UInt32 = defaultMaxCanvasSide, maxCanvasPixels: UInt64 = defaultMaxCanvasPixels) {
        self.maxManifestBytes = maxManifestBytes; self.maxBlobBytes = maxBlobBytes; self.maxTotalBytes = maxTotalBytes
        self.preserveIds = preserveIds; self.maxCanvasSide = maxCanvasSide; self.maxCanvasPixels = maxCanvasPixels
    }
}

/// The `.pcraft` entry points (photocraft-format's crate root).
public enum PcraftFormat {
    /// File extension of the native format.
    public static let fileExtension = "pcraft"
    /// Manifest version written by this build.
    public static let formatVersion = pcraftFormatVersion
    /// Deepest group nesting a bundle may hold.
    public static let maxGroupDepth = Convert.maxGroupDepth

    /// True when ZIP bytes contain a `manifest.json` entry. Bundles written here place the
    /// manifest first; re-zipped bundles may reorder entries.
    public static func isPcraft(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4, bytes[0] == 0x50, bytes[1] == 0x4B, bytes[2] == 3, bytes[3] == 4 else { return false }
        if bytes.count >= 30 {
            let nameLen = Int(bytes[26]) | Int(bytes[27]) << 8
            let name = Array(Store.manifest.utf8)
            if nameLen == name.count, 30 + nameLen <= bytes.count, Array(bytes[30 ..< 30 + nameLen]) == name { return true }
        }
        return (try? ZipReader(bytes))?.find(Store.manifest) != nil
    }

    /// Saves to an in-memory ZIP bundle (one-shot; use `PcraftWriter` for incremental saves, and
    /// `PcraftWriter.save(_:to:as:)` to write a file without holding it).
    public static func save(_ doc: Document, options: SaveOptions = SaveOptions()) throws(FormatError) -> [UInt8] {
        let w = PcraftWriter()
        w.setZipCacheBudget(0)
        return try w.saveZip(doc, options).0
    }

    /// Loads a ZIP bundle from memory.
    public static func load(_ bytes: [UInt8], options: LoadOptions = LoadOptions()) throws(FormatError) -> Document {
        try Store.load(try ZipSource(bytes), options)
    }

    /// Loads a bundle from a file URL: a directory bundle or a ZIP file. A ZIP file is read entry
    /// by entry through its central directory, never whole.
    public static func load(contentsOf url: URL, options: LoadOptions = LoadOptions()) throws(FormatError) -> Document {
        if FS.isDir(url.path) { return try Store.load(DirSource(root: url), options) }
        return try Store.load(try ZipFileSource(url), options)
    }

    /// Loads from any byte source (a directory behind a capability handle, an archive, a test
    /// fixture) with the same migration and limits as the other loads.
    public static func load(from source: any ByteSource, options: LoadOptions = LoadOptions()) throws(FormatError) -> Document {
        try Store.load(source, options)
    }

    /// Reads and migrates only the manifest (fast: no tiles are decoded).
    public static func readManifest(_ bytes: [UInt8]) throws(FormatError) -> Manifest {
        try Store.readManifest(try ZipSource(bytes), LoadOptions())
    }

    /// The previews the bundle at `url` (a package or a single file) holds, as its manifest names
    /// them: nil for one it has none of, or one that doesn't read back as straight 8-bit RGBA.
    public static func readPreviews(contentsOf url: URL) throws(FormatError) -> SaveOptions {
        let src: any ByteSource = FS.isDir(url.path) ? DirSource(root: url) : try ZipFileSource(url)
        let m = try Store.readManifest(src, LoadOptions())
        func image(_ path: String?) throws(FormatError) -> RGBA8Image? {
            guard let path else { return nil }
            return Store.rgba8(try src.get(path, max: 64 << 20))
        }
        return SaveOptions(thumbnail: try image(m.thumbnail), composite: try image(m.composite))
    }

    /// The embedded thumbnail, if present (PNG bytes).
    public static func readThumbnail(_ bytes: [UInt8]) throws(FormatError) -> [UInt8]? {
        let src = try ZipSource(bytes)
        let m = try Store.readManifest(src, LoadOptions())
        guard let p = m.thumbnail else { return nil }
        return try src.get(p, max: 64 << 20)
    }

    // MARK: Re-exports of the crate root

    /// Reads a whole file in bounded chunks (`FileRead.readFile`).
    public static func readFile(_ url: URL) throws(IOError) -> [UInt8] { try FileRead.readFile(url) }

    /// Crash-safe replacement of one file (`AtomicSave.atomicWrite`).
    public static func atomicWrite(_ url: URL, _ bytes: [UInt8]) throws(IOError) { try AtomicSave.atomicWrite(url, bytes) }

    /// `atomicWrite` with progress reports (`AtomicSave.atomicWriteProgress`).
    public static func atomicWriteProgress(_ url: URL, _ bytes: [UInt8], _ progress: (Float) -> Void) throws(IOError) {
        try AtomicSave.atomicWriteProgress(url, bytes, progress)
    }

    /// Recoverable documents in `recoveryDir`, newest first (`Autosave.listRecovery`).
    public static func listRecovery(_ recoveryDir: URL) -> [RecoveryEntry] { Autosave.listRecovery(recoveryDir) }

    /// Loads a recovered document (`Autosave.recover`).
    public static func recover(_ entry: RecoveryEntry) throws(FormatError) -> Document { try Autosave.recover(entry) }

    /// Deletes a recovery entry (`Autosave.discardRecovery`).
    public static func discardRecovery(_ recoveryDir: URL, _ entry: RecoveryEntry) throws(FormatError) {
        try Autosave.discardRecovery(recoveryDir, entry)
    }
}
