// doc → .pcraft → doc equality, incremental saves, ids, previews.
// Port of photocraft-format (crates/format/tests/roundtrip.rs), MIT OR Apache-2.0, © ArtCraft Team
// and the PhotoCraft contributors.

import Foundation
import ImageIO
@testable import PCFormat
import PCDocument
import PCFoundation
import PCIOCore
import Testing

let allModes: [ColorMode] = [.rgb, .grayscale, .cmyk, .lab]
let allDepths: [SampleType] = [.u8, .u16, .f32]

/// Runs `body` on a thread with `stackSize` bytes of stack and returns its result.
final class ThreadResult<T>: @unchecked Sendable {
    var value: T?
    let done = DispatchSemaphore(value: 0)
}

func onThread<T: Sendable>(stackSize: Int, _ body: @escaping @Sendable () -> T) -> T {
    let box = ThreadResult<T>()
    let t = Thread {
        box.value = body()
        box.done.signal()
    }
    t.stackSize = stackSize
    t.start()
    box.done.wait()
    return box.value!
}

@Suite struct RoundtripTests {
    @Test(arguments: allModes)
    func customShapeStrokeRoundtripKeepsEveryStyleField(mode: ColorMode) throws {
        for depth in allDepths {
            var d = richDoc(mode, depth)
            let stroke = ShapeStroke(width: 5.5, opacity: 0.35, align: .outside, cap: .square, join: .bevel, miterLimit: 2,
                                     dashes: [0, 2, 4, 1, 1.5, 3], dashOffset: -0.5)
            d.layers.append(Layer(name: "Custom stroke", content: .shape(ShapeLayer(
                path: VectorPath([Subpath.polygon([(10, 10), (40, 10), (25, 40)])]), stroke: stroke))))
            #expect(try load(try save(d)) == d, "\(mode) \(depth)")
        }
    }

    @Test(arguments: allModes, allDepths)
    func zipRoundtrip(mode: ColorMode, depth: SampleType) throws {
        let doc = richDoc(mode, depth)
        let bytes = try save(doc)
        #expect(PcraftFormat.isPcraft(bytes))
        #expect(try load(bytes) == doc, "\(mode) \(depth)")
    }

    @Test(arguments: allModes)
    func directoryBundleRoundtripAllModes(mode: ColorMode) throws {
        for depth in allDepths {
            let doc = richDoc(mode, depth)
            let dir = tempDir("dir")
            try PcraftWriter().saveDir(doc, dir)
            #expect(FS.isFile(dir.appendingPathComponent("manifest.json").path))
            #expect(try PcraftFormat.load(contentsOf: dir) == doc, "\(mode) \(depth)")
            remove(dir)
        }
    }

    @Test func savePathZipFile() throws {
        let doc = richDoc(.rgb, .u8)
        let dir = tempDir("file")
        let path = dir.appendingPathComponent("a.pcraft")
        try PcraftWriter().savePath(doc, path)
        #expect(FS.isFile(path.path))
        #expect(try PcraftFormat.load(contentsOf: path) == doc)
        remove(dir)
    }

    /// Reads the on-disk bundle shape for `loadBytesSourceMatchesThePathLoad`.
    struct FsDir: ByteSource {
        let root: URL
        func get(_ path: String, max: Int) throws(FormatError) -> [UInt8] {
            let p = root.appendingPathComponent(path).path
            var st = stat()
            guard stat(p, &st) == 0 else { throw .corrupt("missing `\(path)`") }
            guard st.st_mode & S_IFMT == S_IFREG else { throw .corrupt("`\(path)` is not a regular file") }
            let fd = open(p, O_RDONLY)
            guard fd >= 0 else { throw .corrupt("missing `\(path)`") }
            defer { close(fd) }
            var r = FileDescriptorReader(fd: fd)
            return try FileRead.readEntry(&r, len: UInt64(st.st_size), max: max, path: path)
        }
    }

