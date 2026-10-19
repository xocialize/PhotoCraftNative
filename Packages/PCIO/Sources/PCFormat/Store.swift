// Object storage (ZIP or directory), the incremental writer and the loader.
// Port of photocraft-format (crates/format/src/store.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.

import CoreGraphics
import Foundation
import ImageIO
import PCDocument
import PCFoundation
import PCIOCore
import Synchronization
import UniformTypeIdentifiers

enum Store {
    static let manifest = "manifest.json"
    static let thumb = "thumb.png"
    static let composite = "composite/preview.png"

    static func tilePath(_ h: String) -> String { "tiles/\(h).zst" }
    static func blobPath(_ h: String) -> String { "blobs/\(h).zst" }
    static func tilePath(_ d: ContentDigest) -> String { tilePath(d.hex) }
    static func blobPath(_ d: ContentDigest) -> String { blobPath(d.hex) }

    /// A preview as PNG (straight alpha, sRGB).
    static func png(_ img: RGBA8Image) throws(FormatError) -> [UInt8] {
        let w = img.width, h = img.height
        guard w > 0, h > 0, w <= 1 << 16, h <= 1 << 16, img.data.count == w * h * 4 else {
            throw .unsupported("preview: \(w)×\(h) image with \(img.data.count) bytes")
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(img.data) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent) else {
            throw .unsupported("preview: cannot build the image")
        }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw .unsupported("preview: no PNG encoder")
        }
        CGImageDestinationAddImage(dst, cg, nil)
        guard CGImageDestinationFinalize(dst) else { throw .unsupported("preview: PNG encoding failed") }
        return [UInt8](out as Data)
    }

    /// A preview's PNG read back: nil unless it decodes as 8-bit RGBA with straight alpha, as
    /// `png` writes it.
    static func rgba8(_ png: [UInt8]) -> RGBA8Image? {
        guard let source = CGImageSourceCreateWithData(Data(png) as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(source, 0, nil),
              cg.bitsPerComponent == 8, cg.bitsPerPixel == 32, cg.alphaInfo == .last,
              cg.bitmapInfo.intersection(.byteOrderMask) == [] || cg.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Big,
              let data = cg.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return nil }
        let w = cg.width, h = cg.height, stride = cg.bytesPerRow
        guard w > 0, h > 0, stride >= w * 4, CFDataGetLength(data) >= stride * (h - 1) + w * 4 else { return nil }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0 ..< h { for i in 0 ..< w * 4 { out[y * w * 4 + i] = base[y * stride + i] } }
        return RGBA8Image(width: w, height: h, data: out)
    }

    // MARK: - Loading

    /// Deepest JSON nesting a manifest may have: each group level adds three (the layer object,
    /// its content object and the `children` array), with headroom for the document and leaf
    /// layer fields. The saver checks the same bound, so every bundle it writes loads again.
    static let maxManifestDepth = 3 * (Convert.maxGroupDepth + 1) + 64

    /// Rejects JSON nested deeper than `maxManifestDepth` with a linear scan (no recursion), so
    /// parsing can't exhaust the stack on hostile input.
    static func checkManifestDepth(_ json: [UInt8]) throws(FormatError) {
        var depth = 0
        var inString = false, escaped = false
        for b in json {
            if inString {
                if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
                continue
            }
            switch b {
            case 0x22: inString = true
            case 0x5B, 0x7B:
                depth += 1
                if depth > maxManifestDepth { throw .limitExceeded("manifest JSON nested deeper than \(maxManifestDepth) levels") }
            case 0x5D, 0x7D: depth = max(0, depth - 1)
            default: break
            }
        }
    }

    static func readManifest(_ src: any ByteSource, _ opts: LoadOptions) throws(FormatError) -> Manifest {
        let raw = try src.get(manifest, max: opts.maxManifestBytes)
        // The bounded check replaces a recursion limit: nothing below recurses deeper.
        try checkManifestDepth(raw)
        var tree: JSONTree
        do throws(JSONTree.ParseError) {
            tree = try JSONTree.parse(raw)
        } catch {
            throw .json(error.description)
        }
        try Migrate.migrate(&tree)
        return try ManifestJSON.decode(tree)
    }

    /// Refuses a declared canvas outside `opts`' budget before anything is decoded for it
    /// (photocraft #2935).
    static func admitCanvas(_ size: PixelSize, _ opts: LoadOptions) throws(FormatError) {
        let (w, h) = (size.width, size.height)
        if w == 0 || h == 0 { throw .corrupt("canvas size \(w)x\(h) is empty") }
        if w > Int(opts.maxCanvasSide) || h > Int(opts.maxCanvasSide) {
            throw .limitExceeded("canvas \(w)x\(h) exceeds \(opts.maxCanvasSide) pixels per side")
        }
        if UInt64(w) * UInt64(h) > opts.maxCanvasPixels { throw .limitExceeded("canvas \(w)x\(h) exceeds \(opts.maxCanvasPixels) pixels") }
    }

    static func load(_ src: any ByteSource, _ opts: LoadOptions) throws(FormatError) -> Document {
        let m = try readManifest(src, opts)
        try admitCanvas(m.document.size, opts)
        let fetch = LoadFetch(src: src, opts: opts)
        fetch.prefetch(m.document)
        let loader = Loader(fetch: fetch, preserveIds: opts.preserveIds)
        return try loader.document(m.document)
    }
}

// MARK: - Sources

/// Where a bundle's entries come from: a ZIP in memory, a directory, or anything else (a
/// capability-scoped folder, a test fixture). `get` reads entry `path` (bundle-relative, `/`
/// separated) of at most `max` bytes.
public protocol ByteSource {
    func get(_ path: String, max: Int) throws(FormatError) -> [UInt8]
}

/// Sources whose `get` may be called from several threads at once (tiles are then prefetched in
/// parallel).
protocol ConcurrentByteSource: ByteSource, Sendable {}

/// Entries of a ZIP bundle in memory.
struct ZipSource: ConcurrentByteSource {
    let zip: ZipReader

    init(_ bytes: [UInt8]) throws(FormatError) {
        do {
            zip = try ZipReader(bytes)
        } catch {
            throw FormatError.wrap(error)
        }
    }

