// Port of photocraft-engine (crates/engine/src/web_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Every photocraft test is ported, with these substitutions: `image_assets_are_generated_now_and_on_save`
// calls `WebCommands.onSaved` where photocraft goes through Automate's `document_saved`; `webp_export_preferences_select_lossless_or_lossy_output`
// leaves out photocraft's typed-preferences deserialisation check (the defaults are checked
// instead). Files are decoded back with PCPlatform's `ImageCodecs`.

import Foundation
import PCAlgo
import PCDocument
@testable import PCEngine
import PCFoundation
import PCPlatform
import Testing

@Suite struct WebTests {
    typealias W = WebCommands

    func tmp(_ name: String) throws -> String {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("photocraft-web-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.path
    }

    /// A 64×48 document: a red square with soft (40 %) edges on a transparent layer, and a
    /// gradient band.
    func session(_ depth: Int) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 64, "height": 48, "depth": .int(depth), "name": "web.psd", "background": "transparent"])
        try s.edit("paint") { doc, active in
            let fmt = doc.pixelFormat
            var l = Layer.raster("Logo", format: fmt)
            l.withRaster { surf in
                surf.fill(PixelRect(x0: 8, y0: 8, x1: 32, y1: 32), with: PixelCodec.fromRGBA(fmt, SIMD4(1, 0, 0, 1)))
                surf.fill(PixelRect(x0: 32, y0: 8, x1: 34, y1: 32), with: PixelCodec.fromRGBA(fmt, SIMD4(1, 0, 0, 0.4)))
                for x in 0..<64 {
                    let f = Float(x) / 63
                    surf.fill(PixelRect(x0: Int32(x), y0: 36, x1: Int32(x + 1), y1: 48), with: PixelCodec.fromRGBA(fmt, SIMD4(f, 0.5, 1 - f, 1)))
                }
            }
            let id = doc.insertAbove(nil, l)
            active = id
        }
        return s
    }

    /// A decoded file: (width, height, straight RGBA8).
    func decode(_ bytes: [UInt8]) throws -> (Int, Int, [UInt8]) {
        let img = try ImageCodecs.decode(Data(bytes))
        let r = PixelRect(x0: 0, y0: 0, x1: Int32(img.size.width), y1: Int32(img.size.height))
        let px = img.surface.readRGBA(r).flatMap { [W.to8($0.x), W.to8($0.y), W.to8($0.z), W.to8($0.w)] }
        return (img.size.width, img.size.height, px)
    }

    func decode(_ path: String) throws -> (Int, Int, [UInt8]) { try decode([UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))) }
    func dims(_ path: String) throws -> (Int, Int) { let d = try decode(path); return (d.0, d.1) }
    func lastWeb(_ s: Session) -> JSONValue? { s.state[W.LastWebKey.self] }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    func read(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

    @Test func estimatesPreserveLastSuccessfulExportSettings() throws {
        let dir = try tmp("estimate_settings")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = try session(8)
        let saved: JSONValue = ["format": "png24", "path": .string("\(dir)/saved.png"), "width": 32, "height": 24]
        try s.execute("file.export.saveForWebLegacy", saved)
        #expect(lastWeb(s) == saved)
        let estimate = try s.execute("file.export.saveForWebLegacy", ["format": "jpeg", "quality": 10, "width": 16, "height": 12])
        #expect(estimate["width"] == 16 && estimate["height"] == 12)
        #expect(lastWeb(s) == saved, "preview estimates must not replace the settings from the last successful export")
    }

    @Test(arguments: [8, 16, 32]) func platformWriterReceivesResizedImageAtEveryDepth(depth: Int) throws {
        let s = try session(depth)
        let params: JSONValue = ["format": "png24", "path": "download.png", "width": 32, "height": 24]
        var files: [(String, [UInt8])] = []
        let r = try W.saveForWebWithWriter(s, params) { path, bytes in files.append((path, bytes)) }
        try #require(files.count == 1)
        #expect(files[0].0 == "download.png")
        #expect(r["files"] == .strings(["download.png"]))
        #expect(r["bytes"]?.intValue == files[0].1.count)
        let (w, h, px) = try decode(files[0].1)
        #expect(w == 32 && h == 24, "\(depth)-bit document")
        let i = (8 * 32 + 8) * 4
        #expect(Array(px[i..<i + 4]) == [255, 0, 0, 255])
        #expect(lastWeb(s) == params)
    }

    @Test func platformWriterChecksAuthorizationBeforeDroppingFloatingPixels() throws {
        let s = try session(8)
        try s.execute("select.rect", ["x": 8, "y": 8, "width": 4, "height": 4])
        try s.execute("select.float", ["dx": 32])
        #expect(FloatCommands.floating(try #require(s.active)) != nil)
        s.authorize = { cmd, params in
            if cmd == "file.export.saveForWebLegacy", params["path"] == "moved.png" { throw EngineError.other("export denied") }
        }
        let params: JSONValue = ["format": "png24", "path": "moved.png"]
        var output: [UInt8] = []
        do {
            _ = try W.saveForWebWithWriter(s, params) { _, bytes in output += bytes }
            Issue.record("the export should be denied")
        } catch {
            #expect("\(error)".contains("export denied"))
        }
        #expect(output.isEmpty)
        #expect(lastWeb(s) == nil)
        #expect(FloatCommands.floating(try #require(s.active)) != nil, "denied export must not commit a floating move")
        s.authorize = nil
        _ = try W.saveForWebWithWriter(s, params) { _, bytes in output += bytes }
        #expect(FloatCommands.floating(try #require(s.active)) == nil)
        let (_, _, px) = try decode(output)
        let old = (10 * 64 + 10) * 4
        let moved = (10 * 64 + 42) * 4
        #expect(px[old + 3] == 0, "the selected pixels left their original position")
        #expect(Array(px[moved..<moved + 4]) == [255, 0, 0, 255], "the download contains the moved pixels")
    }

    @Test func platformWriterReceivesSlicesSpacerAndHtmlWithSiblingReferences() throws {
        let s = try session(8)
        try s.execute("slice.new", ["rect": [8, 8, 24, 24], "name": "logo", "alt": "Logo"])
        try s.execute("slice.new", ["rect": [40, 0, 24, 20], "kind": "noImage", "cellText": "Hello & bye"])
        let params: JSONValue = ["format": "png24", "dir": "downloads", "imagesFolder": "", "html": true]
        var files: [String: [UInt8]] = [:]
        let r = try W.saveForWebWithWriter(s, params) { path, bytes in
            #expect(files.updateValue(bytes, forKey: path) == nil, "each file is written once")
        }
        let htmlName = try #require(r["html"]?.stringValue)
        let page = String(decoding: try #require(files[htmlName]), as: UTF8.self)
        let images = r["files"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(files.count == images.count + 2, "image slices, spacer and HTML all reach the writer")
        for path in images {
            let name = String(path.dropFirst("downloads/".count))
            #expect(page.contains("src=\"\(name)\""), "the HTML refers to its sibling \(name)")
            #expect((try? decode(try #require(files[path]))) != nil)
        }
        #expect(page.contains("src=\"spacer.gif\""))
        #expect(page.contains("Hello &amp; bye"))
        let spacer = try decode(try #require(files["downloads/spacer.gif"]))
        #expect(spacer.0 == 1 && spacer.1 == 1)
        let logo = try decode(try #require(files["downloads/logo.png"]))
        #expect(logo.0 == 24 && logo.1 == 24)
        #expect(lastWeb(s) == params)
    }

    @Test func reservedDocumentAndSliceNamesExportWithPortableNames() throws {
        let dir = try tmp("reserved-slice-names")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = try session(8)
        try s.edit("rename") { doc, _ in doc.name = "aux.psd" }
        try s.execute("slice.new", ["rect": [0, 0, 16, 16], "name": "con"])
        let result = try s.execute("file.export.saveForWebLegacy", ["dir": .string(dir), "format": "png24", "html": true])
        let html = try #require(result["html"]?.stringValue)
        #expect(html.hasSuffix("/aux_.html"))
        #expect(result["files"]?.arrayValue?.contains { $0.stringValue?.hasSuffix("/con_.png") == true } == true)
        #expect(exists(html))
    }

    @Test func platformWriterFailureStopsExportAndPreservesSavedSettings() throws {
        let s = try session(8)
        let saved: JSONValue = ["format": "png24", "path": "saved.png"]
        _ = try W.saveForWebWithWriter(s, saved) { _, _ in }
        try s.execute("slice.new", ["rect": [8, 8, 24, 24], "name": "logo"])
        var attempts = 0
        do {
            _ = try W.saveForWebWithWriter(s, ["format": "gif", "dir": "downloads", "html": true]) { _, _ in
                attempts += 1
                if attempts == 2 { throw EngineError.other("download failed") }
            }
            Issue.record("the export should fail")
        } catch {
            #expect("\(error)".contains("download failed"))
        }
        #expect(attempts == 2, "no later slice, spacer or HTML should be written after failure")
        #expect(lastWeb(s) == saved)
    }

    @Test(arguments: [8, 16, 32]) func estimatesEveryFormatAtEveryDepth(depth: Int) throws {
        let s = try session(depth)
        var sizes: [Int] = []
        for f in ["gif", "png8", "png24", "jpeg", "wbmp"] {
            let r = try s.execute("file.export.saveForWebLegacy", ["format": .string(f), "colors": 16])
            #expect(r["width"] == 64 && r["height"] == 48, "\(f)")
            #expect((r["bytes"]?.intValue ?? 0) > 20, "\(f)")
            if f == "gif" || f == "png8" { #expect((r["colors"]?.intValue ?? 99) <= 16, "\(f)") }
            sizes.append(r["bytes"]?.intValue ?? 0)
        }
        #expect(sizes[4] == 4 + 8 * 48, "WBMP: header plus 1 bit per pixel")
        if depth == 8 {
            #expect(throws: (any Error).self) { try s.execute("file.export.saveForWebLegacy", ["format": "tiff"]) }
            let r = try s.execute("file.export.saveForWebLegacy", ["preset": "JPEG Low", "percent": 50])
            #expect(r["format"] == "jpg")
            #expect(r["width"] == 32)
        }
    }

    @Test func gifAndPng8KeepTransparencyAndPalette() throws {
        let dir = try tmp("gif")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = try session(8)
        let gif = "\(dir)/a.gif"
        let r = try s.execute("file.export.saveForWebLegacy", ["format": "gif", "colors": 8, "dither": "none", "path": .string(gif)])
        #expect(r["files"]?[0] == .string(gif))
        let (_, _, img) = try decode(gif)
        func px(_ x: Int, _ y: Int) -> [UInt8] { Array(img[(y * 64 + x) * 4..<(y * 64 + x) * 4 + 4]) }
        #expect(px(0, 0)[3] == 0, "transparent background")
        #expect(px(16, 16) == [255, 0, 0, 255])
        // The 40 % edge is under ½: transparent, as Photoshop's hard GIF transparency.
        #expect(px(33, 16)[3] == 0)
        let colors = Set((0..<64 * 48).map { i in Array(img[i * 4..<i * 4 + 4]) }.filter { $0[3] > 0 })
        #expect(colors.count <= 7, "8 colours including the transparent one, got \(colors.count)")
        // Transparency off: everything over the matte.
        let png8 = "\(dir)/a.png"
        try s.execute("file.export.saveForWebLegacy", ["format": "png8", "transparency": false, "matte": "#00ff00", "path": .string(png8)])
        #expect(Array(try decode(png8).2.prefix(4)) == [0, 255, 0, 255])
    }

    @Test func jpegQualityProgressiveAndMetadata() throws {
        let dir = try tmp("jpeg")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = try session(16)
        try s.execute("file.fileInfo", ["copyright": "© Example", "author": "A. Person", "description": "secret notes"])
        let lo = "\(dir)/lo.jpg", hi = "\(dir)/hi.jpg"
        try s.execute("file.export.saveForWebLegacy", ["format": "jpeg", "quality": 10, "path": .string(lo), "metadata": "none"])
        try s.execute("file.export.saveForWebLegacy", ["format": "jpeg", "quality": 95, "progressive": true, "path": .string(hi), "metadata": "copyright"])
        let (a, b) = ([UInt8](try Data(contentsOf: URL(fileURLWithPath: lo))), [UInt8](try Data(contentsOf: URL(fileURLWithPath: hi))))
        #expect(a.count < b.count)
        #expect(zip(b, b.dropFirst()).contains { $0 == 0xFF && $1 == 0xC2 }, "progressive")
        let hiXMP = try ImageCodecs.decode(Data(b)).metadata.xmp.map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(hiXMP.contains("Example"), "copyright kept")
        #expect(!hiXMP.contains("secret"), "description dropped")
        // No XMP packet in the file (ImageIO's decoder synthesises XMP from EXIF/TIFF fields, so
        // the file's APP1 segments are checked instead).
        let xap = Array("http://ns.adobe.com/xap/1.0/".utf8)
        func hasXAP(_ b: [UInt8]) -> Bool { b.count >= xap.count && (0...(b.count - xap.count)).contains { Array(b[$0..<$0 + xap.count]) == xap } }
        #expect(!hasXAP(a))
        #expect(hasXAP(b))
    }

    @Test func slicesExportWithHtmlTable() throws {
        let dir = try tmp("slices")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = try session(8)
        try s.execute("slice.new", ["rect": [8, 8, 24, 24], "name": "logo", "url": "https://example.org/", "alt": "Logo"])
        try s.execute("slice.new", ["rect": [40, 0, 24, 20], "kind": "noImage", "cellText": "Hello & bye"])
        let r = try s.execute("file.export.saveForWebLegacy", ["format": "png24", "dir": .string(dir), "html": true])
        let files = r["files"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let n = try #require(s.active).doc.resolvedSlices().count
        #expect(files.count == n - 1, "every slice but the no-image one")
        let logo = try #require(files.first { $0.hasSuffix("images/logo.png") })
        #expect(try dims(logo) == (24, 24))
        let html = try read(try #require(r["html"]?.stringValue))
        #expect(html.contains("<a href=\"https://example.org/\">"))
        #expect(html.contains("alt=\"Logo\""))
        #expect(html.contains("Hello &amp; bye"))
        #expect(html.contains("images/spacer.gif"))
        #expect(exists("\(dir)/images/spacer.gif"))
        // Total area of the exported slices plus the text cell is the canvas.
        let area = try files.reduce(0) { acc, f in let d = try dims(f); return acc + d.0 * d.1 }
        #expect(area + 24 * 20 == 64 * 48)
        // Scaled export scales slices.
        let dir2 = try tmp("slices2")
        defer { try? FileManager.default.removeItem(atPath: dir2) }
        let r2 = try s.execute("file.export.saveForWebLegacy", ["format": "gif", "dir": .string(dir2), "percent": 50, "slices": "user"])
        #expect(r2["files"]?.arrayValue?.count == 1)
        #expect(try dims(try #require(r2["files"]?[0]?.stringValue)) == (12, 12))
    }

    @Test func sliceHtmlEscapesImportedMarkupByDefaultAndRequiresTrustedOptIn() throws {
        let s = try session(8)
        let slice = try s.execute("slice.new", ["rect": [0, 0, 24, 20], "kind": "noImage", "name": "text", "cellTextIsHtml": true,
                                                "cellText": "<script>alert(1)</script><b>Trusted label</b>"])
        let dir = try tmp("slice-html-safety")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let d = try s.execute("file.export.saveForWebLegacy", ["format": "png24", "dir": .string(dir), "html": true])
        var page = try read(try #require(d["html"]?.stringValue))
        #expect(page.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(!page.contains("<script>"))
        #expect(page.contains("&lt;b&gt;Trusted label&lt;/b&gt;"))
        let trustedDir = try tmp("slice-html-trusted")
        defer { try? FileManager.default.removeItem(atPath: trustedDir) }
        let t = try s.execute("file.export.saveForWebLegacy", ["format": "png24", "dir": .string(trustedDir), "html": true, "trustedSliceHtml": true])
        page = try read(try #require(t["html"]?.stringValue))
        #expect(page.contains("<script>alert(1)</script><b>Trusted label</b>"))
        #expect(lastWeb(s)?["trustedSliceHtml"] == nil)
        let plainDir = try tmp("slice-html-plain")
        defer { try? FileManager.default.removeItem(atPath: plainDir) }
        try s.execute("slice.set", ["slice": try #require(slice["slice"]), "cellTextIsHtml": false])
        let pl = try s.execute("file.export.saveForWebLegacy", ["format": "png24", "dir": .string(plainDir), "html": true, "trustedSliceHtml": true])
        page = try read(try #require(pl["html"]?.stringValue))
        #expect(page.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    }

    @Test func sliceLinksAllowNormalUrlsAndDropActiveSchemes() throws {
        let dir = try tmp("slice-link-safety")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = try session(8)
        for (x, url) in [(0, "javascript:alert(1)"), (10, "data:text/html,<script>alert(1)</script>"), (20, "https://example.org/page?a=1&b=2"),
                         (30, "../relative/page.html#part"), (40, "mailto:hello@example.org"), (50, "JaVa\tscript:alert(1)")] {
            try s.execute("slice.new", ["rect": [.int(x), 0, 10, 10], "name": .string("link\(x)"), "url": .string(url)])
        }
        let r = try s.execute("file.export.saveForWebLegacy", ["format": "png24", "dir": .string(dir), "html": true, "slices": "user"])
        let page = try read(try #require(r["html"]?.stringValue))
        #expect(!page.contains("href=\"javascript:"))
        #expect(!page.contains("href=\"data:"))
        #expect(!page.contains("href=\"JaVa"))
        #expect(page.contains("href=\"https://example.org/page?a=1&amp;b=2\""))
        #expect(page.contains("href=\"../relative/page.html#part\""))
        #expect(page.contains("href=\"mailto:hello@example.org\""))
        #expect(page.components(separatedBy: "<a href=").count - 1 == 3)
    }

    @Test func imagesFolderStaysInsideExportDirectoryAndIsEscapedInHtml() throws {
        let root = try tmp("slice-image-folder")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let dir = "\(root)/output"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let s = try session(8)
        try s.execute("slice.new", ["rect": [0, 0, 20, 20], "name": "logo", "url": "https://example.org", "target": "x\" onclick=\"alert(1)",
                                    "alt": "x\" onerror=\"alert(1)"])
        for images in ["../escaped", "..\\escaped", "/absolute", "C:\\absolute", "nested/../../escaped", "/"] {
            #expect(throws: (any Error).self, "\(images)") {
                try s.execute("file.export.saveForWebLegacy", ["format": "gif", "dir": .string(dir), "html": true, "imagesFolder": .string(images)])
            }
        }
        #expect(!exists("\(root)/escaped"))
        let (folder, escapedFolder) = ("nested/im\" onerror=\"alert(1)&", "nested/im&quot; onerror=&quot;alert(1)&amp;")
        let r = try s.execute("file.export.saveForWebLegacy", ["format": "gif", "dir": .string(dir), "html": true, "imagesFolder": .string(folder)])
        let page = try read(try #require(r["html"]?.stringValue))
        #expect(page.contains("src=\"\(escapedFolder)/logo.gif\""))
        #expect(page.contains("src=\"\(escapedFolder)/spacer.gif\""))
        #expect(page.contains("alt=\"x&quot; onerror=&quot;alert(1)\""))
        #expect(!page.contains("onerror=\"alert(1)\""))
        #expect(!page.contains("onclick=\"alert(1)\""))
        #expect(exists("\(dir)/\(folder)/spacer.gif"))
    }

    @Test func imagesFolderRejectsExistingSymlinkOutsideExportDirectory() throws {
        let dir = try tmp("slice-image-symlink")
        let outside = try tmp("slice-image-outside")
        defer {
            try? FileManager.default.removeItem(atPath: dir)
            try? FileManager.default.removeItem(atPath: outside)
        }
        try FileManager.default.createSymbolicLink(atPath: "\(dir)/linked", withDestinationPath: outside)
        let s = try session(8)
        try s.execute("slice.new", ["rect": [0, 0, 20, 20], "name": "logo"])
        #expect(throws: (any Error).self) {
            try s.execute("file.export.saveForWebLegacy", ["format": "gif", "dir": .string(dir), "html": true, "imagesFolder": "linked"])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside).isEmpty)
    }

    @Test func exportPreferencesDriveQuickExport() throws {
        let dir = try tmp("quick")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = try session(8)
        let r = try s.execute("file.export.exportPreferences", ["quickExportFormat": "jpg", "jpegQuality": 40, "quickExportLocation": "sameFolder"])
        #expect(r["values"]?["quickExportFormat"] == "jpg")
        #expect(throws: (any Error).self) { try s.execute("file.export.exportPreferences", ["quickExportFormat": "bmp"]) }
        // Unsaved document: a path is needed.
        #expect(throws: (any Error).self) { try s.execute("file.export.quickExport") }
        try s.updateActive { $0.path = "\(dir)/web.psd" }
        let r2 = try s.execute("file.export.quickExport")
        #expect(r2["path"] == .string("\(dir)/web.jpg"))
        #expect(try dims("\(dir)/web.jpg") == (64, 48))
        try s.execute("file.export.exportPreferences", ["quickExportFormat": "gif"])
        let r3 = try s.execute("file.export.quickExport", ["path": .string("\(dir)/x.gif")])
        #expect(r3["format"] == "gif")
        #expect(try Data(contentsOf: URL(fileURLWithPath: "\(dir)/x.gif")).starts(with: Data("GIF89a".utf8)))
        try s.execute("prefs.reset", ["path": "export"])
    }

    @Test func webpExportPreferencesSelectLosslessOrLossyOutput() throws {
        let dir = try tmp("quick_webp_quality")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = try session(8)
        #expect(s.preferences["export.webpLossless"] == true, "existing Quick Export defaults to lossless WebP")
        #expect(s.preferences["export.webpQuality"] == 85)
        let r = try s.execute("file.export.exportPreferences", ["quickExportFormat": "webp", "webpLossless": true, "webpQuality": 40])
        #expect(r["values"]?["webpLossless"] == true)
        #expect(r["values"]?["webpQuality"] == 40)
        func bytes(_ p: String) throws -> [UInt8] { [UInt8](try Data(contentsOf: URL(fileURLWithPath: p))) }
        func has(_ b: [UInt8], _ tag: String) -> Bool { let t = Array(tag.utf8); return b.count >= 4 && (0...(b.count - 4)).contains { Array(b[$0..<$0 + 4]) == t } }
        let lossless = "\(dir)/lossless.webp"
        try s.execute("file.export.quickExport", ["path": .string(lossless)])
        let l = try bytes(lossless)
        #expect(l.starts(with: Array("RIFF".utf8)) && Array(l[8..<12]) == Array("WEBP".utf8))
        #expect(has(l, "VP8L"), "lossless WebP should use VP8L")
        #expect(try dims(lossless) == (64, 48))
        try s.execute("file.export.exportPreferences", ["webpLossless": false])
        let lowPath = "\(dir)/lossy40.webp"
        try s.execute("file.export.quickExport", ["path": .string(lowPath)])
        let low = try bytes(lowPath)
        #expect(has(low, "VP8 "), "lossy WebP should contain a VP8 frame")
        #expect(try dims(lowPath) == (64, 48))
        try s.execute("file.export.exportPreferences", ["webpQuality": 90])
        let highPath = "\(dir)/lossy90.webp"
        try s.execute("file.export.quickExport", ["path": .string(highPath)])
        let high = try bytes(highPath)
        #expect(has(high, "VP8 "))
        #expect(low != high, "changing WebP quality should change the encoded image")
        let before = s.preferences["export.webpQuality"]
        for q in [0, 101] {
            #expect(throws: (any Error).self) { try s.execute("file.export.exportPreferences", ["webpQuality": .int(q)]) }
            #expect(s.preferences["export.webpQuality"] == before)
        }
    }

    @Test func generatorNamingGrammar() {
        let a = W.parseAssetName("200% foo@2x.png, 48x48 icons/bar.png8 + photo.jpg8", 72)
        #expect(a.count == 3)
        #expect(a[0].file == "foo@2x.png" && a[0].format == "png32" && a[0].scale == 2)
        #expect(a[1].file == "icons/bar.png" && a[1].format == "png8" && a[1].width == 48 && a[1].height == 48)
        #expect(a[2].file == "photo.jpg" && a[2].quality == 80)
        let b = W.parseAssetName("?x100 thumb.jpg50%", 72)
        #expect(b.first?.width == nil && b.first?.height == 100 && b.first?.quality == 50)
        let c = W.parseAssetName("1in x 2cm label.gif", 300)
        #expect(c.first?.width == 300)
        #expect(abs((c.first?.height ?? 0) - 236.22) < 0.01)
        #expect(W.parseAssetName("Layer 1", 72).isEmpty)
        #expect(W.parseAssetName("notes.txt", 72).isEmpty)
        #expect(W.parseAssetName("x.jpgq", 72).isEmpty)
        let d = W.parseDefaults("default 50% low/ + 200% @2x", 72)
        #expect(d == [W.AssetDefault(scale: 0.5, folder: "low/"), W.AssetDefault(scale: 2, suffix: "@2x")])
        #expect(W.parseDefaults("defaults are nice", 72) == nil)
    }

    @Test func imageAssetsAreGeneratedNowAndOnSave() throws {
        let dir = try tmp("assets")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = try session(8)
        let id = try #require(s.active?.activeLayer)
        try s.execute("layer.renameLayer", ["layer": .id(id), "name": "logo.png, 50% small/logo.gif, logo.jpg80%"])
        let r = try s.execute("file.generate.imageAssets", ["dir": .string(dir)])
        #expect(r["enabled"] == true)
        #expect(r["files"]?.arrayValue?.count == 3, "\(r)")
        // Trimmed to the layer's pixels (x 0..64, y 8..48).
        #expect(try dims("\(dir)/logo.png") == (64, 40))
        #expect(try dims("\(dir)/small/logo.gif") == (32, 20))
        #expect(try dims("\(dir)/logo.jpg") == (64, 40))
        // On save: written to <name>-assets next to the file.
        try s.updateActive { $0.path = "\(dir)/doc.psd" }
        let saved = try #require(W.onSaved(s, 0))
        #expect(saved["dir"] == .string("\(dir)/doc-assets"))
        #expect(exists("\(dir)/doc-assets/logo.png"))
        // Off: nothing on save.
        #expect(try s.execute("file.generate.imageAssets")["enabled"] == false)
        #expect(W.onSaved(s, 0) == nil)
        // A default layer adds variants.
        var d = try #require(try session(8).active).doc
        d.layers.append(Layer(name: "default 200% @2x", content: .group(LayerGroup(children: [], expanded: false, artboard: nil))))
        let lid = d.layers[1].id
        d.updateLayer(lid) { $0.name = "icon.png" }
        let (files, errors) = W.generateAssets(s, d, dir)
        #expect(errors.isEmpty, "\(errors)")
        #expect(files == [FileCommands.join(dir, "icon@2x.png")])
        #expect(try dims(files[0]) == (128, 80))
    }

    @Test func imageAssetsRejectTraversalFromNamesAndDefaults() throws {
        let base = try tmp("asset-path-guard")
        let outside = try tmp("asset-path-outside")
        defer {
            try? FileManager.default.removeItem(atPath: base)
            try? FileManager.default.removeItem(atPath: outside)
        }
        let dir = "\(base)/output"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let s = Session()
        var d = try #require(try session(8).active).doc
        let id = d.layers[1].id
        d.updateLayer(id) { $0.name = "nested/ok.png, ../escaped.png, ..\\backslash.png, \(outside)/absolute.png, C:\\drive\\escape.png, CON.png, aux/escape.png, foo./trailing.png" }
        var (files, errors) = W.generateAssets(s, d, dir)
        #expect(files == ["\(dir)/nested/ok.png"])
        #expect(errors.count == 7, "\(errors)")
        #expect(errors.allSatisfy { $0["error"]?.stringValue?.contains("unsafe component") == true }, "\(errors)")
        #expect(!exists("\(base)/escaped.png"))
        #expect(!exists("\(outside)/absolute.png"))
        d.updateLayer(id) { $0.name = "safe.png" }
        d.layers.append(Layer(name: "default ../ + /outside/ + ..\\bad/ + C:\\drive/ + 50% nested/",
                              content: .group(LayerGroup(children: [], expanded: false, artboard: nil))))
        (files, errors) = W.generateAssets(s, d, dir)
        #expect(files == ["\(dir)/nested/safe.png"])
        #expect(errors.count == 4, "\(errors)")
        #expect(errors.allSatisfy { $0["error"]?.stringValue?.contains("unsafe component") == true }, "\(errors)")
    }

    @Test func imageAssetsRejectExistingSymlinksInFoldersAndFiles() throws {
        let dir = try tmp("asset-symlink-guard")
        let outside = try tmp("asset-symlink-outside")
        defer {
            try? FileManager.default.removeItem(atPath: dir)
            try? FileManager.default.removeItem(atPath: outside)
        }
        let fm = FileManager.default
        let sentinel = "\(outside)/sentinel.png"
        try Data("unchanged".utf8).write(to: URL(fileURLWithPath: sentinel))
        let webpSentinel = "\(outside)/sentinel.webp"
        try Data("also unchanged".utf8).write(to: URL(fileURLWithPath: webpSentinel))
        try fm.createSymbolicLink(atPath: "\(dir)/linked", withDestinationPath: outside)
        try fm.createSymbolicLink(atPath: "\(dir)/leaf.png", withDestinationPath: sentinel)
        try fm.createSymbolicLink(atPath: "\(dir)/leaf.webp", withDestinationPath: webpSentinel)
        let s = Session()
        var d = try #require(try session(8).active).doc
        let id = d.layers[1].id
        d.updateLayer(id) { $0.name = "linked/new/sub.png, leaf.png, leaf.webp, good/safe.png" }
        var (files, errors) = W.generateAssets(s, d, dir)
        #expect(files == ["\(dir)/good/safe.png"])
        #expect(errors.count == 3, "\(errors)")
        #expect(errors.allSatisfy { $0["error"]?.stringValue?.contains("symlink") == true }, "\(errors)")
        #expect(!exists("\(outside)/new"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: sentinel)) == Data("unchanged".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: webpSentinel)) == Data("also unchanged".utf8))
        let linkedRoot = "\(dir)/rootlink"
        try fm.createSymbolicLink(atPath: linkedRoot, withDestinationPath: outside)
        d.updateLayer(id) { $0.name = "root.png" }
        (files, errors) = W.generateAssets(s, d, "\(linkedRoot)/")
        #expect(errors.isEmpty, "\(errors)")
        #expect(files == ["\(linkedRoot)/root.png"])
        #expect(exists("\(outside)/root.png"))
        let t = try session(8)
        let exported = try t.execute("file.export.saveForWebLegacy", ["dir": .string(linkedRoot), "format": "png24", "html": true])
        #expect(exported["html"]?.stringValue?.hasSuffix("/rootlink/web.html") == true)
        #expect(exists("\(outside)/web.html"))
    }

    @Test func webSettingsFromParams() throws {
        let st = try W.Settings.fromParams(["preset": "GIF 32 No Dither", "matte": "none", "webSnap": 50], "x")
        #expect(st.format == .gif && st.colors == 32 && st.dither == .none && st.matte == nil)
        #expect(abs(st.webSnap - 0.5) < 1e-6)
        #expect(throws: (any Error).self) { try W.Settings.fromParams(["preset": "Nope"], "x") }
        #expect(throws: (any Error).self) { try W.Settings.fromParams(["palette": "weird"], "x") }
        for p in W.presets {
            let st = try #require(W.presetSettings(p))
            #expect(try W.Settings.fromParams(st.toParams(), "x") == st, "\(p) round-trips through params")
        }
    }

    @Test func previewsShowTheOptimisedPixels() throws {
        let s = try session(8)
        let doc = try #require(s.active).doc
        let (wd, _, _) = try W.webDocument(s, doc, [:], W.Settings())
        let buf = try W.flatten(s, wd)
        for f in ["jpeg", "gif", "png8", "png24", "wbmp"] {
            let st = try W.Settings.fromParams(["format": .string(f), "quality": 90, "transparency": false], "x")
            let o = try W.optimize(buf, 64, wd.bounds, st, icc: nil, xmp: nil, dpi: 72, preview: true)
            #expect(o.preview.count == 64 * 48 * 4, "\(f)")
            // Red square centre stays red (WBMP: dark).
            let i = (16 * 64 + 16) * 4
            let px = Array(o.preview[i..<i + 4])
            if f == "wbmp" {
                #expect(px[0] == 0)
            } else {
                #expect(px[0] > 200 && px[1] < 60 && px[2] < 60, "\(f): \(px)")
            }
            let none = try W.optimize(buf, 64, wd.bounds, st, icc: nil, xmp: nil, dpi: 72, preview: false)
            #expect(none.preview.isEmpty)
            #expect(none.bytes == o.bytes)
        }
    }

    @Test func jpegPreviewAtOddSizes() throws {
        for (w, h, q) in [(640, 431, 90), (640, 430, 60), (333, 222, 30)] {
            let px: [SIMD4<Float>] = (0..<w * h).map { i in SIMD4(Float(i % w) / Float(w), 0.3, Float(i / w) / Float(h), 1) }
            let st = try W.Settings.fromParams(["format": "jpeg", "quality": .int(q)], "x")
            let o = try W.optimize(px, w, PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h)), st, icc: nil, xmp: nil, dpi: 72, preview: true)
            for (x, y) in [(10, 10), (w - 10, h / 2), (w / 2, h - 5)] {
                let i = (y * w + x) * 4
                let want = [Int(Float(x) / Float(w) * 255), 76, Int(Float(y) / Float(h) * 255)]
                for c in 0..<3 {
                    #expect(abs(Int(o.preview[i + c]) - want[c]) < 12, "\(w)x\(h) at \(x),\(y): \(Array(o.preview[i..<i + 4])) vs \(want)")
                }
            }
        }
    }

    @Test func slicesWithTheSameNameGetDistinctFiles() throws {
        // #908: two slices named `tile` (and names that sanitize alike) used to overwrite each other.
        let dir = try tmp("dupes")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = try session(8)
        try s.execute("slice.new", ["rect": [0, 0, 10, 10], "name": "tile"])
        try s.execute("slice.new", ["rect": [20, 0, 10, 10], "name": "tile"])
        try s.execute("slice.new", ["rect": [40, 0, 10, 10], "name": "a/b"])
        try s.execute("slice.new", ["rect": [0, 20, 10, 10], "name": "a?b"])
        try s.execute("slice.new", ["rect": [20, 20, 10, 10], "name": "spacer"])
        let r = try s.execute("file.export.saveForWebLegacy", ["format": "gif", "dir": .string(dir), "slices": "user", "html": true])
        let files = (r["files"]?.arrayValue?.compactMap { $0.stringValue?.split(separator: "/").last.map(String.init) } ?? []).sorted()
        #expect(files == ["a_b.gif", "a_b_2.gif", "spacer_2.gif", "tile.gif", "tile_2.gif"])
        let html = try read(try #require(r["html"]?.stringValue))
        #expect(html.contains("images/tile.gif") && html.contains("images/tile_2.gif"))
    }

    @Test func overlappingSlicesKeepTheLaterSliceInHtml() throws {
        // #909: the later slice is on top; the earlier one shows only where it isn't covered.
        let dir = try tmp("overlap")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = try session(8)
        try s.execute("slice.new", ["rect": [0, 0, 40, 30], "name": "under", "url": "https://example.org/under"])
        try s.execute("slice.new", ["rect": [20, 15, 40, 30], "name": "over", "url": "https://example.org/over"])
        let r = try s.execute("file.export.saveForWebLegacy", ["format": "png24", "dir": .string(dir), "html": true])
        let html = try read(try #require(r["html"]?.stringValue))
        #expect(html.contains("https://example.org/over"), "the later slice's cell is in the table")
        #expect(html.contains("https://example.org/under"))
        let files = r["files"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let over = try #require(files.first { $0.hasSuffix("images/over.png") })
        #expect(try dims(over) == (40, 30))
        // The visible pieces of every image tile the canvas exactly once.
        let area = try files.filter { !$0.hasSuffix("spacer.gif") }.reduce(0) { acc, f in let d = try dims(f); return acc + d.0 * d.1 }
        #expect(area == 64 * 48)
        #expect(files.contains { $0.hasSuffix("images/under_01.png") }, "the covered slice is cut into pieces: \(files)")
    }

    /// Not a photocraft test: the GIF / WBMP / indexed PNG writers decode back to their input.
    @Test func webCodecsRoundTrip() throws {
        let pal: [SIMD3<UInt8>] = [SIMD3(255, 0, 0), SIMD3(0, 255, 0), SIMD3(0, 0, 255)]
        let idx: [UInt8] = (0..<35).map { UInt8($0 % 3) }
        for interlaced in [false, true] {
            let gif = try W.Codec.encodeGifIndexed(5, 7, idx, pal, transparent: 2, interlaced: interlaced)
            let (w, h, px) = try decode(gif)
            #expect(w == 5 && h == 7)
            for i in 0..<35 {
                let c = pal[Int(idx[i])]
                if idx[i] == 2 { #expect(px[i * 4 + 3] == 0) } else { #expect(Array(px[i * 4..<i * 4 + 3]) == [c.x, c.y, c.z], "\(i)") }
            }
        }
        let png = try W.Codec.encodePngIndexed(5, 7, idx, pal, transparent: nil, dpi: (300, 300))
        let (_, _, ppx) = try decode(png)
        #expect(Array(ppx[4..<8]) == [0, 255, 0, 255])
        let white = (0..<21).map { $0 % 2 == 0 }
        let wb = try W.Codec.encodeWbmp(7, 3, white)
        let (ww, wh, back) = try W.Codec.decodeWbmp(wb)
        #expect(ww == 7 && wh == 3 && back == white)
        #expect(throws: (any Error).self) { try W.Codec.encodeGifIndexed(2, 2, [0, 0, 0, 3], pal, transparent: nil, interlaced: false) }
    }
}
