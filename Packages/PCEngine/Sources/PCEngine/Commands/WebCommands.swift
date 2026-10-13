// Port of photocraft-engine (crates/engine/src/web_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// File › Export › Save for Web (Legacy), File › Export › Export Preferences, the Quick Export
// pipeline that honours them, and File › Generate › Image Assets (Photoshop's Generator).
//
// Save for Web optimises the flattened (optionally resized, sRGB-converted) image as GIF, PNG-8,
// PNG-24, JPEG or WBMP, per slice, into a folder with an optional HTML table; without an output it
// only reports the optimised size (the dialog's 2-Up/4-Up annotations). Colour reduction and
// dithering reuse PCAlgo's `Quantize`; the GIF/WBMP/indexed-PNG writers are
// `WebCommands+Codecs.swift`, PNG-24 and JPEG go through PCPlatform's `ImageCodecs`.
//
// Image Assets implements the naming grammar of Adobe's public Generator documentation
// (`WebCommands+Assets.swift`): a layer or group named `foo.png`, `200% foo@2x.png, 48x48
// icons/foo.png8`, `photo.jpg80%`, `?x100 thumb.gif` is exported into `<document>-assets/`
// whenever the document is saved while the feature is on (`onSaved`); a `default` layer
// (`default 50% low/ + 200% @2x`) adds variants.
//
// photocraft fires the Script Events Manager's "export" event after an export
// (`automate_cmds::fire_event`); `fireEvent` is where that call goes once Automate is ported.

import Foundation
import PCAlgo
import PCDocument
import PCFoundation
import PCPlatform