    func get(_ path: String, max: Int) throws(FormatError) -> [UInt8] {
        do {
            return try zip.read(named: path, max: max)
        } catch {
            throw FormatError.wrap(error)
        }
    }
}

/// Entries of a ZIP bundle in a file, read as the load asks for them (from several threads at
/// once): the archive is never in memory whole.
struct ZipFileSource: ConcurrentByteSource {
    let zip: ZipFileReader

    init(_ url: URL) throws(FormatError) {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        if fd < 0 { throw .io(IOError.last(url.path)) }
        var st = stat()
        if fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFDIR {
            close(fd)
            throw .io(IOError(errno: EISDIR, url.path))
        }
        do {
            zip = try ZipFileReader(fileDescriptor: fd)
        } catch {
            throw FormatError.wrap(error)
        }
    }

    func get(_ path: String, max: Int) throws(FormatError) -> [UInt8] {
        do {
            return try zip.read(named: path, max: max)
        } catch {
            throw FormatError.wrap(error)
        }
    }
}

/// Entries of a directory bundle.
public struct DirSource: ConcurrentByteSource {
    public let root: URL

    public init(root: URL) { self.root = root }

    public func get(_ path: String, max: Int) throws(FormatError) -> [UInt8] {
        let p = root.appendingPathComponent(path).path
        var st = stat()
        guard stat(p, &st) == 0 else { throw .corrupt("missing `\(path)`") }
        guard st.st_mode & S_IFMT == S_IFREG else { throw .corrupt("`\(path)` is not a regular file") }
        let fd = open(p, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw .corrupt("missing `\(path)`") }
        defer { close(fd) }
        var r = FileDescriptorReader(fd: fd)
        return try FileRead.readEntry(&r, len: UInt64(Swift.max(0, st.st_size)), max: max, path: path)
    }
}

// MARK: - Load fetch

/// Fetches tiles and blobs for a load: checks names, charges the byte budget, verifies hashes.
final class LoadFetch: FormatFetch {
    let src: any ByteSource
    let opts: LoadOptions
    var total: UInt64 = 0
    var blobs: [String: [UInt8]] = [:]
    /// Tiles decoded ahead of the load, by "hash/length".
    var prefetched: [String: Result<[UInt8], FormatError>] = [:]

    init(src: any ByteSource, opts: LoadOptions) {
        self.src = src
        self.opts = opts
    }

    func account(_ n: Int) throws(FormatError) {
        total = total.addingReportingOverflow(UInt64(n)).overflow ? .max : total + UInt64(n)
        if total > opts.maxTotalBytes { throw .limitExceeded("bundle expands beyond \(opts.maxTotalBytes) bytes") }
    }

    static func fetchTile(_ src: any ByteSource, _ hash: String, _ len: Int) throws(FormatError) -> [UInt8] {
        let path = Store.tilePath(hash)
        let z = try src.get(path, max: len + len / 8 + 4096)
        let data = try PcraftCodec.decompress(z, expected: len, what: path)
        if PcraftCodec.hash(data) != hash { throw .corrupt("\(path): content does not match its hash") }
        return data
    }

    func tile(_ hash: String, _ len: Int) throws(FormatError) -> [UInt8] {
        guard Convert.isValidHash(hash) else { throw .corrupt("invalid tile hash `\(hash)`") }
        try account(len)
        if let r = prefetched.removeValue(forKey: "\(hash)/\(len)") { return try r.get() }
        return try LoadFetch.fetchTile(src, hash, len)
    }

    func blob(_ hash: String) throws(FormatError) -> [UInt8] {
        if let b = blobs[hash] { return b }
        guard Convert.isValidHash(hash) else { throw .corrupt("invalid blob hash `\(hash)`") }
        let path = Store.blobPath(hash)
        let z = try src.get(path, max: opts.maxBlobBytes)
        // Blob length is not in the manifest; the frame bounds it and the load caps it.
        let data = try PcraftCodec.decompressBounded(z, max: opts.maxBlobBytes, exact: nil, what: path)
        try account(data.count)
        if PcraftCodec.hash(data) != hash { throw .corrupt("\(path): content does not match its hash") }
        blobs[hash] = data
        return data
    }

    /// Decodes and verifies the manifest's distinct tiles on all cores before the (sequential)
    /// load consumes them. Only tiles inside the byte budget are prefetched, and errors are kept
    /// for the load to report in manifest order, so the outcome is the sequential one.
    func prefetch(_ doc: DocM) {
        guard let src = src as? any ConcurrentByteSource else { return }
        var seen = Set<String>()
        var todo: [(hash: String, len: Int)] = []
        var budget: UInt64 = 0
        var full = false
        Convert.forEachSurface(doc) { s in
            let len = Convert.tileLen(s.format)
            for t in s.tiles where !full && Convert.isValidHash(t.hash) {
                let key = "\(t.hash)/\(len)"
                if seen.contains(key) { continue }
                seen.insert(key)
                budget += UInt64(len)
                if budget > opts.maxTotalBytes {
                    full = true
                    return
                }
                todo.append((t.hash, len))
            }
        }
        guard todo.count > 1 else { return }
        let work = todo
        // After a failure at index k the load stops there (or earlier), so later tiles are not
        // decoded; earlier ones still are, since one of them may fail first.
        let firstFailure = Atomic<Int>(.max)
        let results = Parallel.map(work.count) { i -> Result<[UInt8], FormatError>? in
            if i > firstFailure.load(ordering: .relaxed) { return nil }
            do throws(FormatError) {
                return .success(try LoadFetch.fetchTile(src, work[i].hash, work[i].len))
            } catch {
                _ = firstFailure.min(i, ordering: .relaxed)
                return .failure(error)
            }
        }
        for (i, r) in results.enumerated() {
            if let r { prefetched["\(work[i].hash)/\(work[i].len)"] = r }
        }
    }
}

