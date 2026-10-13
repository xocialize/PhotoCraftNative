// Port of photocraft-engine (crates/engine/src/web_cmds.rs: Generate › Image Assets — `AssetSpec`, `AssetDefault`, `parse_asset_name`, `parse_defaults`, `asset_path_components`, `asset_output_path`, `generate_assets`, `image_assets`, `on_saved`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The naming grammar of Adobe's public Generator documentation: a layer named `foo.png`,
// `200% foo@2x.png, 48x48 icons/foo.png8`, `photo.jpg80%`, `?x100 thumb.gif` is exported into
// `<document>-assets/`; a `default …` layer adds variants. Layer names are document data, so every
// output path is checked: no traversal, absolute or drive paths, Windows device names, and (on the
// local file system) no symlink between the chosen folder and the file.

import Foundation
import PCDocument
import PCFoundation

extension WebCommands {
    /// One asset requested by a layer name.
    struct AssetSpec: Equatable, Sendable {
        /// Relative output path (folders allowed), extension included.
        var file: String
        /// png8 | png24 | png32 | jpg | gif | webp
        var format: String
        /// JPEG quality 1…100.
        var quality: UInt8?
        /// Uniform scale (1.0 = 100 %).
        var scale: Double?
        /// Target width / height in px (`?` = keep aspect).
        var width: Double?
        var height: Double?
    }

    /// A `default` layer variant: size plus a folder (`low/`) or name suffix (`@2x`).
    struct AssetDefault: Equatable, Sendable {
        var scale: Double?
        var width: Double?
        var height: Double?
        var folder = ""
        var suffix = ""
    }

    /// `?` → .some(nil); a positive number with an optional px/in/cm/mm unit → its pixels.
    static func unitPx(_ tok: Substring, _ dpi: Double) -> Double?? {
        if tok == "?" { return .some(nil) }
        var num = tok
        var k = 1.0
        if tok.hasSuffix("px") { num = tok.dropLast(2) } else if tok.hasSuffix("in") { num = tok.dropLast(2); k = dpi }
        else if tok.hasSuffix("cm") { num = tok.dropLast(2); k = dpi / 2.54 } else if tok.hasSuffix("mm") { num = tok.dropLast(2); k = dpi / 25.4 }
        guard let v = Double(num.trimmingCharacters(in: .whitespaces)), v > 0 else { return nil }
        return .some(v * k)
    }

    static func isSpace(_ c: Character) -> Bool { c.isWhitespace }