    /// The public `ByteSource` entry loads a saved directory like the path load does.
    @Test func loadBytesSourceMatchesThePathLoad() throws {
        let doc = richDoc(.rgb, .u8)
        let dir = tempDir("bytes-source")
        let bundle = dir.appendingPathComponent("a.pcraft")
        try PcraftWriter().saveDir(doc, bundle)
        #expect(try PcraftFormat.load(from: FsDir(root: bundle)) == doc)
        #expect(throws: FormatError.self, "a missing bundle errors") { try PcraftFormat.load(from: FsDir(root: bundle.appendingPathComponent("no-such-dir"))) }
        remove(dir)
    }

    /// `readEntry` bounds the read itself, not the stat hint: a stream that ignores the hint and
    /// yields more than `max` errors instead of filling memory.
    @Test func readEntryBoundsTheReadNotTheHint() throws {
        struct Endless: ChunkReader {
            mutating func read(_ maxCount: Int) throws(IOError) -> [UInt8] { [UInt8](repeating: UInt8(ascii: "x"), count: min(maxCount, 1 << 16)) }
        }
        var endless = Endless()
        do throws(FormatError) {
            _ = try FileRead.readEntry(&endless, len: 0, max: 100, path: "manifest.json")
            Issue.record("an endless reader must fail")
        } catch {
            #expect(error.description.contains("exceeds"), "\(error)")
        }
        var small = MemoryChunkReader(Array("hi".utf8))
        #expect(try FileRead.readEntry(&small, len: 2, max: 100, path: "manifest.json") == Array("hi".utf8))
    }

    /// Deepest group nesting in `layers` (0 when there are no groups).
    static func groupDepth(_ layers: [Layer]) -> Int {
        layers.map { l in l.children.map { 1 + groupDepth($0) } ?? 0 }.max() ?? 0
    }

    /// `richDoc` with its layers wrapped in groups until they are nested `levels` deep.
    static func nestedDoc(_ levels: Int, _ depth: SampleType) -> Document {
        var doc = richDoc(.rgb, depth)
        var layers = doc.layers
        var i = groupDepth(layers)
        while i < levels {
            layers = [Layer.group("Level \(i)", layers)]
            i += 1
        }
        doc.layers = layers
        return doc
    }

    /// Bundles with 40+ nested groups must stay readable. The save and the load run on a 1 MiB
    /// stack, as photocraft's test does (its smallest main-thread stack); the comparison (the
    /// model's synthesized `==`, recursive and large-framed in debug builds) runs on a big one.
    @Test func deeplyNestedGroupsRoundtrip() throws {
        for (levels, depth) in [(40, SampleType.u8), (PcraftFormat.maxGroupDepth, .u16), (PcraftFormat.maxGroupDepth, .f32)] {
            let doc = RoundtripTests.nestedDoc(levels, depth)
            #expect(RoundtripTests.groupDepth(doc.layers) == levels)
            let back = onThread(stackSize: 1 << 20) { () -> Result<Document, FormatError> in
                do throws(FormatError) {
                    return .success(try PcraftFormat.load(try PcraftFormat.save(doc)))
                } catch {
                    return .failure(error)
                }
            }
            let loaded = try back.get()
            #expect(onThread(stackSize: 64 << 20) { loaded == doc }, "\(levels) levels at \(depth)")
        }
    }