/// Runs work on all cores.
enum Parallel {
    /// `body(i)` for every `i < n`, results in order.
    static func map<T: Sendable>(_ n: Int, _ body: @Sendable (Int) -> T) -> [T] {
        if n <= 1 { return (0 ..< n).map(body) }
        let out = UnsafeMutableBufferPointer<T?>.allocate(capacity: n)
        out.initialize(repeating: nil)
        defer {
            out.deinitialize()
            out.deallocate()
        }
        let box = SendableBuffer(out)
        DispatchQueue.concurrentPerform(iterations: n) { i in box.buffer[i] = body(i) }
        return out.compactMap { $0 }
    }

    struct SendableBuffer<T>: @unchecked Sendable {
        let buffer: UnsafeMutableBufferPointer<T?>
        init(_ b: UnsafeMutableBufferPointer<T?>) { buffer = b }
    }
}

// MARK: - Saving

/// What a save did.
public struct SaveStats: Equatable, Sendable {
    /// Distinct tiles referenced by the document.
    public var tilesTotal = 0
    /// Tiles that had to be compressed (ZIP) or written (directory).
    public var tilesWritten = 0
    /// Tiles reused from the previous save.
    public var tilesReused = 0
    public var blobsTotal = 0
    public var blobsWritten = 0
    /// Unreferenced objects removed (directory bundles).
    public var objectsRemoved = 0
    /// Bytes of the manifest.
    public var manifestBytes = 0

    public init() {}
}

/// Collects a save's objects, hashing tiles through the writer's cache. Each distinct object keeps the hash string
/// the manifest names it by, made once however many times it is referenced.
final class Collect: FormatSink {
    var tiles: [ContentDigest: (tile: Tile, sample: SampleType, hex: Hash)] = [:]
    var blobs: [ContentDigest: (data: [UInt8], hex: Hash)] = [:]
    /// Its hash cache, tile generation → hash (photocraft keys by `Arc` identity; a tile's generation changes on every
    /// write and is copied with the tile): used and filled where it is, never copied.
    let writer: PcraftWriter

    init(_ writer: PcraftWriter) { self.writer = writer }

    func tile(_ format: PixelFormat, _ tile: Tile) -> Hash {
        let h: ContentDigest
        if let c = writer.hashCache[tile.generation] {
            h = c
        } else {
            h = PcraftCodec.digest(Collect.tileLE(tile, format.sample))
            writer.hashCache[tile.generation] = h
        }
        if let t = tiles[h] { return t.hex }
        let hex = h.hex
        tiles[h] = (tile, format.sample, hex)
        return hex
    }

    func blob(_ data: [UInt8]) -> Hash {
        let h = PcraftCodec.digest(data)
        if let b = blobs[h] { return b.hex }
        let hex = h.hex
        blobs[h] = (data, hex)
        return hex
    }

    static func tileLE(_ t: Tile, _ sample: SampleType) -> [UInt8] {
        var b = t.bytes
        Convert.swapToLE(&b, sample)
        return b
    }
}

/// A stored object: a tile (stored little-endian) or a blob.
enum StoreObject: Sendable {
    case tile(Tile, SampleType)
    case blob([UInt8])

    /// The bytes this object stores.
    var content: [UInt8] {
        switch self {
        case let .tile(t, s): Collect.tileLE(t, s)
        case .blob(let b): b
        }
    }

    var isTile: Bool { if case .tile = self { true } else { false } }

    /// The length of `content`, without making it.
    var contentSize: Int {
        switch self {
        case .tile(let t, _): t.bytes.count
        case .blob(let b): b.count
        }
    }

    var compressed: [UInt8] { PcraftCodec.compress(content) }
}

/// A compressed object as a ZIP entry stores it, with its CRC-32.
struct StoredObject: Sendable {
    var data: [UInt8]
    var crc: UInt32

    init(data: [UInt8], crc: UInt32) { self.data = data; self.crc = crc }
    init(data: [UInt8]) { self.init(data: data, crc: CRC32.checksum(data)) }
}

/// A batch of objects `PcraftWriter.writeZip` compressed in the background (nil: reused from its
/// cache). Read only after the batch's dispatch group has finished.
final class CompressedBatch: @unchecked Sendable {
    var objects: [StoredObject?] = []
}

/// What a file looked like when it was verified. Any change means "verify again".
struct FileSignature: Equatable, Sendable {
    var len: UInt64
    var modified: timespec
    /// Inode, device and status-change time: an in-place rewrite changes the change time even
    /// when a tool restores the modification time.
    var ino: UInt64, dev: Int64, ctime: timespec

    init(_ st: stat) {
        len = UInt64(max(0, st.st_size))
        modified = st.st_mtimespec
        ino = UInt64(st.st_ino)
        dev = Int64(st.st_dev)
        ctime = st.st_ctimespec
    }

    static func == (a: FileSignature, b: FileSignature) -> Bool {
        a.len == b.len && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec && a.ino == b.ino && a.dev == b.dev
            && a.ctime.tv_sec == b.ctime.tv_sec && a.ctime.tv_nsec == b.ctime.tv_nsec
    }
}

/// A stored object's name: a tile or a blob, and its hash. Its path is made when it is written, not held for the
/// whole save (AB-T-0328); names order as their paths do.
struct ObjectName: Hashable, Comparable, Sendable {
    var isTile: Bool
    var digest: ContentDigest

    var path: String { isTile ? Store.tilePath(digest) : Store.blobPath(digest) }

    /// `path`'s length: `tiles/` or `blobs/`, 64 hex digits, `.zst`.
    static let pathLength = 74

    static func < (a: ObjectName, b: ObjectName) -> Bool { a.isTile != b.isTile ? !a.isTile : a.digest < b.digest }
}

struct Prepared {
    /// The manifest as JSON, and the format it says. The model it was written from isn't kept: through it, the
    /// streamed archive would hold every tile's hash string (AB-T-0328).
    var manifest: [UInt8]
    var formatVersion: UInt32
    /// The objects, sorted by path.
    var objects: [(name: ObjectName, object: StoreObject)]
    var previews: [(name: String, data: [UInt8])]
    var stats: SaveStats
}

/// Default for `PcraftWriter.setReverifyBudget`: compressed bytes of already-verified objects
/// re-read per directory save.
public let defaultReverifyBudget: UInt64 = 16 * 1024 * 1024

