// Port of photocraft-engine (crates/engine/src/file_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// File-menu commands driven through `s.execute` as the Rust tests are; files are written to a
// temporary folder, PSDs also into the Photoshop oracle's folder. `photocraft_compose::render`
// is the session's `EngineRenderer`, `photocraft_io::import` is `EngineIO.importFile`.
//
// Not ported: `camera_raw_opens_as_16_bit_with_notes` (needs photocraft-raw's DNG test generator),
// `injected_import_failure_does_not_open_a_document` / `injected_save_failure_…` (photocraft's
// allocation-failure injection has no Swift counterpart), `save_a_copy_writes_the_targa_bits_asked_for`
// (the Targa bit depth and the refusal of bad `tgaBits` are tested),
// `guide_layouts` (GuideLayoutTests covers it).

import Foundation
import PCAlgo
import PCDocument
@testable import PCEngine
import PCFoundation
import PCPlatform
import Testing

fileprivate func session(_ w: Int, _ h: Int, _ depth: Int) throws -> Session {
    let s = Session()
    try s.execute("file.new", ["width": .int(w), "height": .int(h), "depth": .int(depth)])
    return s
}

fileprivate func doc(_ s: Session) throws -> Document { try #require(s.active).doc }

fileprivate func activeLayer(_ s: Session) throws -> Layer {
    let d = try #require(s.active)
    return try #require(d.activeLayer.flatMap { d.doc.layer($0) })
}

/// Writes a solid-colour PNG of `w × h` and returns its path.
fileprivate func png(_ dir: URL, _ name: String, _ w: Int, _ h: Int, _ color: String) throws -> String {
    let s = Session()
    try s.execute("file.new", ["width": .int(w), "height": .int(h), "background": .string(color)])
    let path = dir.appendingPathComponent(name).path
    try FileCommands.saveDoc(s, try doc(s), path)
    return path
}

fileprivate func composite(_ s: Session, _ x: Int32, _ y: Int32) throws -> SIMD4<Float> {
    try s.services.renderer.pixel(try doc(s), x: x, y: y)
}

fileprivate func importDoc(_ name: String, _ path: String) throws -> Document {
    let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    return try EngineIO.importFile(name: name, bytes: bytes, services: EngineServices()).document
}

fileprivate func importBytes(_ name: String, _ bytes: [UInt8]) throws -> Document {
    try EngineIO.importFile(name: name, bytes: bytes, services: EngineServices()).document
}

fileprivate func strings(_ v: JSONValue?) -> [String] { v?.arrayValue?.compactMap(\.stringValue) ?? [] }

fileprivate func fileCount(_ dir: URL) -> Int { (try? FileManager.default.contentsOfDirectory(atPath: dir.path).count) ?? -1 }

/// Whether a PSD has Photoshop's thumbnail image resource (1036).
fileprivate func hasThumbnail(_ path: String) throws -> Bool {
    let b = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    func u32(_ i: Int) -> Int { i + 4 <= b.count ? Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) : 0 }
    var at = 26
    at += 4 + u32(at)
    let end = at + 4 + u32(at)
    at += 4
    while at + 12 <= end {
        let id = Int(b[at + 4]) << 8 | Int(b[at + 5])
        var p = at + 6
        let nameLen = Int(b[p])
        p += (nameLen + 2) & ~1
        let size = u32(p)
        if id == 1036 { return true }
        at = p + 4 + ((size + 1) & ~1)
    }
    return false
}

let multilingualXMP = #"""
<x:xmpmeta xmlns:x="adobe:ns:meta/">
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
<rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"
 xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:xmpRights="http://ns.adobe.com/xap/1.0/rights/"
 xmp:CreatorTool="Other App" xmpRights:Marked="True" xmpRights:WebStatement="https://example.com/license">