    /// A save never writes a bundle the loader would reject for its nesting.
    @Test func nestingBeyondTheLoadLimitIsRefusedAtSave() {
        #expect {
            _ = try save(RoundtripTests.nestedDoc(PcraftFormat.maxGroupDepth + 1, .u8))
        } throws: { e in
            if case FormatError.limitExceeded = e { return true }
            return false
        }
    }

    @Test func emptyDocumentRoundtrips() throws {
        let doc = Document(name: "empty", size: PixelSize(width: 1, height: 1), mode: .rgb, depth: .u8)
        #expect(try load(try save(doc)) == doc)
    }

    @Test func exhaustedDocumentIdsAndMaximalTextRunsRoundtrip() throws {
        var doc = Document(name: "exhausted", size: PixelSize(width: 2, height: 1), mode: .rgb, depth: .u8)
        doc.slices.list.append(Slice(id: UInt32.max))
        doc.textStyles.character.append(CharacterStyleDef(id: UInt32.max))
        doc.textStyles.paragraph.append(ParagraphStyleDef(id: UInt32.max))
        var big = CharStyle()
        big.sizePt = 24
        var t = TextLayer(text: "ab")
        t.runs = [TextRun(len: 1, style: CharStyle()), TextRun(len: Int.max, style: big)]
        t.paragraphs = [ParagraphRun(len: 1, style: ParagraphStyle()), ParagraphRun(len: Int.max, style: ParagraphStyle())]
        doc.layers.append(Layer(name: "Text", content: .text(t)))

        let loaded = try load(try save(doc))
        #expect(loaded.slices.nextId == nil)
        #expect(loaded.textStyles.nextCharId == nil)
        #expect(loaded.textStyles.nextParaId == nil)
        guard case .text(let text) = loaded.layers.last?.content else {
            Issue.record("text layer must roundtrip")
            return
        }
        #expect(text.charRuns().map(\.len).reduce(0, +) == text.text.utf8.count)
        #expect(text.charRuns()[1].len == 1)
        #expect(text.charRuns()[1].style.sizePt == 24)
        #expect(text.paragraphRuns().map(\.len).reduce(0, +) == text.text.utf8.count)
    }

    @Test func zipIncrementalOnlyNewTiles() throws {
        var doc = richDoc(.rgb, .u16)
        let w = PcraftWriter()
        let (_, s1) = try w.saveZip(doc)
        #expect(s1.tilesTotal > 5)
        #expect(s1.tilesWritten == s1.tilesTotal)
        let (_, s2) = try w.saveZip(doc)
        #expect(s2.tilesWritten == 0)
        #expect(s2.tilesReused == s2.tilesTotal)
        #expect(s2.blobsWritten == 0)
        // Touch one pixel of one layer: exactly one tile is new.
        let id = doc.layers[1].id
        doc.withRaster(of: id) { $0.setPixel(x: 3, y: 3, [0.5, 0.5, 0.5, 1]) }
        let (bytes, s3) = try w.saveZip(doc)
        #expect(s3.tilesWritten == 1)
        #expect(try load(bytes) == doc)
    }

    @Test func directoryIncrementalAndGC() throws {
        var doc = richDoc(.rgb, .u8)
        let dir = tempDir("gc")
        let w = PcraftWriter()
        let s1 = try w.saveDir(doc, dir)
        #expect(s1.tilesWritten == s1.tilesTotal)
        let s2same = try w.saveDir(doc, dir)
        #expect(s2same.tilesWritten == 0)
        #expect(s2same.tilesReused == s2same.tilesTotal)
        // A fresh writer still skips files already on disk.
        let s2 = try PcraftWriter().saveDir(doc, dir)
        #expect(s2.tilesWritten == 0)
        #expect(s2.objectsRemoved == 0)
        // Delete a layer: its unique tiles get garbage-collected.
        doc.remove(doc.layers[1].id)
        let s3 = try w.saveDir(doc, dir)
        #expect(s3.objectsRemoved > 0, "\(s3)")
        #expect(try PcraftFormat.load(contentsOf: dir) == doc)
        #expect(try FS.list(dir.appendingPathComponent("tiles").path).count == s3.tilesTotal)
        remove(dir)
    }

    @Test func directorySaveRejectsObjectDirectorySymlinkWithoutDeletingExternalObjects() throws {
        let doc = richDoc(.rgb, .u8)
        let dir = tempDir("symlink-object-dir")
        let outside = tempDir("symlink-object-dir-outside")
        let external = outside.appendingPathComponent("unrelated.zst")
        try Data("keep this object".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("tiles"), withDestinationURL: outside)
        #expect(throws: FormatError.self) { try PcraftWriter().saveDir(doc, dir) }
        #expect(try Data(contentsOf: external) == Data("keep this object".utf8))
        #expect(!FS.exists(dir.appendingPathComponent("manifest.json").path))
        remove(dir)
        remove(outside)
    }

    @Test func directorySaveRejectsObjectSymlinkWithoutOverwritingTarget() throws {
        let doc = richDoc(.rgb, .u8)
        let dir = tempDir("symlink-object")
        let outside = tempDir("symlink-object-outside")
        let writer = PcraftWriter()
        try writer.saveDir(doc, dir)
        let tiles = dir.appendingPathComponent("tiles")
        let object = tiles.appendingPathComponent(try FS.list(tiles.path).sorted()[0])
        try FileManager.default.removeItem(at: object)
        let external = outside.appendingPathComponent("external.zst")
        try Data("do not overwrite".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: object, withDestinationURL: external)
        #expect(throws: FormatError.self) { try writer.saveDir(doc, dir) }
        #expect(try Data(contentsOf: external) == Data("do not overwrite".utf8))
        #expect(try FS.lkind(object.path) == .symlink)
        remove(dir)
        remove(outside)
    }

    @Test func directorySaveAcceptsChosenRootSymlinkButRejectsPreviewSymlink() throws {
        let doc = richDoc(.rgb, .u8)
        let outside = tempDir("symlink-preview-outside")
        let parent = tempDir("symlink-root-parent")
        let rootLink = parent.appendingPathComponent("linked.pcraft")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: outside)
        try PcraftWriter().saveDir(doc, rootLink)
        #expect(try PcraftFormat.load(contentsOf: rootLink) == doc)
        try PcraftWriter().saveDir(doc, URL(fileURLWithPath: rootLink.path + "/"))
        #expect(FS.isFile(outside.appendingPathComponent("manifest.json").path))

        let dir = tempDir("symlink-preview")
        let externalPreview = outside.appendingPathComponent("preview.png")
        try Data("keep preview".utf8).write(to: externalPreview)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("composite"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("composite/preview.png"), withDestinationURL: externalPreview)
        let opts = SaveOptions(composite: RGBA8Image(width: 2, height: 2))
        #expect(throws: FormatError.self) { try PcraftWriter().saveDir(doc, dir, opts) }
        #expect(try Data(contentsOf: externalPreview) == Data("keep preview".utf8))
        #expect(!FS.exists(dir.appendingPathComponent("manifest.json").path))
        remove(rootLink)
        remove(parent)
        remove(dir)
        remove(outside)
    }

    @Test func directorySaveRejectsManifestSymlinkWithoutOverwritingTarget() throws {
        let doc = richDoc(.rgb, .u8)
        let dir = tempDir("symlink-manifest")
        let outside = tempDir("symlink-manifest-outside")
        let external = outside.appendingPathComponent("external.json")
        try Data("keep manifest".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("manifest.json"), withDestinationURL: external)
        #expect(throws: FormatError.self) { try PcraftWriter().saveDir(doc, dir) }
        #expect(try Data(contentsOf: external) == Data("keep manifest".utf8))
        #expect(try FS.list(dir.appendingPathComponent("tiles").path).isEmpty)
        remove(dir)
        remove(outside)
    }

    @Test func identicalTilesAreStoredOnce() throws {
        var doc = Document(name: "d", size: PixelSize(width: 10, height: 10), mode: .rgb, depth: .u8)
        var a = Layer.raster("a", format: doc.pixelFormat)
        a.withRaster { scribble(&$0, 5, false) }
        let b = a.duplicate()
        doc.layers += [a, b]
        let (_, s) = try PcraftWriter().saveZip(doc)
        #expect(s.tilesTotal == doc.layers[0].surface?.tileCount)
    }

    /// A solid fill saves one tile however many coordinates share it; reopening must decode it
    /// once, charge the byte budget once and keep the sharing (photocraft #3315). The budget here
    /// holds one tile, standing in for a canvas too large to expand tile by tile.
    @Test(arguments: allDepths)
    func solidFillReopensWithOneSharedTile(depth: SampleType) throws {
        let size = PixelSize(width: 2048, height: 2048)
        var doc = Document(name: "d", size: size, mode: .rgb, depth: depth)
        var l = Layer.raster("solid", format: doc.pixelFormat)
        l.withRaster { $0.fill(PixelRect(size: size), with: [1, 0.5, 0.25, 1]) }
        doc.layers.append(l)
        let bytes = try save(doc)
        let oneTile = UInt64(256 * 256 * doc.pixelFormat.bytesPerPixel)
        let back = try load(bytes, LoadOptions(maxTotalBytes: oneTile))
        #expect(back == doc, "\(depth)")
        let s = try #require(back.layers[0].surface)
        #expect(s.tileCount == 64)
        let first = try #require(s.tile(s.tileCoords[0]))
        // Every reference shares the one decoded tile (same identity and the same storage).
        let base = first.bytes.withUnsafeBufferPointer { $0.baseAddress }
        #expect(s.tileCoords.allSatisfy { c in
            s.tile(c).map { $0.generation == first.generation && $0.bytes.withUnsafeBufferPointer { $0.baseAddress } == base } ?? false
        }, "\(depth): tiles not shared after reopening")
    }

    @Test func idsPreservedAndCounterAdvanced() throws {
        let doc = richDoc(.rgb, .u8)
        let bytes = try save(doc)
        // Simulate a file written with much larger ids.
        var m = try PcraftFormat.readManifest(bytes)
        m.document.layers[0].id = LayerId.fresh().rawValue + 5000
        let big = m.document.layers[0].id
        let text = [UInt8](try JSONEncoder().encode(m))
        let rebuilt = try rebuild(bytes) { name, data in name == "manifest.json" ? text : data }
        let back = try load(rebuilt)
        #expect(back.layers[0].id.rawValue == big)
        #expect(LayerId.fresh().rawValue > big, "fresh ids must not collide with loaded ids")
    }

    @Test func freshIdsOption() throws {
        let doc = richDoc(.rgb, .u8)
        let back = try load(try save(doc), LoadOptions(preserveIds: false))
        #expect(back.id != doc.id)
        #expect(back.layers[0].id != doc.layers[0].id)
        #expect(back.layers.count == doc.layers.count)
        #expect(back.layers[1].surface == doc.layers[1].surface)
    }

    /// Straight RGBA8 pixels of a PNG, read without premultiplying.
    static func pngPixels(_ png: [UInt8]) -> (Int, Int, [UInt8])? {
        guard let src = CGImageSourceCreateWithData(Data(png) as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              img.bitsPerComponent == 8, img.bitsPerPixel == 32, img.alphaInfo == .last,
              let data = img.dataProvider?.data as Data? else { return nil }
        var out: [UInt8] = []
        for y in 0 ..< img.height { out += data[y * img.bytesPerRow ..< y * img.bytesPerRow + img.width * 4] }
        return (img.width, img.height, out)
    }

    @Test func previewsEmbeddedAndReadable() throws {
        let doc = richDoc(.rgb, .u8)
        var thumb = RGBA8Image(width: 4, height: 3)
        for i in thumb.data.indices { thumb.data[i] = UInt8(i) }
        let bytes = try save(doc, SaveOptions(thumbnail: thumb, composite: thumb))
        let png = try #require(try PcraftFormat.readThumbnail(bytes))
        let decoded = try #require(RoundtripTests.pngPixels(png))
        #expect(decoded.0 == 4 && decoded.1 == 3)
        #expect(decoded.2 == thumb.data)
        let m = try PcraftFormat.readManifest(bytes)
        #expect(m.composite == "composite/preview.png")
        #expect(m.formatVersion == PcraftFormat.formatVersion)
        #expect(try PcraftFormat.readThumbnail(try save(doc)) == nil)
    }

    @Test func manifestIsHumanReadableJSON() throws {
        let bytes = try save(richDoc(.rgb, .u8))
        let r = try ZipReader(bytes)
        #expect(r.entries[0].name == "manifest.json")
        let text = String(decoding: try r.read(named: "manifest.json", max: .max), as: UTF8.self)
        #expect(text.contains("\"format_version\": 1"))
        #expect(text.contains("\"Hue/Sat\""))
        #expect(text.contains("filter.blur.gaussian"))
        #expect(r.entries.contains { $0.name.hasPrefix("tiles/") && $0.name.hasSuffix(".zst") })
        #expect(r.entries.contains { $0.name.hasPrefix("blobs/") })
    }

    @Test func saveIsDeterministic() throws {
        let doc = richDoc(.cmyk, .u16)
        #expect(try save(doc) == save(doc))
    }

    @Test func notPcraft() throws {
        #expect(!PcraftFormat.isPcraft([]))
        #expect(!PcraftFormat.isPcraft(Array("8BPS....".utf8)))
        var z = ZipWriter()
        try z.add("other.txt", Array("x".utf8))
        #expect(!PcraftFormat.isPcraft(try z.finish()))
    }

    /// The document part of a manifest as a Foundation JSON object.
    static func docJSON(_ m: Manifest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try JSONEncoder().encode(m.document)) as? [String: Any] ?? [:]
    }

    static func docM(_ v: [String: Any]) throws -> DocM {
        try JSONDecoder().decode(DocM.self, from: try JSONSerialization.data(withJSONObject: v))
    }

    @Test func vectorFieldsRoundtripAndDefaultWhenAbsent() throws {
        let doc = richDoc(.rgb, .u8)
        let back = try load(try save(doc))
        #expect(back.paths == doc.paths)
        #expect(back.workPath == doc.workPath)
        #expect(back.clippingPath == doc.clippingPath)
        func vm(_ d: Document) -> VectorMask? { d.walk().lazy.compactMap(\.layer.vectorMask).first }
        #expect(vm(back) != nil)
        #expect(vm(back) == vm(doc))
        // Manifests written before the vector fields existed still load (serde defaults).
        var v = try RoundtripTests.docJSON(try PcraftFormat.readManifest(try save(doc)))
        for k in ["paths", "work_path", "clipping_path"] { v[k] = nil }
        func strip(_ layers: [Any]) -> [Any] {
            layers.map { l in
                guard var l = l as? [String: Any] else { return l }
                l["vector_mask"] = nil
                if var c = l["content"] as? [String: Any] {
                    for k in ["path", "stroke", "live"] { c[k] = nil }
                    if let ch = c["children"] as? [Any] { c["children"] = strip(ch) }
                    l["content"] = c
                }
                return l
            }
        }
        v["layers"] = strip(v["layers"] as? [Any] ?? [])
        let old = try RoundtripTests.docM(v)
        #expect(old.paths.isEmpty && old.workPath == nil)
        #expect(old.layers.allSatisfy { $0.vectorMask == nil })
    }

    /// Type kerning: the auto mode and manual kerning survive .pcraft; manifests written before
    /// `kern` existed load with no manual kerning.
    @Test func textKerningRoundtripsAndDefaults() throws {
        let doc = richDoc(.rgb, .u8)
        let bytes = try save(doc)
        let back = try load(bytes)
        func runs(_ d: Document) -> [String] {
            for e in d.walk() {
                if case .text(let t) = e.layer.content { return t.runs.map { "\($0.len) \($0.style.kerning) \($0.style.kern)" } }
            }
            return []
        }
        #expect(runs(back) == ["1 \(Kerning.off) 120.0", "5 \(Kerning.metrics) 0.0", "9 \(Kerning.optical) 0.0"])
        #expect(runs(back) == runs(doc))
        func strip(_ v: Any) -> Any {
            if var o = v as? [String: Any] {
                o["kern"] = nil
                for (k, x) in o { o[k] = strip(x) }
                return o
            }
            if let a = v as? [Any] { return a.map(strip) }
            return v
        }
        let stripped = strip(try RoundtripTests.docJSON(try PcraftFormat.readManifest(bytes))) as? [String: Any] ?? [:]
        let strippedText = String(decoding: try JSONSerialization.data(withJSONObject: stripped), as: UTF8.self)
        #expect(!strippedText.contains("\"kern\""))
        let old = try RoundtripTests.docM(stripped)
        let s = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        #expect(s.contains("\"kern\":0"), "kern defaults to 0")
    }

    @Test func channelRestrictionsAndBevelElementsRoundtrip() throws {
        var doc = richDoc(.rgb, .u8)
        doc.updateLayer(at: [0]) { $0.excludedChannels = 0b101 }
        let b = Bevel(enabled: true, style: .emboss, technique: .chiselHard, depth: 1.2, up: false, size: 9, soften: 1, angle: 30, altitude: 40,
                      useGlobalLight: false, glossContour: .linear, highlight: FxCommon(.screen, 0.7), highlightColor: .white,
                      shadow: FxCommon(.multiply, 0.6), shadowColor: .black,
                      contour: BevelContour(contour: .linear, range: 0.3, antiAlias: true),
                      texture: BevelTexture(name: "p", id: "i", scale: 0.5, depth: -1.5, invert: true, link: false, phase: SIMD2(1, 2)))
        doc.updateLayer(at: [0]) { $0.effects.items.append(.bevelEmboss(b)) }
        let back = try load(try save(doc))
        #expect(back == doc)
        #expect(back.layers[0].excludedChannels == 0b101)
    }

    @Test func blendIfRoundtrips() throws {
        var doc = richDoc(.rgb, .u16)
        var bi = BlendIf()
        bi.set(0, BlendRangePair(BlendRange(black: SIMD2(20, 60), white: SIMD2(255, 255)), .full))
        bi.set(3, BlendRangePair(.full, BlendRange(black: SIMD2(0, 0), white: SIMD2(180, 220))))
        doc.updateLayer(at: [0]) { $0.blendIf = bi }
        let back = try load(try save(doc))
        #expect(back == doc)
        #expect(back.layers[0].blendIf == bi)
        // Layers without Blend If keep the default (the field is omitted from the manifest).
        #expect(back.layers.dropFirst().allSatisfy { $0.blendIf.isDefault })
    }

    /// Advanced Blending survives .pcraft at every depth; manifests written before the field
    /// existed load with Photoshop's defaults, and default layers don't write it.
    @Test(arguments: allDepths)
    func advancedBlendingRoundtripsAndDefaultsWhenAbsent(depth: SampleType) throws {
        var doc = richDoc(.rgb, depth)
        let a = AdvancedBlending(knockout: .deep, blendInterior: true, blendClipped: false, transparencyShapes: false,
                                 layerMaskHidesEffects: true, vectorMaskHidesEffects: true)
        doc.updateLayer(at: [0]) { $0.advanced = a }
        if doc.layers.count > 1 { doc.updateLayer(at: [1]) { $0.advanced.knockout = .shallow } }
        let bytes = try save(doc)
        let back = try load(bytes)
        #expect(back == doc, "\(depth)")
        #expect(back.layers[0].advanced == a)
        // Only the non-default layers carry the field.
        let v = try RoundtripTests.docJSON(try PcraftFormat.readManifest(bytes))
        let layers = v["layers"] as? [[String: Any]] ?? []
        #expect(layers.filter { $0["advanced"] != nil }.count == (doc.layers.count > 1 ? 2 : 1))
        // An older manifest (no `advanced`) loads with the defaults.
        var old = v
        old["layers"] = layers.map { l -> [String: Any] in
            var l = l
            l["advanced"] = nil
            return l
        }
        #expect(try RoundtripTests.docM(old).layers.allSatisfy { $0.advanced.isDefault })
    }

    @Test func videoLayerFramesSurviveRoundtrip() throws {
        var doc = Document(name: "Vid", size: PixelSize(width: 8, height: 6), mode: .rgb, depth: .u8)
        doc.timeline = Timeline(duration: 3, fps: 24)
        let fmt = doc.pixelFormat
        var l = Layer.raster("Clip", format: fmt)
        var frames: [Surface] = []
        for i in 0 ..< 3 {
            var s = Surface(format: fmt)
            let v = Float(i) / 2
            s.fill(PixelRect(x0: 0, y0: 0, x1: 8, y1: 6), with: fmt.components(fromRGBA: SIMD4(v, 0, 1 - v, 1)))
            frames.append(s)
        }
        var vd = VideoData(frames: frames, fps: 24)
        vd.originalFrames = vd.frames
        vd.source = .file(path: "/tmp/seq")
        vd.showAltered = false
        l.video = vd
        doc.layers.append(l)

        let back = try load(try save(doc))
        let v = try #require(back.layers.last?.video, "video survived")
        #expect(v.frames.count == 3)
        #expect(v.originalFrames?.count == 3)
        #expect(v.originalFrames?[2].rgba(x: 1, y: 1) == v.frames[2].rgba(x: 1, y: 1))
        #expect(v.fps == 24)
        #expect(!v.showAltered)
        #expect(v.source == .file(path: "/tmp/seq"))
        #expect(back.timeline?.duration == 3)
        // A middle frame's pixel survived.
        let px = v.frames[2].rgba(x: 1, y: 1)
        #expect(px.x > 0.9 && px.z < 0.1, "frame 2 is reddish: \(px)")
    }

    /// photocraft #1101: JSON can't hold NaN or the infinities, so such a document would save
    /// "successfully" and never open again. The save is refused instead, naming the value; finite
    /// documents are unaffected.
    @Test func aNonFiniteFloatIsRefusedAtSaveRatherThanBreakingEveryLaterLoad() throws {
        let base = richDoc(.rgb, .u8)
        let cases: [(String, (inout Document) -> Void)] = [
            ("exposure", { d in d.insertAbove(nil, Layer(name: "adj", content: .adjustment(.exposure(.init(exposure: .nan, offset: 0, gamma: 1))))) }),
            ("gamma", { d in d.insertAbove(nil, Layer(name: "adj", content: .adjustment(.exposure(.init(exposure: 0, offset: 0, gamma: -.infinity))))) }),
            ("resolution_dpi", { d in d.resolutionDpi = .infinity }),
        ]
        for (field, mutate) in cases {
            var doc = base
            mutate(&doc)
            do throws(FormatError) {
                _ = try PcraftFormat.save(doc)
                Issue.record("\(field): saved")
            } catch {
                guard case .nonFinite = error else {
                    Issue.record("\(field): \(error)")
                    continue
                }
                #expect(error.description.contains(field) && error.description.contains("NaN or infinite"), "\(field): \(error)")
            }
            // The incremental writer shares the check, for autosave and directory bundles.
            #expect { _ = try PcraftWriter().saveZip(doc) } throws: { e in
                if case FormatError.nonFinite = e { return true }
                return false
            }
        }
        var doc = base
        doc.insertAbove(nil, Layer(name: "adj", content: .adjustment(.exposure(.init(exposure: 0.5, offset: 0, gamma: 1)))))
        #expect(try load(try save(doc)) == doc)
    }
}