/// Default for `PcraftWriter.setZipCacheBudget`: compressed bytes of objects a writer keeps
/// between ZIP saves.
public let defaultZipCacheBudget = 64 << 20

/// Incremental `.pcraft` writer. Keep one per open document: it remembers tile hashes (by tile
/// generation), compressed objects, objects it has verified in the current directory and its last
/// previews' PNG bytes, so repeated saves stay cheap.
///
/// **What the directory cache trusts.** A directory save reuses an existing object file only
/// after decompressing it and checking its content. After that, the writer remembers the file's
/// signature (length and modification time, plus inode, device and change time) and skips the
/// full check on later saves while the signature is unchanged. A file damaged in place without
/// changing its signature would be trusted, so each save also re-verifies a rolling share of the
/// cached objects, oldest-checked first, up to `defaultReverifyBudget` bytes (see
/// `setReverifyBudget`). Over enough saves every object is read again, and a damaged one is
/// rewritten.
public final class PcraftWriter {
    var hashCache: [UInt64: ContentDigest] = [:]
    /// Compressed objects by name (ZIP mode), costing at most `zipCacheBudget`.
    var compressedObjects: [ObjectName: StoredObject] = [:]
    var zipCacheBudget = defaultZipCacheBudget
    /// Writes every ZIP64 field (and a format 2 manifest) even when classic ZIP fits: tests of
    /// format 2 without multi-gigabyte documents.
    var forceZip64 = false
    var verified: DirectoryVerificationCache?
    var reverifyBudget = defaultReverifyBudget

    struct DirectoryVerificationCache {
        var directory: String
        /// Directory saves so far; an object's `checkedAt` is the save that last read it fully.
        var generation: UInt64 = 0
        var objects: [String: (signature: FileSignature, checkedAt: UInt64)] = [:]
    }

    public init() {}

    /// How many compressed bytes of already-verified objects each directory save re-reads and
    /// re-checks (oldest-checked first; at least one object when the budget is non-zero). `0`
    /// trusts unchanged signatures entirely; `.max` re-verifies everything on every save.
    public func setReverifyBudget(_ bytes: UInt64) { reverifyBudget = bytes }

    /// How many bytes of compressed objects the writer keeps between ZIP saves, so the next one
    /// reuses them instead of compressing them again (in archive order, as many as fit; each
    /// costs its bytes and `zipCacheEntryCost`). A ZIP save holds at most this much beyond the
    /// document, its manifest and two batches being compressed and written; `0` keeps nothing (a
    /// one-off save).
    public func setZipCacheBudget(_ bytes: Int) {
        zipCacheBudget = max(0, bytes)
        var kept = 0
        compressedObjects = compressedObjects.filter { _, o in
            kept += o.data.count + PcraftWriter.zipCacheEntryCost
            return kept <= zipCacheBudget
        }
    }

    /// What a cached object costs beyond its bytes: its name and its dictionary entry.
    static let zipCacheEntryCost = 256

    /// The PNG bytes of the last previews saved, by entry name.
    var previewPNGs: [String: (image: RGBA8Image, png: [UInt8])] = [:]

    /// Preview `image` as PNG for entry `name`: the last save's bytes again when it is unchanged.
    func png(_ name: String, _ image: RGBA8Image) throws(FormatError) -> [UInt8] {
        if let last = previewPNGs[name], last.image == image { return last.png }
        let png = try Store.png(image)
        previewPNGs[name] = (image, png)
        return png
    }

    /// Generator string written into manifests.
    public static let generator = "photocraft-format 0.1.0 (PhotoCraftNative PCFormat)"

    func prepare(_ doc: Document, _ opts: SaveOptions) throws(FormatError) -> Prepared { try prepareWithModel(doc, opts).prepared }

    /// `prepare`, and the manifest it wrote as a model.
    func prepareWithModel(_ doc: Document, _ opts: SaveOptions) throws(FormatError) -> (model: Manifest, prepared: Prepared) {
        try Convert.checkNesting(doc.layers)
        updateHashCache(doc)
        let (document, objects, counts) = collect(doc)
        var previews: [(String, [UInt8])] = []
        if let t = opts.thumbnail { previews.append((Store.thumb, try png(Store.thumb, t))) }
        if let t = opts.composite { previews.append((Store.composite, try png(Store.composite, t))) }
        // photocraft's version unless the document (a filter adjustment layer) or the container
        // (`saveZip` decides that) needs more.
        let version = Convert.holdsFilterAdjustment(doc.layers) ? pcraftFilterFormatVersion : pcraftPhotocraftFormatVersion
        let manifest = Manifest(formatVersion: version, generator: PcraftWriter.generator, document: document,
                                thumbnail: opts.thumbnail == nil ? nil : Store.thumb, composite: opts.composite == nil ? nil : Store.composite)
        // JSON can't hold NaN or the infinities (they would load as errors): refuse the save
        // instead, naming the value (photocraft #1101).
        do throws(Finite.Problem) {
            try Finite.checkManifest(manifest)
        } catch {
            switch error {
            case .nonFinite(let path): throw .nonFinite(path: path)
            case .other(let m): throw .unsupported("manifest: \(m)")
            }
        }
        let json = try ManifestJSON.encode(manifest)
        try Store.checkManifestDepth(json)
        var stats = SaveStats()
        stats.tilesTotal = counts.tiles
        stats.blobsTotal = counts.blobs
        stats.manifestBytes = json.count
        return (manifest, Prepared(manifest: json, formatVersion: manifest.formatVersion, objects: objects, previews: previews.map { ($0.0, $0.1) },
                                   stats: stats))
    }

    /// `doc` as a manifest model, and its objects sorted by path. The collector's tables, and the hash strings only
    /// they hold, are gone when this returns: before the manifest is encoded.
    func collect(_ doc: Document) -> (DocM, [(name: ObjectName, object: StoreObject)], counts: (tiles: Int, blobs: Int)) {
        let c = Collect(self)
        let document = Convert.docM(doc, c)
        var objects: [(name: ObjectName, object: StoreObject)] = []
        objects.reserveCapacity(c.tiles.count + c.blobs.count)
        for (h, t) in c.tiles { objects.append((ObjectName(isTile: true, digest: h), .tile(t.tile, t.sample))) }
        for (h, b) in c.blobs { objects.append((ObjectName(isTile: false, digest: h), .blob(b.data))) }
        objects.sort { $0.name < $1.name }
        return (document, objects, (c.tiles.count, c.blobs.count))
    }

