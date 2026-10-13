// Port of photocraft-engine (crates/engine/src/file_cmds.rs: File Info (XMP), `read_file_info`, `write_file_info`, `camera_data`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// File › File Info: the description fields edited in the document's XMP packet (only the changed
// properties are rewritten, everything else — translations, other namespaces — is kept
// verbatim), and the read-only Camera Data from the EXIF block (PCAlgo's `Exif`), falling back to
// the XMP `tiff:` / `exif:` / `aux:` copies. The packet is handled as UTF-8 bytes with byte
// offsets, exactly as photocraft's string slicing does (every searched token is ASCII).

import Foundation
import PCAlgo
import PCDocument

extension FileCommands {
    /// The File Info fields we edit, as (JSON key, XMP property, container kind).
    static let infoFields: [(key: String, prop: String, kind: String)] = [
        ("title", "dc:title", "Alt"),
        ("author", "dc:creator", "Seq"),
        ("description", "dc:description", "Alt"),
        ("keywords", "dc:subject", "Bag"),
        ("copyright", "dc:rights", "Alt"),
        ("authorTitle", "photoshop:AuthorsPosition", ""),
    ]

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;", options: .literal).replacingOccurrences(of: "<", with: "&lt;", options: .literal)
            .replacingOccurrences(of: ">", with: "&gt;", options: .literal).replacingOccurrences(of: "\"", with: "&quot;", options: .literal)
    }

    static func xmlUnescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<", options: .literal).replacingOccurrences(of: "&gt;", with: ">", options: .literal)
            .replacingOccurrences(of: "&quot;", with: "\"", options: .literal).replacingOccurrences(of: "&apos;", with: "'", options: .literal)
            .replacingOccurrences(of: "&amp;", with: "&", options: .literal)
    }

    /// Rust's `str::trim` (Unicode white space at both ends).
    static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The first occurrence of `needle` in `hay` at or after `from`.
    static func find(_ hay: [UInt8], _ needle: [UInt8], from: Int = 0) -> Int? {
        guard !needle.isEmpty, from >= 0, hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
        let first = needle[0]
        var i = from
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == first {
                var k = 1
                while k < needle.count && hay[i + k] == needle[k] { k += 1 }
                if k == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    /// The last occurrence of `needle` in `hay`.
    static func rfind(_ hay: [UInt8], _ needle: [UInt8]) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        var i = hay.count - needle.count
        while i >= 0 {
            if hay[i ..< i + needle.count].elementsEqual(needle) { return i }
            i -= 1
        }
        return nil
    }

    static func text(_ b: ArraySlice<UInt8>) -> String { String(decoding: b, as: UTF8.self) }

    /// The element `<tag …>…</tag>` (first occurrence) as (start, end, inner range).
    static func findElement(_ x: [UInt8], _ tag: String) -> (Int, Int, Range<Int>)? {
        let open = Array("<\(tag)".utf8)
        var from = 0
        while let i = find(x, open, from: from) {
            let after = i + open.count < x.count ? x[i + open.count] : nil
            if let a = after, [UInt8(ascii: ">"), UInt8(ascii: " "), UInt8(ascii: "/"), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t")].contains(a) {
                guard let gt = find(x, [UInt8(ascii: ">")], from: i) else { return nil }
                if gt > 0 && x[gt - 1] == UInt8(ascii: "/") { return (i, gt + 1, gt ..< gt) }
                let close = Array("</\(tag)>".utf8)
                guard let c = find(x, close, from: gt) else { return nil }
                return (i, c + close.count, gt + 1 ..< c)
            }
            from = i + open.count
        }
        return nil
    }

    /// `rdf:li` values of a container (or the element text for simple properties).
    static func liValues(_ inner: [UInt8]) -> [String] {
        var out: [String] = []
        var rest = inner
        while let (_, b, v) = findElement(rest, "rdf:li") {
            out.append(xmlUnescape(trimmed(text(rest[v]))))
            rest = Array(rest[b...])
        }
        let whole = text(inner[...])
        if out.isEmpty && !whole.contains("<") && !trimmed(whole).isEmpty { out.append(xmlUnescape(trimmed(whole))) }
        return out
    }

    /// Attribute form `prop="value"` on an `rdf:Description`.
    static func findAttr(_ x: [UInt8], _ prop: String) -> (Int, Int, Range<Int>)? {
        let key = Array(" \(prop)=\"".utf8)
        guard let i = find(x, key) else { return nil }
        let v0 = i + key.count
        guard let v1 = find(x, [UInt8(ascii: "\"")], from: v0) else { return nil }
        return (i, v1 + 1, v0 ..< v1)
    }

    /// File Info fields read from an XMP packet (photocraft `read_file_info`).
    public static func readFileInfo(_ xmp: String?) -> JSONValue {
        let x = Array((xmp ?? "").utf8)
        var m: [String: JSONValue] = [:]
        for f in infoFields {
            let vals: [String]
            if let (_, _, inner) = findElement(x, f.prop) {
                vals = liValues(Array(x[inner]))
            } else if let (_, _, v) = findAttr(x, f.prop) {
                vals = [xmlUnescape(text(x[v]))]
            } else {
                vals = []
            }
            switch f.kind {
            case "Bag": m[f.key] = .strings(vals)
            case "Seq": m[f.key] = .string(vals.joined(separator: "; "))
            default: m[f.key] = .string(vals.first ?? "")
            }
        }
        let marked = findElement(x, "xmpRights:Marked").map { trimmed(text(x[$0.2])) } ?? findAttr(x, "xmpRights:Marked").map { text(x[$0.2]) }
        m["copyrightStatus"] = .string(marked == "True" ? "copyrighted" : marked == "False" ? "publicDomain" : "unknown")
        let url = findElement(x, "xmpRights:WebStatement").map { xmlUnescape(trimmed(text(x[$0.2]))) }
            ?? findAttr(x, "xmpRights:WebStatement").map { xmlUnescape(text(x[$0.2])) }
        m["copyrightUrl"] = .string(url ?? "")
        return .object(m)
    }

    /// File Info's read-only Camera Data, as (result key, English label) in display order.
    public static let cameraFields: [(key: String, label: String)] = [
        ("make", "Make"), ("model", "Model"), ("dateTaken", "Date Taken"), ("exposure", "Exposure"), ("fNumber", "F-Stop"), ("iso", "ISO Speed"),
        ("focalLength", "Focal Length"), ("focalLength35mm", "Focal Length (35 mm)"), ("lens", "Lens"),
    ]

    /// `v` with at most `decimals` decimals and no trailing zeros (33.10 → "33.1", 8.0 → "8").
    static func shortNum(_ v: Double, _ decimals: Int) -> String {
        let s = String(format: "%.\(decimals)f", v)
        guard s.contains(".") else { return s }
        var t = Substring(s)
        while t.hasSuffix("0") { t = t.dropLast() }
        if t.hasSuffix(".") { t = t.dropLast() }
        return String(t)
    }

    /// A whole number as Rust's `{}` prints an `f64` (`400`, not `400.0`).
    static func wholeText(_ v: Double) -> String {
        if v.isFinite, v == v.rounded(), abs(v) < 9e15 { return String(Int64(v)) }
        return "\(v)"
    }

    /// Exposure time as cameras print it: "1/250 s" for fractions of a second, "0.4 s" or "2 s"
    /// when the reciprocal isn't a whole number or the exposure is a second or longer.
    static func exposureText(_ t: Double) -> String? {
        guard t.isFinite, t > 0 else { return nil }
        let r = 1 / t
        if t < 1 && abs(r - r.rounded()) <= r * 0.01 { return "1/\(wholeText(r.rounded())) s" }
        return "\(shortNum(t, t < 1 ? 2 : 1)) s"
    }

    /// EXIF (`2024:02:17 12:40:19`) or XMP (`2024-02-17T12:40:19.00+01:00`) dates as
    /// `2024-02-17 12:40:19`; anything else is shown as stored.
    static func dateText(_ s: String) -> String {
        let t = trimmed(s)
        let b = Array(t.utf8)
        func digits(_ r: [Int]) -> Bool { r.allSatisfy { $0 < b.count && b[$0] >= 0x30 && b[$0] <= 0x39 } }
        func sep(_ i: Int, _ set: String) -> Bool { i < b.count && set.utf8.contains(b[i]) }
        func part(_ r: Range<Int>) -> String { String(r.map { i -> Character in i < b.count ? Character(Unicode.Scalar(b[i])) : "0" }) }
        if !(digits([0, 1, 2, 3, 5, 6, 8, 9]) && sep(4, ":-") && sep(7, ":-")) { return t }
        let date = "\(part(0 ..< 4))-\(part(5 ..< 7))-\(part(8 ..< 10))"
        if digits([11, 12, 14, 15, 17, 18]) && sep(10, " T") && sep(13, ":") && sep(16, ":") { return "\(date) \(part(11 ..< 19))" }
        return date
    }

    /// A single XMP value: the first `rdf:li` of a container, element text or attribute.
    static func xmpValue(_ x: [UInt8], _ prop: String) -> String? {
        let v: String?
        if let (_, _, inner) = findElement(x, prop) {
            v = liValues(Array(x[inner])).first
        } else {
            v = findAttr(x, prop).map { xmlUnescape(text(x[$0.2])) }
        }
        guard let t = v.map(trimmed), !t.isEmpty else { return nil }
        return t
    }

    /// An XMP number: a rational "331/10" or a decimal.
    static func xmpNumber(_ x: [UInt8], _ prop: String) -> Double? {
        guard let v = xmpValue(x, prop) else { return nil }
        let n: Double
        if let slash = v.firstIndex(of: "/") {
            guard let a = Double(trimmed(String(v[..<slash]))), let b = Double(trimmed(String(v[v.index(after: slash)...]))), b != 0 else { return nil }
            n = a / b
        } else {
            guard let d = Double(v) else { return nil }
            n = d
        }
        return n.isFinite ? n : nil
    }

    /// File Info's read-only Camera Data (keys of `cameraFields`, present ones only), formatted for
    /// display. Read from the EXIF block (JPEG APP1, PSD resource 1058, …); properties it lacks
    /// fall back to the XMP `tiff:`/`exif:`/`aux:` copies (photocraft `camera_data`).
    public static func cameraData(exif: [UInt8]?, xmp: String?) -> JSONValue {
        let e = exif.map { Exif.read($0) } ?? Exif.CameraInfo()
        let x = Array((xmp ?? "").utf8)
        func textField(_ v: String?, _ props: [String]) -> String? { v ?? props.lazy.compactMap { xmpValue(x, $0) }.first }
        func num(_ v: Double?, _ props: [String]) -> Double? {
            let n = v.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? props.lazy.compactMap { xmpNumber(x, $0) }.first
            return n.flatMap { $0 > 0 ? $0 : nil }
        }
        let values: [String?] = [
            textField(e.make, ["tiff:Make"]),
            textField(e.model, ["tiff:Model"]),
            textField(e.dateTaken, ["exif:DateTimeOriginal"]).map(dateText),
            num(e.exposureTime, ["exif:ExposureTime"]).flatMap(exposureText),
            num(e.fNumber, ["exif:FNumber"]).map { "f/\(shortNum($0, 1))" },
            num(e.iso, ["exif:ISOSpeedRatings", "exifEX:PhotographicSensitivity"]).map { "ISO \(wholeText($0.rounded()))" },
            num(e.focalLength, ["exif:FocalLength"]).map { "\(shortNum($0, 1)) mm" },
            num(e.focalLength35mm, ["exif:FocalLengthIn35mmFilm"]).map { "\(shortNum($0, 1)) mm" },
            textField(e.lens, ["exifEX:LensModel", "aux:Lens"]),
        ]
        var m: [String: JSONValue] = [:]
        for (f, v) in zip(cameraFields, values) {
            // Hostile files can carry megabytes of "lens name"; the dialog shows a line.
            if let v = v.map({ String($0.prefix(200)) }), !v.isEmpty { m[f.key] = .string(v) }
        }
        return .object(m)
    }

    /// Rewrites only changed File Info fields of an XMP packet (creating one when there is none),
    /// keeping the other properties verbatim. Edited properties move into their own
    /// `rdf:Description` (several descriptions per packet are valid XMP) (photocraft
    /// `write_file_info`).
    public static func writeFileInfo(_ xmp: String?, _ info: JSONValue) -> String {
        let cur = readFileInfo(xmp)
        let given = info.objectValue ?? [:]
        // The dialog submits all fields, including unchanged language alternatives.
        func changed(_ key: String) -> Bool { given[key].map { cur[key] != $0 } ?? false }
        let packet = xmp.flatMap { $0.contains("</rdf:RDF>") ? $0 : nil }
            ?? "<?xpacket begin=\"\u{feff}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">\n <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n </rdf:RDF>\n</x:xmpmeta>\n<?xpacket end=\"w\"?>"
        var x = Array(packet.utf8)
        let props = infoFields.map { ($0.key, $0.prop) } + [("copyrightStatus", "xmpRights:Marked"), ("copyrightUrl", "xmpRights:WebStatement")]
        for (key, prop) in props where changed(key) {
            while let (a, b, _) = findElement(x, prop) { x.removeSubrange(a ..< b) }
            while let (a, b, _) = findAttr(x, prop) { x.removeSubrange(a ..< b) }
        }
        func get(_ k: String) -> JSONValue { changed(k) ? (given[k] ?? .null) : .null }
        var body = ""
        for f in infoFields {
            let vals: [String]
            switch get(f.key) {
            case .array(let a): vals = a.compactMap(\.stringValue).filter { !$0.isEmpty }
            case .string(let s) where f.kind == "Bag" || f.kind == "Seq":
                vals = s.split(whereSeparator: { $0 == ";" || $0 == "," }).map { trimmed(String($0)) }.filter { !$0.isEmpty }
            case .string(let s) where !s.isEmpty: vals = [s]
            default: vals = []
            }
            if vals.isEmpty { continue }
            let items = vals.map { f.kind == "Alt" ? "<rdf:li xml:lang=\"x-default\">\(xmlEscape($0))</rdf:li>" : "<rdf:li>\(xmlEscape($0))</rdf:li>" }.joined()
            if f.kind.isEmpty {
                body += "   <\(f.prop)>\(xmlEscape(vals[0]))</\(f.prop)>\n"
            } else {
                body += "   <\(f.prop)><rdf:\(f.kind)>\(items)</rdf:\(f.kind)></\(f.prop)>\n"
            }
        }
        switch get("copyrightStatus").stringValue {
        case "copyrighted": body += "   <xmpRights:Marked>True</xmpRights:Marked>\n"
        case "publicDomain": body += "   <xmpRights:Marked>False</xmpRights:Marked>\n"
        default: break
        }
        if let u = get("copyrightUrl").stringValue, !u.isEmpty { body += "   <xmpRights:WebStatement>\(xmlEscape(u))</xmpRights:WebStatement>\n" }
        if !body.isEmpty {
            let desc = "  <rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:photoshop=\"http://ns.adobe.com/photoshop/1.0/\" xmlns:xmpRights=\"http://ns.adobe.com/xap/1.0/rights/\">\n\(body)  </rdf:Description>\n "
            let at = rfind(x, Array("</rdf:RDF>".utf8)) ?? x.count
            x.insert(contentsOf: Array(desc.utf8), at: at)
        }
        return String(decoding: x, as: UTF8.self)
    }

    static func fileInfo(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let keys: Set<String> = ["title", "author", "authorTitle", "description", "keywords", "copyright", "copyrightStatus", "copyrightUrl"]
        let edits = p.objectValue?.keys.contains(where: keys.contains) ?? false
        if edits {
            guard let d = s.active else { throw EngineError.noDocument }
            let new = writeFileInfo(d.doc.metadata.xmp, p)
            try s.edit("File Info") { doc, _ in doc.metadata.xmp = new }
        }
        guard let d = s.active else { throw EngineError.noDocument }
        return readFileInfo(d.doc.metadata.xmp).setting("camera", cameraData(exif: d.doc.metadata.exif, xmp: d.doc.metadata.xmp))
    }
}