    /// `200%` or `WxH` (units px/in/cm/mm, `?` wildcard) at the start of `item`; returns the size
    /// and the rest.
    static func parseSize(_ item0: Substring, _ dpi: Double) -> (Double?, Double?, Double?, Substring) {
        let item = Substring(item0.trimmingCharacters(in: .whitespacesAndNewlines))
        let first: Substring, rest: Substring
        if let sp = item.firstIndex(where: isSpace) {
            first = item[..<sp]
            rest = Substring(item[item.index(after: sp)...].trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            (first, rest) = (item, "")
        }
        if first.hasSuffix("%"), let pc = Double(first.dropLast()), pc > 0 { return (pc / 100, nil, nil, rest) }
        // "100x50", "2in x 1in", "?x100"
        if let x = first.firstIndex(where: { $0 == "x" || $0 == "X" }) {
            let (w, h) = (first[..<x], first[first.index(after: x)...])
            if !w.isEmpty && !h.isEmpty, let ww = unitPx(w, dpi), let hh = unitPx(h, dpi) { return (nil, ww, hh, rest) }
        }
        // Spaced form "2in x 1in name.png": three tokens.
        let toks = item.split(whereSeparator: isSpace)
        if toks.count >= 4, toks[1].lowercased() == "x", let ww = unitPx(toks[0], dpi), let hh = unitPx(toks[2], dpi) {
            let pos = item.range(of: toks[3])?.lowerBound ?? item.endIndex
            return (nil, ww, hh, item[pos...])
        }
        return (nil, nil, nil, item)
    }

    /// Parses a layer name into its asset specs (empty when it names no asset).
    static func parseAssetName(_ name: String, _ dpi: Double) -> [AssetSpec] {
        var out: [AssetSpec] = []
        for item in name.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "+" }) {
            let (scale, width, height, rest) = parseSize(item, dpi)
            let file = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let dot = file.lastIndex(of: ".") else { continue }
            let stemPart = file[..<dot]
            let ext = file[file.index(after: dot)...]
            if stemPart.isEmpty { continue }
            let extL = ext.lowercased()
            let format: String, quality: UInt8?, outExt: String
            if extL.hasPrefix("jpeg") || extL.hasPrefix("jpg") {
                let q = String(extL.dropFirst(extL.hasPrefix("jpeg") ? 4 : 3)).trimmingCharacters(in: .whitespacesAndNewlines)
                if q.isEmpty {
                    quality = nil
                } else if q.hasSuffix("%") {
                    quality = UInt32(q.dropLast()).map { UInt8(min(max($0, 1), 100)) }
                } else {
                    // 1–10 scale.
                    quality = UInt32(q).map { UInt8(min(max($0, 1), 10) * 10) }
                }
                if !q.isEmpty && quality == nil { continue }
                (format, outExt) = ("jpg", extL.hasPrefix("jpeg") ? "jpeg" : "jpg")
            } else {
                switch extL {
                case "png", "png32": (format, outExt) = ("png32", "png")
                case "png24": (format, outExt) = ("png24", "png")
                case "png8": (format, outExt) = ("png8", "png")
                case "gif": (format, outExt) = ("gif", "gif")
                case "webp": (format, outExt) = ("webp", "webp")
                default: continue
                }
                quality = nil
            }
            out.append(AssetSpec(file: "\(stemPart).\(outExt)", format: format, quality: quality, scale: scale, width: width.flatMap { $0 },
                                 height: height.flatMap { $0 }))
        }
        return out
    }

    /// Parses a `default …` layer name into its variants.
    static func parseDefaults(_ name: String, _ dpi: Double) -> [AssetDefault]? {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("default") else { return nil }
        let rest = t.dropFirst("default".count)
        if let c = rest.first, !c.isWhitespace { return nil }
        var v: [AssetDefault] = []
        for item in rest.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "+" }) {
            let (scale, width, height, tail0) = parseSize(item, dpi)
            let tail = tail0.trimmingCharacters(in: .whitespacesAndNewlines)
            let folder: String, suffix: String
            if let i = tail.lastIndex(of: "/") {
                (folder, suffix) = (String(tail[...i]), String(tail[tail.index(after: i)...]))
            } else {
                (folder, suffix) = ("", tail)
            }
            if scale == nil && width == nil && height == nil && folder.isEmpty && suffix.isEmpty { continue }
            v.append(AssetDefault(scale: scale, width: width.flatMap { $0 }, height: height.flatMap { $0 }, folder: folder, suffix: suffix))
        }
        return v
    }

    static func assetSettings(_ spec: AssetSpec) -> Settings {
        var base = Settings()
        base.transparency = true
        base.matte = nil
        base.metadata = .none
        switch spec.format {
        case "jpg":
            base.format = .jpeg
            base.quality = spec.quality ?? 90
            base.matte = SIMD3(1, 1, 1)
        case "png8":
            base.format = .png8
            base.dither = .none
        case "png24":
            base.format = .png24
            base.transparency = false
            base.matte = SIMD3(1, 1, 1)
        case "gif":
            base.format = .gif
            base.dither = .none
        default:
            base.format = .png24
        }
        return base
    }

    static func isWindowsDeviceAssetName(_ component: String) -> Bool {
        var stem = Substring(component.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(component))
        while stem.hasSuffix(" ") { stem = stem.dropLast() }
        let s = stem.uppercased()
        if ["CON", "PRN", "AUX", "NUL", "CLOCK$", "CONIN$", "CONOUT$"].contains(s) { return true }
        for p in ["COM", "LPT"] where s.hasPrefix(p) {
            if let n = Int(s.dropFirst(3)), (1...9).contains(n), s.count == 4 { return true }
        }
        return false
    }

    /// Layer names and `default` folders are document data, so unsafe output components are
    /// rejected (both separator styles, drive, rooted and UNC paths on every platform).
    static func assetPathComponents(_ relative: String) throws -> [String] {
        var parts: [String] = []
        for part in relative.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init) {
            if part.isEmpty || part == "." || part == ".." || part.hasSuffix(".") || part.hasSuffix(" ") || part.contains(":") || part.contains("\0")
                || isWindowsDeviceAssetName(part) {
                throw other("asset path \(debugQuoted(relative)) has an unsafe component \(debugQuoted(part))")
            }
            parts.append(part)
        }
        return parts
    }

    /// Rust's `{:?}` of a string.
    static func debugQuoted(_ s: String) -> String {
        var o = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            case "\0": o += "\\0"
            default: o.unicodeScalars.append(c)
            }
        }
        return o + "\""
    }

    static func realPath(_ p: String) -> String? {
        guard let r = realpath(p, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    static func pathHasPrefix(_ p: String, _ root: String) -> Bool {
        p == root || p.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    enum FileKind { case missing, symlink, directory, file, other }

    static func kind(_ path: String) -> (FileKind, String?) {
        do {
            let a = try FileManager.default.attributesOfItem(atPath: path)
            switch a[.type] as? FileAttributeType {
            case .typeSymbolicLink?: return (.symlink, nil)
            case .typeDirectory?: return (.directory, nil)
            case .typeRegular?: return (.file, nil)
            default: return (.other, nil)
            }
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError) { return (.missing, nil) }
            if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError, u.domain == NSPOSIXErrorDomain, u.code == Int(ENOENT) { return (.missing, nil) }
            return (.other, error.localizedDescription)
        }
    }

    /// Resolves a generated asset below the selected output directory (photocraft
    /// `asset_output_path`): (the path to write, the path to report in the caller's spelling).
    /// On the local file system an existing symlink below the chosen folder, or at the file, is
    /// refused (the atomic writer would follow it); a scoped file service confines paths itself,
    /// and its folders are created through it.
    static func assetOutputPath(_ s: Session, _ dir: String, _ relative: String) throws -> (String, String) {
        if dir.isEmpty { throw other("image assets need an output directory") }
        var parts = try assetPathComponents(relative)
        let reported = parts.reduce(dir) { FileCommands.join($0, $1) }
        guard let file = parts.popLast() else { throw other("asset path \(debugQuoted(relative)) is empty") }
        let fs = s.services.fileSystem
        guard fs is LocalFileSystem else {
            let parent = parts.reduce(dir) { FileCommands.join($0, $1) }
            if !fs.isDirectory(parent) { try fs.createDirectory(parent) }
            return (FileCommands.join(parent, file), reported)
        }
        let fm = FileManager.default
        let chosen = URL(fileURLWithPath: dir).standardizedFileURL.path
        do { try fm.createDirectory(atPath: chosen, withIntermediateDirectories: true) } catch {
            throw other("asset output directory \(debugQuoted(dir)): \(error.localizedDescription)")
        }
        // The caller chose this root, so a symlink to an existing directory is intentional. All
        // document-derived components below it are checked against its canonical target.
        guard let root = realPath(chosen) else { throw other("asset output directory \(debugQuoted(dir)): cannot resolve it") }
        var parent = root
        for part in parts {
            parent = (parent as NSString).appendingPathComponent(part)
            switch kind(parent) {
            case (.symlink, _): throw other("asset path \(debugQuoted(relative)) crosses a symlink at \(parent)")
            case (.directory, _): break
            case (.missing, _):
                do { try fm.createDirectory(atPath: parent, withIntermediateDirectories: false) } catch {
                    throw other("asset folder \(parent): \(error.localizedDescription)")
                }
            case (.other, let why?): throw other("asset folder \(parent): \(why)")
            default: throw other("asset path \(debugQuoted(relative)) has a non-directory at \(parent)")
            }
            guard let actual = realPath(parent) else { throw other("asset folder \(parent): cannot resolve it") }
            if !pathHasPrefix(actual, root) { throw other("asset path \(debugQuoted(relative)) escapes output directory \(debugQuoted(dir))") }
            parent = actual
        }
        guard let canon = realPath(parent), pathHasPrefix(canon, root) else {
            throw other("asset path \(debugQuoted(relative)) escapes output directory \(debugQuoted(dir))")
        }
        let output = (canon as NSString).appendingPathComponent(file)
        switch kind(output) {
        case (.symlink, _): throw other("asset path \(debugQuoted(relative)) points to a symlink")
        case (.missing, _), (.file, _): break
        case (.other, let why?): throw other("asset path \(debugQuoted(relative)): \(why)")
        default: throw other("asset path \(debugQuoted(relative)) is not a file")
        }
        return (output, reported)
    }

    /// Exports every asset named by `doc`'s layers into `dir`. Returns (files, errors).
    static func generateAssets(_ s: Session, _ doc: Document, _ dir: String) -> ([String], [JSONValue]) {
        let dpi = Double(max(doc.resolutionDpi, 1))
        var defaults: [AssetDefault]?
        var jobs: [(LayerId, AssetSpec)] = []
        for e in doc.walk() {
            let l = e.layer
            if let d = parseDefaults(l.name, dpi) {
                defaults = d
                continue
            }
            if case .adjustment = l.content { continue }
            for spec in parseAssetName(l.name, dpi) { jobs.append((l.id, spec)) }
        }
        let variants = (defaults?.isEmpty ?? true) ? [AssetDefault()] : defaults ?? []
        var files: [String] = []
        var errors: [JSONValue] = []
        for (id, spec) in jobs {
            for v in variants {
                do {
                    let (nameStem, ext): (String, String) = spec.file.lastIndex(of: ".").map { (String(spec.file[..<$0]), String(spec.file[spec.file.index(after: $0)...])) }
                        ?? (spec.file, "png")
                    let rel = "\(v.folder)\(nameStem)\(v.suffix).\(ext)"
                    _ = try assetPathComponents(rel)
                    var one = try LayerMenuCommands.layerDocument(doc, id, renderer: s.services.renderer)
                    one.metadata = Metadata()
                    let (w0, h0) = (Double(one.size.width), Double(one.size.height))
                    // The layer's own size spec wins; default variants scale on top of it.
                    var k = spec.scale ?? 1
                    var (tw, th) = (w0 * k, h0 * k)
                    switch (spec.width, spec.height) {
                    case let (w?, h?): (tw, th) = (w, h)
                    case let (w?, nil): (tw, th) = (w, h0 * w / w0)
                    case let (nil, h?): (tw, th) = (w0 * h / h0, h)
                    default: break
                    }
                    k = v.scale ?? 1
                    tw *= k
                    th *= k
                    switch (v.width, v.height) {
                    case let (w?, h?): (tw, th) = (w, h)
                    case let (w?, nil): (tw, th) = (w, th * w / tw)
                    case let (nil, h?): (tw, th) = (tw * h / th, h)
                    default: break
                    }
                    let st = assetSettings(spec)
                    var conv = st
                    conv.convertToSrgb = true
                    let p: JSONValue = ["width": .number(max(tw.rounded(), 1)), "height": .number(max(th.rounded(), 1))]
                    let (wdoc, _, _) = try webDocument(s, one, p, conv)
                    if spec.format == "webp" {
                        let (out, reported) = try assetOutputPath(s, dir, rel)
                        try FileCommands.saveDoc(s, wdoc, out)
                        files.append(reported)
                        continue
                    }
                    let buf = try flatten(s, wdoc)
                    let o = try optimize(buf, wdoc.size.width, wdoc.bounds, st, icc: nil, xmp: nil, dpi: wdoc.resolutionDpi, preview: false)
                    let (out, reported) = try assetOutputPath(s, dir, rel)
                    try FileCommands.writeFile(s, out, o.bytes)
                    files.append(reported)
                } catch {
                    errors.append(["asset": .string(spec.file), "error": .string(EngineError.wrap(error).description)])
                }
            }
        }
        return (files, errors)
    }

    /// `<document folder>/<document name>-assets`.
    static func assetsDir(_ docPath: String) -> String {
        FileCommands.join((docPath as NSString).deletingLastPathComponent, "\(FileCommands.stem(docPath))-assets")
    }

    static func imageAssets(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let id = d.id
        let was = s.state[ImageAssetsKey.self].contains(id)
        let on = p["on"]?.boolValue ?? !was
        if on {
            if !was { s.state[ImageAssetsKey.self].append(id) }
        } else {
            s.state[ImageAssetsKey.self].removeAll { $0 == id }
        }
        if !on { return ["enabled": false] }
        if let dir = p["dir"]?.stringValue ?? d.path.map(assetsDir) {
            let (files, errors) = generateAssets(s, d.doc, dir)
            return ["enabled": true, "dir": .string(dir), "files": .strings(files), "errors": .array(errors)]
        }
        return ["enabled": true, "dir": .null, "files": .array([]), "note": "assets are written when the document is saved"]
    }

    /// After a save: regenerates the document's image assets when Generate › Image Assets is on
    /// (photocraft `on_saved`, which Automate's `document_saved` calls).
    static func onSaved(_ s: Session, _ index: Int) -> JSONValue? {
        guard index >= 0, index < s.documents.count else { return nil }
        let d = s.documents[index]
        guard s.state[ImageAssetsKey.self].contains(d.id), let path = d.path else { return nil }
        let dir = assetsDir(path)
        let (files, errors) = generateAssets(s, d.doc, dir)
        return ["dir": .string(dir), "files": .strings(files), "errors": .array(errors)]
    }
}