    /// Brings the hash cache to `doc`'s tiles: those it doesn't have are hashed on all cores, and those of earlier
    /// saves that `doc` no longer has are dropped. Changed in place, so a save never holds two of these tables.
    func updateHashCache(_ doc: Document) {
        var generations = Set<UInt64>()
        var pending: [UInt64: (Tile, SampleType)] = [:]
        Convert.forEachSurface(doc) { s in
            s.forEachTile { _, t in
                generations.insert(t.generation)
                if hashCache[t.generation] == nil { pending[t.generation] = (t, s.format.sample) }
            }
        }
        if hashCache.count > generations.count - pending.count {
            for g in Array(hashCache.keys) where !generations.contains(g) { hashCache[g] = nil }
        }
        generations = []
        if !pending.isEmpty {
            let list = Array(pending)
            pending = [:]
            let hashes = Parallel.map(list.count) { i in PcraftCodec.digest(Collect.tileLE(list[i].value.0, list[i].value.1)) }
            for (i, h) in hashes.enumerated() { hashCache[list[i].key] = h }
        }
    }

    /// Saves as a ZIP bundle in memory: classic ZIP with a format 1 manifest when it fits (what
    /// photocraft reads), ZIP64 with a format 2 manifest when it doesn't (over 4 GiB or 65,535
    /// entries). `save(_:to:as:)` writes a single file without holding it.
    public func saveZip(_ doc: Document, _ opts: SaveOptions = SaveOptions()) throws(FormatError) -> ([UInt8], SaveStats) {
        let p = try prepare(doc, opts)
        var sink = ZipMemorySink()
        // Room for the objects uncompressed: never regrown and copied, and pages that compression
        // saved are never touched.
        sink.bytes.reserveCapacity(p.manifest.count + p.previews.reduce(0) { $0 + $1.data.count }
            + p.objects.reduce(0) { $0 + $1.object.contentSize + $1.object.contentSize / 64 + 128 + ObjectName.pathLength } + 4096)
        let (out, stats) = try writeZip(consume p, into: sink)
        return (out.bytes, stats)
    }

    /// Uncompressed bytes of objects compressed together, on all cores, while the batch before
    /// them is written.
    static let zipBatchBytes = 32 << 20