enum WebCommands: CommandModule {
    static let name = "web_cmds"
    static let m = name

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }
    static func other(_ msg: String) -> EngineError { .other(msg) }

    /// The parameters of the last successful Save for Web (photocraft `FileMenuState::last_web`).
    enum LastWebKey: StateKey {
        static let defaultValue: JSONValue? = nil
    }

    /// Documents with File › Generate › Image Assets on (photocraft `FileMenuState::image_assets`).
    enum ImageAssetsKey: StateKey {
        static let defaultValue: [DocId] = []
    }

    /// photocraft `automate_cmds::fire_event` (Script Events Manager): "export" / "print".
    static func fireEvent(_ s: Session, _ event: String) { AutomateCommands.fireEvent(s, event) }

    // MARK: Settings

    enum WebFormat: String, Sendable {
        case gif, png8, png24, jpeg, wbmp

        static func fromId(_ s: String) -> WebFormat? {
            switch s.lowercased() {
            case "gif": .gif
            case "png8", "png-8": .png8
            case "png24", "png-24", "png", "png32": .png24
            case "jpeg", "jpg": .jpeg
            case "wbmp": .wbmp
            default: nil
            }
        }

        var ext: String {
            switch self {
            case .gif: "gif"
            case .png8, .png24: "png"
            case .jpeg: "jpg"
            case .wbmp: "wbmp"
            }
        }

        var indexed: Bool { self == .gif || self == .png8 }
    }

    /// Which metadata Save for Web embeds (JPEG only, like Photoshop's legacy exporter).
    enum WebMetadata: String, Sendable {
        case none, copyright, copyrightAndContact, all
    }

    /// One optimisation preset (the right-hand side of the Save for Web dialog).
    struct Settings: Equatable, Sendable {
        var format: WebFormat = .png24
        var palette: Quantize.PaletteKind = .selective
        var colors = 256
        var dither: Quantize.Dither = .diffusion
        /// 0…1.
        var ditherAmount: Float = 0.88
        var transparency = true
        /// Edge / background colour (0…1 RGB); nil = no matte (hard alpha threshold).
        var matte: SIMD3<Float>? = SIMD3(1, 1, 1)
        var interlaced = false
        /// Web Snap: palette entries within this distance (0…1 of the channel range) snap to the
        /// web-safe cube.
        var webSnap: Float = 0
        /// JPEG quality 0…100.
        var quality: UInt8 = 60
        var progressive = false
        var optimized = true
        var embedIcc = false
        var metadata: WebMetadata = .copyright
        var convertToSrgb = true

        static func hex3(_ s: String) -> SIMD3<Float>? {
            var t = Substring(s)
            while t.hasPrefix("#") { t = t.dropFirst() }
            guard t.utf8.count == 6, let v = UInt32(t, radix: 16) else { return nil }
            return SIMD3(Float((v >> 16) & 0xff) / 255, Float((v >> 8) & 0xff) / 255, Float(v & 0xff) / 255)
        }

        /// Settings from command parameters (missing keys keep the defaults; Photoshop's preset
        /// names such as "GIF 128 Dithered" or "JPEG High" are accepted as `"preset"`).
        static func fromParams(_ p: JSONValue, _ cmd: String) throws -> Settings {
            var st = Settings()
            if let preset = p["preset"]?.stringValue {
                guard let v = presetSettings(preset) else { throw bad(cmd, "unknown preset `\(preset)`") }
                st = v
            }
            func str(_ k: String) -> String? { p[k]?.stringValue }
            if let f = str("format") {
                guard let v = WebFormat.fromId(f) else { throw bad(cmd, "unknown format `\(f)` (gif|png8|png24|jpeg|wbmp)") }
                st.format = v
            }
            if let k = str("palette") {
                if k == "restrictive" || k == "web" {
                    st.palette = .web
                } else {
                    guard let v = Quantize.PaletteKind(id: k) else {
                        throw bad(cmd, "unknown palette `\(k)` (perceptual|selective|adaptive|restrictive|exact|systemMac|systemWindows|uniform)")
                    }
                    st.palette = v
                }
            }
            if let n = p["colors"]?.intValue, n > 0 { st.colors = min(max(n, 2), 256) }
            if let d = str("dither") {
                switch d {
                case "none", "noDither": st.dither = .none
                case "diffusion": st.dither = .diffusion
                case "pattern": st.dither = .pattern
                case "noise": st.dither = .noise
                default: throw bad(cmd, "unknown dither `\(d)` (none|diffusion|pattern|noise)")
                }
            }
            if let a = p["ditherAmount"]?.doubleValue { st.ditherAmount = min(max(Float(a) / 100, 0), 1) }
            if let b = p["transparency"]?.boolValue { st.transparency = b }
            switch str("matte") {
            case "none"?: st.matte = nil
            case let c?:
                guard let v = hex3(c) else { throw bad(cmd, ##"matte is "none" or "#rrggbb""##) }
                st.matte = v
            case nil: break
            }
            if let b = p["interlaced"]?.boolValue { st.interlaced = b }
            if let b = p["progressive"]?.boolValue { st.progressive = b }
            if let b = p["optimized"]?.boolValue { st.optimized = b }
            if let b = p["embedIcc"]?.boolValue { st.embedIcc = b }
            if let b = p["convertToSrgb"]?.boolValue { st.convertToSrgb = b }
            if let w = p["webSnap"]?.doubleValue { st.webSnap = min(max(Float(w) / 100, 0), 1) }
            if let q = p["quality"]?.doubleValue, !q.isNaN { st.quality = UInt8(min(max(q, 0), 100).rounded()) }
            if let mm = str("metadata") {
                switch mm {
                case "none": st.metadata = .none
                case "copyright": st.metadata = .copyright
                case "copyrightAndContact", "contact": st.metadata = .copyrightAndContact
                case "all", "allExceptCameraInfo": st.metadata = .all
                default: throw bad(cmd, "unknown metadata `\(mm)` (none|copyright|copyrightAndContact|all)")
                }
            }
            return st
        }

        /// The settings as command parameters (the inverse of `fromParams`).
        func toParams() -> JSONValue {
            let palette: String = switch self.palette {
            case .exact: "exact"
            case .systemMac: "systemMac"
            case .systemWindows: "systemWindows"
            case .web: "restrictive"
            case .uniform: "uniform"
            case .perceptual: "perceptual"
            case .selective: "selective"
            case .adaptive: "adaptive"
            }
            let matte = self.matte.map { String(format: "#%02x%02x%02x", WebCommands.to8($0.x), WebCommands.to8($0.y), WebCommands.to8($0.z)) } ?? "none"
            return ["format": .string(format.rawValue), "palette": .string(palette), "colors": .int(colors), "dither": .string(dither.rawValue),
                    "ditherAmount": .number(Double((ditherAmount * 100).rounded())), "transparency": .bool(transparency), "matte": .string(matte),
                    "interlaced": .bool(interlaced), "webSnap": .number(Double((webSnap * 100).rounded())), "quality": .int(Int(quality)),
                    "progressive": .bool(progressive), "optimized": .bool(optimized), "embedIcc": .bool(embedIcc),
                    "metadata": .string(metadata.rawValue), "convertToSrgb": .bool(convertToSrgb)]
        }
    }

    /// Save for Web's named presets.
    static let presets = [
        "GIF 128 Dithered", "GIF 128 No Dither", "GIF 32 Dithered", "GIF 32 No Dither", "GIF 64 Dithered", "GIF 64 No Dither",
        "GIF Restrictive", "JPEG High", "JPEG Low", "JPEG Medium", "PNG-24", "PNG-8 128 Dithered",
    ]

    static func presetSettings(_ name: String) -> Settings? {
        func gif(_ colors: Int, _ dither: Bool) -> Settings {
            var s = Settings()
            s.format = .gif
            s.colors = colors
            s.dither = dither ? .diffusion : .none
            return s
        }
        func jpeg(_ q: UInt8) -> Settings {
            var s = Settings()
            s.format = .jpeg
            s.quality = q
            return s
        }
        switch name {
        case "GIF 128 Dithered": return gif(128, true)
        case "GIF 128 No Dither": return gif(128, false)
        case "GIF 32 Dithered": return gif(32, true)
        case "GIF 32 No Dither": return gif(32, false)
        case "GIF 64 Dithered": return gif(64, true)
        case "GIF 64 No Dither": return gif(64, false)
        case "GIF Restrictive":
            var s = gif(256, true)
            s.palette = .web
            return s
        case "JPEG High": return jpeg(60)
        case "JPEG Low": return jpeg(10)
        case "JPEG Medium": return jpeg(30)
        case "JPEG Maximum": return jpeg(100)
        case "JPEG Very High": return jpeg(80)
        case "PNG-24": return Settings()
        case "PNG-8 128 Dithered":
            var s = Settings()
            s.format = .png8
            s.colors = 128
            return s
        default: return nil
        }
    }

    // MARK: The image

    /// A scratch session holding a copy of `doc` (photocraft `Session::new()` for commands that
    /// work on a copy; FileCommands' `scratchSession`: the caller's registry, services and gate).
    static func scratch(_ s: Session, _ doc: Document) -> Session {
        let t = FileCommands.scratchSession(s)
        _ = t.setActive(t.addDocument(doc))
        return t
    }

    /// The document as Save for Web sees it: RGB (converted to sRGB unless told otherwise), resized
    /// by `"width"`/`"height"`/`"percent"`, flattened. Returns the document and the scale factors.
    static func webDocument(_ s: Session, _ doc: Document, _ p: JSONValue, _ st: Settings) throws -> (Document, Double, Double) {
        let tmp = scratch(s, doc)
        if doc.mode != .rgb { try tmp.execute("image.mode.rgb") }
        if st.convertToSrgb && doc.iccProfile != nil {
            // Documents without a profile are treated as sRGB already.
            try tmp.execute("edit.convertToProfile", ["profile": "srgb", "intent": "perceptual"])
        }
        let (w0, h0) = (Double(doc.size.width), Double(doc.size.height))
        func positive(_ k: String) -> Double? { p[k]?.doubleValue.flatMap { $0 > 0 ? $0 : nil } }
        let (pct, w, h) = (positive("percent"), positive("width"), positive("height"))
        var (nw, nh) = (w0, h0)
        if let pc = pct {
            (nw, nh) = (w0 * pc / 100, h0 * pc / 100)
        } else if let w, let h {
            (nw, nh) = (w, h)
        } else if let w {
            (nw, nh) = (w, h0 * w / w0)
        } else if let h {
            (nw, nh) = (w0 * h / h0, h)
        }
        (nw, nh) = (max(nw.rounded(), 1), max(nh.rounded(), 1))
        if abs(nw - w0) >= 1 || abs(nh - h0) >= 1 {
            let resample = p["resample"]?.stringValue ?? "bicubic"
            try tmp.execute("image.imageSize", ["width": .number(nw), "height": .number(nh), "resample": .string(resample)])
        }
        guard let out = tmp.active?.doc else { throw EngineError.noDocument }
        return (out, nw / w0, nh / h0)
    }

    /// The flattened composite of `doc` (straight RGBA over its bounds; photocraft
    /// `compose::flatten`).
    static func flatten(_ s: Session, _ doc: Document) throws -> [SIMD4<Float>] {
        do { return try s.services.renderer.render(doc, region: doc.bounds).px } catch { throw EngineError.wrap(error) }
    }

    /// An optimised image.
    struct Optimized: Sendable {
        var bytes: [UInt8]
        var ext: String
        var width: Int
        var height: Int
        /// Colours in the palette (indexed formats).
        var colors: Int?
        /// What the optimised file looks like, straight RGBA8 (for the dialog's previews).
        var preview: [UInt8]
    }

    static func to8(_ v: Float) -> UInt8 { UInt8((min(max(v.isNaN ? 0 : v, 0), 1) * 255).rounded()) }

    /// XMP to embed for the metadata choice (photocraft `web_xmp`).
    static func webXMP(_ doc: Document, _ m: WebMetadata) -> String? {
        guard let xmp = doc.metadata.xmp else { return nil }
        switch m {
        case .none: return nil
        case .all: return xmp
        case .copyright, .copyrightAndContact:
            let info = FileCommands.readFileInfo(xmp)
            var keys = ["copyright", "copyrightStatus", "copyrightUrl"]
            if m == .copyrightAndContact { keys += ["author", "authorTitle"] }
            var keep: [String: JSONValue] = [:]
            for k in keys {
                guard let v = info[k] else { continue }
                if let s = v.stringValue, !s.isEmpty { keep[k] = v } else if v.arrayValue != nil { keep[k] = v }
            }
            return keep.isEmpty ? nil : FileCommands.writeFileInfo(nil, .object(keep))
        }
    }

    /// Optimises `rect` of `px` (straight RGBA, `bw` wide) with `st`. `preview` also returns what
    /// the file looks like (the dialog's panes); exports skip it.
    static func optimize(_ px: [SIMD4<Float>], _ bw: Int, _ rect: PixelRect, _ st: Settings, icc: [UInt8]?, xmp: String?, dpi: Float,
                         preview: Bool) throws -> Optimized {
        let (w, h) = (rect.width, rect.height)
        if w <= 0 || h <= 0 { throw other("empty slice") }
        guard rect.x0 >= 0, rect.y0 >= 0, Int(rect.x1) <= bw, Int(rect.y1) * bw <= px.count else { throw other("empty slice") }
        var region: [SIMD4<Float>] = []
        region.reserveCapacity(w * h)
        for y in Int(rect.y0)..<Int(rect.y1) {
            let o = y * bw
            region.append(contentsOf: px[(o + Int(rect.x0))..<(o + Int(rect.x1))])
        }
        let matte = st.matte ?? SIMD3(1, 1, 1)
        func over(_ p: SIMD4<Float>) -> SIMD4<Float> {
            SIMD4(p.x * p.w + matte.x * (1 - p.w), p.y * p.w + matte.y * (1 - p.w), p.z * p.w + matte.z * (1 - p.w), 1)
        }
        var look: [UInt8] = []
        let bytes: [UInt8]
        var colors: Int?
        func codec(_ e: any Error) -> EngineError { other("\(e)") }
        switch st.format {
        case .png24:
            let alpha = st.transparency && region.contains { $0.w < 1 }
            let k = alpha ? 4 : 3
            var data: [UInt8] = []
            data.reserveCapacity(w * h * k)
            for p in region {
                let q = alpha ? p : over(p)
                data.append(to8(q.x)); data.append(to8(q.y)); data.append(to8(q.z))
                if alpha { data.append(to8(q.w)) }
            }
            if preview {
                look = alpha ? data : stride(from: 0, to: data.count, by: 3).flatMap { [data[$0], data[$0 + 1], data[$0 + 2], 255] }
            }
            let fmt = PixelFormat(mode: .rgb, sample: .u8, alpha: alpha)
            var o = EncodeOptions()
            o.pngInterlaced = st.interlaced
            o.embedICC = icc != nil
            o.embedMetadata = true
            let meta = ImageMetadata(xmp: xmp.map { Data($0.utf8) }, resolution: Resolution(x: Double(dpi), y: Double(dpi)))
            let profile = icc.flatMap { try? ICCProfile(data: Data($0)) }
            do {
                bytes = [UInt8](try ImageCodecs.encode(RasterBuffer(width: w, height: h, format: fmt, bytes: data), as: .png, profile: profile,
                                                        metadata: meta, options: o))
            } catch { throw codec(error) }
        case .jpeg:
            var rgb: [UInt8] = []
            rgb.reserveCapacity(w * h * 3)
            for p in region {
                let q = over(p)
                rgb.append(to8(q.x)); rgb.append(to8(q.y)); rgb.append(to8(q.z))
            }
            // Save for Web's 0–100 quality → encoder 1–100.
            var o = EncodeOptions()
            o.jpegQuality = Int(max(st.quality, 1))
            o.jpegProgressive = st.progressive
            let embed = st.embedIcc ? icc : nil
            o.embedICC = embed != nil
            o.embedMetadata = true
            let profile = embed.flatMap { try? ICCProfile(data: Data($0)) }
            let meta = ImageMetadata(xmp: xmp.map { Data($0.utf8) }, resolution: dpi >= 1 ? Resolution(x: Double(dpi), y: Double(dpi)) : nil)
            do {
                bytes = [UInt8](try ImageCodecs.encode(RasterBuffer(width: w, height: h, format: PixelFormat(mode: .rgb, sample: .u8, alpha: false), bytes: rgb),
                                                        as: .jpeg, profile: profile, metadata: meta, options: o))
            } catch { throw codec(error) }
            if preview {
                // The preview shows the compression artefacts.
                if let img = try? ImageCodecs.decode(Data(bytes)) {
                    let r = PixelRect(x0: 0, y0: 0, x1: Int32(img.size.width), y1: Int32(img.size.height))
                    look = img.surface.readRGBA(r).flatMap { [to8($0.x), to8($0.y), to8($0.z), to8($0.w)] }
                }
                if look.count != w * h * 4 { look = stride(from: 0, to: rgb.count, by: 3).flatMap { [rgb[$0], rgb[$0 + 1], rgb[$0 + 2], 255] } }
            }
        case .wbmp:
            var gray: [Float] = region.map { p in
                let q = over(p)
                return 0.299 * q.x + 0.587 * q.y + 0.114 * q.z
            }
            let method: Quantize.BitmapMethod = switch st.dither {
            case .none: .threshold
            case .pattern: .pattern
            default: .diffusion
            }
            Quantize.toBitmap(&gray, w: w, method: method)
            let white = gray.map { $0 > 0.5 }
            if preview { look = white.flatMap { $0 ? [255, 255, 255, 255] : [0, 0, 0, 255] } }
            do { bytes = try Codec.encodeWbmp(w, h, white) } catch { throw codec(error) }
            colors = 2
        case .gif, .png8:
            let transparent = st.transparency && region.contains { $0.w < 0.5 }
            // Partially transparent edges blend with the matte; with transparency off everything does.
            var work: [SIMD4<Float>] = region.map { p in
                if st.transparency && p.w < 0.5 { return .zero }
                if st.transparency && st.matte == nil { return SIMD4(p.x, p.y, p.z, 1) }
                return over(p)
            }
            let room = transparent ? max(st.colors - 1, 2) : st.colors
            // Large images: build adaptive palettes from an even ~1 MP sample (Exact needs all).
            let opaque = work.filter { $0.w >= 0.5 }
            let step = opaque.count > 1 << 20 && st.palette != .exact ? opaque.count / (1 << 20) + 1 : 1
            var src: [SIMD4<Float>] = step == 1 ? opaque : stride(from: 0, to: opaque.count, by: step).map { opaque[$0] }
            if src.isEmpty { src = work }
            var pal: [SIMD3<UInt8>]
            do { pal = try Quantize.buildPalette(src, kind: st.palette, colors: room, forced: .none) } catch { throw other("\(error)") }
            if pal.isEmpty { pal = [.zero] }
            if st.webSnap > 0 {
                let tol = Int(st.webSnap * 255)
                for i in pal.indices {
                    let c = pal[i]
                    let snap = SIMD3<UInt8>(UInt8((Float(c.x) / 51).rounded() * 51), UInt8((Float(c.y) / 51).rounded() * 51), UInt8((Float(c.z) / 51).rounded() * 51))
                    if abs(Int(c.x) - Int(snap.x)) <= tol && abs(Int(c.y) - Int(snap.y)) <= tol && abs(Int(c.z) - Int(snap.z)) <= tol { pal[i] = snap }
                }
            }
            var t: Int?
            if transparent {
                if pal.count > 255 { pal.removeLast(pal.count - 255) }
                pal.append(pal[0])
                t = pal.count - 1
            }
            let idx = quantizeRows(&work, w, pal, st.dither, st.ditherAmount, t)
            if preview {
                look = idx.flatMap { k -> [UInt8] in
                    let c = pal[Int(k)]
                    return [c.x, c.y, c.z, Int(k) == t ? 0 : 255]
                }
            }
            let tt = t.map { UInt8($0) }
            do {
                bytes = st.format == .gif ? try Codec.encodeGifIndexed(w, h, idx, pal, transparent: tt, interlaced: st.interlaced)
                    : try Codec.encodePngIndexed(w, h, idx, pal, transparent: tt)
            } catch { throw codec(error) }
            colors = pal.count
        }
        return Optimized(bytes: bytes, ext: st.format.ext, width: w, height: h, colors: colors, preview: look)
    }

    /// Nearest palette entry through a lazily filled 6-bit-per-channel inverse colour map: each
    /// 4×4×4 cell is resolved once (by its centre), so large images cost a table lookup per pixel
    /// instead of a palette scan. `t` (the transparent index) is never returned.
    struct InverseMap {
        let pal: [SIMD3<UInt8>]
        let t: Int?
        var lut: [UInt16]

        init(_ pal: [SIMD3<UInt8>], _ t: Int?) {
            self.pal = pal
            self.t = t
            lut = [UInt16](repeating: .max, count: 1 << 18)
        }

        mutating func get(_ c: SIMD3<Float>) -> Int {
            func q(_ v: Float) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) >> 2 }
            let (r, g, b) = (q(c.x), q(c.y), q(c.z))
            let key = r << 12 | g << 6 | b
            let v = lut[key]
            if v != .max { return Int(v) }
            let center = SIMD3<Float>(Float(r * 4 + 2), Float(g * 4 + 2), Float(b * 4 + 2))
            var best = (Float.greatestFiniteMagnitude, 0)
            for (i, e) in pal.enumerated() where i != t {
                let d = center - SIMD3(Float(e.x), Float(e.y), Float(e.z))
                let dd = (d * d).sum()
                if dd < best.0 { best = (dd, i) }
            }
            lut[key] = UInt16(best.1)
            return best.1
        }
    }

    static func hash01(_ x: Int, _ y: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: x) &* 0x8da6_b343 ^ UInt32(truncatingIfNeeded: y) &* 0xd816_3841 ^ 0x2545_f491
        h ^= h >> 13
        h = h &* 0x5bd1_e995
        h ^= h >> 15
        return Float(h & 0xffff) / 65535
    }

    /// Palette mapping with dithering (Floyd–Steinberg diffusion, 8×8 Bayer pattern, noise), like
    /// `Quantize.quantize` but through `InverseMap` (photocraft `quantize_band` / `quantize_rows`).
    /// Pixels with alpha < ½ take index `t`. The pattern and noise dithers depend on position
    /// only, so photocraft's parallel bands give the same indices as this single pass.
    static func quantizeRows(_ px: inout [SIMD4<Float>], _ w: Int, _ pal: [SIMD3<UInt8>], _ dither: Quantize.Dither, _ amount: Float, _ t: Int?) -> [UInt8] {
        let h = px.count / max(w, 1)
        var map = InverseMap(pal, t)
        var idx = [UInt8](repeating: 0, count: px.count)
        let opaqueN = pal.count - (t != nil ? 1 : 0)
        let a = min(max(amount, 0), 1)
        let spread = min(1 / max(cbrt(Float(opaqueN)), 1), 0.5) * a
        let diffusion = dither == .diffusion
        var cur = [SIMD3<Float>](repeating: .zero, count: diffusion ? w + 2 : 0)
        var next = cur
        for y in 0..<h {
            if diffusion {
                swap(&cur, &next)
                for i in next.indices { next[i] = .zero }
            }
            for x in 0..<w {
                let i = y * w + x
                let p = px[i]
                if p.w < 0.5, let t {
                    idx[i] = UInt8(t)
                    continue
                }
                var c = SIMD3(p.x, p.y, p.z)
                switch dither {
                case .none: break
                case .diffusion: c += cur[x + 1]
                case .pattern: c += SIMD3(repeating: Quantize.bayer8(x, y) * spread)
                case .noise: c += SIMD3(repeating: (hash01(x, y) - 0.5) * spread)
                }
                c = c.clamped(lowerBound: .zero, upperBound: .one)
                let k = map.get(c)
                idx[i] = UInt8(k)
                if diffusion {
                    let e = SIMD3<Float>(Float(pal[k].x), Float(pal[k].y), Float(pal[k].z)) / 255
                    let d = (c - e) * a
                    cur[x + 2] += d * 7 / 16
                    next[x] += d * 3 / 16
                    next[x + 1] += d * 5 / 16
                    next[x + 2] += d / 16
                }
            }
        }
        return idx
    }

    // MARK: Slices and HTML

    /// A file-name-safe slice name.
    static func sliceFile(_ name: String) -> String {
        let s = String(String.UnicodeScalarView(name.unicodeScalars.map { u in
            u.properties.isAlphabetic || u.properties.numericType != nil || u == "-" || u == "_" ? u : "_"
        }))
        return portableGeneratedStem(s.isEmpty ? "slice" : s)
    }

    /// Generated filenames stay usable on Windows even when a document or slice is named after a
    /// reserved device. Caller-supplied path components are still rejected.
    static func portableGeneratedStem(_ stem: String) -> String { isWindowsDeviceAssetName(stem) ? stem + "_" : stem }

    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Imported slice URLs are document data. Only ordinary web/contact links and relative links
    /// become anchors; an unsupported scheme leaves the image unlinked.
    static func safeSliceURL(_ url: String) -> Bool {
        if url.isEmpty || url.trimmingCharacters(in: .whitespacesAndNewlines) != url { return false }
        if url.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0 == "\\" }) { return false }
        let delimiter = url.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? url.endIndex
        guard let colon = url.firstIndex(of: ":"), colon < delimiter else { return true }
        let scheme = url[..<colon].lowercased()
        let rest = url[url.index(after: colon)...]
        switch scheme {
        case "http", "https", "ftp", "ftps":
            guard rest.hasPrefix("//") else { return false }
            let host = rest.dropFirst(2)
            return !host.isEmpty && !host.hasPrefix("/")
        case "mailto", "tel": return !rest.isEmpty
        default: return false
        }
    }

    /// Keeps the image folder relative to the selected export directory on every platform.
    static func webImagesFolder(_ images: String, _ cmd: String) throws -> String {
        if images.isEmpty { return "" }
        var trimmed = Substring(images)
        while trimmed.hasSuffix("/") || trimmed.hasSuffix("\\") { trimmed = trimmed.dropLast() }
        if trimmed.isEmpty { throw bad(cmd, "imagesFolder must be a relative folder name") }
        do { return try assetPathComponents(String(trimmed)).joined(separator: "/") } catch {
            throw bad(cmd, "imagesFolder: \(EngineError.wrap(error).description)")
        }
    }

    static func webDerivedPath(_ s: Session, _ dir: String, _ relative: String, nativePaths: Bool) throws -> String {
        if nativePaths { return try assetOutputPath(s, dir.isEmpty ? "." : dir, relative).0 }
        // Platform writers (browser downloads) take logical names, without a host file system.
        _ = try assetPathComponents(relative)
        return FileCommands.join(dir, relative)
    }

    static func scaleRect(_ r: PixelRect, _ sx: Double, _ sy: Double) -> PixelRect {
        func c(_ v: Int32, _ k: Double) -> Int32 { Int32(clamping: Int64(max(min((Double(v) * k).rounded(), 9e18), -9e18))) }
        return PixelRect(x0: c(r.x0, sx), y0: c(r.y0, sy), x1: c(r.x1, sx), y1: c(r.y1, sy))
    }

    /// The HTML table for `cells` (rect, td attributes, td body) over a `w`×`h` image: one column
    /// per distinct x edge, one row per y edge, colspan/rowspan per slice, and a spacer row fixing
    /// column widths.
    static func htmlTable(_ title: String, _ w: Int, _ h: Int, _ cells: [(PixelRect, String, String)], spacer: String?) -> String {
        let xs = Array(Set(cells.flatMap { [$0.0.x0, $0.0.x1] })).sorted()
        let ys = Array(Set(cells.flatMap { [$0.0.y0, $0.0.y1] })).sorted()
        func col(_ x: Int32) -> Int { xs.firstIndex(of: x) ?? 0 }
        func row(_ y: Int32) -> Int { ys.firstIndex(of: y) ?? 0 }
        let (nc, nr) = (max(xs.count - 1, 0), max(ys.count - 1, 0))
        var taken = [Bool](repeating: false, count: nc * nr)
        var byRow = [[(Int, String)]](repeating: [], count: nr)
        for (r, attrs, body) in cells {
            let (c0, c1, r0, r1) = (col(r.x0), col(r.x1), row(r.y0), row(r.y1))
            guard c0 < c1, r0 < r1 else { continue }
            if (r0..<r1).contains(where: { j in (c0..<c1).contains { taken[j * nc + $0] } }) { continue }
            for j in r0..<r1 { for i in c0..<c1 { taken[j * nc + i] = true } }
            var td = "\t\t<td"
            if c1 - c0 > 1 { td += " colspan=\"\(c1 - c0)\"" }
            if r1 - r0 > 1 { td += " rowspan=\"\(r1 - r0)\"" }
            td += attrs + ">" + body + "</td>\n"
            byRow[r0].append((c0, td))
        }
        let t = htmlEscape(title)
        var s = "<html>\n<head>\n<title>\(t)</title>\n<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">\n</head>\n<body bgcolor=\"#FFFFFF\" leftmargin=\"0\" topmargin=\"0\" marginwidth=\"0\" marginheight=\"0\">\n<!-- Save for Web Slices (\(t)) -->\n<table id=\"Table_01\" width=\"\(w)\" height=\"\(h)\" border=\"0\" cellpadding=\"0\" cellspacing=\"0\">\n"
        for (j, tds) in byRow.enumerated() {
            s += "\t<tr>\n"
            for (_, td) in tds.enumerated().sorted(by: { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }).map(\.element) { s += td }
            if let sp = spacer {
                s += "\t\t<td>\n\t\t\t<img src=\"\(htmlEscape(sp))\" width=\"1\" height=\"\(ys[j + 1] - ys[j])\" alt=\"\"></td>\n"
            }
            s += "\t</tr>\n"
        }
        if let sp = spacer {
            s += "\t<tr>\n"
            for i in 0..<nc { s += "\t\t<td>\n\t\t\t<img src=\"\(htmlEscape(sp))\" width=\"\(xs[i + 1] - xs[i])\" height=\"1\" alt=\"\"></td>\n" }
            s += "\t\t<td></td>\n\t</tr>\n"
        }
        s += "</table>\n<!-- End Save for Web Slices -->\n</body>\n</html>\n"
        return s
    }

    // MARK: Save for Web

    /// File › Export › Save for Web (Legacy).
    static func saveForWeb(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        try saveForWebImpl(s, p, write: { path, bytes in try FileCommands.writeFile(s, path, bytes) }, nativePaths: true)
    }

    /// Save for Web through a platform writer (native files or browser downloads). The writer
    /// receives every image, spacer and HTML file. A write error stops the export; only a complete
    /// export remembers its settings and fires the export event. A custom writer that targets the
    /// local file system must enforce its own path confinement.
    static func saveForWebWithWriter(_ s: Session, _ p: JSONValue, write: (String, [UInt8]) throws -> Void) throws -> JSONValue {
        try saveForWebImpl(s, p, write: write, nativePaths: false)
    }

    static func saveForWebImpl(_ s: Session, _ p: JSONValue, write: (String, [UInt8]) throws -> Void, nativePaths: Bool) throws -> JSONValue {
        let cmd = "file.export.saveForWebLegacy"
        if let authorize = s.authorize {
            do { try authorize(cmd, p) } catch { throw EngineError.wrap(error) }
        }
        // Direct platform calls export the moved selection as it appears on the canvas, just as
        // `Session.execute` does before dispatching the command.
        _ = try FloatCommands.beforeCommand(s, cmd)
        let st = try Settings.fromParams(p, cmd)
        guard let d = s.active else { throw EngineError.noDocument }
        let doc = d.doc
        let (wdoc, sx, sy) = try webDocument(s, doc, p, st)
        let buf = try flatten(s, wdoc)
        let bw = wdoc.size.width
        let icc = wdoc.iccProfile
        let xmp = webXMP(doc, st.metadata)
        let dpi = wdoc.resolutionDpi
        let all = doc.resolvedSlices()
        let pick = p["slices"]?.stringValue ?? "all"
        let numbers: [UInt64]? = p["numbers"]?.arrayValue.map { $0.compactMap(\.uint64Value) }
        let chosen = all.filter { r in
            if let n = numbers { return n.contains(UInt64(r.number)) }
            if pick == "user" { return r.origin != .auto }
            return true
        }
        let single = p["path"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let dirParam = p["dir"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        // A trusted-markup decision applies to this export only, never to another document
        // exported with the dialog's remembered settings.
        var lastWeb = p
        if case .object(var o) = lastWeb {
            o["trustedSliceHtml"] = nil
            lastWeb = .object(o)
        }
        func optional(_ v: Int?) -> JSONValue { v.map { .int($0) } ?? .null }
        // Estimate only (the dialog's annotations): the whole image.
        if single == nil && dirParam == nil {
            let o = try optimize(buf, bw, wdoc.bounds, st, icc: icc, xmp: xmp, dpi: dpi, preview: false)
            return ["format": .string(o.ext), "bytes": .int(o.bytes.count), "width": .int(o.width), "height": .int(o.height), "colors": optional(o.colors)]
        }
        if let path = single, dirParam == nil, all.count == 1 || p["slices"] == nil {
            let o = try optimize(buf, bw, wdoc.bounds, st, icc: icc, xmp: xmp, dpi: dpi, preview: false)
            try write(path, o.bytes)
            s.state[LastWebKey.self] = lastWeb
            fireEvent(s, "export")
            return ["files": .strings([path]), "bytes": .int(o.bytes.count), "width": .int(o.width), "height": .int(o.height), "colors": optional(o.colors)]
        }
        let dir = dirParam ?? single.map { ($0 as NSString).deletingLastPathComponent } ?? ""
        let html = p["html"]?.boolValue ?? false
        let images = try webImagesFolder(p["imagesFolder"]?.stringValue ?? "images", cmd)
        let trustedSliceHtml = p["trustedSliceHtml"]?.boolValue ?? false
        let base = portableGeneratedStem(single.map(FileCommands.stem) ?? doc.sliceBaseName)
        var files: [String] = []
        var cells: [(PixelRect, String, String)] = []
        var total = 0
        // Output names are unique (case-insensitively, for macOS and Windows file systems): two
        // slices named alike, or names that sanitize alike, must not overwrite each other. The HTML
        // page's spacer image is reserved.
        var used = Set<String>()
        if html { used.insert("spacer.gif") }
        func unique(_ stem: String, _ ext: String) -> String {
            var name = "\(stem).\(ext)"
            var k = 2
            while !used.insert(name.lowercased()).inserted {
                name = "\(stem)_\(k).\(ext)"
                k += 1
            }
            return name
        }
        // Stacking order: later stored slices are on top (auto slices never overlap anything).
        func z(_ r: ResolvedSlice) -> Int { r.id.flatMap { id in doc.slices.list.firstIndex { $0.id == id } } ?? -1 }
        for r in chosen {
            let rect = scaleRect(r.rect, sx, sy).intersect(wdoc.bounds)
            if rect.isEmpty { continue }
            // In the HTML table a slice shows only where no slice above covers it; that visible part
            // is cut into rectangles, each its own cell (and image), as Photoshop's subslices.
            let pieces: [PixelRect]
            if html {
                let above = chosen.filter { z($0) > z(r) }.map { scaleRect($0.rect, sx, sy).intersect(wdoc.bounds) }
                pieces = autoSlices(canvas: rect, taken: above)
            } else {
                pieces = [rect]
            }
            let split = pieces.count > 1
            let stored = r.id.flatMap { doc.slices.get($0) }
            for (k, piece) in pieces.enumerated() {
                if r.kind == .noImage {
                    let text = k > 0 ? "" : stored.map { trustedSliceHtml && $0.cellTextIsHtml ? $0.cellText : htmlEscape($0.cellText) } ?? ""
                    let bg = stored?.background.map { String(format: " bgcolor=\"#%02X%02X%02X\"", $0[1], $0[2], $0[3]) } ?? ""
                    cells.append((piece, bg, text))
                    continue
                }
                let o = try optimize(buf, bw, piece, st, icc: icc, xmp: xmp, dpi: dpi, preview: false)
                let stem = split ? "\(sliceFile(r.name))_\(String(format: "%02d", k + 1))" : sliceFile(r.name)
                let name = unique(stem, o.ext)
                let rel = images.isEmpty ? name : "\(images)/\(name)"
                let out = FileCommands.join(dir, rel)
                try write(try webDerivedPath(s, dir, rel, nativePaths: nativePaths), o.bytes)
                total += o.bytes.count
                files.append(out)
                let alt = stored.map { htmlEscape($0.alt) } ?? ""
                let img = "\n\t\t\t<img src=\"\(htmlEscape(rel))\" width=\"\(piece.width)\" height=\"\(piece.height)\" alt=\"\(alt)\">"
                let body: String
                if let sl = stored, safeSliceURL(sl.url) {
                    let target = sl.target.isEmpty ? "" : " target=\"\(htmlEscape(sl.target))\""
                    body = "\n\t\t\t<a href=\"\(htmlEscape(sl.url))\"\(target)>\(img)</a>"
                } else {
                    body = img
                }
                cells.append((piece, "", body))
            }
        }
        var htmlPath: String?
        if html {
            let grid = cells.count > 1
            let spacer: String? = grid ? (images.isEmpty ? "spacer.gif" : "\(images)/spacer.gif") : nil
            if let sp = spacer {
                let gif: [UInt8]
                do { gif = try Codec.encodeGifIndexed(1, 1, [0], [.zero], transparent: 0, interlaced: false) } catch { throw other("\(error)") }
                try write(try webDerivedPath(s, dir, sp, nativePaths: nativePaths), gif)
            }
            let page = htmlTable(base, wdoc.size.width, wdoc.size.height, cells, spacer: spacer)
            let hp = FileCommands.join(dir, "\(base).html")
            try write(try webDerivedPath(s, dir, "\(base).html", nativePaths: nativePaths), Array(page.utf8))
            htmlPath = hp
        }
        s.state[LastWebKey.self] = lastWeb
        fireEvent(s, "export")
        return ["files": .strings(files), "html": htmlPath.map { .string($0) } ?? .null, "bytes": .int(total), "slices": .int(chosen.count),
                "width": .int(wdoc.size.width), "height": .int(wdoc.size.height)]
    }

    // MARK: Export Preferences / Quick Export

    /// photocraft prefs `choices` / `range` for the Export section (validated before `prefs.set`).
    static let exportChoices: [String: [String]] = [
        "export.quickExportFormat": ["png", "jpg", "gif", "webp"],
        "export.quickExportLocation": ["ask", "sameFolder"],
        "export.metadata": ["none", "copyright", "all"],
    ]
    static let exportRanges: [String: (Double, Double)] = ["export.jpegQuality": (1, 100), "export.webpQuality": (1, 100)]

    static func exportPreferences(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.export.exportPreferences"
        var values: [String: JSONValue] = [:]
        for (k, key) in [("quickExportFormat", "export.quickExportFormat"), ("quickExportLocation", "export.quickExportLocation"),
                         ("jpegQuality", "export.jpegQuality"), ("webpLossless", "export.webpLossless"), ("webpQuality", "export.webpQuality"),
                         ("metadata", "export.metadata"), ("convertToSrgb", "export.convertToSrgb")] {
            guard let v = p[k] else { continue }
            // photocraft's `prefs.set` refuses these (its typed preferences); the message is the one
            // its error carries.
            func refuse(_ m: String) -> EngineError { bad(cmd, EngineError.bad("prefs.set", m).description) }
            if let c = exportChoices[key] {
                guard let str = v.stringValue else { throw refuse("`\(key)` must be one of \(c.joined(separator: "|"))") }
                if !c.contains(str) { throw refuse("`\(key)` must be one of \(c.joined(separator: "|")) (got `\(str)`)") }
            }
            if let rg = exportRanges[key] {
                let (lo, hi) = rg
                guard let x = v.doubleValue else { throw refuse("`\(key)` must be a number") }
                if !(lo...hi).contains(x) { throw refuse("`\(key)` must be within \(Int(lo))..\(Int(hi)) (got \(v.serialized()))") }
            }
            values[key] = v
        }
        if !values.isEmpty {
            do { try s.execute("prefs.set", ["values": .object(values)]) } catch { throw bad(cmd, EngineError.wrap(error).description) }
        }
        return ["section": "export", "values": s.preferences["export"] ?? .null]
    }

    /// File › Export › Quick Export as <format>: the format, quality, metadata, colour space and
    /// location from Export Preferences. `path` overrides the location ("ask" needs one).
    static func quickExport(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.export.quickExport"
        let prefs = s.preferences["export"] ?? .null
        let fmt = prefs["quickExportFormat"]?.stringValue ?? "png"
        guard let d = s.active else { throw EngineError.noDocument }
        let doc = d.doc
        let path: String
        if let v = p["path"]?.stringValue, !v.isEmpty {
            path = v
        } else if prefs["quickExportLocation"]?.stringValue == "sameFolder", let dp = d.path {
            path = FileCommands.join((dp as NSString).deletingLastPathComponent, "\(FileCommands.stem(dp)).\(fmt)")
        } else {
            throw bad(cmd, #"missing `path` (Export Preferences › Location is "ask", or the document was never saved)"#)
        }
        let metadata = prefs["metadata"]?.stringValue ?? ""
        let convert = prefs["convertToSrgb"]?.boolValue ?? true
        var o: [String: JSONValue] = ["metadata": .string(metadata == "all" ? "all" : metadata == "none" ? "none" : "copyright"),
                                      "convertToSrgb": .bool(convert), "transparency": true]
        switch fmt {
        case "jpg":
            o["format"] = "jpeg"
            o["quality"] = .int(min(max(prefs["jpegQuality"]?.intValue ?? 85, 0), 100))
        case "gif":
            o["format"] = "gif"
        case "webp":
            // WebP uses the regular exporter. Lossless unless Export Preferences ask for lossy at
            // their 1–100 quality.
            var ws = Settings()
            ws.convertToSrgb = convert
            let (wdoc, _, _) = try webDocument(s, doc, [:], ws)
            let lossless = prefs["webpLossless"]?.boolValue ?? true
            let quality = lossless ? nil : min(max(prefs["webpQuality"]?.intValue ?? 85, 1), 100)
            let warnings = try saveWebP(s, wdoc, path, quality: quality)
            fireEvent(s, "export")
            return ["path": .string(path), "format": .string(fmt), "warnings": .strings(warnings)]
        default:
            o["format"] = "png24"
        }
        let st = try Settings.fromParams(.object(o), cmd)
        let (wdoc, _, _) = try webDocument(s, doc, [:], st)
        let buf = try flatten(s, wdoc)
        let xmp = webXMP(doc, st.metadata)
        let opt = try optimize(buf, wdoc.size.width, wdoc.bounds, st, icc: wdoc.iccProfile, xmp: xmp, dpi: wdoc.resolutionDpi, preview: false)
        try FileCommands.writeFile(s, path, opt.bytes)
        fireEvent(s, "export")
        return ["path": .string(path), "format": .string(fmt), "bytes": .int(opt.bytes.count)]
    }

    /// A WebP of `doc`'s composite: lossless, or lossy at `quality` 1–100 (photocraft `save_doc`
    /// with a quality on Photoshop's 0–12 scale, mapped back to the codec's 1–100).
    static func saveWebP(_ s: Session, _ doc: Document, _ path: String, quality: Int?) throws -> [String] {
        let pf = doc.pixelFormat
        let target = PixelFormat(mode: pf.mode == .grayscale ? .grayscale : .rgb, sample: pf.sample, alpha: true)
        let surface = try s.services.renderer.compositeToSurface(doc, rect: doc.bounds, format: target)
        var o = EncodeOptions()
        if let q = quality {
            o.webpLossless = false
            o.webpQuality = q
        }
        let profile = doc.iccProfile.flatMap { try? ICCProfile(data: Data($0)) }
        let warnings = ImageCodecs.fidelityWarnings(for: target, width: doc.size.width, height: doc.size.height, as: .webp).map(\.description)
        let data: Data
        do { data = try ImageCodecs.encode(surface, rect: doc.bounds, as: .webp, profile: profile, options: o) } catch {
            throw other("save as WebP: \(error)")
        }
        try FileCommands.writeFile(s, path, [UInt8](data))
        return warnings
    }

    // MARK: Specs

    static let hasDoc: CommandEnabled = { s, _ in s.active == nil ? "no document open" : nil }

    static func register(into r: inout CommandRegistry) {
        r.add([
            CommandSpec("file.export.saveForWebLegacy", "Save for Web (Legacy)…", menu: ["File", "Export"], shortcut: "Cmd+Alt+Shift+S",
                        params: ##"{"preset":"GIF 128 Dithered|JPEG High|PNG-24|…"?,"format":"gif|png8|png24|jpeg|wbmp"="png24","palette":"perceptual|selective|adaptive|restrictive|exact|systemMac|systemWindows|uniform"="selective","colors":2..256=256,"dither":"none|diffusion|pattern|noise"="diffusion","ditherAmount":0..100=88,"transparency":bool=true,"matte":"#rrggbb|none"="#ffffff","interlaced":bool=false,"webSnap":0..100=0,"quality":0..100=60,"progressive":bool=false,"optimized":bool=true,"embedIcc":bool=false,"metadata":"none|copyright|copyrightAndContact|all"="copyright","convertToSrgb":bool=true,"width"|"height"|"percent"? (image size),"resample":"bicubic|bilinear|nearest"?,"path":file? (whole image),"dir":folder? (one file per slice in images/),"imagesFolder":relative-folder?="images","html":bool=false,"trustedSliceHtml":bool=false (only for trusted documents; emit raw no-image cell HTML),"slices":"all|user"="all","numbers":[n]?} → no path/dir: {bytes,width,height,colors} estimate; else {files, html, bytes}"##,
                        module: m, enabled: hasDoc, run: saveForWeb),
            CommandSpec("file.export.exportPreferences", "Export Preferences…", menu: ["File", "Export"],
                        params: ##"{"quickExportFormat":"png|jpg|gif|webp"?,"quickExportLocation":"ask|sameFolder"?,"jpegQuality":1..100?,"webpLossless":bool?,"webpQuality":1..100?,"metadata":"none|copyright|all"?,"convertToSrgb":bool?} → {values}"##,
                        module: m, enabled: Pre.always, run: exportPreferences),
            CommandSpec("file.export.quickExport", "Quick Export",
                        params: ##"{"path":str? (required unless Export Preferences › Location is "sameFolder" and the document is saved)} → {path, format, bytes}"##,
                        module: m, enabled: hasDoc, run: quickExport),
            CommandSpec("file.generate.imageAssets", "Image Assets", menu: ["File", "Generate"],
                        params: ##"{"on":bool? (default: toggle),"dir":folder? (default <document>-assets next to the file)} → {enabled, files, errors}; layers named like "foo.png", "200% foo@2x.png", "48x48 icons/a.png8", "photo.jpg80%" are exported, now and after each save"##,
                        module: m, enabled: hasDoc, run: imageAssets),
        ])
    }
}
