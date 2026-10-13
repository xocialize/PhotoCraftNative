// Port of photocraft-engine (crates/engine/src/print_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// File › Print…, Print One Copy, File › Package… and File › Export › Paths to Illustrator….
//
// Printing renders the flattened document into a PDF page (paper size, orientation, position,
// scale, colour handling with printer profile / intent / black-point compensation, corner and
// centre crop marks, registration marks, description and label) with a small PDF writer (ISO
// 32000: one page, a Flate-compressed image XObject, vector marks, Helvetica text), then hands it
// to the system spooler with `lp` (CUPS). `"dryRun": true` stops before spooling and reports the
// command line. Without an explicit PDF output the spool file is private (created exclusively,
// mode 0600) and removed when `lp` finishes; dry runs do not create one. Tests drive
// `doPrint(_:_:_:spooler:)` with their own spooler, never a real printer.
//
// Paths to Illustrator writes the document's paths as an Adobe Illustrator 3 compatible
// PostScript file (`m`/`L`/`C` path construction, `n`/`N` unpainted closed/open paths, `*u`/`*U`
// compound paths), following the public PostScript Language Reference and the AI3 format notes.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore

enum PrintCommands: CommandModule {
    static let name = "print_cmds"
    static let m = name

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }
    static func other(_ msg: String) -> EngineError { .other(msg) }

    /// The last Print settings, which Print One Copy repeats (photocraft `FileMenuState::last_print`).
    enum LastPrintKey: StateKey {
        static let defaultValue: JSONValue? = nil
    }

    // MARK: PDF

    /// Paper sizes in points (portrait).
    static let papers: [(String, Double, Double)] = [
        ("letter", 612.0, 792.0), ("legal", 612.0, 1008.0), ("tabloid", 792.0, 1224.0), ("a3", 841.89, 1190.55),
        ("a4", 595.28, 841.89), ("a5", 419.53, 595.28), ("4x6", 288.0, 432.0), ("5x7", 360.0, 504.0),
    ]

    /// The image placed on a print page.
    struct PrintImage: Sendable {
        var width: Int
        var height: Int
        /// 1 (gray), 3 (RGB) or 4 (CMYK, 1 = full ink), 8-bit interleaved.
        var channels: Int
        var data: [UInt8]
        var icc: [UInt8]?
    }

    /// Printer marks around the image.
    struct Marks: Equatable, Sendable {
        var cornerCrop = false
        var centerCrop = false
        var registration = false
        var any: Bool { cornerCrop || centerCrop || registration }
    }

    /// One page: paper (pt), image box (pt, origin bottom-left), marks and texts.
    struct PrintPage: Sendable {
        var paper: (Double, Double)
        var image: PrintImage
        var rect: (Double, Double, Double, Double)
        var marks: Marks
        var description: String?
        var label: String?
        /// Functions › Emulsion Down: the whole page mirrored left to right, for transfer printing
        /// (sublimation, iron-on, DTF, film read from the back).
        var emulsionDown: Bool
    }

    static func f2(_ v: Double) -> String { String(format: "%.2f", v) }
    static func f3(_ v: Double) -> String { String(format: "%.3f", v) }

    static func pdfString(_ s: String) -> String {
        var o = "("
        for c in s.unicodeScalars {
            switch c {
            case "(", ")", "\\":
                o += "\\"
                o.unicodeScalars.append(c)
            case _ where c.isASCII && !(c.value < 0x20 || c.value == 0x7f):
                o.unicodeScalars.append(c)
            default:
                o += "?"
            }
        }
        return o + ")"
    }

    static func deflate(_ data: [UInt8]) -> [UInt8] { (try? Deflate.zlibDeflate(data)) ?? [] }

    /// Vector marks around `(x, y, w, h)`.
    static func marksOps(_ m: Marks, _ r: (Double, Double, Double, Double)) -> String {
        let (x, y, w, h) = r
        var s = "q 0 G 0.3 w\n"
        let (gap, len) = (6.0, 18.0)
        func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) { s += "\(f2(x0)) \(f2(y0)) m \(f2(x1)) \(f2(y1)) l S\n" }
        if m.cornerCrop {
            for (cx, cy, dx, dy) in [(x, y, -1.0, -1.0), (x + w, y, 1.0, -1.0), (x, y + h, -1.0, 1.0), (x + w, y + h, 1.0, 1.0)] {
                line(cx + dx * gap, cy, cx + dx * (gap + len), cy)
                line(cx, cy + dy * gap, cx, cy + dy * (gap + len))
            }
        }
        if m.centerCrop {
            let (mx, my) = (x + w / 2, y + h / 2)
            line(mx, y - gap, mx, y - gap - len)
            line(mx, y + h + gap, mx, y + h + gap + len)
            line(x - gap, my, x - gap - len, my)
            line(x + w + gap, my, x + w + gap + len, my)
        }
        if m.registration {
            let r = 5.0
            let off = gap + len / 2
            for (cx, cy) in [(x + w / 2, y - off), (x + w / 2, y + h + off), (x - off, y + h / 2), (x + w + off, y + h / 2)] {
                // Circle (four Béziers) plus crosshair.
                let k = 0.5523 * r
                s += "\(f2(cx + r)) \(f2(cy)) m \(f2(cx + r)) \(f2(cy + k)) \(f2(cx + k)) \(f2(cy + r)) \(f2(cx)) \(f2(cy + r)) c "
                    + "\(f2(cx - k)) \(f2(cy + r)) \(f2(cx - r)) \(f2(cy + k)) \(f2(cx - r)) \(f2(cy)) c "
                    + "\(f2(cx - r)) \(f2(cy - k)) \(f2(cx - k)) \(f2(cy - r)) \(f2(cx)) \(f2(cy - r)) c "
                    + "\(f2(cx + k)) \(f2(cy - r)) \(f2(cx + r)) \(f2(cy - k)) \(f2(cx + r)) \(f2(cy)) c S\n"
                line(cx - r * 1.6, cy, cx + r * 1.6, cy)
                line(cx, cy - r * 1.6, cx, cy + r * 1.6)
            }
        }
        s += "Q\n"
        return s
    }

    /// A one-page PDF.
    static func printPDF(_ page: PrintPage) -> [UInt8] {
        var out = Array("%PDF-1.4\n".utf8) + [0x25, 0xe2, 0xe3, 0xcf, 0xd3, 0x0a]
        var offsets: [Int] = []
        func obj(_ body: [UInt8]) {
            offsets.append(out.count)
            out += Array("\(offsets.count) 0 obj\n".utf8)
            out += body
            out += Array("\nendobj\n".utf8)
        }
        let img = page.image
        let (pw, ph) = page.paper
        let (x, y, w, h) = page.rect
        // 1 catalog, 2 pages, 3 page, 4 contents, 5 image, 6 font, 7 ICC (optional).
        obj(Array("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        obj(Array("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8))
        obj(Array("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(f2(pw)) \(f2(ph))] /Resources << /XObject << /Im0 5 0 R >> /Font << /F1 6 0 R >> >> /Contents 4 0 R >>".utf8))
        // An explicit white page, so every viewer (and rasteriser) shows paper, not transparency.
        var content = "q 1 g 0 0 \(f2(pw)) \(f2(ph)) re f Q\n"
        if page.emulsionDown { content += "q -1 0 0 1 \(f2(pw)) 0 cm\n" }
        content += "q \(f3(w)) 0 0 \(f3(h)) \(f3(x)) \(f3(y)) cm /Im0 Do Q\n"
        content += marksOps(page.marks, page.rect)
        let pad = page.marks.any ? 30.0 : 6.0
        if let l = page.label, !l.isEmpty { content += "BT /F1 8 Tf 0 g \(f2(x)) \(f2(y + h + pad)) Td \(pdfString(l)) Tj ET\n" }
        if let d = page.description, !d.isEmpty { content += "BT /F1 8 Tf 0 g \(f2(x)) \(f2(y - pad - 8)) Td \(pdfString(d)) Tj ET\n" }
        if page.emulsionDown { content += "Q\n" }
        let c = deflate(Array(content.utf8))
        obj(Array("<< /Length \(c.count) /Filter /FlateDecode >>\nstream\n".utf8) + c + Array("\nendstream".utf8))
        let device = switch img.channels {
        case 1: "/DeviceGray"
        case 4: "/DeviceCMYK"
        default: "/DeviceRGB"
        }
        let cs = img.icc != nil ? "[/ICCBased 7 0 R]" : device
        let z = deflate(img.data)
        obj(Array("<< /Type /XObject /Subtype /Image /Width \(img.width) /Height \(img.height) /ColorSpace \(cs) /BitsPerComponent 8 /Filter /FlateDecode /Length \(z.count) >>\nstream\n".utf8)
            + z + Array("\nendstream".utf8))
        obj(Array("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8))
        if let icc = img.icc {
            let z = deflate(icc)
            obj(Array("<< /N \(img.channels) /Alternate \(device) /Filter /FlateDecode /Length \(z.count) >>\nstream\n".utf8) + z + Array("\nendstream".utf8))
        }
        let xref = out.count
        out += Array("xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n".utf8)
        for o in offsets { out += Array(String(format: "%010d 00000 n \n", o).utf8) }
        out += Array("trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return out
    }

    // MARK: Print

    static func to8(_ v: Float) -> UInt8 { UInt8((min(max(v.isNaN ? 0 : v, 0), 1) * 255).rounded()) }

    /// The flattened, colour-handled document as 8-bit samples in its print colour space.
    static func printImage(_ s: Session, _ doc: Document, _ p: JSONValue, _ cmd: String) throws -> (PrintImage, JSONValue) {
        let t = WebCommands.scratch(s, doc)
        let handling = p["colorHandling"]?.stringValue ?? "printerManages"
        var info: [String: JSONValue] = ["colorHandling": .string(handling)]
        if ![.rgb, .grayscale, .cmyk].contains(doc.mode) { try t.execute("image.mode.rgb") }
        switch handling {
        case "photocraftManages", "photoshopManages":
            guard let profile = p["printerProfile"]?.stringValue else { throw bad(cmd, #""photocraftManages" needs a "printerProfile""#) }
            let intent = p["intent"]?.stringValue ?? "relative"
            let bpc = p["bpc"]?.boolValue ?? true
            try t.execute("edit.convertToProfile", ["profile": .string(profile), "intent": .string(intent), "bpc": .bool(bpc)])
            info["printerProfile"] = .string(profile)
            info["intent"] = .string(intent)
            info["bpc"] = .bool(bpc)
        case "printerManages", "noColorManagement":
            break
        case "separations":
            throw bad(cmd, "Separations printing is not supported; use photocraftManages with a CMYK printer profile")
        default:
            throw bad(cmd, "unknown colorHandling `\(handling)` (printerManages|photocraftManages|noColorManagement)")
        }
        guard let d0 = t.active?.doc else { throw EngineError.noDocument }
        let icc = handling == "noColorManagement" ? nil : d0.iccProfile
        // RGB and Grayscale: the composite over white is the print image (no layer flatten).
        if d0.mode == .rgb || d0.mode == .grayscale {
            let gray = d0.mode == .grayscale
            let px = try WebCommands.flatten(s, d0)
            var data: [UInt8] = []
            data.reserveCapacity(px.count * (gray ? 1 : 3))
            for q in px {
                let a = q.w
                if gray {
                    data.append(to8(q.x * a + (1 - a)))
                } else {
                    data.append(to8(q.x * a + (1 - a))); data.append(to8(q.y * a + (1 - a))); data.append(to8(q.z * a + (1 - a)))
                }
            }
            return (PrintImage(width: d0.size.width, height: d0.size.height, channels: gray ? 1 : 3, data: data, icc: icc), .object(info))
        }
        try t.execute("layer.flattenImage")
        guard let d = t.active?.doc else { throw EngineError.noDocument }
        let fmt = d.pixelFormat
        let k = fmt.mode.colorChannels
        let n = fmt.channels
        guard let surf = d.layers.first?.surface else { throw other("nothing to print") }
        let vals = surf.readRegion(d.bounds)
        var data: [UInt8] = []
        data.reserveCapacity(vals.count / max(n, 1) * k)
        var i = 0
        while i + n <= vals.count {
            for c in 0..<k { data.append(to8(vals[i + c])) }
            i += n
        }
        return (PrintImage(width: d.size.width, height: d.size.height, channels: k, data: data, icc: icc), .object(info))
    }

    static func paper(_ p: JSONValue, _ cmd: String) throws -> (Double, Double) {
        var (w, h) = (612.0, 792.0)
        switch p["paper"] {
        case nil: break
        case .string(let name)?:
            guard let e = papers.first(where: { $0.0.lowercased() == name.lowercased() }) else {
                throw bad(cmd, "unknown paper `\(name)` (\(papers.map(\.0).joined(separator: "|")))")
            }
            (w, h) = (e.1, e.2)
        case .array(let a)? where a.count == 2:
            (w, h) = (a[0].doubleValue ?? 0, a[1].doubleValue ?? 0)
        default:
            throw bad(cmd, "paper is a name or [width, height] in points")
        }
        if !(w > 36 && h > 36) { throw bad(cmd, "paper is too small") }
        return p["orientation"]?.stringValue == "landscape" ? (max(h, w), min(w, h)) : (w, h)
    }

    /// Where the image lands on the paper.
    struct PrintLayout: Sendable {
        /// Paper size in points (after orientation).
        var paper: (Double, Double)
        /// Image box in points, origin bottom-left.
        var rect: (Double, Double, Double, Double)
        /// Print scale (1.0 = 100 %).
        var scale: Double
        var marks: Marks
        /// Emulsion Down: the page prints mirrored (`rect` is where the image is before mirroring).
        var emulsionDown: Bool
    }

    /// The print layout for `doc` with Print parameters `p` (used by the dialog's preview too).
    static func layout(_ doc: Document, _ p: JSONValue, _ cmd: String) throws -> PrintLayout {
        let (pw, ph) = try paper(p, cmd)
        let dpi = Double(max(doc.resolutionDpi, 1))
        let (iw, ih) = (Double(doc.size.width) * 72 / dpi, Double(doc.size.height) * 72 / dpi)
        let marks = Marks(cornerCrop: p["cornerCropMarks"]?.boolValue ?? false, centerCrop: p["centerCropMarks"]?.boolValue ?? false,
                          registration: p["registrationMarks"]?.boolValue ?? false)
        let margin = marks.any ? 36.0 : 18.0
        let scale: Double
        if p["scaleToFit"]?.boolValue ?? false {
            scale = min((pw - 2 * margin) / iw, (ph - 2 * margin) / ih)
        } else {
            scale = (p["scale"]?.doubleValue.flatMap { $0 > 0 ? $0 : nil } ?? 100) / 100
        }
        let (w, h) = (iw * scale, ih * scale)
        let x: Double, y: Double
        if p["center"]?.boolValue ?? true {
            (x, y) = ((pw - w) / 2, (ph - h) / 2)
        } else {
            // Top / left in inches from the paper's top-left corner (Photoshop's Position fields).
            let top = (p["top"]?.doubleValue ?? 0) * 72
            let left = (p["left"]?.doubleValue ?? 0) * 72
            (x, y) = (left, ph - top - h)
        }
        return PrintLayout(paper: (pw, ph), rect: (x, y, w, h), scale: scale, marks: marks, emulsionDown: p["emulsionDown"]?.boolValue ?? false)
    }

    /// A private spool PDF in `dir`: a random name created exclusively with mode 0600, so a symlink
    /// at a guessed path cannot redirect the write (photocraft `private_spool_pdf_in`). The caller
    /// removes it.
    static func privateSpoolPDF(_ pdf: [UInt8], in dir: String = NSTemporaryDirectory()) throws -> String {
        var template = Array((dir as NSString).appendingPathComponent("photocraft-print-XXXXXXXX.pdf").utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemps($0.baseAddress!, 4) }
        if fd < 0 { throw other("could not create a spool file: \(String(cString: strerror(errno)))") }
        let path = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        fchmod(fd, 0o600)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(pdf))
            try handle.synchronize()
            try handle.close()
        } catch {
            unlink(path)
            throw other("\(error)")
        }
        return path
    }

    /// Lays out, renders and (unless dry-run) spools a print. Shared by Print and Print One Copy.
    static func doPrint(_ s: Session, _ p: JSONValue, _ cmd: String, spooler: ([String]) throws -> String = spoolPDF) throws -> JSONValue {
        let output = p["output"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let send = p["send"]?.boolValue ?? (output == nil)
        let dry = p["dryRun"]?.boolValue ?? false
        if !dry && !send && output == nil { throw bad(cmd, "send: false needs an output path or dryRun: true") }
        guard let d = s.active else { throw EngineError.noDocument }
        let doc = d.doc
        let lay = try layout(doc, p, cmd)
        let (img, color) = try printImage(s, doc, p, cmd)
        let description = (p["description"]?.boolValue ?? false) ? FileCommands.readFileInfo(doc.metadata.xmp)["description"]?.stringValue ?? "" : nil
        let label = (p["labels"]?.boolValue ?? false) ? doc.name : nil
        let page = PrintPage(paper: lay.paper, image: img, rect: lay.rect, marks: lay.marks, description: description, label: label,
                             emulsionDown: lay.emulsionDown)
        let pdf = printPDF(page)
        // An explicit output is the caller's requested artifact, including for dry runs.
        if let path = output { try FileCommands.writeFile(s, path, pdf) }
        let spoolFile = output == nil && send && !dry ? try privateSpoolPDF(pdf) : nil
        defer { if let f = spoolFile { unlink(f) } }
        // Dry runs report a descriptive placeholder because no spool file exists.
        let commandPath = output ?? spoolFile ?? "<temporary PDF>"
        let copies = min(max(p["copies"]?.intValue ?? 1, 1), 999)
        var argv = ["lp"]
        if let pr = p["printer"]?.stringValue, !pr.isEmpty { argv += ["-d", pr] }
        if copies > 1 { argv += ["-n", "\(copies)"] }
        argv += ["-t", doc.name, commandPath]
        var sent = false
        var spool = JSONValue.null
        if send && !dry {
            spool = .string(try spooler(argv))
            sent = true
        }
        rememberPrint(s, p)
        WebCommands.fireEvent(s, "print")
        let (pw, ph) = lay.paper
        let (x, y, w, h) = lay.rect
        return ["pdf": output.map { .string($0) } ?? .null, "bytes": .int(pdf.count), "paper": .doubles([pw, ph]), "imageRect": .doubles([x, y, w, h]),
                "emulsionDown": .bool(lay.emulsionDown), "scale": .number(lay.scale * 100), "copies": .int(copies),
                "command": send ? .strings(argv) : .null, "sent": .bool(sent), "spooler": spool, "color": color]
    }

    /// Print One Copy repeats these.
    static func rememberPrint(_ s: Session, _ p: JSONValue) {
        var o = p.objectValue ?? [:]
        o["output"] = nil
        o["dryRun"] = nil
        // A send override can depend on the output or dry-run choice. Neither is remembered, so
        // replay and the next Print dialog derive the default from their own output.
        o["send"] = nil
        s.state[LastPrintKey.self] = .object(o)
    }

    /// The executable `lp` on the search path.
    static func lpExecutable() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":").map(String.init) + ["/usr/bin"] {
            let p = (dir as NSString).appendingPathComponent("lp")
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Runs `argv` (`lp …`) and returns its output (the request id).
    static func spoolPDF(_ argv: [String]) throws -> String {
        guard let exe = lpExecutable() else { throw other("could not run `lp` (CUPS): not found on the search path") }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = Array(argv.dropFirst())
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do { try proc.run() } catch { throw other("could not run `lp` (CUPS): \(error.localizedDescription)") }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw other("lp failed: \(String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func printCmd(_ s: Session, _ p: JSONValue) throws -> JSONValue { try doPrint(s, p, "file.print") }

    static func printOneCopy(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        var q = s.state[LastPrintKey.self]?.objectValue ?? [:]
        for (k, v) in p.objectValue ?? [:] { q[k] = v }
        q["copies"] = 1
        return try doPrint(s, .object(q), "file.printOneCopy")
    }

    // MARK: Package

    static func package(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.package"
        guard let dir = p["dir"]?.stringValue, !dir.isEmpty else { throw bad(cmd, #"missing "dir" (where to create the package folder)"#) }
        guard let d = s.active else { throw EngineError.noDocument }
        let doc = d.doc
        let name = FileCommands.stem(d.path ?? doc.name)
        // The native format keeps external links; a PSD package embeds or flattens them.
        let ext: String
        switch p["format"]?.stringValue {
        case let f? where ["psd", "psb", "pcraft"].contains(f): ext = f
        case let f?: throw bad(cmd, "unknown package format `\(f)` (pcraft|psd|psb)")
        case nil: ext = "pcraft"
        }
        let folder = FileCommands.join(dir, FileCommands.sanitize(name))
        let linksDir = FileCommands.join(folder, "Links")
        // Copy every linked file once; relink the copy of the document to the copies.
        var copied: [(String, String)] = []
        var relinks: [(LayerId, String)] = []
        var missing: [String] = []
        for e in doc.walk() {
            guard case .smart(let so) = e.layer.content, case .linked(let path) = so.source else { continue }
            let target: String
            if let t = copied.first(where: { $0.0 == path })?.1 {
                target = t
            } else {
                var fname = FileCommands.fileName(path)
                if copied.contains(where: { FileCommands.fileName($0.1) == fname }) { fname = "\(copied.count)-\(fname)" }
                let t = FileCommands.join(linksDir, fname)
                guard let bytes = try? FileCommands.readFile(s, path) else {
                    missing.append(path)
                    continue
                }
                try FileCommands.writeFile(s, t, bytes)
                copied.append((path, t))
                target = t
            }
            relinks.append((e.layer.id, target))
        }
        let t = WebCommands.scratch(s, doc)
        for (id, path) in relinks { try relink(t, id, path) }
        let out = FileCommands.join(folder, "\(FileCommands.sanitize(name)).\(ext)")
        guard let pdoc = t.active?.doc else { throw EngineError.noDocument }
        let warnings = try FileCommands.saveDoc(s, pdoc, out)
        return ["folder": .string(folder), "document": .string(out), "links": .strings(copied.map(\.1)), "missing": .strings(missing),
                "warnings": .strings(warnings)]
    }

    /// Points layer `id`'s linked smart object at `path` (photocraft runs
    /// `layer.smartObjects.relinkToFile`).
    static func relink(_ t: Session, _ id: LayerId, _ path: String) throws {
        try t.execute("layer.smartObjects.relinkToFile", ["layer": .id(id), "path": .string(path)])
    }

    // MARK: Paths to Illustrator

    /// The document's paths as an Illustrator 3 PostScript file. `which`: "all", "work" or a path
    /// name. Coordinates are points (pixels at the document resolution), y up.
    static func pathsToAI(_ doc: Document, _ which: String) -> (String, Int) {
        let dpi = Double(max(doc.resolutionDpi, 1))
        let k = 72 / dpi
        let (w, h) = (Double(doc.size.width) * k, Double(doc.size.height) * k)
        var chosen: [(String, VectorPath)] = []
        switch which {
        case "all":
            chosen = doc.paths.map { ($0.name, $0.path) }
            if let wp = doc.workPath { chosen.append(("Work Path", wp)) }
        case "work":
            if let wp = doc.workPath { chosen.append(("Work Path", wp)) }
        default:
            chosen = doc.paths.filter { $0.name == which }.map { ($0.name, $0.path) }
        }
        func f4(_ v: Double) -> String { String(format: "%.4f", v) }
        var s = "%!PS-Adobe-2.0 EPSF-1.2\n%%Creator: PhotoCraft\n"
        s += "%%Title: (\(doc.name.replacingOccurrences(of: ")", with: "_").replacingOccurrences(of: "(", with: "_")))\n"
        s += "%%BoundingBox: 0 0 \(Int64(w.rounded(.up))) \(Int64(h.rounded(.up)))\n%%HiResBoundingBox: 0 0 \(f4(w)) \(f4(h))\n%AI3_Cropmarks: 0 0 \(f4(w)) \(f4(h))\n"
        s += "%%DocumentProcessColors: Black\n%%EndComments\n%%EndProlog\n%%BeginSetup\n%%EndSetup\n"
        func pt(_ p: PCPoint) -> (Double, Double) { (p.x * k, h - p.y * k) }
        var n = 0
        for (name, path) in chosen {
            let subs = path.subpaths.filter { !$0.knots.isEmpty }
            if subs.isEmpty { continue }
            n += 1
            s += "%%Note: \(name)\n"
            let compound = subs.count > 1
            if compound { s += "*u\n" }
            for sp in subs {
                let (x, y) = pt(sp.knots[0].anchor)
                s += "\(f4(x)) \(f4(y)) m\n"
                for seg in sp.segments {
                    let (a, c1, c2, b) = (seg[0], seg[1], seg[2], seg[3])
                    let (bx, by) = pt(b)
                    if c1 == a && c2 == b {
                        s += "\(f4(bx)) \(f4(by)) L\n"
                    } else {
                        let (x1, y1) = pt(c1)
                        let (x2, y2) = pt(c2)
                        s += "\(f4(x1)) \(f4(y1)) \(f4(x2)) \(f4(y2)) \(f4(bx)) \(f4(by)) C\n"
                    }
                }
                // Unpainted: `n` closes the path, `N` leaves it open.
                s += sp.closed ? "n\n" : "N\n"
            }
            if compound { s += "*U\n" }
        }
        s += "%%PageTrailer\n%%Trailer\n%%EOF\n"
        return (s, n)
    }

    static func pathsToIllustrator(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.export.pathsToIllustrator"
        guard let d = s.active else { throw EngineError.noDocument }
        let which = p["paths"]?.stringValue ?? "all"
        let (text, n) = pathsToAI(d.doc, which)
        if n == 0 { throw bad(cmd, "no paths match `\(which)`") }
        if let path = p["path"]?.stringValue, !path.isEmpty {
            try FileCommands.writeFile(s, path, Array(text.utf8))
            return ["path": .string(path), "paths": .int(n)]
        }
        return ["ai": .string(text), "paths": .int(n)]
    }

    static let hasPaths: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return d.doc.paths.isEmpty && d.doc.workPath == nil ? "the document has no paths" : nil
    }

    // MARK: Specs

    static func register(into r: inout CommandRegistry) {
        let printParams = ##"{"printer":name? (default printer),"copies":1..999=1,"paper":"letter|legal|tabloid|a3|a4|a5|4x6|5x7"|[w,h] pt="letter","orientation":"portrait|landscape"="portrait","center":bool=true,"top":in?,"left":in?,"scale":%=100,"scaleToFit":bool=false,"colorHandling":"printerManages|photocraftManages|noColorManagement"="printerManages","printerProfile":profile? (photocraftManages),"intent":"perceptual|relative|saturation|absolute"="relative","bpc":bool=true,"cornerCropMarks":bool,"centerCropMarks":bool,"registrationMarks":bool,"description":bool,"labels":bool,"emulsionDown":bool=false (mirror the page left to right, for sublimation and other transfer printing),"output":pdf path? (print to PDF; then "send" defaults to false),"send":bool?,"dryRun":bool=false (render the PDF, report the lp command, don't spool; no temporary PDF is written)} → {pdf:explicit output path or null, imageRect, command, sent}"##
        let hasDoc = WebCommands.hasDoc
        r.add([
            CommandSpec("file.print", "Print…", menu: ["File"], shortcut: "Cmd+P", params: printParams, module: m, enabled: hasDoc, run: printCmd),
            CommandSpec("file.printOneCopy", "Print One Copy", menu: ["File"], shortcut: "Cmd+Alt+Shift+P",
                        params: "{} (the last Print settings, one copy; any Print key overrides)", module: m, enabled: hasDoc, run: printOneCopy),
            CommandSpec("file.package", "Package…", menu: ["File"],
                        params: ##"{"dir":folder,"format":"pcraft|psd|psb"="pcraft"} → {folder, document, links, missing} (copies the document and its linked files into <dir>/<name>/, relinked to Links/)"##,
                        module: m, enabled: hasDoc, run: package),
            CommandSpec("file.export.pathsToIllustrator", "Paths to Illustrator…", menu: ["File", "Export"],
                        params: ##"{"path":str? (.ai; omit to return the text),"paths":"all|work|<path name>"="all"} → {path, paths}"##,
                        module: m, enabled: hasPaths, run: pathsToIllustrator),
        ])
    }
}