    /// Writes prepared bundle `p` as a ZIP archive into `sink`, entry by entry: manifest, previews,
    /// then the objects in path order, compressed a batch at a time. A format 1 manifest is
    /// rewritten in place as format 2 (the same length) if the archive turns out to need ZIP64; a
    /// format 3 one (a filter adjustment layer) already allows it. Holds the central directory and
    /// at most two batches beyond the document: not the manifest, once it is written, when `p` is
    /// handed over (AB-T-0328).
    func writeZip<Sink: ZipSink>(_ p: consuming Prepared, into sink: Sink) throws(FormatError) -> (Sink, SaveStats) {
        var manifest = p.manifest, version = p.formatVersion
        p.manifest = []
        var stats = p.stats
        if forceZip64 && version < pcraftZip64FormatVersion {
            manifest = try Self.manifest(manifest, saying: pcraftZip64FormatVersion)
            version = pcraftZip64FormatVersion
        }
        // Format 2 differs from 1 only in the version's digits: where they are and the format 2 text's CRC are worked
        // out now, so the text isn't kept while the objects stream.
        var zip64Patch: (offset: Int, digits: [UInt8], crc: UInt32)?
        let digits = Array(String(pcraftZip64FormatVersion).utf8)
        if version < pcraftZip64FormatVersion, let range = ManifestJSON.formatVersionRange(manifest), range.count == digits.count {
            // In place and back, not in a copy of the text.
            let old = Array(manifest[range])
            manifest.replaceSubrange(range, with: digits)
            zip64Patch = (range.lowerBound, digits, CRC32.checksum(manifest))
            manifest.replaceSubrange(range, with: old)
        }
        var z = ZipStreamWriter(sink, forceZip64: forceZip64)
        do {
            try z.add(Store.manifest, manifest)
            manifest = []
            for (name, data) in p.previews { try z.add(name, data) }
        } catch {
            throw FormatError.wrap(error)
        }
        // Batches of objects, by the bytes they compress.
        let objects = p.objects, cached = compressedObjects
        var batches: [Range<Int>] = []
        var start = 0, bytes = 0
        for (i, o) in objects.enumerated() where cached[o.name] == nil {
            bytes += o.object.contentSize
            if bytes >= PcraftWriter.zipBatchBytes {
                batches.append(start ..< i + 1)
                (start, bytes) = (i + 1, 0)
            }
        }
        if start < objects.count || batches.isEmpty { batches.append(start ..< objects.count) }
        // New objects of a batch, compressed and checksummed on all cores (compression dominates a
        // save, and one CRC pass over gigabytes would be next), in the background.
        func compress(_ range: Range<Int>) -> (DispatchGroup, CompressedBatch) {
            let group = DispatchGroup(), out = CompressedBatch()
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                out.objects = Parallel.map(range.count) { k -> StoredObject? in
                    let o = objects[range.lowerBound + k]
                    if cached[o.name] != nil { return nil }
                    let data = o.object.compressed
                    return StoredObject(data: data, crc: CRC32.checksum(data))
                }
            }
            return (group, out)
        }
        var next: [ObjectName: StoredObject] = [:]
        var kept = 0
        var pending = compress(batches[0])
        // No compression outlives the save, whichever way it ends.
        defer { pending.0.wait() }
        for b in batches.indices {
            let (group, batch) = pending
            group.wait()
            if b + 1 < batches.count { pending = compress(batches[b + 1]) }
            for (k, i) in batches[b].enumerated() {
                let (name, obj) = objects[i]
                let o: StoredObject
                if let d = cached[name] {
                    if obj.isTile { stats.tilesReused += 1 }
                    o = d
                } else {
                    if obj.isTile { stats.tilesWritten += 1 } else { stats.blobsWritten += 1 }
                    o = batch.objects[k] ?? StoredObject(data: obj.compressed)
                }
                do { try z.addStored(name.path, o.data, crc: o.crc) } catch { throw FormatError.wrap(error) }
                let cost = o.data.count + PcraftWriter.zipCacheEntryCost
                if kept + cost <= zipCacheBudget {
                    next[name] = o
                    kept += cost
                }
            }
            batch.objects = []
        }
        do {
            if z.usesZip64 && version < pcraftZip64FormatVersion {
                guard let patch = zip64Patch else { throw FormatError.unsupported("manifest: format \(pcraftZip64FormatVersion) changes its length") }
                try z.patchStored(0, at: patch.offset, patch.digits, crc: patch.crc)
            }
            let out = try z.finish()
            compressedObjects = next
            return (out, stats)
        } catch {
            throw FormatError.wrap(error)
        }
    }

    /// Manifest text `json` saying format `version`, the same length: its `format_version` rewritten in place
    /// (`ManifestJSON.withFormatVersion`), as encoding its model again with that version would write it.
    static func manifest(_ json: [UInt8], saying version: UInt32) throws(FormatError) -> [UInt8] {
        guard let out = ManifestJSON.withFormatVersion(json, version) else {
            throw FormatError.unsupported("manifest: format \(version) changes its length")
        }
        return out
    }

    /// Saves into a directory bundle: reuses only valid existing objects, rewrites missing or
    /// damaged ones, then writes the manifest atomically and removes unreferenced objects.
    ///
    /// **Durability.** The manifest is written last: until it is renamed into place the bundle
    /// still opens as its previous save, whose objects this save never removes before then. New
    /// objects and previews are compressed and written on all cores, each through a temporary file
    /// flushed to the drive (`fsync`) and renamed; their folders are synced once; the manifest's
    /// own full flush (`F_FULLFSYNC`), before its rename, then empties the drive's cache, so every
    /// object it names is on stable storage before it is. One full flush per save, where a flush
    /// per object made a first save of 1,211 tiles spend seconds waiting on the drive (AB-T-0259).
    @discardableResult
    public func saveDir(_ doc: Document, _ dir: URL, _ opts: SaveOptions = SaveOptions()) throws(FormatError) -> SaveStats {
        let root = try DirBundle.root(dir.path)
        let existing = try DirBundle.listObjects(root)
        // Reject a hostile existing entry before writing any object or manifest. This also covers
        // entries that this save would otherwise leave untouched or garbage-collect.
        for path in [Store.manifest, Store.thumb, Store.composite] { try DirBundle.validateFile(root, FS.join(root, path)) }
        let p = try prepare(doc, opts)
        var stats = p.stats
        if verified?.directory != root { verified = DirectoryVerificationCache(directory: root) }
        verified?.generation += 1
        let generation = verified?.generation ?? 0
        // A package save names its objects by path throughout.
        let objects = p.objects.map { (path: $0.name.path, object: $0.object) }
        let recheck = rollingRecheck(Set(objects.map(\.path)))
        // Objects on disk whose signature this writer checked and which aren't due a recheck are
        // reused; the other existing ones are read back and checked, and what is missing or
        // damaged is written. Checks and writes run on all cores.
        var check: [(path: String, object: StoreObject)] = []
        var writes: [(path: String, object: StoreObject)] = []
        for (path, obj) in objects {
            let objectPath = FS.join(root, path)
            // `root` and `listObjects` validated the fixed parent directories once. Check each
            // leaf here; `writeFile` rechecks its parent around every mutation.
            try DirBundle.plainFileOrMissing(objectPath)
            let signature = try DirBundle.pathSignature(objectPath)
            let alreadyVerified = !recheck.contains(path) && signature != nil && verified?.objects[path]?.signature == signature
            if existing.contains(path) && alreadyVerified {
                if obj.isTile { stats.tilesReused += 1 }
            } else if existing.contains(path) {
                check.append((path, obj))
            } else {
                writes.append((path, obj))
            }
        }
        let toCheck = check
        let checked = Parallel.map(toCheck.count) { i -> Result<(Bool, FileSignature?), FormatError> in
            do throws(FormatError) {
                return .success(try DirBundle.existingObjectIsValid(FS.join(root, toCheck[i].path), toCheck[i].object, toCheck[i].path))
            } catch {
                return .failure(error)
            }
        }
        for (i, r) in checked.enumerated() {
            switch r {
            case .success((true, let sig)):
                if let sig { verified?.objects[check[i].path] = (sig, generation) }
                if check[i].object.isTile { stats.tilesReused += 1 }
            case .success((false, _)): writes.append(check[i])
            case .failure(let e): throw e
            }
        }
        for (_, obj) in writes { if obj.isTile { stats.tilesWritten += 1 } else { stats.blobsWritten += 1 } }
        let toWrite = writes
        let written = Parallel.map(toWrite.count) { i -> Result<FileSignature?, FormatError> in
            let objectPath = FS.join(root, toWrite[i].path)
            do throws(FormatError) {
                try DirBundle.writeFile(root, objectPath, toWrite[i].object.compressed, durability: .drive)
                return .success(try DirBundle.pathSignature(objectPath))
            } catch {
                return .failure(error)
            }
        }
        for (i, r) in written.enumerated() {
            switch r {
            case .success(let signature?): verified?.objects[writes[i].path] = (signature, generation)
            case .success(nil): verified?.objects[writes[i].path] = nil
            case .failure(let e): throw e
            }
        }
        for (name, data) in p.previews { try DirBundle.writeFile(root, FS.join(root, name), data, durability: .drive) }
        for stale in [Store.thumb, Store.composite] where !p.previews.contains(where: { $0.name == stale }) {
            let path = FS.join(root, stale)
            try DirBundle.validateFile(root, path)
            do throws(IOError) {
                try DirBundle.removeFile(root, path)
            } catch {
                if error.kind != .notFound { throw .io(error) }
            }
        }
        // The new objects' and previews' names reach the drive before the manifest's flush.
        let renamedInto = Set((writes.map(\.path) + p.previews.map(\.name)).map { (FS.join(root, $0) as NSString).deletingLastPathComponent })
        for dir in renamedInto.sorted() { DirBundle.syncDirectory(dir) }
        try DirBundle.writeFile(root, FS.join(root, Store.manifest), p.manifest)
        // The manifest is committed: the save has succeeded. Removing objects it no longer
        // references is best-effort housekeeping (a vanished or locked file must not turn a
        // complete save into a reported failure); a leftover is retried on the next save.
        let referenced = Set(objects.map(\.path))
        for path in existing.sorted() where !referenced.contains(path) {
            if (try? DirBundle.removeFile(root, FS.join(root, path))) != nil { stats.objectsRemoved += 1 }
            verified?.objects[path] = nil
        }
        return stats
    }

    /// The cached objects this save re-verifies even though their signature is unchanged:
    /// oldest-checked first, until their recorded sizes reach the re-verify budget (always at
    /// least one, so an object larger than the budget is still reached in turn).
    func rollingRecheck(_ objects: Set<String>) -> Set<String> {
        var out = Set<String>()
        guard let cache = verified, reverifyBudget > 0 else { return out }
        let candidates = cache.objects.filter { objects.contains($0.key) }
            .sorted { $0.value.checkedAt != $1.value.checkedAt ? $0.value.checkedAt < $1.value.checkedAt : $0.key < $1.key }
        var spent: UInt64 = 0
        for (path, v) in candidates {
            let next = spent.addingReportingOverflow(v.signature.len).overflow ? UInt64.max : spent + v.signature.len
            if !out.isEmpty && next > reverifyBudget { break }
            spent = next
            out.insert(path)
        }
        return out
    }

    /// Saves to `url`: a directory bundle if `url` is an existing directory or ends with a path
    /// separator, otherwise a ZIP file (written atomically).
    @discardableResult
    public func savePath(_ doc: Document, _ url: URL, _ opts: SaveOptions = SaveOptions()) throws(FormatError) -> SaveStats {
        let package = FS.isDir(url.path) || url.hasDirectoryPath || url.path.hasSuffix("/")
        return try save(doc, to: url, as: package ? .package : .singleFile, opts)
    }

    /// Saves to `url` in `container`'s form: a package (`saveDir`, incremental) or one ZIP file
    /// written atomically (`saveZip`).
    @discardableResult
    public func save(_ doc: Document, to url: URL, as container: PcraftFormat.Container, _ opts: SaveOptions = SaveOptions()) throws(FormatError) -> SaveStats {
        switch container {
        case .package:
            return try saveDir(doc, url, opts)
        case .singleFile:
            // Handed to the archive writer, which lets go of the manifest once it is written.
            var p: Prepared? = try prepare(doc, opts)
            var stats = SaveStats()
            try AtomicSave.atomicWriteStreaming(url) { fd throws(FormatError) in
                stats = try writeZip(p.take()!, into: FileZipSink(fd: fd, path: url.path)).1
            }
            return stats
        }
    }
}

