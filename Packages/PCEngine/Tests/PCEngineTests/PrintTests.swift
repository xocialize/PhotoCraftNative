// Port of photocraft-engine (crates/engine/src/print_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Every photocraft test is ported. Nothing reaches a real printer: prints are dry runs, PDF
// outputs, or go through `PrintCommands.doPrint` with a test spooler. `package_copies_links_and_relinks`
// builds its linked smart object in the model (`file.placeLinked` is FileCommands'), and the
// symlink test drives `privateSpoolPDF(_:in:)` directly.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCIOCore
import PCPlatform
import Testing

@Suite struct PrintTests {
    typealias P = PrintCommands

    func tmp(_ name: String) throws -> String {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("photocraft-print-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.path
    }

    func session(_ mode: String, _ depth: Int) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 300, "height": 150, "mode": .string(mode), "depth": .int(depth), "name": "Print Me.psd", "background": "#3366cc"])
        return s
    }

    func find(_ h: [UInt8], _ n: String, _ from: Int) throws -> Int {
        let needle = Array(n.utf8)
        var i = from
        while i + needle.count <= h.count {
            if Array(h[i..<i + needle.count]) == needle { return i }
            i += 1
        }
        throw EngineError.other("`\(n)` not found")
    }

    /// The (inflated) image stream of a print PDF: (width, height, colour space, samples).
    func pdfImage(_ pdf: [UInt8]) throws -> (Int, Int, String, [UInt8]) {
        let i = try find(pdf, "/Subtype /Image", 0)
        let end = try find(pdf, ">>\nstream\n", i)
        let dict = String(decoding: pdf[i..<end], as: UTF8.self)
        func num(_ k: String) -> Int { Int(dict.components(separatedBy: k)[1].split(separator: " ").first ?? "") ?? -1 }
        let cs = dict.components(separatedBy: "/ColorSpace ")[1].components(separatedBy: " /BitsPerComponent")[0]
        let len = num("/Length ")
        let start = end + 10
        let data = try Deflate.zlibInflate(Array(pdf[start..<start + len]))
        return (num("/Width "), num("/Height "), cs, data)
    }

    /// The inflated page content stream (object 4).
    func pdfContent(_ pdf: [UInt8]) throws -> String {
        let i = try find(pdf, "4 0 obj\n", 0)
        let lenAt = try find(pdf, "/Length ", i) + 8
        let len = Int(String(decoding: pdf[lenAt..<lenAt + 12], as: UTF8.self).split(separator: " ").first ?? "") ?? 0
        let start = try find(pdf, "stream\n", i) + 7
        return String(decoding: try Deflate.zlibInflate(Array(pdf[start..<start + len])), as: UTF8.self)
    }

    func read(_ path: String) throws -> [UInt8] { [UInt8](try Data(contentsOf: URL(fileURLWithPath: path))) }

    @Test func printDryRunRendersAPdfAndReportsLp() throws {
        let dir = try tmp("print")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for depth in [8, 16, 32] {
            let s = try session("rgb", depth)
            let out = "\(dir)/rgb-\(depth).pdf"
            let r = try s.execute("file.print", ["output": .string(out), "send": true, "dryRun": true, "printer": "Office", "copies": 2, "paper": "a4",
                                                 "cornerCropMarks": true, "registrationMarks": true, "labels": true])
            let cmd = r["command"]?.arrayValue?.compactMap(\.stringValue) ?? []
            #expect(Array(cmd.prefix(5)) == ["lp", "-d", "Office", "-n", "2"])
            #expect(cmd.last == out)
            #expect(r["sent"] == false)
            #expect(r["pdf"]?.stringValue == out)
            let pdf = try read(out)
            #expect(pdf.starts(with: Array("%PDF-1.4".utf8)))
            #expect(String(decoding: pdf, as: UTF8.self).contains("/MediaBox [0 0 595.28 841.89]"))
            let (w, h, cs, data) = try pdfImage(pdf)
            #expect(w == 300 && h == 150)
            #expect(cs == "/DeviceRGB")
            #expect(Array(data.prefix(3)) == [0x33, 0x66, 0xcc], "depth \(depth)")
            // 300 px at 72 ppi = 300 pt, centred.
            let rect = r["imageRect"]?.arrayValue?.compactMap(\.doubleValue) ?? []
            #expect(rect.count == 4 && abs(rect[2] - 300) < 1e-6 && abs(rect[0] - (595.28 - 300) / 2) < 1e-6)
        }
        // Print to PDF: no spooling by default.
        let s = try session("gray", 8)
        let out = "\(dir)/out.pdf"
        let r = try s.execute("file.print", ["output": .string(out), "scaleToFit": true, "orientation": "landscape"])
        #expect(r["sent"] == false)
        #expect(r["command"] == .null)
        #expect(try pdfImage(try read(out)).2 == "/DeviceGray")
        let scale = r["scale"]?.doubleValue ?? 0
        #expect(scale > 200, "fit to a landscape letter page: \(scale)")
        #expect(throws: (any Error).self) { try s.execute("file.print", ["paper": "napkin", "dryRun": true]) }
        #expect(throws: (any Error).self, "needs a printer profile") { try s.execute("file.print", ["colorHandling": "photocraftManages", "dryRun": true]) }
    }

    @Test func photocraftManagesColorsConvertsToThePrinterProfile() throws {
        let s = try session("rgb", 8)
        let dir = try tmp("managed")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = "\(dir)/managed.pdf"
        let r = try s.execute("file.print", ["output": .string(out), "dryRun": true, "colorHandling": "photocraftManages", "printerProfile": "coated-cmyk",
                                             "intent": "perceptual", "bpc": false])
        #expect(r["color"]?["intent"] == "perceptual")
        let pdf = try read(out)
        let (_, _, cs, data) = try pdfImage(pdf)
        #expect(cs == "[/ICCBased 7 0 R]")
        #expect(String(decoding: pdf, as: UTF8.self).contains("/N 4 /Alternate /DeviceCMYK"))
        #expect(data.count == 300 * 150 * 4)
        // Blue: lots of cyan, little yellow.
        #expect(data[0] > 150 && data[2] < 60, "\(Array(data.prefix(4)))")
        // The document itself is untouched.
        #expect(s.active?.doc.mode == .rgb)
    }

    @Test func emulsionDownMirrorsTheWholePage() throws {
        let s = try session("rgb", 8)
        let dir = try tmp("emulsion")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let base: [String: JSONValue] = ["dryRun": true, "paper": "a4", "center": false, "left": 1.0, "top": 1.0, "labels": true]
        var p1 = base
        p1["output"] = .string("\(dir)/plain.pdf")
        var p2 = base
        p2["output"] = .string("\(dir)/mirrored.pdf")
        p2["emulsionDown"] = true
        let plain = try s.execute("file.print", .object(p1))
        let mirrored = try s.execute("file.print", .object(p2))
        #expect(plain["emulsionDown"] == false)
        #expect(mirrored["emulsionDown"] == true)
        // Same layout; only the page is flipped.
        #expect(plain["imageRect"] == mirrored["imageRect"])
        let (p, m) = (try read("\(dir)/plain.pdf"), try read("\(dir)/mirrored.pdf"))
        let (pc, mc) = (try pdfContent(p), try pdfContent(m))
        #expect(!pc.contains("-1 0 0 1"))
        // The flip wraps the image and the label, after the white paper, and is closed again.
        let flip = try #require(mc.range(of: "q -1 0 0 1 595.28 0 cm")?.lowerBound)
        let paper = try #require(mc.range(of: "re f Q")?.lowerBound)
        let image = try #require(mc.range(of: "/Im0 Do")?.lowerBound)
        let text = try #require(mc.range(of: "Tj")?.lowerBound)
        #expect(flip > paper && flip < image && flip < text)
        let opens = mc.components(separatedBy: "q ").count - 1 + mc.components(separatedBy: "q\n").count - 1
        #expect(opens == mc.components(separatedBy: "Q\n").count - 1, "balanced q/Q: \(mc)")
        // The pixels themselves are not touched (the transform mirrors them).
        #expect(try pdfImage(p).3 == pdfImage(m).3)
        // Print One Copy keeps it.
        let again = try s.execute("file.printOneCopy", ["output": .string("\(dir)/again.pdf"), "dryRun": true])
        #expect(again["emulsionDown"] == true)
    }

    @Test func printerProfileCanBeAnInstalledIccFile() throws {
        let dir = try tmp("icc")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let icc = "\(dir)/My Paper.icc"
        try BuiltinProfile.coatedCMYK.profile.data.write(to: URL(fileURLWithPath: icc))
        let s = try session("rgb", 16)
        let r = try s.execute("file.print", ["output": .string("\(dir)/managed.pdf"), "dryRun": true, "colorHandling": "photocraftManages",
                                             "printerProfile": .string(icc), "emulsionDown": true])
        #expect(r["color"]?["printerProfile"] == .string(icc))
        let (_, _, cs, data) = try pdfImage(try read(try #require(r["pdf"]?.stringValue)))
        #expect(cs == "[/ICCBased 7 0 R]")
        #expect(data.count == 300 * 150 * 4)
        #expect(throws: (any Error).self) {
            try s.execute("file.print", ["dryRun": true, "colorHandling": "photocraftManages", "printerProfile": .string("\(dir)/missing.icc")])
        }
    }

    @Test func printOneCopyRepeatsTheLastSettings() throws {
        let s = try session("rgb", 8)
        let first = try s.execute("file.print", ["dryRun": true, "copies": 3, "paper": "a5", "scale": 50])
        #expect(first["pdf"] == .null)
        let r = try s.execute("file.printOneCopy", ["dryRun": true])
        #expect(r["copies"] == 1)
        #expect(r["paper"] == .doubles([419.53, 595.28]))
        #expect(r["scale"] == 50)
        let cmd = r["command"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(!cmd.contains("-n"))
        #expect(cmd.last == "<temporary PDF>")
        #expect(r["pdf"] == .null)
    }

    @Test func printWithoutOutputKeepsPrivatePdfOnlyDuringSpooling() throws {
        let s = try session("rgb", 8)
        var temporary: String?
        let result = try P.doPrint(s, [:], "file.print") { argv in
            let path = try #require(argv.last)
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(data.starts(with: Data("%PDF-1.4".utf8)))
            let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
            #expect((perms?.intValue ?? 0o777) & 0o077 == 0)
            temporary = path
            return "request id 1"
        }
        #expect(result["sent"] == true)
        #expect(result["pdf"] == .null, "the temporary path must not be advertised as a retained PDF")
        #expect(!FileManager.default.fileExists(atPath: try #require(temporary)), "spool PDF survives after lp returns")
    }

    @Test func printSpoolErrorRemovesPrivatePdf() throws {
        let s = try session("rgb", 8)
        var temporary: String?
        #expect(throws: (any Error).self) {
            try P.doPrint(s, [:], "file.print") { argv in
                let path = argv.last ?? ""
                #expect(FileManager.default.fileExists(atPath: path))
                temporary = path
                throw EngineError.other("spooler unavailable")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: try #require(temporary)), "spool PDF survives a failed lp call")
    }

    @Test func privateSpoolPdfDoesNotFollowAGuessedSymlink() throws {
        let dir = try tmp("symlink")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let victim = "\(dir)/victim.pdf"
        let link = "\(dir)/photocraft-print-AAAAAAAA.pdf"
        try Data("keep this".utf8).write(to: URL(fileURLWithPath: victim))
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: victim)
        let path = try P.privateSpoolPDF(Array("%PDF-private".utf8), in: dir)
        #expect(path != link)
        #expect(try Data(contentsOf: URL(fileURLWithPath: victim)) == Data("keep this".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("%PDF-private".utf8))
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeRegular)
        unlink(path)
        #expect((try FileManager.default.attributesOfItem(atPath: link)[.type] as? FileAttributeType) == .typeSymbolicLink)
    }

    @Test func printDryRunWithoutOutputCreatesNoSpoolPdf() throws {
        let s = try session("rgb", 8)
        let result = try P.doPrint(s, ["dryRun": true], "file.print") { _ in throw EngineError.other("dry run invoked spooler") }
        #expect(result["pdf"] == .null)
        #expect(result["sent"] == false)
        #expect(result["command"]?.arrayValue?.last == "<temporary PDF>")
        #expect((result["bytes"]?.intValue ?? 0) > 100)
    }

    @Test func printWithoutSendingRequiresAnOutputUnlessDryRun() throws {
        let s = try session("rgb", 8)
        let before = s.state[P.LastPrintKey.self]
        do {
            _ = try P.doPrint(s, ["send": false], "file.print") { _ in throw EngineError.other("unexpected spooler call") }
            Issue.record("send: false without an output must fail")
        } catch {
            #expect("\(error)".contains("needs an output path"), "\(error)")
        }
        #expect(s.state[P.LastPrintKey.self] == before, "a rejected print must not become a remembered successful print")
        _ = try P.doPrint(s, ["send": false, "dryRun": true], "file.print") { _ in throw EngineError.other("dry run invoked spooler") }
        #expect(s.state[P.LastPrintKey.self]?["send"] == nil)

        let dir = try tmp("non-sending-export")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let output = "\(dir)/export.pdf"
        _ = try P.doPrint(s, ["output": .string(output), "send": false], "file.print") { _ in throw EngineError.other("non-sending export invoked spooler") }
        #expect(FileManager.default.fileExists(atPath: output))
        var repeatP = try #require(s.state[P.LastPrintKey.self]?.objectValue)
        #expect(repeatP["send"] == nil, "a removed output must not leave send: false in remembered settings")
        repeatP["copies"] = 1
        let replay = try P.doPrint(s, .object(repeatP), "file.printOneCopy") { argv in
            #expect(FileManager.default.fileExists(atPath: argv.last ?? ""))
            return "request id 2"
        }
        #expect(replay["sent"] == true)
        #expect(replay["copies"] == 1)

        let both = "\(dir)/print-and-export.pdf"
        _ = try P.doPrint(s, ["output": .string(both), "send": true, "dryRun": true], "file.print") { _ in throw EngineError.other("dry run invoked spooler") }
        #expect(s.state[P.LastPrintKey.self]?["send"] == nil, "a removed output must not leave send: true in remembered settings")
    }

    @Test func packageCopiesLinksAndRelinks() throws {
        let dir = try tmp("package")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let link = "\(dir)/art.png"
        let src = Session()
        try src.execute("file.new", ["width": 20, "height": 20, "background": "#ff0000"])
        try src.saveDocument(to: link)
        let s = try session("rgb", 8)
        try s.edit("place linked") { doc, active in
            let fmt = doc.pixelFormat
            var cache = Surface(format: fmt)
            cache.fill(PixelRect(x0: 0, y0: 0, x1: 20, y1: 20), with: PixelCodec.fromRGBA(fmt, SIMD4(1, 0, 0, 1)))
            let so = SmartObject(source: .linked(path: link), transform: .identity, cache: cache)
            let id = doc.insertAbove(active, Layer(name: "art", content: .smart(so)))
            active = id
        }
        let r = try s.execute("file.package", ["dir": .string("\(dir)/pkg")])
        let copied = "\(dir)/pkg/Print Me/Links/art.png"
        #expect(r["links"] == .strings([copied]))
        #expect(FileManager.default.fileExists(atPath: copied))
        let docp = try #require(r["document"]?.stringValue)
        #expect(docp.hasSuffix("Print Me/Print Me.pcraft"))
        let back = try EngineIO.importPath(docp, services: s.services).document
        let linked: [String] = back.walk().compactMap { e in
            guard case .smart(let so) = e.layer.content, case .linked(let path) = so.source else { return nil }
            return path
        }
        #expect(linked.count == 1)
        #expect(linked.first?.hasSuffix("Links/art.png") == true, "\(linked)")
        // The open document still points at the original.
        let open = try #require(s.active).doc
        #expect(open.walk().contains { e in
            if case .smart(let so) = e.layer.content, case .linked(let path) = so.source { return path == link }
            return false
        })
        // As a PSD package too (for the Photoshop oracle).
        let r2 = try s.execute("file.package", ["dir": .string("\(dir)/pkg-psd"), "format": "psd"])
        let psd = try #require(r2["document"]?.stringValue)
        #expect(psd.hasSuffix("Print Me/Print Me.psd"))
        dropForOracle(URL(fileURLWithPath: psd), as: "print-package.psd")
        #expect(throws: (any Error).self) { try s.execute("file.package", ["dir": .string(dir), "format": "tiff"]) }
    }

    @Test func pathsExportAsIllustratorPostScript() throws {
        let s = try session("rgb", 8)
        #expect(!s.isEnabled("file.export.pathsToIllustrator"))
        try s.edit("paths") { d, _ in
            let tri = Subpath.polygon([(10, 10), (100, 10), (50, 90)])
            var curve = Subpath.polyline([(0, 0), (300, 150)])
            curve.knots[0] = Knot.smooth(anchor: PCPoint(0, 0), inCtrl: PCPoint(0, 0), outCtrl: PCPoint(50, 0))
            d.paths.append(NamedPath(name: "Shapes", path: VectorPath([tri, curve])))
        }
        let r = try s.execute("file.export.pathsToIllustrator")
        let ai = try #require(r["ai"]?.stringValue)
        #expect(ai.hasPrefix("%!PS-Adobe-2.0 EPSF-1.2"))
        #expect(ai.contains("%%BoundingBox: 0 0 300 150"))
        #expect(ai.contains("*u\n10.0000 140.0000 m\n100.0000 140.0000 L\n"), "\(ai)")
        #expect(ai.contains("\nn\n") && ai.contains("\nN\n*U\n"))
        #expect(ai.contains(" C\n"), "curve segment")
        let dir = try tmp("ai")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let r2 = try s.execute("file.export.pathsToIllustrator", ["path": .string("\(dir)/p.ai"), "paths": "Shapes"])
        #expect(r2["paths"] == 1)
        #expect(throws: (any Error).self) { try s.execute("file.export.pathsToIllustrator", ["paths": "Nope"]) }
    }

    /// Not a photocraft test: the one-page PDF's cross-reference offsets point at its objects.
    @Test func printPdfXrefOffsetsPointAtObjects() throws {
        let page = P.PrintPage(paper: (612, 792), image: P.PrintImage(width: 2, height: 1, channels: 3, data: [255, 0, 0, 0, 0, 255], icc: nil),
                               rect: (10, 10, 20, 10), marks: P.Marks(cornerCrop: true, centerCrop: true, registration: true),
                               description: "a (note)", label: "lab\\el", emulsionDown: false)
        let pdf = P.printPDF(page)
        let text = String(decoding: pdf.map { $0 < 0x80 ? $0 : 0x3F }, as: UTF8.self)
        let xref = try #require(text.range(of: "\nxref\n", options: .backwards))
        let lines = text[text.index(after: xref.lowerBound)...].split(separator: "\n", omittingEmptySubsequences: false)
        let offsets = lines.dropFirst(3).prefix(6).compactMap { Int($0.prefix(10)) }
        #expect(offsets.count == 6)
        for (i, o) in offsets.enumerated() {
            #expect(String(decoding: pdf[o..<min(o + 12, pdf.count)], as: UTF8.self).hasPrefix("\(i + 1) 0 obj"), "object \(i + 1)")
        }
        let content = try pdfContent(pdf)
        #expect(content.contains("(a \\(note\\)) Tj") && content.contains("(lab\\\\el) Tj"))
    }
}
