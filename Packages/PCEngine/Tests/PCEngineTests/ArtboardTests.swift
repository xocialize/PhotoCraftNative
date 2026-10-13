// Port of photocraft-engine (crates/engine/src/artboard_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Skipped: `moving_an_artboard_past_the_canvas_keeps_its_shapes_whole`
// (shape.create / shape.info, not in this package yet), the TySh checks of
// `artboard_export_keeps_imported_type_as_rendered` (photocraft-text's PSD TySh codec; the cache
// part is ported) and `moving_imported_type_shifts_it_without_re_rendering` (layer.translate's
// type handling, not this module). `view.newGuide` / `view.clearGuides` (edit_cmds) are replaced
// by direct guide edits.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct ArtboardTests {
    func session(_ depth: Int) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 100, "height": 80, "depth": .int(depth)])
        return s
    }

    func doc(_ s: Session) -> Document { s.active!.doc }

    @discardableResult
    func addSquare(_ s: Session, _ r: PixelRect, _ rgba: SIMD4<Float>) throws -> LayerId {
        try s.edit("sq") { doc, active -> LayerId in
            let fmt = doc.pixelFormat
            var l = Layer.raster(doc.nextLayerName("Layer"), format: fmt)
            l.withRaster { $0.fill(r, with: fmt.components(fromRGBA: rgba)) }
            let id = doc.insertAbove(nil, l)
            active = id
            return id
        }
    }

    func px(_ s: Session, _ x: Int, _ y: Int) throws -> [Float] {
        try s.execute("document.pixel", ["x": .int(x), "y": .int(y)]).arrayValue!.map { Float($0.doubleValue!) }
    }

    func redAt(_ s: Session, _ x: Int, _ y: Int) throws -> Bool {
        let p = try px(s, x, y)
        return p[0] > 0.99 && p[1] < 0.01 && p[3] > 0.99
    }

    func boardRect(_ s: Session, _ id: UInt64) -> PixelRect? { doc(s).layer(LayerId(id))?.artboard?.rect }

    func layerId(_ v: JSONValue) throws -> UInt64 { try #require(v["layer"]?.uint64Value) }

    @Test func newArtboardsPlaceAndGrowCanvas() throws {
        let s = try session(8)
        let r = try s.execute("layer.new.artboard", ["rect": [0, 0, 100, 80]])
        let a1 = LayerId(try layerId(r))
        #expect(doc(s).layer(a1)?.name == "Artboard 1")
        // Default: canvas-sized, right of the last board with a gap; the canvas grows.
        let r2 = try s.execute("layer.new.artboard", ["background": "black"])
        #expect(r2["rect"] == [200, 0, 100, 80])
        #expect(doc(s).size.width == 300)
        let r3 = try s.execute("layer.new.artboard", ["preset": "iPhone 14", "x": 0, "y": 100])
        #expect(r3["rect"] == [0, 100, 390, 844])
        #expect(doc(s).artboards.count == 3)
        #expect(throws: EngineError.self) { try s.execute("layer.new.artboard", ["preset": "Nope"]) }
        #expect(throws: EngineError.self) { try s.execute("layer.new.artboard", ["rect": [0, 0, 0, 5]]) }
        #expect(throws: EngineError.self) { try s.execute("layer.new.artboard", ["background": "plaid"]) }
        // Undo removes the board (and the canvas growth).
        s.undo()
        #expect(doc(s).artboards.count == 2)
        #expect(doc(s).size.height == 80)
    }

    @Test func fromLayersAndGroupThenComposeClips() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            let red = try addSquare(s, PixelRect(x0: 10, y0: 10, x1: 30, y1: 30), SIMD4(1, 0, 0, 1))
            let r = try s.execute("layer.new.artboardFromLayers", ["name": "Board"])
            #expect(r["rect"] == [10, 10, 20, 20])
            let gid = LayerId(try layerId(r))
            #expect(doc(s).artboard(of: red) == gid)
            // Grow the board; the white background shows around the square, nothing outside it.
            try s.execute("layer.artboard.set", ["width": 40, "height": 40])
            let p = try px(s, 40, 40)
            #expect(p[0] > 0.99 && p[1] > 0.99, "\(depth)")
            #expect(try px(s, 15, 15)[1] < 0.01)
            // Moving the board moves its contents.
            try s.execute("layer.artboard.set", ["x": 50, "y": 20])
            #expect(boardRect(s, gid.rawValue) == PixelRect(x: 50, y: 20, width: 40, height: 40))
            #expect(doc(s).layer(red)?.surface?.contentBounds == PixelRect(x0: 50, y0: 20, x1: 70, y1: 40))
            // layer.translate on the board does the same.
            try s.execute("layer.translate", ["layer": .id(gid), "dx": -5, "dy": 0])
            #expect(boardRect(s, gid.rawValue)?.x0 == 45)
            #expect(doc(s).layer(red)?.surface?.contentBounds.x0 == 45)
            // Background and name.
            try s.execute("layer.artboard.set", ["background": "custom", "color": "#00ff00", "name": "Green"])
            let l = try #require(doc(s).layer(gid))
            #expect(l.name == "Green")
            if case .custom? = l.artboard?.background {} else { Issue.record("expected a custom background") }
            // A plain group becomes an artboard sized to its contents.
            try addSquare(s, PixelRect(x0: 0, y0: 60, x1: 8, y1: 70), SIMD4(0, 0, 1, 1))
            let g = try s.execute("layer.groupLayers", .object([:]))
            let gid2 = try layerId(g)
            #expect(s.isEnabled("layer.new.artboardFromGroup"))
            let r2 = try s.execute("layer.new.artboardFromGroup", ["layer": .number(Double(gid2))])
            #expect(r2["rect"] == [0, 60, 8, 10])
            #expect(!s.isEnabled("layer.new.artboardFromGroup"))
        }
    }

    @Test func clearArtboardGuidesOnlyInside() throws {
        let s = try session(8)
        try s.execute("layer.new.artboard", ["rect": [0, 0, 50, 50]])
        try s.edit("guides") { d, _ in
            d.guides.vertical = [10, 70]
            d.guides.horizontal = [20]
        }
        #expect(try s.execute("view.clearSelectedArtboardGuides", .object([:]))["cleared"] == 2)
        #expect(doc(s).guides.vertical == [70])
        #expect(doc(s).guides.horizontal.isEmpty)
        // Clear Canvas Guides leaves the artboard's guides.
        try s.edit("guides") { d, _ in d.guides.vertical = [10, 70] }
        #expect(try s.execute("view.clearCanvasGuides", .object([:]))["cleared"] == 1)
        #expect(doc(s).guides.vertical == [10])
    }

    /// Clearing guides drops their colours, so a guide added later at the same place doesn't
    /// inherit one.
    @Test func clearingGuidesDropsTheirColours() throws {
        let s = try session(8)
        let magenta = SIMD3<UInt8>(0xff, 0x00, 0xff)
        func coloured(_ x: Double) throws {
            try s.edit("guide") { d, _ in
                d.guides.vertical.append(x)
                d.guides.setColor(vertical: true, position: x, rgb: magenta)
            }
        }
        func colour(_ x: Double) -> SIMD3<UInt8>? { doc(s).guides.color(vertical: true, position: x) }
        try s.execute("layer.new.artboard", ["rect": [0, 0, 50, 50]])
        try coloured(10)
        try coloured(70)
        try s.execute("view.clearSelectedArtboardGuides", .object([:]))
        try s.execute("view.clearCanvasGuides", .object([:]))
        #expect(doc(s).guides.colors.isEmpty)
        try s.edit("guides") { d, _ in d.guides.vertical = [10, 70] }
        #expect(colour(10) == nil && colour(70) == nil)
        // New Guide Layout's Clear Existing Guides likewise; a guide it keeps keeps its colour.
        try s.edit("clear") { d, _ in d.guides = Guides() }
        try coloured(0)
        try s.execute("view.newGuideLayout", ["columns": 1])
        #expect(colour(0) == magenta)
        try s.execute("view.newGuideLayout", ["columns": 1, "clearExisting": true])
        #expect(doc(s).guides.vertical.contains(0))
        #expect(colour(0) == nil)
    }

    @Test func exportToFilesAndPdf() throws {
        let s = try session(16)
        try addSquare(s, PixelRect(x0: 0, y0: 0, x1: 10, y1: 10), SIMD4(1, 0, 0, 1))
        try s.execute("layer.new.artboardFromLayers", ["name": "Red Board"])
        try s.execute("layer.new.artboard", ["rect": [20, 0, 30, 15], "name": "Empty/One", "background": "transparent"])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pcengine-artboards-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r0 = try s.execute("file.export.artboardsToFiles", ["dir": .string(dir.path), "prefix": "site"])
        let files = r0["files"]?.arrayValue?.compactMap(\.stringValue) ?? []
        try #require(files.count == 2)
        #expect(files[0].hasSuffix("site_Empty_One.png"), "\(files)")
        #expect(files[1].hasSuffix("site_Red Board.png"), "\(files)")
        let img = try EngineIO.importPath(files[1], services: s.services).document
        #expect(img.size == PixelSize(width: 10, height: 10))
        let img2 = try EngineIO.importPath(files[0], services: s.services).document
        #expect(img2.size == PixelSize(width: 30, height: 15))
        // Layered PSD keeps the board, moved to the origin.
        let rp = try s.execute("file.export.artboardsToFiles", ["dir": .string(dir.path), "prefix": "", "format": "psd",
                                                                 "artboards": [.id(doc(s).artboards[0].id)]])
        let psdPath = try #require(rp["files"]?[0]?.stringValue)
        let psd = try EngineIO.importPath(psdPath, services: s.services).document
        #expect(psd.artboards.first?.artboard.rect == PixelRect(x0: 0, y0: 0, x1: 10, y1: 10))
        dropForOracle(URL(fileURLWithPath: psdPath), as: "artboards-to-files.psd")
        let pdf = dir.appendingPathComponent("boards.pdf").path
        let r = try s.execute("file.export.artboardsToPdf", ["path": .string(pdf)])
        #expect(r["pages"] == 2)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: pdf))
        #expect(bytes.starts(with: Data("%PDF-1.4".utf8)))
        #expect(bytes.suffix(6) == Data("%%EOF\n".utf8))
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.components(separatedBy: "/Type /Page ").count - 1 == 2)
        #expect(text.components(separatedBy: "/DCTDecode").count - 1 == 2)
    }

    @Test func rasterPdfXrefOffsetsPointAtObjects() throws {
        let pdf = ArtboardCommands.rasterPdf([(2, 3, 72, Data([0xff, 0xd8, 0xff, 0xd9]))])
        // One character per byte, so string offsets are byte offsets.
        let chars = Array(try #require(String(data: pdf, encoding: .isoLatin1)))
        let text = String(chars)
        // The xref table itself (photocraft's `rfind("xref\n")` lands on `startxref`, checking nothing).
        let xref = try #require(text.range(of: "\nxref\n", options: .backwards))
        let lines = text[text.index(after: xref.lowerBound)...].split(separator: "\n", omittingEmptySubsequences: false)
        let offsets = lines.dropFirst(3).prefix(5).compactMap { Int($0.prefix(10)) }
        #expect(offsets.count == 5)
        for (i, o) in offsets.enumerated() {
            let head = "\(i + 1) 0 obj"
            #expect(o + head.count <= chars.count && String(chars[o..<(o + head.count)]) == head)
        }
        #expect(text.contains("/MediaBox [0 0 2.000 3.000]"))
    }

    @Test func disabledWithoutArtboards() throws {
        let s = try session(8)
        for id in ["layer.artboard.set", "view.clearSelectedArtboardGuides", "file.export.artboardsToFiles", "file.export.artboardsToPdf",
                   "layer.new.artboardFromGroup"] {
            #expect(!s.isEnabled(id), "\(id)")
        }
        #expect(s.isEnabled("layer.new.artboard"))
        #expect(s.isEnabled("layer.new.artboardFromLayers"))
        _ = try? s.execute("layer.new.artboard", .object([:]))
        #expect(!s.isEnabled("layer.new.artboardFromLayers"))
    }

    /// Runs `cmd` and checks it fails with a bad-params error that leaves the document, its
    /// revision, its active layer and its history exactly as they were (#931).
    @discardableResult
    func assertRejected(_ s: Session, _ cmd: String, _ p: JSONValue, sourceLocation: SourceLocation = #_sourceLocation) -> String {
        let d = s.active!
        let (before, rev, active, past) = (d.doc, d.revision, d.activeLayer, d.history.pastCount)
        do {
            try s.execute(cmd, p)
            Issue.record("\(cmd) \(p.serialized()) should fail", sourceLocation: sourceLocation)
            return ""
        } catch {
            if case .badParams? = error as? EngineError {} else { Issue.record("\(cmd) \(p.serialized()): \(error)", sourceLocation: sourceLocation) }
            let d = s.active!
            #expect(d.doc == before, "\(cmd) \(p.serialized()) changed the document", sourceLocation: sourceLocation)
            #expect(d.revision == rev, sourceLocation: sourceLocation)
            #expect(d.activeLayer == active, sourceLocation: sourceLocation)
            #expect(d.history.pastCount == past, "\(cmd) recorded a history step", sourceLocation: sourceLocation)
            return "\(error)"
        }
    }

    static let maxI = Double(Int32.max), minI = Double(Int32.min)

    @Test func newArtboardRejectsCoordinatesPastThe32BitRange() throws {
        let (maxI, minI) = (Self.maxI, Self.minI)
        var s = try session(8)
        // A board flush with the far right edge: x1 = Int32.max.
        let r = try s.execute("layer.new.artboard", ["x": .number(maxI - 50), "y": 0, "width": 50, "height": 50])
        #expect(r["rect"] == [.number(maxI - 50), 0, 50, 50])
        // Default placement right of it has no room: an error naming the edge, not a wrapped x.
        let msg = assertRejected(s, "layer.new.artboard", .object([:]))
        #expect(msg.contains(String(Int32.max)), "\(msg)")
        assertRejected(s, "layer.new.artboard", ["preset": "iPhone 14"])
        // An explicit position still works beside it (the canvas grew to its 300000 px cap).
        #expect(try s.execute("layer.new.artboard", ["x": 0])["rect"] == [0, 0, 300_000, 80])
        #expect(try s.execute("layer.new.artboard", ["preset": "A4", "x": 0, "y": 100])["rect"] == [0, 100, 595, 842])
        #expect(doc(s).artboards.count == 3)

        // Default placement whose x fits but whose canvas-sized width runs past the edge.
        s = try session(8)
        try s.execute("layer.new.artboard", ["x": .number(maxI - 250), "width": 50, "height": 50])
        assertRejected(s, "layer.new.artboard", .object([:]))

        // Explicit rects that would end past Int32.max (or start outside it) are rejected, not clamped.
        s = try session(8)
        let bad: [JSONValue] = [
            ["x": .number(maxI), "width": 50, "height": 50],
            ["x": .number(maxI - 10), "width": 50, "height": 50],
            ["y": .number(maxI - 10), "width": 50, "height": 50],
            ["rect": [.number(maxI - 10), 0, 50, 50]],
            ["rect": [0, .number(maxI), 50, 50]],
            ["rect": [3e9, 0, 50, 50]],
            ["rect": [-3e9, 0, 50, 50]],
            ["rect": [0, 0, 3e9, 50]],
            ["x": 0, "width": 3_000_000_000, "height": 50],
        ]
        for p in bad { assertRejected(s, "layer.new.artboard", p) }
        // Representable extremes are fine: flush with either edge.
        #expect(try s.execute("layer.new.artboard", ["x": .number(minI), "y": .number(minI), "width": 50, "height": 50])["rect"]
            == [.number(minI), .number(minI), 50, 50])
        #expect(try s.execute("layer.new.artboard", ["rect": [.number(maxI - 50), .number(maxI - 50), 50, 50]])["rect"]
            == [.number(maxI - 50), .number(maxI - 50), 50, 50])
    }

    @Test func editArtboardRejectsMovesAndSizesPastThe32BitRange() throws {
        let (maxI, minI) = (Self.maxI, Self.minI)
        let s = try session(8)
        let id = try layerId(try s.execute("layer.new.artboard", ["x": .number(minI), "y": .number(minI), "width": 50, "height": 50]))
        // Moving the board with its contents from one edge to the other needs an offset of about
        // 2^32, which no layer can be translated by.
        let msg = assertRejected(s, "layer.artboard.set", ["x": .number(maxI - 50)])
        #expect(msg.contains("4294967245"), "\(msg)")
        assertRejected(s, "layer.artboard.set", ["y": .number(maxI - 50)])
        // A rect that would end past the edge is rejected with or without moving the contents.
        assertRejected(s, "layer.artboard.set", ["x": .number(maxI), "moveContents": false])
        assertRejected(s, "layer.artboard.set", ["x": .number(maxI - 10)])
        assertRejected(s, "layer.artboard.set", ["rect": [.number(maxI - 10), 0, 50, 50], "moveContents": false])
        // Without the contents only the board's own rect changes, so the far move is fine.
        let r = try s.execute("layer.artboard.set", ["x": .number(maxI - 50), "y": .number(maxI - 50), "moveContents": false])
        #expect(r["rect"] == [.number(maxI - 50), .number(maxI - 50), 50, 50])
        #expect(boardRect(s, id) == PixelRect(x0: .max - 50, y0: .max - 50, x1: .max, y1: .max))
        // Resizing past the edge is rejected instead of shrinking the board to fit.
        assertRejected(s, "layer.artboard.set", ["width": 51])
        assertRejected(s, "layer.artboard.set", ["height": 3_000_000_000])
        assertRejected(s, "layer.artboard.set", ["preset": "iPhone 14"])
        // A board at the edge can still be shrunk or moved back in.
        #expect(try s.execute("layer.artboard.set", ["width": 20])["rect"] == [.number(maxI - 50), .number(maxI - 50), 20, 50])
        #expect(try s.execute("layer.artboard.set", ["x": 0, "y": 0, "moveContents": false])["rect"] == [0, 0, 20, 50])
    }

    @Test func artboardsAtOrdinaryCoordinatesStillPlaceAndEdit() throws {
        let s = try session(8)
        let first = try layerId(try s.execute("layer.new.artboard", ["x": 10, "width": 50, "height": 50]))
        #expect(try s.execute("layer.new.artboard", ["width": 50])["rect"] == [160, 0, 50, 80])
        // Editing moves the board (and its contents) and resizes it.
        let red = try addSquare(s, PixelRect(x0: 20, y0: 10, x1: 30, y1: 20), SIMD4(1, 0, 0, 1))
        try s.edit("into board") { doc, _ in
            guard let l = doc.remove(red) else { throw EngineError.noLayer(red) }
            doc.updateLayer(LayerId(first)) { $0.withChildren { $0.append(l) } }
        }
        #expect(try s.execute("layer.artboard.set", ["layer": .number(Double(first)), "x": 200])["rect"] == [200, 0, 50, 50])
        #expect(doc(s).layer(red)?.surface?.contentBounds == PixelRect(x0: 210, y0: 10, x1: 220, y1: 20))
        #expect(try s.execute("layer.artboard.set", ["layer": .number(Double(first)), "width": 70, "height": 40])["rect"] == [200, 0, 70, 40])
    }

    @Test func exportRejectsABoardTooFarFromTheOrigin() throws {
        let s = try session(8)
        try s.execute("layer.new.artboard", ["x": .number(Self.minI), "width": 50, "height": 50, "name": "Far"])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pcengine-artboards-931-\(ProcessInfo.processInfo.processIdentifier)")
        // Moving the board to the origin needs dx = 2^31, one past Int32.max: an error, not a trap.
        do {
            try s.execute("file.export.artboardsToFiles", ["dir": .string(dir.path)])
            Issue.record("export should fail")
        } catch {
            #expect("\(error)".contains(String(Int32.min)), "\(error)")
        }
        #expect(throws: EngineError.self) { try s.execute("file.export.artboardsToPdf", ["path": .string(dir.appendingPathComponent("boards.pdf").path)]) }
        #expect(!FileManager.default.fileExists(atPath: dir.path), "nothing was written")
        let id = doc(s).artboards[0].id
        #expect(throws: EngineError.self) { try ArtboardCommands.artboardDocument(doc(s), id) }
        // One pixel in from the edge is representable and still exports.
        try s.execute("layer.artboard.set", ["x": .number(Self.minI + 1), "moveContents": false])
        let one = try #require(try ArtboardCommands.artboardDocument(doc(s), id))
        #expect(one.size == PixelSize(width: 50, height: 50))
        #expect(one.artboards[0].artboard.rect == PixelRect(x0: 0, y0: 0, x1: 50, y1: 50))
    }

    /// #1531: a board 40×40 at (10, 10) holding a red square at (10..30)², the artboard active.
    func boardWithSquare(_ s: Session) throws -> LayerId {
        try addSquare(s, PixelRect(x0: 10, y0: 10, x1: 30, y1: 30), SIMD4(1, 0, 0, 1))
        let gid = LayerId(try layerId(try s.execute("layer.new.artboardFromLayers", ["name": "Board"])))
        try s.execute("layer.artboard.set", ["width": 40, "height": 40])
        try s.execute("layer.select", ["layer": .id(gid)])
        return gid
    }

    @Test func duplicateArtboardLandsBesideTheOriginalWithItsContents() throws {
        let s = try session(8)
        let gid = try boardWithSquare(s)
        let size = doc(s).size
        let copy = try layerId(try s.execute("layer.duplicate", .object([:])))
        #expect(boardRect(s, gid.rawValue) == PixelRect(x0: 10, y0: 10, x1: 50, y1: 50), "the original stays")
        // Photoshop: right of the original with the artboard gap, the canvas growing to show it.
        #expect(boardRect(s, copy) == PixelRect(x0: 150, y0: 10, x1: 190, y1: 50))
        #expect(doc(s).size.width >= 190)
        #expect(try redAt(s, 155, 15), "the copy's contents moved with it")
        #expect(try redAt(s, 15, 15), "the original's contents stay")
        #expect(doc(s).layer(LayerId(copy))?.name == "Board copy")
        // Again from the original: the spot beside it is taken, so the next free one.
        try s.execute("layer.select", ["layer": .id(gid)])
        let copy2 = try layerId(try s.execute("layer.duplicate", .object([:])))
        #expect(boardRect(s, copy2) == PixelRect(x0: 290, y0: 10, x1: 330, y1: 50))
        // One undo step each: the copy and the canvas growth go together.
        s.undo()
        s.undo()
        #expect(doc(s).artboards.count == 1)
        #expect(doc(s).size == size)
        // `inPlace` (the Move tool's ⌥-drag) keeps the copy on the original.
        try s.execute("layer.select", ["layer": .id(gid)])
        let copy3 = try layerId(try s.execute("layer.duplicate", ["inPlace": true]))
        #expect(boardRect(s, copy3) == PixelRect(x0: 10, y0: 10, x1: 50, y1: 50))
    }

    @Test func duplicatingSeveralArtboardsPlacesEachCopyInAFreeSpot() throws {
        let s = try session(8)
        let a = try boardWithSquare(s)
        let b = try layerId(try s.execute("layer.new.artboard", ["rect": [10, 100, 40, 40]]))
        try s.execute("layer.select", ["layer": .id(a)])
        try s.execute("layer.select", ["layer": .number(Double(b)), "mode": "add"])
        let r = try s.execute("layer.duplicate", .object([:]))
        #expect(r["layers"]?.arrayValue?.count == 2)
        let boards = doc(s).artboards.map(\.artboard.rect)
        #expect(boards.count == 4)
        for (i, x) in boards.enumerated() {
            for y in boards[(i + 1)...] { #expect(x.intersect(y).isEmpty, "\(x) overlaps \(y)") }
        }
        let canvas = doc(s).bounds
        #expect(boards.allSatisfy { $0.intersect(canvas) == $0 }, "\(boards) in \(canvas)")
        // One undo step.
        s.undo()
        #expect(doc(s).artboards.count == 2)
    }

    @Test func movingAnArtboardPastTheCanvasGrowsIt() throws {
        // #1531: a board dragged right of the canvas was cut off at the old edge.
        let s = try session(8)
        let gid = try boardWithSquare(s)
        try s.execute("layer.translate", ["dx": 200, "dy": 60])
        #expect(boardRect(s, gid.rawValue) == PixelRect(x0: 210, y0: 70, x1: 250, y1: 110))
        #expect(doc(s).size == PixelSize(width: 250, height: 110))
        #expect(try redAt(s, 215, 75))
        s.undo()
        #expect(doc(s).size == PixelSize(width: 100, height: 80))
    }

    @Test func artboardExportKeepsImportedTypeAsRendered() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            let block = PixelRect(x0: 30, y0: 20, x1: 60, y1: 30)
            let text = try s.edit("type") { doc, active -> LayerId in
                var t = TextLayer(text: "Hello!", fontFamily: "No Such Font", sizePt: 26)
                t.transform = .translate(Double(block.x0), Double(block.y1))
                let fmt = doc.pixelFormat
                var cache = Surface(format: fmt)
                cache.fill(block, with: fmt.components(fromRGBA: SIMD4(0.4, 0.2, 0.6, 1)))
                t.cache = cache
                let id = doc.insertAbove(nil, Layer(name: "Hello!", content: .text(t)))
                active = id
                return id
            }
            try s.execute("layer.new.artboard", ["rect": [20, 10, 50, 40]])
            let board = doc(s).artboards[0].id
            try s.edit("into board") { doc, _ in
                guard let l = doc.remove(text) else { throw EngineError.noLayer(text) }
                doc.updateLayer(board) { $0.withChildren { $0.append(l) } }
            }
            let one = try #require(try ArtboardCommands.artboardDocument(doc(s), board))
            guard case .text(let t)? = one.layer(text)?.content, let c = t.cache else { Issue.record("not a type layer"); continue }
            // The same pixels, moved to the board's origin: not re-rendered.
            #expect(c.contentBounds == PixelRect(x0: 10, y0: 10, x1: 40, y1: 20), "depth \(depth)")
            let p = c.rgba(x: 15, y: 15)
            #expect(abs(p.x - 0.4) < 0.01 && abs(p.z - 0.6) < 0.01, "depth \(depth): \(p)")
        }
    }

    @Test func movingAnArtboardLeftOfOrAboveTheOriginGrowsTheCanvasThere() throws {
        for (cmd, p): (String, JSONValue) in [("layer.translate", ["dx": -60, "dy": -30]), ("layer.artboard.set", ["x": -50, "y": -20])] {
            let s = try session(8)
            let gid = try boardWithSquare(s)
            let other = try layerId(try s.execute("layer.new.artboard", ["rect": [60, 10, 30, 30]]))
            try s.edit("guide") { doc, _ in doc.guides.vertical.append(70) }
            try s.execute("layer.select", ["layer": .id(gid)])
            try s.execute(cmd, p)
            #expect(boardRect(s, gid.rawValue) == PixelRect(x0: 0, y0: 0, x1: 40, y1: 40), "\(cmd)")
            #expect(boardRect(s, other) == PixelRect(x0: 110, y0: 30, x1: 140, y1: 60), "\(cmd): the other board shifts too")
            #expect(doc(s).size == PixelSize(width: 150, height: 100), "\(cmd)")
            #expect(doc(s).guides.vertical == [120], "\(cmd)")
            #expect(try redAt(s, 0, 0) && redAt(s, 19, 19) && !redAt(s, 20, 20), "\(cmd): the contents moved with the board")
            // One undo step back.
            s.undo()
            #expect(boardRect(s, gid.rawValue) == PixelRect(x0: 10, y0: 10, x1: 50, y1: 50), "\(cmd)")
            #expect(boardRect(s, other) == PixelRect(x0: 60, y0: 10, x1: 90, y1: 40), "\(cmd)")
            #expect(doc(s).size == PixelSize(width: 100, height: 80), "\(cmd)")
            #expect(doc(s).guides.vertical == [70], "\(cmd)")
        }
    }

    @Test func addBesidePlacesABoardOnEachSideAndAltDuplicatesContents() throws {
        // #3033: the Artboard tool's "+" buttons. Board 40×40 at (10, 10) holding a red square.
        let s = try session(8)
        let gid = try boardWithSquare(s)
        #expect(try s.execute("layer.artboard.addBeside", ["side": "right"])["rect"] == [150, 10, 40, 40], "same size, a gap to the right")
        #expect(try !redAt(s, 155, 15), "a plain \"+\" adds an empty board")
        #expect(try s.execute("layer.artboard.addBeside", ["layer": .id(gid), "side": "bottom", "duplicate": true])["rect"] == [10, 150, 40, 40])
        #expect(try redAt(s, 15, 155), "⌥: the copy brings the contents")
        // Again on the right: that spot is taken, so the next free one.
        #expect(try s.execute("layer.artboard.addBeside", ["layer": .id(gid)])["rect"] == [290, 10, 40, 40])
        // Left of x = 10 is past the canvas origin: everything shifts right by 130 to make room.
        let before = doc(s).size
        #expect(try s.execute("layer.artboard.addBeside", ["layer": .id(gid), "side": "left"])["rect"] == [0, 10, 40, 40])
        #expect(boardRect(s, gid.rawValue) == PixelRect(x0: 140, y0: 10, x1: 180, y1: 50))
        #expect(try redAt(s, 145, 15), "the original's contents moved with the shift")
        #expect(doc(s).size.width == before.width + 130)
        // One undo step.
        s.undo()
        #expect(boardRect(s, gid.rawValue) == PixelRect(x0: 10, y0: 10, x1: 50, y1: 50))
        #expect(doc(s).size == before)
        #expect(throws: EngineError.self) { try s.execute("layer.artboard.addBeside", ["side": "diagonal"]) }
    }
}