/// A ZIP archive streamed into an open file. Headers and other small entries are gathered into
/// one write; large entries go straight to the file.
struct FileZipSink: ZipSink {
    let fd: Int32
    let path: String
    private var buffer: [UInt8] = []
    static let bufferSize = 1 << 20

    init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
        buffer.reserveCapacity(FileZipSink.bufferSize)
    }

    mutating func write(_ bytes: UnsafeRawBufferPointer) throws {
        if buffer.count + bytes.count > FileZipSink.bufferSize { try flush() }
        if bytes.count >= FileZipSink.bufferSize / 4 {
            try flush()
            try AtomicSave.writeAll(fd, bytes, path)
        } else {
            buffer.append(contentsOf: bytes.assumingMemoryBound(to: UInt8.self))
        }
    }

    mutating func overwrite(_ bytes: UnsafeRawBufferPointer, at offset: Int) throws {
        try flush()
        try AtomicSave.writeAll(fd, bytes, at: offset, path)
    }

    mutating func flush() throws {
        if buffer.isEmpty { return }
        let failure: IOError? = buffer.withUnsafeBytes { b in
            do throws(IOError) { try AtomicSave.writeAll(fd, b, path) } catch { return error }
            return nil
        }
        if let failure { throw failure }
        buffer.removeAll(keepingCapacity: true)
    }
}

// MARK: - Directory bundles

/// Directory-bundle file operations: every managed entry stays below the bundle root, and none
/// may be a symlink (the root itself may be one the caller chose).
enum DirBundle {
    static func unsafeEntry(_ path: String) -> FormatError {
        .io(IOError(.invalidData, "refusing directory bundle save: \(path) is a symlink or not a regular file"))
    }

    static func lkind(_ path: String) throws(FormatError) -> FS.Kind? {
        do throws(IOError) { return try FS.lkind(path) } catch { throw .io(error) }
    }

    static func plainFileOrMissing(_ path: String) throws(FormatError) {
        switch try lkind(path) {
        case nil, .file?: return
        default: throw unsafeEntry(path)
        }
    }

    static func plainDirectoryOrMissing(_ path: String) throws(FormatError) {
        switch try lkind(path) {
        case nil, .directory?: return
        default: throw .io(IOError(.invalidData, "refusing directory bundle save: \(path) is a symlink or not a directory"))
        }
    }

    static func canonical(_ path: String) throws(FormatError) -> String {
        do throws(IOError) { return try FS.canonicalize(path) } catch { throw .io(error) }
    }

    /// The canonical root (created if needed), so a later replacement of the caller's path can't
    /// redirect the save; managed subdirectories below it must not be symlinks.
    static func root(_ dir: String) throws(FormatError) -> String {
        var d = dir
        while d.count > 1 && d.hasSuffix("/") { d.removeLast() }
        do throws(IOError) { try FS.createDirAll(d) } catch { throw .io(error) }
        let root = try canonical(d)
        try plainDirectoryOrMissing(root)
        for sub in ["tiles", "blobs", "composite"] {
            let path = FS.join(root, sub)
            try plainDirectoryOrMissing(path)
            if !FS.exists(path) && mkdir(path, 0o777) != 0 && errno != EEXIST { throw .io(IOError.last(path)) }
            try plainDirectoryOrMissing(path)
            if try canonical(path) != path { throw unsafeEntry(path) }
        }
        return root
    }