<dc:title><rdf:Alt><rdf:li xml:lang="x-default">Sun</rdf:li><rdf:li xml:lang="fr">Soleil</rdf:li><rdf:li xml:lang="ar">الشمس</rdf:li></rdf:Alt></dc:title>
<dc:description><rdf:Alt><rdf:li xml:lang="x-default">Sunrise</rdf:li><rdf:li xml:lang="fr">Lever du soleil</rdf:li></rdf:Alt></dc:description>
<dc:rights><rdf:Alt><rdf:li xml:lang="x-default">All rights reserved</rdf:li><rdf:li xml:lang="fr">Tous droits réservés</rdf:li></rdf:Alt></dc:rights>
<dc:subject><rdf:Bag><rdf:li>sky</rdf:li></rdf:Bag></dc:subject>
</rdf:Description></rdf:RDF></x:xmpmeta>
"""#

fileprivate func inner(_ xmp: String, _ prop: String) -> [UInt8]? {
    let x = Array(xmp.utf8)
    return FileCommands.findElement(x, prop).map { Array(x[$0.2]) }
}

fileprivate func expectTranslationsKept(_ xmp: String) {
    for prop in ["dc:title", "dc:description", "dc:rights"] {
        #expect(inner(xmp, prop) != nil && inner(xmp, prop) == inner(multilingualXMP, prop), "\(prop)")
        #expect(xmp.components(separatedBy: "<\(prop)>").count - 1 == 1)
    }
    #expect(xmp.contains("xmp:CreatorTool=\"Other App\""))
    #expect(xmp.contains("xmpRights:Marked=\"True\""))
    #expect(xmp.contains("xmpRights:WebStatement=\"https://example.com/license\""))
}

fileprivate func cameraEXIF() -> [UInt8] {
    Exif.build(Exif.CameraInfo(make: "SONY", model: "ILCE-7RM5", lens: "24-70mm F2.8", exposureTime: 1.0 / 250, fNumber: 8, iso: 400, focalLength: 33.1,
                               focalLength35mm: 50, dateTaken: "2024:02:17 12:40:19"))
}

fileprivate func colorOverlay() -> Effect { .colorOverlay(Effect.ColorOverlay(common: FxCommon(.normal, 1), color: .rgb(0, 1, 0))) }

@Suite struct FileCommandsTests {
    @Test func closeAllAndCloseOthers() throws {
        let s = try session(8, 8, 8)
        try s.execute("file.new", ["width": 9, "height": 9])
        try s.execute("file.new", ["width": 10, "height": 10])
        _ = s.setActive(1)
        #expect(try s.execute("file.closeOthers")["closed"] == 2)
        #expect(s.documents.count == 1)
        #expect(try doc(s).size.width == 9)
        #expect(s.activeIndex == 0)
        #expect(throws: (any Error).self) { try s.execute("file.closeOthers", ["document": 5]) }
        try s.execute("file.new")
        #expect(try s.execute("file.closeAll")["closed"] == 2)
        #expect(s.documents.isEmpty)
        #expect(!s.isEnabled("file.closeAll"))
    }

    @Test func revertReloadsAsOneUndoableStep() throws {
        let dir = try ioDir("revert")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try png(dir, "a.png", 16, 12, "#ff0000")
        let s = Session()
        #expect(!s.isEnabled("file.revert"))
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        _ = try FileCommands.openBytesAs(s, name: path, bytes: bytes, as: nil, path: path)
        let id = try doc(s).id
        #expect(s.isEnabled("file.revert"))
        try s.execute("layer.new.layer")
        try s.execute("edit.fill", ["color": "#0000ff"])
        #expect(try #require(s.active).isDirty)
        try s.execute("file.revert")
        #expect(try doc(s).layers.count == 1)
        #expect(try doc(s).id == id, "identity kept")
        #expect(try !#require(s.active).isDirty)
        #expect(try composite(s, 3, 3).x > 0.99)
        // Revert is a history state: undo brings the edits back.
        #expect(s.undo())
        #expect(try doc(s).layers.count == 2)
        // An unsaved document cannot revert.
        try s.execute("file.new")
        #expect(throws: (any Error).self) { try s.execute("file.revert") }
    }

    @Test func saveACopyKeepsPathAndDirtyState() throws {
        let dir = try ioDir("copy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try session(20, 10, 16)
        try s.execute("layer.new.layer")
        let rev = try #require(s.active).revision
        let out = dir.appendingPathComponent("copy.psd").path
        try s.execute("file.saveACopy", ["path": .string(out)])
        dropForOracle(URL(fileURLWithPath: out), as: "file_cmds-save_a_copy.psd")
        #expect(try Data(contentsOf: URL(fileURLWithPath: out)).count > 0)
        #expect(try #require(s.active).path == nil)
        #expect(try #require(s.active).revision == rev)
        #expect(try #require(s.active).isDirty)
        let back = try importDoc("copy.psd", out)
        #expect(back.layers.count == 2)
        #expect(back.depth == .u16)
        // Flattened copy.
        let flat = dir.appendingPathComponent("flat.psd").path
        try s.execute("file.saveACopy", ["path": .string(flat), "layers": false])
        dropForOracle(URL(fileURLWithPath: flat), as: "file_cmds-save_a_copy_flat.psd")
        #expect(try importDoc("flat.psd", flat).layers.count == 1)
        #expect(throws: (any Error).self) { try s.execute("file.saveACopy") }
    }

    /// `tgaBits` picks the Targa's bits per pixel (byte 16 of the header); unset, a document with
    /// an alpha channel is written as 32-bit, with the channel as the alpha.
    @Test func saveACopyWritesTheTargaBitsAskedFor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tga-bits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = Session()
        try s.execute("file.new", ["width": 20, "height": 10])
        try s.execute("select.all")
        try s.execute("select.saveSelection")
        let cases: [(JSONValue, UInt8)] = [(.object([:]), 32), (["tgaBits": 24], 24), (["tgaBits": 32], 32), (["tgaBits": nil], 32)]
        for (params, bpp) in cases {
            let out = dir.appendingPathComponent("a.tga").path
            try s.execute("file.saveACopy", params.setting("path", .string(out)))
            let bytes = try Data(contentsOf: URL(fileURLWithPath: out))
            #expect(bytes.count > 16 && bytes[16] == bpp, "\(params)")
        }
    }

    /// A `tgaBits` other than 24 or 32 is a bad parameter, reported before anything is written.
    @Test func badTargaBitsAreRefusedBeforeWriting() throws {
        let dir = try ioDir("tga-bad")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try session(8, 8, 8)
        let bads: [JSONValue] = [16, 0, -32, 32.5, "32", true, [32]]
        for bad in bads {
            let out = dir.appendingPathComponent("a.tga").path
            let e1 = #expect(throws: EngineError.self) { try s.execute("file.saveACopy", ["path": .string(out), "tgaBits": bad]) }
            if case .badParams? = e1 {} else { Issue.record("\(bad.serialized()): \(String(describing: e1))") }
            #expect(!FileManager.default.fileExists(atPath: out), "\(bad.serialized()): nothing written")
            let e2 = #expect(throws: EngineError.self) { try s.execute("file.export.layersToFiles", ["dir": .string(dir.path), "format": "tga", "tgaBits": bad]) }
            if case .badParams? = e2 {} else { Issue.record("\(bad.serialized()): \(String(describing: e2))") }
            #expect(fileCount(dir) == 0, "\(bad.serialized()): no layer written")
        }
    }

    /// Preferences › File Handling › Image Previews decides whether a PSD gets Photoshop's
    /// thumbnail resource (1036): Always and Ask When Saving write it, Never doesn't.
    @Test func imagePreviewsPreferenceControlsThePSDThumbnail() throws {
        let dir = try ioDir("previews")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try session(300, 200, 16)
        for (ask, expect) in [("always", true), ("never", false), ("ask", true)] {
            try s.execute("prefs.set", ["path": "fileHandling.imagePreviews", "value": .string(ask)])
            let out = dir.appendingPathComponent("\(ask).psd").path
            try s.execute("file.saveACopy", ["path": .string(out)])
            dropForOracle(URL(fileURLWithPath: out), as: "file_cmds-image_previews_\(ask).psd")
            #expect(try hasThumbnail(out) == expect, "\(ask)")
            let png = dir.appendingPathComponent("\(ask).png").path
            try s.execute("file.saveACopy", ["path": .string(png)])
        }
    }

    @Test func openAsForcesTheDecoder() throws {
        let dir = try ioDir("openas")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try png(dir, "a.png", 6, 5, "#00ff00")
        let renamed = dir.appendingPathComponent("mystery.bin").path
        try FileManager.default.copyItem(atPath: path, toPath: renamed)
        let s = Session()
        try s.execute("file.openAs", ["path": .string(renamed), "as": "png"])
        #expect(try doc(s).size.width == 6)
        #expect(try doc(s).name == "mystery.bin")
        #expect(s.active?.path == renamed)
        #expect(throws: (any Error).self) { try s.execute("file.openAs", ["path": .string(dir.appendingPathComponent("missing.png").path)]) }
    }

    @Test func placeEmbeddedCentresFitsAndEmbeds() throws {
        let dir = try ioDir("place")
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = try png(dir, "big.png", 200, 100, "#ff0000")
        let small = try png(dir, "small.png", 10, 10, "#0000ff")
        for depth in [8, 16, 32] {
            let s = try session(100, 100, depth)
            let r = try s.execute("file.placeEmbedded", ["path": .string(big)])
            #expect(abs((r["scale"]?.doubleValue ?? 0) - 50) < 1e-9)
            let l = try activeLayer(s)
            #expect(l.name == "big")
            guard case .smart(let so) = l.content else { Issue.record("smart object expected"); continue }
            guard case .embedded(let fileName, let bytes) = so.source else { Issue.record("embedded source expected"); continue }
            #expect(fileName == "big.png" && !bytes.isEmpty)
            #expect(so.transform.a == 0.5)
            // Fitted to the canvas width, centred vertically: rows 25..75 red.
            #expect(try composite(s, 50, 50).x > 0.99 && composite(s, 50, 50).z < 0.01, "depth \(depth)")
            #expect(try composite(s, 50, 10).y > 0.99, "white background above")
            // Small images keep their size, centred.
            try s.execute("file.placeLinked", ["path": .string(small)])
            #expect(try composite(s, 50, 50).z > 0.99)
            #expect(try composite(s, 40, 40).z < 0.01)
            let linked = try activeLayer(s)
            guard case .smart(let lso) = linked.content, case .linked(let lpath) = lso.source else { Issue.record("linked smart object expected"); continue }
            #expect(lpath == small)
            // One step each.
            #expect(s.undo() && s.undo())
            #expect(try doc(s).layers.count == 1)
        }
    }

    /// Preferences ▸ General ▸ Always Create Smart Objects When Placing: unchecked, an embedded
    /// place lands as a plain pixel layer; a linked place is always a smart object and
    /// `"smartObject"` wins.
    @Test func alwaysCreateSmartObjectsPreferencePlacesAPixelLayer() throws {
        let dir = try ioDir("place-smart-pref")
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = try png(dir, "big.png", 200, 100, "#ff0000")
        let s = try session(100, 100, 8)
        try s.execute("prefs.set", ["path": "general.alwaysCreateSmartObjectsWhenPlacing", "value": false])
        let r = try s.execute("file.placeEmbedded", ["path": .string(big)])
        #expect(r["smartObject"] == false)
        guard case .raster = try activeLayer(s).content else { Issue.record("a pixel layer"); return }
        // Fitted to the canvas width, centred vertically, exactly like the smart-object place.
        #expect(try composite(s, 50, 50).x > 0.99 && composite(s, 50, 50).z < 0.01)
        #expect(try composite(s, 50, 10).y > 0.99, "white background above")
        // An explicit "smartObject": true overrides, and Place Linked with the preference off still
        // creates a linked smart object.
        #expect(try s.execute("file.placeEmbedded", ["path": .string(big), "smartObject": true])["smartObject"] == true)
        #expect(try s.execute("file.placeLinked", ["path": .string(big)])["smartObject"] == true)
    }

    /// Preferences ▸ General ▸ Resize Image During Place: off, a larger image keeps its natural
    /// size instead of being fitted to the canvas; an explicit `"fit"` still wins.
    @Test func resizeImageDuringPlacePreferenceControlsTheFit() throws {
        let dir = try ioDir("place-fit-pref")
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = try png(dir, "big.png", 200, 100, "#ff0000")
        let s = try session(100, 100, 8)
        try s.execute("prefs.set", ["path": "general.resizeImageDuringPlace", "value": false])
        let r = try s.execute("file.placeEmbedded", ["path": .string(big)])
        #expect(abs((r["scale"]?.doubleValue ?? 0) - 100) < 1e-9, "natural size: \(r.serialized())")
        #expect((r["bounds"]?.arrayValue?[2].doubleValue ?? 0) > 100, "wider than the canvas")
        let fitted = try s.execute("file.placeEmbedded", ["path": .string(big), "fit": true])
        #expect(abs((fitted["scale"]?.doubleValue ?? 0) - 50) < 1e-9, "fitted on request")
    }

    /// A 40×20 JPEG (left half red, right half blue) tagged EXIF Orientation = 6: shown upright it
    /// is 20×40, red on top.
    func rotatedJPEG(_ dir: URL) throws -> String {
        let fmt = PixelFormat(mode: .rgb, sample: .u8, alpha: true)
        var rgba: [SIMD4<Float>] = []
        for _ in 0 ..< 20 {
            for x in 0 ..< 40 { rgba.append(x < 20 ? SIMD4(230, 20, 20, 255) / 255 : SIMD4(20, 20, 230, 255) / 255) }
        }
        var surface = Surface(format: fmt)
        let rect = PixelRect(x0: 0, y0: 0, x1: 40, y1: 20)
        surface.writeRegion(rect, PixelCodec.fromRGBA(fmt, rgba: rgba))
        let jpeg = [UInt8](try ImageCodecs.encode(surface, rect: rect, as: .jpeg, profile: nil, options: EncodeOptions()))
        let seg: [UInt8] = Array("Exif".utf8) + [0, 0, 0x49, 0x49, 0x2A, 0, 0x08, 0, 0, 0, 0x01, 0, 0x12, 0x01, 0x03, 0, 0x01, 0, 0, 0, 0x06, 0, 0, 0, 0, 0, 0, 0]
        let len = UInt16(seg.count + 2)
        let file: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1, UInt8(len >> 8), UInt8(len & 0xFF)] + seg + jpeg[2...]
        let path = dir.appendingPathComponent("IMG_0001.jpg").path
        try Data(file).write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test func rotatedJPEGsOpenAndPlaceUpright() throws {
        let dir = try ioDir("orientation")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try rotatedJPEG(dir)
        let s = Session()
        try s.execute("file.openAs", ["path": .string(path), "as": "jpg"])
        #expect(try (doc(s).size.width, doc(s).size.height) == (20, 40))
        #expect(try composite(s, 10, 5).x > 0.8 && composite(s, 10, 35).z > 0.8, "red on top, blue below")
        // Placed as a smart object: upright too.
        let t = try session(100, 100, 8)
        let r = try t.execute("file.placeEmbedded", ["path": .string(path)])
        #expect(r["bounds"] == [40.0, 30.0, 60.0, 70.0])
        #expect(try composite(t, 50, 35).x > 0.8 && composite(t, 50, 65).z > 0.8)
    }

    @Test func fileInfoRoundTripsThroughXMPAndPSD() throws {
        let s = try session(8, 8, 8)
        let empty = try s.execute("file.fileInfo")
        #expect(empty["title"] == "")
        #expect(!s.undo(), "reading is not a history step")
        try s.execute("file.fileInfo", ["title": "Starry <Night>", "author": "V. van Gogh", "keywords": ["stars", "night"], "copyright": "Public domain",
                                        "copyrightStatus": "publicDomain", "description": "Oil & canvas"])
        let info = try s.execute("file.fileInfo")
        #expect(info["title"] == "Starry <Night>")
        #expect(info["author"] == "V. van Gogh")
        #expect(info["keywords"] == ["stars", "night"])
        #expect(info["description"] == "Oil & canvas")
        #expect(info["copyrightStatus"] == "publicDomain")
        // Editing one field keeps the others and replaces, not duplicates.
        try s.execute("file.fileInfo", ["title": "The Starry Night"])
        let xmp = try #require(try doc(s).metadata.xmp)
        #expect(xmp.components(separatedBy: "<dc:title>").count - 1 == 1)
        #expect(FileCommands.readFileInfo(xmp)["author"] == "V. van Gogh")
        // PSD round trip.
        let (bytes, _) = try FileCommands.encode(s, try doc(s), "x.psd")
        let back = try importBytes("x.psd", bytes)
        let read = FileCommands.readFileInfo(back.metadata.xmp)
        #expect(read["title"] == "The Starry Night")
        #expect(read["keywords"] == ["stars", "night"])
        // Foreign XMP (attribute form, other namespaces) keeps its other properties.
        let foreign = #"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:CreatorTool="Other App" photoshop:AuthorsPosition="Painter"/></rdf:RDF></x:xmpmeta>"#
        #expect(FileCommands.readFileInfo(foreign)["authorTitle"] == "Painter")
        let out = FileCommands.writeFileInfo(foreign, ["authorTitle": "Artist"])
        #expect(out.contains("xmp:CreatorTool=\"Other App\""))
        #expect(FileCommands.readFileInfo(out)["authorTitle"] == "Artist")
    }

    @Test func fileInfoReadsCameraDataFromJPEGAndPSDEXIF() throws {
        let s = try session(8, 8, 8)
        #expect(try s.execute("file.fileInfo")["camera"] == .object([:]))
        try s.edit("exif") { doc, _ in doc.metadata.exif = cameraEXIF() }
        let want: JSONValue = [
            "make": "SONY", "model": "ILCE-7RM5", "dateTaken": "2024-02-17 12:40:19", "exposure": "1/250 s", "fNumber": "f/8",
            "iso": "ISO 400", "focalLength": "33.1 mm", "focalLength35mm": "50 mm", "lens": "24-70mm F2.8",
        ]
        for name in ["x.jpg", "x.psd"] {
            let (bytes, _) = try FileCommands.encode(s, try doc(s), name)
            let back = try importBytes(name, bytes)
            let t = Session()
            t.addDocument(back)
            #expect(try t.execute("file.fileInfo")["camera"] == want, "\(name)")
            // Editing the description fields leaves the read-only camera data alone.
            let edited = try t.execute("file.fileInfo", ["title": "Pier", "camera": ["make": "ignored"]])
            #expect(edited["camera"] == want, "\(name)")
        }
    }

    @Test func cameraDataFormatsLikePhotoshopAndFallsBackToXMP() {
        func info(_ t: Double?, _ n: Double?, _ f: Double?) -> JSONValue {
            FileCommands.cameraData(exif: Exif.build(Exif.CameraInfo(exposureTime: t, fNumber: n, focalLength: f)), xmp: nil)
        }
        #expect(info(2, 2.8, 35) == ["exposure": "2 s", "fNumber": "f/2.8", "focalLength": "35 mm"])
        #expect(info(0.5, 5.6, nil) == ["exposure": "1/2 s", "fNumber": "f/5.6"])
        #expect(info(0.4, nil, nil) == ["exposure": "0.4 s"])
        #expect(info(1.0 / 2000, nil, nil) == ["exposure": "1/2000 s"])
        #expect(info(0, 0, 0) == .object([:]))
        // No EXIF block (a raw import, XMP-only files): Photoshop's exif:/tiff:/aux: properties.
        let xmp = #"""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:tiff="http://ns.adobe.com/tiff/1.0/" xmlns:exif="http://ns.adobe.com/exif/1.0/" xmlns:aux="http://ns.adobe.com/exif/1.0/aux/"
         tiff:Make="SONY" tiff:Model="ILCE-7RM5" exif:ExposureTime="1/250" exif:FNumber="8/1" exif:FocalLength="331/10"
         exif:FocalLengthIn35mmFilm="50" exif:DateTimeOriginal="2024-02-17T12:40:19.00+01:00" aux:Lens="Lens &amp; Co">
        <exif:ISOSpeedRatings><rdf:Seq><rdf:li>400</rdf:li></rdf:Seq></exif:ISOSpeedRatings>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """#
        let want: JSONValue = [
            "make": "SONY", "model": "ILCE-7RM5", "dateTaken": "2024-02-17 12:40:19", "exposure": "1/250 s", "fNumber": "f/8",
            "iso": "ISO 400", "focalLength": "33.1 mm", "focalLength35mm": "50 mm", "lens": "Lens & Co",
        ]
        #expect(FileCommands.cameraData(exif: nil, xmp: xmp) == want)
        // EXIF wins; XMP only fills what EXIF lacks.
        let both = FileCommands.cameraData(exif: Exif.build(Exif.CameraInfo(make: "Other")), xmp: xmp)
        #expect(both["make"] == "Other")
        #expect(both["exposure"] == "1/250 s")
        // Garbage in either block reads as no data, never a crash.
        #expect(FileCommands.cameraData(exif: [0x49, 0x49, 0x2A, 0, 0xFF, 0xFF, 0xFF, 0xFF],
                                        xmp: "<exif:FNumber>0/0</exif:FNumber> exif:ExposureTime=\"-1/0\"") == .object([:]))
    }

    @Test func fileInfoKeepsTranslationsWhenEditingKeywords() {
        let partial: JSONValue = ["keywords": ["sky", "sunrise"]]
        let dialog = FileCommands.readFileInfo(multilingualXMP).setting("keywords", "sky; sunrise")
        for params in [partial, dialog] {
            let out = FileCommands.writeFileInfo(multilingualXMP, params)
            expectTranslationsKept(out)
            #expect(FileCommands.readFileInfo(out)["keywords"] == ["sky", "sunrise"])
        }
        let unchanged = FileCommands.readFileInfo(multilingualXMP)
        #expect(FileCommands.writeFileInfo(multilingualXMP, unchanged) == multilingualXMP)
        #expect(FileCommands.writeFileInfo(multilingualXMP, .object([:])) == multilingualXMP)
    }

    @Test func fileInfoClearsOnlyTheRequestedField() {
        let out = FileCommands.writeFileInfo(multilingualXMP, ["keywords": .array([])])
        expectTranslationsKept(out)
        #expect(FileCommands.findElement(Array(out.utf8), "dc:subject") == nil)
        #expect(FileCommands.readFileInfo(out)["keywords"] == .array([]))
    }

    @Test func fileInfoTranslationsSurviveUndoAndPSDRoundTrip() throws {
        for depth in [8, 16, 32] {
            let s = try session(8, 8, depth)
            try s.edit("Set metadata") { doc, _ in doc.metadata.xmp = multilingualXMP }
            try s.execute("file.fileInfo", ["keywords": ["sunrise"]])
            let edited = try #require(try doc(s).metadata.xmp)
            expectTranslationsKept(edited)
            #expect(s.undo())
            #expect(try doc(s).metadata.xmp == multilingualXMP)
            #expect(s.redo())
            #expect(try doc(s).metadata.xmp == edited)
            let (bytes, _) = try FileCommands.encode(s, try doc(s), "x.psd")
            let back = try importBytes("x.psd", bytes)
            expectTranslationsKept(back.metadata.xmp ?? "")
            #expect(FileCommands.readFileInfo(back.metadata.xmp)["keywords"] == ["sunrise"])
        }
    }

    @Test func fitImageAndConditionalModeChange() throws {
        let s = try session(400, 200, 8)
        try s.execute("file.automate.fitImage", ["width": 100, "height": 100])
        #expect(try (doc(s).size.width, doc(s).size.height) == (100, 50))
        #expect(try s.execute("file.automate.fitImage", ["width": 1000, "height": 1000, "dontEnlarge": true])["changed"] == false)
        try s.execute("file.automate.fitImage", ["width": 1000, "height": 1000])
        #expect(try doc(s).size.width == 1000)
        #expect(try s.execute("file.automate.conditionalModeChange", ["from": ["cmyk"], "to": "grayscale"])["changed"] == false)
        try s.execute("file.automate.conditionalModeChange", ["from": ["rgb", "lab"], "to": "grayscale"])
        #expect(try doc(s).mode == .grayscale)
        try s.execute("file.automate.conditionalModeChange", ["to": "rgb"])
        #expect(try doc(s).mode == .rgb)
        #expect(throws: (any Error).self) { try s.execute("file.automate.conditionalModeChange", ["to": "duotone"]) }
    }

    @Test func conditionalModeChangeCannotRunAModeChangeTheGateDenies() throws {
        let s = try session(4, 4, 8)
        s.authorize = { id, _ in
            if id.hasPrefix("image.mode.") { throw EngineError.other("automation command `\(id)` is disabled") }
        }
        do {
            try s.execute("file.automate.conditionalModeChange", ["to": "grayscale"])
            Issue.record("the gate must refuse the nested mode change")
        } catch {
            #expect("\(error)".contains("image.mode.grayscale"), "\(error)")
        }
        #expect(try doc(s).mode == .rgb, "the refused nested step leaves the document alone")
        // Commands that compose only allowed steps still run.
        try s.execute("file.automate.fitImage", ["width": 2, "height": 2])
        #expect(try doc(s).size.width == 2)
    }

    @Test func flattenAllLayerEffectsAndMasks() throws {
        for depth in [8, 16, 32] {
            let s = try session(40, 40, depth)
            try s.execute("layer.new.layer")
            try s.execute("select.rect", ["x": 10, "y": 10, "width": 20, "height": 20])
            try s.execute("edit.fill", ["color": "#ff0000"])
            try s.execute("select.deselect")
            let id = try #require(s.active?.activeLayer)
            try s.edit("fx") { doc, _ in
                _ = doc.updateLayer(id) { l in
                    l.effects.enabled = true
                    l.effects.items.append(colorOverlay())
                }
            }
            let before = try composite(s, 15, 15)
            #expect(before.y > 0.99, "overlay renders green")
            #expect(try s.execute("file.scripts.flattenAllLayerEffects")["flattened"] == 1)
            let l = try #require(try doc(s).layer(id))
            guard case .raster = l.content else { Issue.record("a pixel layer"); continue }
            #expect(l.effects.items.isEmpty)
            let after = try composite(s, 15, 15)
            #expect(abs(after.y - before.y) < 0.01 && after.x < 0.01, "\(after)")
            // Masks: hide the left half, flatten, mask gone, pixels gone.
            try s.execute("select.rect", ["x": 0, "y": 0, "width": 20, "height": 40])
            try s.execute("select.inverse")
            try s.execute("layer.layerMask.revealSelection")
            try s.execute("select.deselect")
            #expect(try composite(s, 15, 15).y > 0.99 && composite(s, 15, 15).x > 0.99, "white shows through the mask")
            #expect(try s.execute("file.scripts.flattenAllMasks")["flattened"] == 1)
            let m = try #require(try doc(s).layer(id))
            #expect(m.mask == nil)
            #expect((m.surface?.contentBounds.x0 ?? 0) >= 20)
            #expect(try composite(s, 25, 15).y > 0.99 && composite(s, 25, 15).x < 0.01)
            // Each script is a single history step.
            #expect(s.undo())
            #expect(try doc(s).layer(id)?.mask != nil)
        }
    }

    /// Flatten All Layer Effects must bake the effect visuals without destroying the layer's
    /// masks: an enabled raster mask and a vector mask on one layer, a disabled raster mask on
    /// another (#3804). The command is a visual no-op; the masks survive, including a `.pcraft`
    /// round trip.
    @Test func flattenAllLayerEffectsKeepsMasks() throws {
        let dir = try ioDir("flatten-effects-masks")
        defer { try? FileManager.default.removeItem(at: dir) }
        for depth in [8, 16, 32] {
            let s = try session(40, 40, depth)
            // Layer 1: a red square with a green colour overlay, an enabled raster mask revealing
            // x < 20 and a vector mask revealing x 15..30.
            try s.execute("layer.new.layer")
            try s.execute("select.rect", ["x": 10, "y": 10, "width": 20, "height": 20])
            try s.execute("edit.fill", ["color": "#ff0000"])
            try s.execute("select.deselect")
            let id1 = try #require(s.active?.activeLayer)
            try s.edit("fx") { doc, _ in
                _ = doc.updateLayer(id1) { l in
                    l.effects.enabled = true
                    l.effects.items.append(colorOverlay())
                    l.vectorMask = VectorMask(path: VectorPath([Subpath.polygon([(15, 15), (30, 15), (30, 30), (15, 30)])]))
                }
            }
            try s.execute("select.rect", ["x": 0, "y": 0, "width": 20, "height": 40])
            try s.execute("layer.layerMask.revealSelection")
            try s.execute("select.deselect")
            // Layer 2: a red square at the bottom-right with the same overlay and a disabled mask.
            try s.execute("layer.new.layer")
            try s.execute("select.rect", ["x": 30, "y": 30, "width": 8, "height": 8])
            try s.execute("edit.fill", ["color": "#ff0000"])
            try s.execute("select.deselect")
            let id2 = try #require(s.active?.activeLayer)
            try s.edit("fx") { doc, _ in
                _ = doc.updateLayer(id2) { l in
                    l.effects.enabled = true
                    l.effects.items.append(colorOverlay())
                }
            }
            try s.execute("select.rect", ["x": 34, "y": 34, "width": 2, "height": 2])
            try s.execute("layer.layerMask.revealSelection")
            try s.execute("select.deselect")
            try s.edit("disable") { doc, _ in _ = doc.updateLayer(id2) { l in l.mask?.enabled = false } }
            let m1 = try doc(s).layer(id1)?.mask, v1 = try doc(s).layer(id1)?.vectorMask, m2 = try doc(s).layer(id2)?.mask
            #expect(m1?.enabled == true, "layer 1 raster mask is enabled")
            #expect(v1?.enabled == true, "layer 1 vector mask is enabled")
            #expect(m2?.enabled == false, "layer 2 raster mask is disabled")
            let points: [(Int32, Int32)] = [(17, 15), (22, 15), (12, 15), (34, 34)]
            let before = try points.map { try composite(s, $0.0, $0.1) }
            #expect(before[0].y > 0.99 && before[0].x < 0.01, "overlay renders green: \(before[0])")
            #expect(before[1].x > 0.99 && before[1].y > 0.99, "the raster mask hides: \(before[1])")
            #expect(before[2].x > 0.99 && before[2].y > 0.99, "the vector mask hides: \(before[2])")
            #expect(before[3].y > 0.99, "the disabled mask does not hide")
            #expect(try s.execute("file.scripts.flattenAllLayerEffects")["flattened"] == 2)
            #expect(try doc(s).layer(id1)?.mask == m1, "layer 1 raster mask survives")
            #expect(try doc(s).layer(id1)?.vectorMask == v1, "layer 1 vector mask survives")
            #expect(try doc(s).layer(id2)?.mask == m2, "the disabled mask survives")
            let after = try points.map { try composite(s, $0.0, $0.1) }
            for (a, b) in zip(after, before) {
                #expect((0 ..< 4).allSatisfy { abs(a[$0] - b[$0]) < 0.01 }, "flattening is a visual no-op: \(after) vs \(before) (depth \(depth))")
            }
            // One history step: undo restores the effects, redo re-flattens, and the masks stay.
            #expect(s.undo())
            #expect(try !(doc(s).layer(id1)?.effects.items.isEmpty ?? true))
            #expect(try doc(s).layer(id1)?.mask == m1)
            #expect(s.redo())
            #expect(try doc(s).layer(id1)?.mask == m1)
            #expect(try doc(s).layer(id1)?.vectorMask == v1)
            #expect(try doc(s).layer(id2)?.mask == m2)
            // The masks survive a `.pcraft` save and reopen.
            let path = dir.appendingPathComponent("masks-\(depth).pcraft").path
            try FileCommands.saveDoc(s, try doc(s), path)
            let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
            let s2 = Session()
            _ = try FileCommands.openBytesAs(s2, name: "masks.pcraft", bytes: bytes, as: nil, path: nil)
            let layers = try doc(s2).walk().map(\.layer)
            #expect(layers.contains { $0.mask == m1 && $0.vectorMask == v1 }, "the raster and vector masks survive .pcraft")
            #expect(layers.contains { $0.mask == m2 }, "the disabled mask survives .pcraft")
        }
    }

    @Test func layersToFilesWritesEachVisibleLayer() throws {
        let dir = try ioDir("layers")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try session(12, 12, 8)
        try s.execute("layer.new.layer", ["name": "Ink/1"])
        try s.execute("layer.new.layer", ["name": "Hidden"])
        try s.execute("layer.setProps", ["visible": false])
        let r = try s.execute("file.export.layersToFiles", ["dir": .string(dir.path), "prefix": "doc", "format": "png"])
        let files = strings(r["files"])
        #expect(files.count == 2, "\(files)")
        #expect(files.first?.hasSuffix("doc_0000_Ink_1.png") == true, "\(files)")
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        let psds = try s.execute("file.export.layersToFiles", ["dir": .string(dir.path), "visibleOnly": false, "format": "psd"])
        let psdFiles = strings(psds["files"])
        #expect(psdFiles.count == 3)
        for (i, f) in psdFiles.enumerated() { dropForOracle(URL(fileURLWithPath: f), as: "file_cmds-layers_to_files_\(i).psd") }
    }

    @Test func loadFilesIntoStackAndImageProcessorAndBatch() throws {
        let dir = try ioDir("batch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let a = try png(input, "a.png", 40, 20, "#ff0000")
        let b = try png(input, "b.png", 30, 30, "#0000ff")
        try Data("not an image".utf8).write(to: input.appendingPathComponent("notes.txt"))
        let s = Session()
        let r = try s.execute("file.scripts.loadFilesIntoStack", ["paths": .strings([a, b])])
        #expect(r["layers"] == 2)
        #expect(try (doc(s).size.width, doc(s).size.height) == (40, 30))
        #expect(try doc(s).layers.first?.name == "a.png")
        // Image Processor: fit into 20×20 JPEGs.
        let out = dir.appendingPathComponent("jpg").path
        let ip = try s.execute("file.scripts.imageProcessor", ["input": .string(input.path), "output": .string(out), "format": "jpg", "width": 20, "height": 20])
        let files = strings(ip["files"])
        #expect(files.count == 2, "\(ip.serialized())")
        let back = try importDoc("a.jpg", try #require(files.first))
        #expect((back.size.width, back.size.height) == (20, 10))
        // Batch: run an action (invert) over the folder, save PNGs.
        let pngOut = dir.appendingPathComponent("png")
        let br = try s.execute("file.automate.batch", ["steps": [["image.adjustments.invert", .object([:])]], "input": .string(input.path),
                                                       "output": .string(pngOut.path), "format": "png"])
        #expect(strings(br["files"]).count == 2, "\(br.serialized())")
        #expect(br["errors"]?.arrayValue?.isEmpty == true)
        let inv = try importDoc("a.png", pngOut.appendingPathComponent("a.png").path)
        let px = try s.services.renderer.pixel(inv, x: 1, y: 1)
        #expect(px.x < 0.01 && px.y > 0.99 && px.z > 0.99, "red inverted to cyan: \(px)")
        #expect(throws: (any Error).self) {
            try s.execute("file.automate.batch", ["steps": [["no.such.command", .object([:])]], "input": .string(input.path), "output": .string(pngOut.path)])
        }
    }

    /// Load Files into Stack › Create Smart Object: one smart object holding a layer per file.
    @Test func loadFilesIntoStackCreatesASmartObject() throws {
        let dir = try ioDir("stack-smart")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try png(dir, "a.png", 16, 8, "#ff0000")
        let b = try png(dir, "b.png", 16, 8, "#0000ff")
        let s = Session()
        #expect(try s.execute("file.scripts.loadFilesIntoStack", ["paths": .strings([a, b]), "createSmartObject": true])["layers"] == 2)
        let d = try doc(s)
        #expect(d.layers.count == 1)
        guard case .smart(let so) = d.layers[0].content, case .embedded(let name, let bytes) = so.source else { Issue.record("an embedded smart object"); return }
        #expect(name == "a.pcraft")
        let inner = try importBytes(name, bytes)
        #expect(inner.layers.map(\.name) == ["a.png", "b.png"])
        #expect(try composite(s, 3, 3).z > 0.99, "the top file shows")
    }

    @Test func colorLookupTableBakesTheAdjustmentStack() throws {
        let s = try session(8, 8, 8)
        #expect(!s.isEnabled("file.export.colorLookupTables"))
        try s.execute("layer.newAdjustmentLayer.invert")
        let r = try s.execute("file.export.colorLookupTables", ["size": 3])
        let cube = try #require(r["cube"]?.stringValue)
        #expect(cube.contains("LUT_3D_SIZE 3"))
        let rows: [[Float]] = cube.split(separator: "\n").filter { $0.first?.isNumber == true }.map { $0.split(separator: " ").compactMap { Float($0) } }
        #expect(rows.count == 27)
        guard rows.count == 27 else { return }
        // First entry (0,0,0) → white; second (r = 0.5) → 0.5; last (1,1,1) → black.
        #expect(rows[0].allSatisfy { abs($0 - 1) < 1e-3 }, "\(rows[0])")
        #expect(abs(rows[1][0] - 0.5) < 0.01 && abs(rows[1][1] - 1) < 1e-3, "\(rows[1])")
        #expect(abs(rows[2][0]) < 1e-3 && abs(rows[2][2] - 1) < 1e-3, "red fastest")
        #expect(rows[26].allSatisfy { abs($0) < 1e-3 })
        let dir = try ioDir("lut")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("invert.cube").path
        try s.execute("file.export.colorLookupTables", ["path": .string(path), "size": 17])
        #expect(try String(contentsOfFile: path, encoding: .utf8).contains("LUT_3D_SIZE 17"))
    }

    @Test func cubeExportUsesOnlySelectedAdjustmentsInDocumentOrder() throws {
        let s = try session(8, 8, 8)
        let first = try #require(try s.execute("layer.newAdjustmentLayer.invert")["layer"]?.uint64Value)
        let second = try #require(try s.execute("layer.newAdjustmentLayer.invert")["layer"]?.uint64Value)
        let both = try s.execute("file.export.colorLookupTables", ["size": 3])
        let all = try AdjustCommands.LutFile.parseCube(try #require(both["cube"]?.stringValue)).get()
        #expect(both["layerCount"] == 2)
        #expect(all.data[0] < 0.001, "two Invert adjustments produce identity")
        // Selection comes from the Layers panel rather than the active layer alone.
        try s.execute("layer.select", ["layer": .int(first)])
        let selected = try s.execute("file.export.colorLookupTables", ["size": 3, "scope": "selected"])
        let one = try AdjustCommands.LutFile.parseCube(try #require(selected["cube"]?.stringValue)).get()
        #expect(selected["layerCount"] == 1)
        #expect(one.data[0] > 0.999, "one invert maps black to white")
        #expect(all.size == one.size)
        #expect(try s.execute("file.export.colorLookupTables", ["size": 3, "layers": [.int(first)]])["cube"] == selected["cube"])
        // Reversing the caller's ID list must not reverse document stack order.
        let normal = try s.execute("file.export.colorLookupTables", ["size": 3, "layers": [.int(first), .int(second)]])
        let reversed = try s.execute("file.export.colorLookupTables", ["size": 3, "layers": [.int(second), .int(first)]])
        #expect(normal["cube"] == reversed["cube"])
        #expect(normal["cube"] == both["cube"])
        // Additional non-adjustment layers must not affect the LUT export.
        try s.execute("layer.new.layer", ["name": "Raster"])
        #expect(try s.execute("file.export.colorLookupTables", ["size": 3])["cube"] == both["cube"])
    }

    @Test func selectedCubeValidationIsExplicitAndNeverMutatesTheDocument() throws {
        let s = try session(8, 8, 8)
        let a = try #require(try s.execute("layer.newAdjustmentLayer.invert")["layer"]?.uint64Value)
        let raster = try #require(try s.execute("layer.new.layer")["layer"]?.uint64Value)
        let rev = try #require(s.active).revision
        let history = try #require(s.active).history.entries.count
        #expect(try s.execute("file.export.colorLookupTables", ["size": 3, "layers": [.int(a)]])["layerCount"] == 1)
        let cases: [JSONValue] = [
            ["size": 1], ["size": 130], ["size": 1.5], ["size": -3], ["scope": "unknown"], ["scope": 42], ["scope": "selected", "layers": [.int(a)]],
            ["layers": .array([])], ["layers": 42], ["layers": [.int(a), .int(a)]], ["layers": [.int(a), "oops"]], ["layers": [.number(1.8446744073709552e19)]],
            ["layers": [.int(raster)]],
        ]
        for params in cases {
            #expect(throws: (any Error).self, "\(params.serialized())") { try s.execute("file.export.colorLookupTables", params) }
            #expect(s.active?.revision == rev, "\(params.serialized()): export must be read-only")
            #expect(s.active?.history.entries.count == history)
        }
        try s.execute("layer.select", ["layer": .int(raster)])
        #expect(throws: (any Error).self) { try s.execute("file.export.colorLookupTables", ["size": 3, "scope": "selected"]) }
    }

    @Test func exportedSelectedCubeRoundTripsThroughLookupImporter() throws {
        let dir = try ioDir("selected_cube")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try session(8, 8, 8)
        let a = try #require(try s.execute("layer.newAdjustmentLayer.invert")["layer"]?.uint64Value)
        let path = dir.appendingPathComponent("chosen.cube").path
        let r = try s.execute("file.export.colorLookupTables", ["size": 17, "title": "Chosen", "layers": [.int(a)], "path": .string(path)])
        #expect(r["size"] == 17)
        #expect(r["layerCount"] == 1)
        let parsed = try AdjustCommands.LutFile.parseCube(try String(contentsOfFile: path, encoding: .utf8)).get()
        #expect(parsed.size == 17)
        #expect(parsed.data.count == 17 * 17 * 17 * 3)
        #expect(parsed.data.prefix(3).allSatisfy { $0 > 0.999 })
        #expect(parsed.data.suffix(3).allSatisfy { $0 < 0.001 })
        try s.execute("layer.newAdjustmentLayer.colorLookup", ["file": .string(path)])
        #expect(try doc(s).layers.count == 3)
    }

    @Test func onlyLayeredFilesSaveInPlace() {
        for path in ["a.psd", "dir/a.PSB", #"C:\w\a.pcraft"#, "my.dir/a.psd", "a.ora", "dir/A.ORA"] {
            #expect(FileCommands.savesInPlace(path), "\(path)")
        }
        // Flat formats, no extension, a dotted folder with an extensionless file, a dot file.
        for path in ["a.png", "a.jpg", "a.pdn", "a.PDN", "a", "my.psd/a", ".psd", "a.", ""] {
            #expect(!FileCommands.savesInPlace(path), "\(path)")
        }
        #expect(FileCommands.fileExtension("dir/Photo.JPEG") == "jpeg")
        #expect(FileCommands.fileExtension("my.dir/name") == nil)
    }

    @Test func templatesOpenUntitledWithoutTheirPath() throws {
        #expect(FileCommands.isTemplate("dir/card.PSDT") && !FileCommands.isTemplate("card.psd") && !FileCommands.isTemplate("psdt"))
        let dir = try ioDir("template")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("card.psdt").path
        let s = try session(8, 8, 8)
        try Data(try FileCommands.encode(s, try doc(s), "x.psd").0).write(to: URL(fileURLWithPath: path))
        dropForOracle(URL(fileURLWithPath: path), as: "file_cmds-template.psd")
        try s.execute("file.openAs", ["path": .string(path)])
        try s.execute("file.openAs", ["path": .string(path), "as": "psd"])
        let opened = s.documents.dropFirst().map { "\($0.doc.name)|\($0.path ?? "nil")" }
        #expect(opened == ["Untitled-1|nil", "Untitled-2|nil"])
    }

    /// Two inputs with one output name: the first result is kept and the second is an error,
    /// never a silent overwrite listed as written (#422).
    @Test func batchReportsInputsThatShareAnOutputName() throws {
        let dir = try ioDir("collide")
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        _ = try png(input, "a.png", 8, 8, "#ff0000")
        let s = Session()
        try s.execute("file.new", ["width": 8, "height": 8, "background": "#0000ff"])
        try FileCommands.saveDoc(s, try doc(s), input.appendingPathComponent("a.jpg").path)
        _ = try png(input, "B.png", 8, 8, "#00ff00")
        _ = try png(input, "b.tif", 8, 8, "#00ff00")
        let runs: [(String, JSONValue)] = [
            ("file.automate.batch", ["steps": .array([]), "format": "jpg"]), ("file.scripts.imageProcessor", .object([:])),
            ("file.automate.lensCorrection", ["format": "jpg"]),
        ]
        for (cmd, extra) in runs {
            let out = dir.appendingPathComponent(cmd).path
            let r = try s.execute(cmd, extra.setting("input", .string(input.path)).setting("output", .string(out)))
            let files = strings(r["files"]), errors = r["errors"]?.arrayValue ?? []
            // `a.*` and `B.png`/`b.tif` (names that differ only in case) each collide once.
            #expect((files.count, errors.count) == (2, 2), "\(cmd): \(r.serialized())")
            #expect(errors.allSatisfy { $0["error"]?.stringValue?.contains("not written") == true }, "\(r.serialized())")
            #expect(Set(files.map { $0.lowercased() }).count == files.count, "each listed file is distinct")
        }
        // Keeping each file's format, nothing collides.
        let same = try s.execute("file.automate.batch", ["steps": .array([]), "input": .string(input.path), "output": .string(dir.appendingPathComponent("same").path)])
        #expect((strings(same["files"]).count, same["errors"]?.arrayValue?.count ?? -1) == (4, 0), "\(same.serialized())")
        // A droplet over two folders holding the same name.
        let other = dir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        _ = try png(other, "a.png", 8, 8, "#ffffff")
        let droplet = dir.appendingPathComponent("d.pcdroplet").path
        let dv: JSONValue = ["photocraftDroplet": 1, "name": "d", "action": ["steps": .array([])], "options": ["format": "png"]]
        try Data(dv.serialized().utf8).write(to: URL(fileURLWithPath: droplet))
        let out = dir.appendingPathComponent("droplet")
        let r = try s.execute("file.automate.runDroplet", ["droplet": .string(droplet), "input": .strings([input.appendingPathComponent("a.png").path, other.path]),
                                                           "output": .string(out.path)])
        #expect((strings(r["files"]).count, r["errors"]?.arrayValue?.count ?? -1) == (1, 1), "\(r.serialized())")
        let kept = try importDoc("a.png", out.appendingPathComponent("a.png").path)
        let px = try s.services.renderer.pixel(kept, x: 1, y: 1)
        #expect(px.x > 0.99 && px.y < 0.01, "the first input's result is kept: \(px)")
    }

    /// `file.revealInFinder` (the document tab's Reveal, UI-217-6) reveals the clicked document's
    /// saved path — the tab menu passes `document`, not just the active one.
    @Test func revealInFinderRevealsTheDocumentsSavedPath() throws {
        let s = try session(8, 8, 8)
        #expect(s.isEnabled("file.revealInFinder"))
        // A new document has no file yet.
        do {
            try s.execute("file.revealInFinder", ["dryRun": true])
            Issue.record("a new document has no file")
        } catch { #expect("\(error)".contains("no saved file"), "\(error)") }
        let path = "/tmp/pics/a.psd"
        try s.updateActive { $0.path = path }
        let r = try s.execute("file.revealInFinder", ["dryRun": true])
        let (program, args) = LayerMenuCommands.revealCommand(path)
        #expect(r["program"] == .string(program))
        #expect(r["args"] == .strings(args))
        // The tab menu names a background tab: the active document is not the one revealed.
        try s.execute("file.new", ["width": 8, "height": 8, "name": "other"])
        do {
            try s.execute("file.revealInFinder", ["document": 1, "dryRun": true])
            Issue.record("document 1 has no file")
        } catch { #expect("\(error)".contains("no saved file"), "\(error)") }
        let r0 = try s.execute("file.revealInFinder", ["document": 0, "dryRun": true])
        #expect(r0["program"] == .string(program))
        #expect(r0["args"] == .strings(args))
    }

    /// Every id of the ported modules is registered with photocraft's label, menu, shortcut and
    /// params, and is available.
    @Test func idsMatchThePhotocraftCatalog() throws {
        let s = Session()
        let modules = ["file_cmds", "exr_cmds", "migrate_cmds", "automate_cmds", "wia_cmds"]
        // The guide layouts of file_cmds.rs are GuideLayoutCommands'.
        let ids = PhotocraftCatalog.commands.filter { modules.contains($0.module) && !$0.id.hasPrefix("view.") }.map(\.id)
        #expect(ids.count == 28)
        for id in ids {
            let spec = try #require(s.registry.spec(id), "\(id)")
            let pc = try #require(PhotocraftCatalog.byId[id])
            #expect(spec.isAvailable, "\(id)")
            #expect(spec.module == pc.module && spec.label == pc.label && spec.menu == pc.menu && spec.shortcut == pc.shortcut && spec.params == pc.params,
                    "\(id)")
        }
    }
}