    static func validateFile(_ root: String, _ path: String) throws(FormatError) {
        let parent = (path as NSString).deletingLastPathComponent
        guard [root, FS.join(root, "tiles"), FS.join(root, "blobs"), FS.join(root, "composite")].contains(parent) else { throw unsafeEntry(path) }
        try plainDirectoryOrMissing(parent)
        if try canonical(parent) != parent { throw unsafeEntry(parent) }
        try plainFileOrMissing(path)
    }

    static func pathSignature(_ path: String) throws(FormatError) -> FileSignature? {
        var st = stat()
        if lstat(path, &st) != 0 {
            if errno == ENOENT { return nil }
            throw .io(IOError.last(path))
        }
        guard st.st_mode & S_IFMT == S_IFREG else { throw unsafeEntry(path) }
        return FileSignature(st)
    }

    /// How far `writeFile` flushes what it writes before it returns.
    enum Durability {
        /// On stable storage: the file fully flushed (`F_FULLFSYNC`), and its folder synced after
        /// the rename.
        case stable
        /// On the drive: the file `fsync`ed (the drive may still cache it), its folder not synced.
        /// The caller syncs the folders (`syncDirectory`) and fully flushes something after.
        case drive
    }

    /// Writes `data` to `path` through a temporary file and a rename, rechecking the target and
    /// its parent around each step (photocraft `write_bundle_file`).
    static func writeFile(_ root: String, _ path: String, _ data: [UInt8], durability: Durability = .stable) throws(FormatError) {
        try validateFile(root, path)
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        var tmp: String?
        var fd: Int32 = -1
        for _ in 0 ..< 8 {
            let candidate = FS.join(parent, AtomicSave.tempName(name))
            fd = open(candidate, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
            if fd >= 0 {
                tmp = candidate
                break
            }
            if errno != EEXIST { throw .io(IOError.last(candidate)) }
        }
        guard let tmp else { throw .io(IOError(.alreadyExists, "could not create a temporary file beside \(path)")) }
        var open = true
        func closeOnce() {
            if open { close(fd) }
            open = false
        }
        do throws(FormatError) {
            // The parent may have changed between validation and creation: check the new file's
            // resolved location before putting document bytes into it.
            if try canonical(tmp) != tmp { throw unsafeEntry(tmp) }
            try validateFile(root, path)
            do throws(IOError) {
                try AtomicSave.writeAll(fd, data, 0, data.count, tmp)
                switch durability {
                case .stable: try AtomicSave.syncFile(fd)
                case .drive: if fsync(fd) != 0 { throw IOError.last("fsync") }
                }
            } catch {
                throw .io(error)
            }
            closeOnce()
            // Preserve the existing mode where possible.
            var st = stat()
            if stat(path, &st) == 0 { _ = chmod(tmp, st.st_mode & 0o7777) }
            // Recheck the parent and target just before publishing. rename replaces a symlink
            // itself, never its referent, even if one appears after this check.
            try validateFile(root, path)
            do throws(IOError) {
                try AtomicSave.retryRename(.platform) { () throws(IOError) in
                    if rename(tmp, path) != 0 { throw IOError.last("rename") }
                }
            } catch {
                throw .io(error)
            }
            if durability == .stable { syncDirectory(parent) }
        } catch {
            closeOnce()
            if (try? validateFile(root, tmp)) != nil { unlink(tmp) }
            throw error
        }
    }

    /// Syncs folder `dir` (best effort: the files in it are already renamed into place).
    static func syncDirectory(_ dir: String) {
        let dfd = Darwin.open(dir, O_RDONLY | O_CLOEXEC)
        if dfd >= 0 {
            _ = fsync(dfd)
            close(dfd)
        }
    }

    static func removeFile(_ root: String, _ path: String) throws(IOError) {
        do throws(FormatError) { try validateFile(root, path) } catch {
            if case .io(let e) = error { throw e }
            throw IOError(.invalidData, error.description)
        }
        try FS.removeFile(path)
    }

    /// Whether the object file at `path` decodes to exactly `object`'s content, and its signature.
    static func existingObjectIsValid(_ path: String, _ object: StoreObject, _ what: String) throws(FormatError) -> (Bool, FileSignature?) {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return (false, nil) }
            throw .io(IOError.last(path))
        }
        defer { close(fd) }
        var st = stat()
        if fstat(fd, &st) != 0 { throw .io(IOError.last(path)) }
        guard st.st_mode & S_IFMT == S_IFREG else { return (false, nil) }
        let signature = FileSignature(st)
        let expected = object.content
        // The tile loader's bound: zstd framing overhead included, damaged files kept bounded.
        let maxLen = expected.count + expected.count / 8 + 4096
        if UInt64(max(0, st.st_size)) > UInt64(maxLen) { return (false, nil) }
        var r = FileDescriptorReader(fd: fd)
        let compressed: [UInt8]
        do throws(FormatError) {
            compressed = try FileRead.readEntry(&r, len: UInt64(max(0, st.st_size)), max: maxLen, path: what)
        } catch {
            if case .limitExceeded = error { return (false, nil) }
            throw error
        }
        let matches = (try? PcraftCodec.decompress(compressed, expected: expected.count, what: what)) == expected
        return (matches, signature)
    }

    static func listObjects(_ root: String) throws(FormatError) -> Set<String> {
        var out = Set<String>()
        for sub in ["tiles", "blobs"] {
            let dir = FS.join(root, sub)
            try plainDirectoryOrMissing(dir)
            if try canonical(dir) != dir { throw unsafeEntry(dir) }
            let names: [String]
            do throws(IOError) { names = try FS.list(dir) } catch { throw .io(error) }
            for name in names where name.hasSuffix(".zst") {
                let path = FS.join(dir, name)
                switch try lkind(path) {
                case .symlink?: throw unsafeEntry(path)
                case .file?: out.insert("\(sub)/\(name)")
                // Stale directories can't be removed with unlink: leave them for later cleanup
                // without failing a save of otherwise valid content.
                default: break
                }
            }
        }
        return out
    }
}
