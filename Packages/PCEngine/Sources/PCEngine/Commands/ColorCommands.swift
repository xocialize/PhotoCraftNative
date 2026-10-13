// Port of photocraft-engine (crates/engine/src/color_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Colour management commands and helpers: document profiles (Edit › Assign / Convert to Profile),
// CMS-based Image › Mode conversions, Edit › Color Settings (working spaces, policies, conversion
// options) and the embedded-profile policy applied when a file opens, soft proofing (View › Proof
// Setup / Proof Colors / Gamut Warning) and the display transform the canvas applies.
//
// ColorSync (PCPlatform `ColorTransform`, `ICCProfile`, `BuiltinProfile`, `GamutCheck`) replaces
// photocraft-cms. Document space: `Document.iccProfile` holds the document's ICC bytes; nil means
// untagged: the mode's default profile is assumed (sRGB, sGray, the coated CMYK, Lab D50).
//
// State: Color Settings live in the preferences' `colorSettings` section (keys photocraft's
// `ColorSettings` serializes; keys the preferences don't define are kept in session state);
// proofing is per document (`DocState.view[ColorCommands.ProofKey]`, wrapping Glue's `ProofView`);
// the displays the UI reports are session state.

import Foundation
import PCDocument
import PCFoundation
import PCPlatform
import Synchronization

public enum ColorCommands: CommandModule {
    public static let name = "color_cmds"
    static let m = "color_cmds"

    // MARK: State

    /// Edit › Color Settings › policies for documents whose embedded profile differs from the
    /// working space (photocraft `Policy`).
    public enum Policy: String, Sendable, Equatable {
        /// Keep the embedded profile.
        case preserve
        /// Convert the pixels to the working space.
        case convert
        /// Discard the embedded profile (the document is assumed to be in the working space).
        case off

        public var id: String { rawValue }

        public static func parse(_ s: String) -> Policy? {
            switch s {
            case "preserve", "preserveEmbedded": .preserve
            case "convert", "convertToWorking": .convert
            case "off": .off
            default: nil
            }
        }
    }

    /// Edit › Color Settings (photocraft `ColorSettings`): working spaces, colour management
    /// policies and conversion options.
    public struct Settings: Equatable, Sendable {
        /// Working spaces: built-in profile ids (see `edit.profileInfo`) or `.icc` paths.
        public var workingRgb = "srgb"
        public var workingCmyk = "coated-cmyk"
        public var workingGray = "sgray"
        public var policyRgb = Policy.preserve
        public var policyCmyk = Policy.preserve
        public var policyGray = Policy.preserve
        /// Ask what to do when an opened file's embedded profile differs from the working space.
        public var askOnMismatch = true
        public var askOnPaste = true
        /// Ask when an opened file has no profile.
        public var askOnMissing = false
        /// Conversion options: rendering intent and black point compensation.
        public var intent = "relative"
        public var bpc = true
        public var dither = true
        /// Advanced › "Blend Text Colors Using Gamma" (1 = off).
        public var blendTextGamma: Float = 1.45
        /// `auto` (the display's profile when the platform reports it, else sRGB), a built-in RGB
        /// profile id or an `.icc` path.
        public var monitorProfile = "auto"

        public init() {}

        public var renderingIntent: RenderingIntent { RenderingIntent(parsing: intent) ?? .relativeColorimetric }

        /// Policy for documents in `mode`'s colour space (Lab documents are never converted).
        public func policy(_ mode: ColorMode) -> Policy {
            switch modeSpace(mode) {
            case .cmyk: policyCmyk
            case .gray: policyGray
            case .rgb: policyRgb
            default: .preserve
            }
        }

        func workingSpec(_ space: ProfileColorSpace) -> String? {
            switch space {
            case .rgb: workingRgb
            case .cmyk: workingCmyk
            case .gray: workingGray
            default: nil
            }
        }

        /// The settings as photocraft serializes them (camelCase keys).
        public var json: JSONValue {
            .object(Dictionary(uniqueKeysWithValues: entries.map { ($0.0, $0.2) }))
        }

        /// (key, preference aliases, value) for every field.
        var entries: [(String, [String], JSONValue)] {
            [
                ("workingRgb", [], .string(workingRgb)), ("workingCmyk", [], .string(workingCmyk)), ("workingGray", [], .string(workingGray)),
                ("policyRgb", ["rgbPolicy"], .string(policyRgb.id)), ("policyCmyk", ["cmykPolicy"], .string(policyCmyk.id)),
                ("policyGray", ["grayPolicy"], .string(policyGray.id)),
                ("askOnMismatch", [], .bool(askOnMismatch)), ("askOnPaste", [], .bool(askOnPaste)), ("askOnMissing", [], .bool(askOnMissing)),
                ("intent", [], .string(intent)), ("bpc", [], .bool(bpc)), ("dither", [], .bool(dither)),
                ("blendTextGamma", [], .float(blendTextGamma)), ("monitorProfile", [], .string(monitorProfile)),
            ]
        }
    }

    /// Settings keys the preferences don't define (kept for the session).
    enum SettingsOverlayKey: StateKey { static let defaultValue: [String: JSONValue] = [:] }

    /// Per-document proofing state (photocraft `ProofView` + `ProofSetup`): Glue's `ProofView`
    /// (what the canvas display reads) plus the resolved proof profile, the simulation kind and the
    /// gamut-warning threshold.
    public struct ProofState: Sendable, Equatable {
        public var view: ProofView
        /// The proof profile, resolved when Proof Setup ran (`view.profile` is what was asked for).
        public var profile: ICCProfile
        /// What is simulated (View › Proof Setup's plates and simulations, `proof_sim`).
        public var kind: ProofSimCommands.Kind
        /// Gamut Warning's ΔE threshold.
        public var gamutThreshold: Float

        public init() {
            view = ProofView()
            profile = BuiltinProfile.coatedCMYK.profile
            kind = .profile
            gamutThreshold = GamutCheck.defaultThreshold
        }
    }

    public enum ProofKey: StateKey { public static let defaultValue = ProofState() }

    /// The displays the platform reported (primary first) and the one showing the main window
    /// (photocraft `ColorState::displays` / `main_display`); the UI sets them.
    enum DisplaysKey: StateKey { static let defaultValue: [DisplayInfo] = [] }
    enum MainDisplayKey: StateKey { static let defaultValue: UInt32? = nil }

    // MARK: Settings access

    /// The current Color Settings (preferences first, then the session's own keys, then
    /// photocraft's defaults).
    public static func settings(_ s: Session) -> Settings {
        var c = Settings()
        let overlay = s.state[SettingsOverlayKey.self]
        func v(_ k: String, _ aliases: [String]) -> JSONValue? {
            for key in [k] + aliases { if let x = s.preferences["colorSettings.\(key)"] { return x } }
            return overlay[k]
        }
        for (k, aliases, _) in c.entries {
            guard let x = v(k, aliases) else { continue }
            switch k {
            case "workingRgb": if let t = x.stringValue { c.workingRgb = t }
            case "workingCmyk": if let t = x.stringValue { c.workingCmyk = t }
            case "workingGray": if let t = x.stringValue { c.workingGray = t }
            case "policyRgb": if let t = x.stringValue.flatMap(Policy.parse) { c.policyRgb = t }
            case "policyCmyk": if let t = x.stringValue.flatMap(Policy.parse) { c.policyCmyk = t }
            case "policyGray": if let t = x.stringValue.flatMap(Policy.parse) { c.policyGray = t }
            case "askOnMismatch": if let t = x.boolValue { c.askOnMismatch = t }
            case "askOnPaste": if let t = x.boolValue { c.askOnPaste = t }
            case "askOnMissing": if let t = x.boolValue { c.askOnMissing = t }
            case "intent": if let t = x.stringValue { c.intent = t }
            case "bpc": if let t = x.boolValue { c.bpc = t }
            case "dither": if let t = x.boolValue { c.dither = t }
            case "blendTextGamma": if let t = x.floatValue { c.blendTextGamma = t }
            case "monitorProfile": if let t = x.stringValue { c.monitorProfile = t }
            default: break
            }
        }
        return c
    }

    /// Stores `c`: into the preferences where they define the key (persisted with them), else into
    /// the session.
    static func store(_ s: Session, _ c: Settings) {
        var overlay = s.state[SettingsOverlayKey.self]
        for (k, aliases, value) in c.entries {
            var stored = false
            for key in [k] + aliases where !stored {
                if (try? s.preferences.set("colorSettings.\(key)", value)) != nil { stored = true }
            }
            overlay[k] = stored ? nil : value
        }
        s.state[SettingsOverlayKey.self] = overlay
        // Advanced › Blend Text Colors Using Gamma lives in the compositor too (photocraft
        // `psblend::set_text_gamma`).
        s.services.renderer.textGamma = c.blendTextGamma
    }

    /// Checks that each working space resolves to a profile of the right colour space (photocraft
    /// `validate_settings`).
    public static func validate(_ c: Settings, fs: any FileSystemService = LocalFileSystem()) -> String? {
        for (space, spec) in [(ProfileColorSpace.rgb, c.workingRgb), (.cmyk, c.workingCmyk), (.gray, c.workingGray)] {
            let p: ICCProfile
            do { p = try resolveProfile(spec, doc: nil, mode: spaceMode(space), fs: fs) } catch { return EngineError.wrap(error).description }
            if p.colorSpace != space { return "working space `\(spec)` is \(spaceName(p.colorSpace)), not \(spaceName(space))" }
        }
        let mon = c.monitorProfile
        if !(mon.isEmpty || mon == "auto") {
            let p: ICCProfile
            do { p = try resolveProfile(mon, doc: nil, mode: .rgb, fs: fs) } catch { return EngineError.wrap(error).description }
            if p.colorSpace != .rgb { return "monitor profile `\(mon)` is \(spaceName(p.colorSpace)), not RGB" }
        }
        if RenderingIntent(parsing: c.intent) == nil { return "unknown intent `\(c.intent)` (perceptual|relative|saturation|absolute)" }
        return nil
    }

    // MARK: Profiles

    /// ICC colour space of a document mode (photocraft `mode_space`).
    public static func modeSpace(_ mode: ColorMode) -> ProfileColorSpace {
        switch mode {
        case .grayscale, .bitmap, .duotone: .gray
        case .cmyk: .cmyk
        case .lab: .lab
        default: .rgb
        }
    }

    static func spaceMode(_ cs: ProfileColorSpace) -> ColorMode? {
        switch cs {
        case .rgb: .rgb
        case .gray: .grayscale
        case .cmyk: .cmyk
        case .lab: .lab
        default: nil
        }
    }

    /// photocraft's `{:?}` of a colour space.
    static func spaceName(_ cs: ProfileColorSpace) -> String {
        switch cs {
        case .rgb: "Rgb"
        case .gray: "Gray"
        case .cmyk: "Cmyk"
        case .lab: "Lab"
        case .xyz: "Xyz"
        case .other(let s): s.trimmingCharacters(in: .whitespaces)
        }
    }

    /// photocraft's `{:?}` of a colour mode.
    static func modeName(_ m: ColorMode) -> String {
        switch m {
        case .rgb: "Rgb"
        case .grayscale: "Grayscale"
        case .cmyk: "Cmyk"
        case .lab: "Lab"
        case .indexed: "Indexed"
        case .bitmap: "Bitmap"
        case .duotone: "Duotone"
        case .multichannel: "Multichannel"
        }
    }

    /// photocraft's `{:?}` of a profile class.
    static func className(_ c: ProfileClass) -> String {
        switch c {
        case .input: "Input"
        case .display: "Display"
        case .output: "Output"
        case .link: "DeviceLink"
        case .abstract: "Abstract"
        case .colorSpace: "ColorSpace"
        case .namedColor: "NamedColor"
        case .unknown: "Unknown"
        }
    }

    static func cmsError(_ e: any Error) -> EngineError { .other("colour management: \(e)") }

    /// Working (default) profile of a mode (photocraft `working_profile`): sRGB, sGray, the coated
    /// CMYK, Lab D50.
    public static func workingProfile(_ mode: ColorMode) -> ICCProfile { BuiltinProfile.defaultProfile(for: mode) }

    private static let parsed = Mutex<[Data: ICCProfile]>([:])

    /// Parses ICC bytes, caching recent documents' profiles (photocraft `profile_from_bytes`).
    public static func profile(fromBytes bytes: [UInt8]) throws -> ICCProfile {
        let d = Data(bytes)
        if let p = parsed.withLock({ $0[d] }) { return p }
        let p = try ICCProfile(data: d)
        parsed.withLock { c in
            if c.count > 16 { c.removeAll() }
            c[d] = p
        }
        return p
    }

    /// The document's profile: its embedded profile when it parses and matches the mode, otherwise
    /// the mode's working profile (photocraft `document_profile`).
    public static func documentProfile(_ doc: Document) -> ICCProfile {
        if let b = doc.iccProfile, let p = try? profile(fromBytes: b), p.colorSpace == modeSpace(doc.mode) { return p }
        return workingProfile(doc.mode)
    }

    /// Resolves a profile parameter (photocraft `resolve_profile`): a built-in id/alias/description,
    /// `"working"` (the mode's default), `"document"`, or a path to an `.icc`/`.icm` file.
    public static func resolveProfile(_ spec: String, doc: Document?, mode: ColorMode?,
                                      fs: any FileSystemService = LocalFileSystem()) throws -> ICCProfile {
        switch spec {
        case "working", "default": return workingProfile(mode ?? doc?.mode ?? .rgb)
        case "working-cmyk", "workingCmyk": return workingProfile(.cmyk)
        case "working-rgb", "workingRgb": return workingProfile(.rgb)
        case "working-gray", "workingGray": return workingProfile(.grayscale)
        case "document":
            guard let doc else { throw EngineError.noDocument }
            return documentProfile(doc)
        default: break
        }
        if let b = BuiltinProfile.from(id: spec) { return b.profile }
        let lower = spec.lowercased()
        if lower.hasSuffix(".icc") || lower.hasSuffix(".icm") || spec.contains("/") || spec.contains("\\") {
            let bytes: Data
            do { bytes = try fs.read(spec) } catch {
                let why = (error as? EngineError).map { e -> String in
                    if case .other(let m) = e { return m.hasPrefix("\(spec): ") ? String(m.dropFirst(spec.count + 2)) : m }
                    return e.description
                } ?? "\(error)"
                throw EngineError.other("cannot read profile `\(spec)`: \(why)")
            }
            do { return try ICCProfile(data: bytes) } catch { throw cmsError(error) }
        }
        let ids = BuiltinProfile.allCases.map(\.id).joined(separator: ", ")
        throw EngineError.other("unknown profile `\(spec)` (built-ins: \(ids), or a path to an .icc file)")
    }

    /// The working profile of a mode from Color Settings (the built-in default when the setting
    /// doesn't resolve) — photocraft `ColorState::working`.
    public static func working(_ s: Session, _ mode: ColorMode) -> ICCProfile {
        let space = modeSpace(mode)
        if let spec = settings(s).workingSpec(space), let p = try? resolveProfile(spec, doc: nil, mode: mode, fs: s.services.fileSystem),
           p.colorSpace == space {
            return p
        }
        return workingProfile(mode)
    }

    /// Resolves a profile spec, reading "working…" specs from Color Settings (photocraft
    /// `ColorState::resolve`).
    public static func resolve(_ s: Session, _ spec: String, doc: Document?, mode: ColorMode?) throws -> ICCProfile {
        switch spec {
        case "working", "default": return working(s, mode ?? doc?.mode ?? .rgb)
        case "working-cmyk", "workingCmyk": return working(s, .cmyk)
        case "working-rgb", "workingRgb": return working(s, .rgb)
        case "working-gray", "workingGray": return working(s, .grayscale)
        default: return try resolveProfile(spec, doc: doc, mode: mode, fs: s.services.fileSystem)
        }
    }

    /// Profile describing the compositor's output for this document (photocraft
    /// `composite_profile`; for Gray documents the gray profile itself, whose composite repeats
    /// the gray value in R, G and B).
    public static func compositeProfile(_ doc: Document) -> ICCProfile { DisplayColor.compositeProfile(doc) }

    /// A linear-light gray profile (photocraft `builtin::linear_gray`), for the 32-bit open policy.
    static let linearGray: ICCProfile? = try? ICCProfile(data: ICCWriter.grayProfile(description: "Linear Gray") { $0 })

    static func profileJSON(_ p: ICCProfile) -> JSONValue {
        let lut = ["A2B0", "A2B1", "A2B2"].contains { p.tag($0) != nil }
        let b2a = ["B2A0", "B2A1", "B2A2"].map { p.tag($0) != nil }
        let intents = RenderingIntent.allCases.filter { i in
            let k = i == .perceptual ? 0 : (i == .saturation ? 2 : 1)
            return b2a[k] || !b2a.contains(true)
        }
        return [
            "description": .string(p.profileDescription), "colorSpace": .string(spaceName(p.colorSpace)),
            "class": .string(className(p.deviceClass)), "version": .string("\(p.version.major).\(p.version.minor)"),
            "bytes": .int(p.data.count), "lut": .bool(lut), "intents": .strings(intents.map(\.id)),
        ]
    }

    // MARK: Conversion

    /// Evaluates one colour through `t` with normalised values on both sides (Lab as PCFoundation
    /// stores it: L/100, (a+128)/255).
    static func evalColor(_ t: ColorTransform, _ input: [Float]) -> [Float] {
        var i = input
        if t.source.colorSpace == .lab, i.count >= 3 {
            let e = LabEncoding.colorSync.encode(LabEncoding.normalized.decode(SIMD3(i[0], i[1], i[2])))
            i[0] = e.x; i[1] = e.y; i[2] = e.z
        }
        var o = t.eval(i)
        if t.destination.colorSpace == .lab, o.count >= 3 {
            let e = LabEncoding.normalized.encode(LabEncoding.colorSync.decode(SIMD3(o[0], o[1], o[2])))
            o[0] = e.x; o[1] = e.y; o[2] = e.z
        }
        return o
    }

    /// Converts one surface's colour channels with `t` into `to`'s model (alpha copied, depth kept).
    /// Surfaces whose model is not `from` fall back to the generic conversion (photocraft
    /// `convert_surface`).
    public static func convertSurface(_ s: Surface, from: ColorMode, to: PixelFormat, _ t: ColorTransform) -> Surface {
        let sf = s.format
        if sf.mode != from || t.inputChannels != sf.mode.colorChannels || t.outputChannels != to.mode.colorChannels || sf.alpha != to.alpha {
            return s.convertedAny(to: to)
        }
        let target = PixelFormat(mode: to.mode, sample: sf.sample, alpha: sf.alpha)
        guard let def = try? t.convert(RasterBuffer(width: 1, height: 1, format: sf, floats: s.defaultPixelValue), to: sf.sample) else {
            return s.convertedAny(to: target)
        }
        // Every tile through the transform, tiles in parallel (ColorSync transforms are thread-safe).
        var out = Surface(format: target, defaultPixel: def.floats())
        let coords = s.tileCoords
        let results = Mutex<[Int: [UInt8]]>([:])
        let src = s
        DispatchQueue.concurrentPerform(iterations: coords.count) { i in
            guard let r = try? t.convert(RasterBuffer(surface: src, rect: coords[i].rect), to: sf.sample) else { return }
            results.withLock { $0[i] = r.bytes }
        }
        let converted = results.withLock { $0 }
        for (i, c) in coords.enumerated() {
            guard let b = converted[i], b.count >= c.rect.area * target.bytesPerPixel else { return s.convertedAny(to: target) }
            out.writeInterleaved(c.rect, b)
        }
        return out
    }

    /// Converts a colour value that is in `from` (the document's old mode) to the new mode.
    static func convertColor(_ c: inout PCColor, from: ColorMode, to: ColorMode, _ t: ColorTransform) {
        guard c.mode == from else { return }
        let n = from.colorChannels
        let o = evalColor(t, (0..<n).map { c.c[$0] })
        let m = to.colorChannels
        var nc = SIMD4<Float>(repeating: 0)
        for k in 0..<min(m, 4, o.count) { nc[k] = min(max(o[k], 0), 1) }
        c.mode = to
        c.c = nc
    }

    static func convertFill(_ f: inout Fill, _ cc: (inout PCColor) -> Void) {
        switch f {
        case .solid(var c):
            cc(&c)
            f = .solid(c)
        case .gradient(var g):
            for i in g.stops.indices { cc(&g.stops[i].color) }
            f = .gradient(g)
        case .pattern:
            break
        }
    }

    static func paintColors(_ p: inout FxPaint, _ cc: (inout PCColor) -> Void) {
        switch p {
        case .color(var c):
            cc(&c)
            p = .color(c)
        case .gradient(var g):
            for i in g.stops.indices { cc(&g.stops[i].color) }
            p = .gradient(g)
        case .pattern:
            break
        }
    }

    /// Applies `cc` to every colour value of `l` (fill, text, shape and effect colours), recursing
    /// into groups (photocraft `convert_layer_colors`).
    static func convertLayerColors(_ l: inout Layer, _ cc: (inout PCColor) -> Void) {
        for i in l.effects.items.indices {
            switch l.effects.items[i] {
            case .dropShadow(var s): cc(&s.color); l.effects.items[i] = .dropShadow(s)
            case .innerShadow(var s): cc(&s.color); l.effects.items[i] = .innerShadow(s)
            case .outerGlow(var g): paintColors(&g.paint, cc); l.effects.items[i] = .outerGlow(g)
            case .innerGlow(var g): paintColors(&g.paint, cc); l.effects.items[i] = .innerGlow(g)
            case .stroke(var s): paintColors(&s.paint, cc); l.effects.items[i] = .stroke(s)
            case .colorOverlay(var o): cc(&o.color); l.effects.items[i] = .colorOverlay(o)
            case .gradientOverlay(var o):
                for k in o.gradient.stops.indices { cc(&o.gradient.stops[k].color) }
                l.effects.items[i] = .gradientOverlay(o)
            case .satin(var s): cc(&s.color); l.effects.items[i] = .satin(s)
            case .bevelEmboss(var b):
                cc(&b.highlightColor)
                cc(&b.shadowColor)
                l.effects.items[i] = .bevelEmboss(b)
            case .patternOverlay:
                break
            }
        }
        switch l.content {
        case .fill(var f):
            convertFill(&f, cc)
            l.content = .fill(f)
        case .text:
            l.withText { t in
                cc(&t.color)
                for i in t.runs.indices { cc(&t.runs[i].style.color) }
            }
        case .shape:
            l.withShape { sh in
                if var f = sh.fill { convertFill(&f, cc); sh.fill = f }
                if var st = sh.stroke { convertFill(&st.paint, cc); sh.stroke = st }
            }
        case .group:
            l.withChildren { ch in for i in ch.indices { convertLayerColors(&ch[i], cc) } }
        default:
            break
        }
    }

    /// Converts every pixel layer (and cached text/shape/smart pixels and fill caches) of `doc` from
    /// its profile to `dst`, switching the mode to `dst`'s colour space (photocraft
    /// `convert_document`). Masks, alpha channels and the selection are untouched; fill, text, shape
    /// and effect colours are converted. A Duotone document going to a colour space starts from its
    /// ink colours. The document is tagged with `dst`.
    public static func convertDocument(_ doc: inout Document, to dst: ICCProfile, intent: RenderingIntent, bpc: Bool) throws {
        guard let toMode = spaceMode(dst.colorSpace) else {
            throw EngineError.other("cannot convert to a \(spaceName(dst.colorSpace)) profile")
        }
        if toMode != .grayscale { inkDuotone(&doc) }
        let src = documentProfile(doc)
        let fromMode = doc.pixelFormat.mode
        let t: ColorTransform
        do { t = try ColorTransform(source: src, destination: dst, options: TransformOptions(intent: intent, blackPointCompensation: bpc)) } catch {
            throw cmsError(error)
        }
        let depth = doc.depth
        ImageCommands.forEachSurface(&doc.layers, masks: false) { surf, _ in
            surf = convertSurface(surf, from: fromMode, to: PixelFormat(mode: toMode, sample: depth, alpha: surf.format.alpha), t)
        }
        for i in doc.layers.indices {
            doc.updateLayer(at: [i]) { l in convertLayerColors(&l) { c in convertColor(&c, from: fromMode, to: toMode, t) } }
        }
        doc.mode = toMode
        doc.iccProfile = [UInt8](dst.data)
        // Leaving Indexed / Duotone: the palette and inks no longer apply.
        doc.colorTable = nil
        doc.duotone = nil
    }

    /// Turns a Duotone document into the sRGB document it displays as: every gray pixel and colour
    /// value becomes its printed ink colour (photocraft `ink_duotone`). Other documents (and
    /// Duotone without inks) are left alone.
    static func inkDuotone(_ doc: inout Document) {
        guard doc.mode == .duotone, let d = doc.duotone, !d.inks.isEmpty else { return }
        doc.duotone = nil
        ImageCommands.forEachSurface(&doc.layers, masks: false) { surf, _ in surf = inkSurface(surf, d) }
        for i in doc.layers.indices {
            doc.updateLayer(at: [i]) { l in
                convertLayerColors(&l) { c in
                    if c.mode == .grayscale || c.mode == .duotone {
                        let rgb = d.render(c.c.x)
                        c = .rgb(rgb.x, rgb.y, rgb.z, c.alpha)
                    }
                }
            }
        }
        doc.mode = .rgb
        doc.iccProfile = [UInt8](BuiltinProfile.srgb.profile.data)
    }

    /// The RGB surface of a gray surface's ink colours (same depth and alpha); non-gray surfaces
    /// are returned unchanged (photocraft `ink_surface`).
    static func inkSurface(_ s: Surface, _ d: Duotone) -> Surface {
        let sf = s.format
        guard sf.mode == .grayscale else { return s }
        let to = PixelFormat(mode: .rgb, sample: sf.sample, alpha: sf.alpha)
        let ink: @Sendable (ArraySlice<Float>) -> [Float] = { src in
            let v = d.render(src.first ?? 0)
            var out = [v.x, v.y, v.z]
            if sf.alpha, src.count > 1 { out.append(src[src.startIndex + 1]) }
            return out
        }
        var out = Surface(format: to, defaultPixel: ink(s.defaultPixelValue[...]))
        ImageCommands.mapTiles(s, into: &out) { raw in
            var o = [Float]()
            o.reserveCapacity(raw.count / sf.channels * to.channels)
            for i in stride(from: 0, to: raw.count, by: sf.channels) { o += ink(raw[i..<(i + sf.channels)]) }
            return o
        }
        return out
    }

    /// Image › Mode › RGB/Grayscale/CMYK/Lab through the CMS (photocraft `convert_mode`). Params:
    /// `profile` (destination, default the mode's working profile), `intent`, `bpc` (defaults from
    /// Color Settings).
    public static func convertMode(_ s: Session, _ mode: ColorMode, _ p: JSONValue) throws -> JSONValue {
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        if doc.mode == .multichannel && mode != .multichannel { return try multichannelConvertFrom(s, mode) }
        if doc.mode == mode && p["profile"] == nil { return .null }
        let c = settings(s)
        let dst: ICCProfile
        if let spec = p["profile"]?.stringValue { dst = try resolve(s, spec, doc: doc, mode: mode) } else { dst = working(s, mode) }
        let expected: ColorMode
        switch mode {
        case .bitmap, .duotone: expected = .grayscale
        case .indexed, .multichannel: expected = .rgb
        default: expected = mode
        }
        if spaceMode(dst.colorSpace) != expected {
            throw EngineError.other("profile `\(dst.profileDescription)` is \(spaceName(dst.colorSpace)), not \(modeName(mode))")
        }
        let intent = try intentParam(p, default: c.renderingIntent)
        let bpc = p["bpc"]?.boolValue ?? c.bpc
        try s.edit("Mode Change") { doc, _ in try convertDocument(&doc, to: dst, intent: intent, bpc: bpc) }
        return ["profile": .string(dst.profileDescription), "intent": .string(intent.id), "bpc": .bool(bpc)]
    }

    static func intentParam(_ p: JSONValue, default d: RenderingIntent) throws -> RenderingIntent {
        guard let s = p["intent"]?.stringValue else { return d }
        guard let i = RenderingIntent(parsing: s) else { throw EngineError.other("unknown intent `\(s)` (perceptual|relative|saturation|absolute)") }
        return i
    }

    /// A Multichannel document to a colour mode (photocraft `multichannel_cmds::convert_from`,
    /// which `convert_mode` hands Multichannel documents to): spot channels that match the
    /// destination's channel count become its channels, otherwise the printed look is converted.
    static func multichannelConvertFrom(_ s: Session, _ mode: ColorMode) throws -> JSONValue {
        guard [.rgb, .cmyk, .lab, .grayscale].contains(mode) else {
            throw EngineError.other("a Multichannel document can't be converted to \(modeName(mode))")
        }
        let renderer = s.services.renderer
        let how: String = try s.edit("Mode Change") { doc, active in
            let inks = doc.channels.filter { $0.spot != nil }
            let others = doc.channels.filter { $0.spot == nil }
            doc.channels = []
            let canvas = doc.bounds
            let n = canvas.area
            let reinterpret = ((mode == .rgb || mode == .lab) && inks.count == 3) || (mode == .cmyk && inks.count == 4) || (mode == .grayscale && inks.count == 1)
            var shown: [SIMD4<Float>]?
            if !reinterpret {
                var d = doc
                d.channels = inks
                shown = try renderer.render(d, region: canvas).px
            }
            doc.mode = mode
            let fmt = doc.pixelFormat
            let cc = fmt.mode.colorChannels
            var data = [Float](repeating: 0, count: n * (cc + 1))
            if let buf = shown {
                for (i, q) in buf.prefix(n).enumerated() {
                    let px = fmt.components(fromRGBA: SIMD4(q.x, q.y, q.z, 1))
                    for k in 0..<min(cc + 1, px.count) { data[i * (cc + 1) + k] = px[k] }
                }
            } else {
                for (k, ch) in inks.enumerated() where k < cc {
                    let vals = ch.surface.readRegion(canvas)
                    let step = ch.surface.channels
                    for i in 0..<n where i * step < vals.count {
                        // CMYK plates are ink amounts already; other modes store light.
                        data[i * (cc + 1) + k] = mode == .cmyk ? vals[i * step] : 1 - vals[i * step]
                    }
                }
                for i in 0..<n { data[i * (cc + 1) + cc] = 1 }
            }
            var surf = Surface(format: fmt)
            surf.writeRegion(canvas, data)
            surf.prune()
            var bg = Layer(name: "Background", content: .raster(surf))
            bg.locks.transparency = true
            bg.locks.position = true
            active = bg.id
            doc.layers = [bg]
            doc.channels = others
            return reinterpret ? "channels" : "appearance"
        }
        return ["mode": .string(modeName(mode).lowercased()), "from": "multichannel", "converted": .string(how)]
    }

    // MARK: Opening files

    /// The EXIF ColorSpace value of a TIFF-structured block (with or without the `Exif\0\0`
    /// prefix), nil when absent or malformed (photocraft `codecs::exif_color_space`).
    public static func exifColorSpace(_ exif: [UInt8]) -> UInt16? {
        var b = exif[...]
        if b.starts(with: Array("Exif\0\0".utf8)) { b = b.dropFirst(6) }
        let a = Array(b)
        guard a.count >= 8 else { return nil }
        let little: Bool
        switch (a[0], a[1], a[2], a[3]) {
        case (0x49, 0x49, 42, 0): little = true
        case (0x4D, 0x4D, 0, 42): little = false
        default: return nil // BigTIFF and anything else: no tag
        }
        func u16(_ at: Int) -> UInt16? {
            guard at >= 0, at + 2 <= a.count else { return nil }
            return little ? UInt16(a[at]) | UInt16(a[at + 1]) << 8 : UInt16(a[at]) << 8 | UInt16(a[at + 1])
        }
        func u32(_ at: Int) -> UInt32? {
            guard at >= 0, at + 4 <= a.count else { return nil }
            let v = (0..<4).map { UInt32(a[at + $0]) }
            return little ? v[0] | v[1] << 8 | v[2] << 16 | v[3] << 24 : v[0] << 24 | v[1] << 16 | v[2] << 8 | v[3]
        }
        func find(_ first: Int, _ count: Int, _ tag: UInt16) -> Int? {
            (0..<count).map { first + $0 * 12 }.first { u16($0) == tag }
        }
        guard let ifd0 = u32(4).map(Int.init), ifd0 >= 8, let count0 = u16(ifd0).map(Int.init) else { return nil }
        let first0 = ifd0 + 2
        guard first0 + count0 * 12 + 4 <= a.count, let ptr = find(first0, count0, 0x8769) else { return nil }
        guard let ty = u16(ptr + 2), ty == 4 || ty == 13, u32(ptr + 4) == 1, let ifd = u32(ptr + 8).map(Int.init), ifd >= 8,
              let n = u16(ifd).map(Int.init) else { return nil }
        let first = ifd + 2
        guard first + n * 12 <= a.count, let e = find(first, n, 0xA001), u32(e + 4) == 1 else { return nil }
        switch u16(e + 2) {
        case 3: return u16(e + 8)
        case 4: return u32(e + 8).flatMap { UInt16(exactly: $0) }
        default: return nil
        }
    }

    /// Applies the Color Settings policy to a document being opened (photocraft
    /// `ColorState::open_policy`). Returns what happened (`action`: kept|converted|discarded|
    /// assigned|untagged) and whether to ask the user.
    ///
    /// An RGB file with no embedded profile whose EXIF ColorSpace tag says sRGB is opened as sRGB;
    /// `ignoreExif` (Preferences › File Handling › Ignore EXIF Profile Tag) treats it as untagged.
    public static func openPolicy(_ s: Session, _ doc: inout Document, ignoreExif: Bool) -> JSONValue {
        let space = modeSpace(doc.mode)
        guard space == .rgb || space == .cmyk || space == .gray else { return ["action": "kept"] }
        let exifSRGB = space == .rgb && !ignoreExif && doc.iccProfile == nil && doc.metadata.exif.flatMap(exifColorSpace) == 1
        if exifSRGB { doc.iccProfile = [UInt8](BuiltinProfile.srgb.profile.data) }
        let report = applyOpenPolicy(s, &doc, space)
        return exifSRGB ? report.merging(["exif": true]) : report
    }

    static func applyOpenPolicy(_ s: Session, _ doc: inout Document, _ space: ProfileColorSpace) -> JSONValue {
        let c = settings(s)
        let working = working(s, doc.mode)
        let policy = c.policy(doc.mode)
        let embedded = doc.iccProfile.flatMap { try? profile(fromBytes: $0) }.flatMap { $0.colorSpace == space ? $0 : nil }
        guard let emb = embedded else {
            // Untagged files are assumed to be in the working space; tag them when it is not the
            // built-in default so they display (and save) as intended.
            let assign = policy != .off && working.data != workingProfile(doc.mode).data
            if assign { doc.iccProfile = [UInt8](working.data) }
            return ["action": .string(assign ? "assigned" : "untagged"), "working": .string(working.profileDescription),
                    "policy": .string(policy.id), "ask": .bool(c.askOnMissing), "missing": true]
        }
        // Compared by colour, not bytes.
        let mismatch = !emb.sameColors(as: working)
        let base: JSONValue = ["embedded": .string(emb.profileDescription), "working": .string(working.profileDescription),
                               "mismatch": .bool(mismatch), "policy": .string(policy.id)]
        // 32-bit linear images stay linear.
        let linearHDR = doc.depth == .f32 && (emb.sameColors(as: BuiltinProfile.linearSRGB.profile) || (linearGray.map { emb.sameColors(as: $0) } ?? false))
        if !mismatch || linearHDR { return base.merging(["action": "kept"]) }
        // An input-only profile can't be the document's space: Preserve converts it instead.
        let inputOnly = !emb.canBeDestination
        let action: String
        switch policy {
        case .preserve where !inputOnly:
            action = "kept"
        case .off:
            doc.iccProfile = nil
            action = "discarded"
        default:
            do {
                try convertDocument(&doc, to: working, intent: c.renderingIntent, bpc: c.bpc)
                action = "converted"
            } catch {
                action = "kept"
            }
        }
        let report = base.merging(["action": .string(action), "ask": .bool(c.askOnMismatch)])
        return inputOnly ? report.merging(["inputOnly": true]) : report
    }

    /// Adds a document read from a file, applying the Color Settings policy first (photocraft
    /// `Session::open_document`). Returns the document index and the policy report.
    @discardableResult
    public static func openDocument(_ s: Session, _ doc: Document, path: String? = nil) -> (Int, JSONValue) {
        var doc = doc
        let ignore = s.preferences["fileHandling.ignoreExifProfileTag"]?.boolValue ?? false
        let report = openPolicy(s, &doc, ignoreExif: ignore)
        return (s.addDocument(doc, path: path), report)
    }

    // MARK: Display

    /// The UI reports the displays (primary first) and the one showing the main window.
    public static func setDisplays(_ s: Session, _ displays: [DisplayInfo], main: UInt32? = nil) {
        s.state[DisplaysKey.self] = displays
        s.state[MainDisplayKey.self] = main
    }

    /// The monitor profile for `display` (photocraft `monitor_for`) and why (`monitor_status_for`).
    public static func monitorStatus(_ s: Session, display: UInt32? = nil) -> (ICCProfile, JSONValue) {
        let spec = settings(s).monitorProfile
        let auto = spec.isEmpty || spec == "auto"
        let displays = s.state[DisplaysKey.self]
        let id = display ?? s.state[MainDisplayKey.self]
        let shown = id.flatMap { i in displays.first { $0.displayID == i } } ?? displays.first
        var found: ICCProfile?
        var why: String?
        if auto {
            if let d = shown {
                found = d.profile
                if found == nil { why = "\(d.name) has no ICC profile" }
            } else {
                why = "this platform doesn't report display profiles"
            }
        } else {
            do { found = try resolveProfile(spec, doc: nil, mode: .rgb, fs: s.services.fileSystem) } catch {
                why = EngineError.wrap(error).description
            }
        }
        if let q = found {
            if q.colorSpace != .rgb {
                (found, why) = (nil, "`\(q.profileDescription)` is a \(spaceName(q.colorSpace)) profile, not RGB")
            } else if !q.canBeDestination {
                (found, why) = (nil, "`\(q.profileDescription)` can't be used as a display profile")
            }
        }
        let (p, source, reason): (ICCProfile, String, String?) =
            found.map { ($0, auto ? "auto" : "manual", nil) } ?? (BuiltinProfile.srgb.profile, "fallback", why)
        let status: JSONValue = [
            "requested": .string(spec.isEmpty ? "auto" : spec), "source": .string(source),
            "display": shown.map { .string($0.name) } ?? .null, "profile": .string(p.profileDescription),
            "profileName": auto ? (shown?.profile.map { .string($0.profileDescription) } ?? .null) : .null,
            "fingerprint": .string(p.md5.prefix(8).map { String(format: "%02x", $0) }.joined()),
            "detection": .string(displays.isEmpty ? "Unsupported" : "Found"), "reason": reason.map(JSONValue.string) ?? .null,
        ]
        return (p, status)
    }

    /// The monitor profile the canvas is displayed in.
    public static func monitorProfile(_ s: Session, display: UInt32? = nil) -> ICCProfile { monitorStatus(s, display: display).0 }

    /// The proofing state of a document.
    public static func proof(_ st: DocState) -> ProofState { st.view[ProofKey.self] }

    /// The Gamut Warning colour (Preferences › Transparency & Gamut).
    static func warningColor(_ s: Session) -> SIMD3<Float> {
        let c = s.preferences["transparencyAndGamut.gamutWarningColor"]?.stringValue.flatMap(Params.parseHex) ?? SIMD4(0.5, 0.5, 0.5, 1)
        return SIMD3(c.x, c.y, c.z)
    }

    /// Transform from the composite to the monitor, including the soft proof when Proof Colors is
    /// on (photocraft `ColorState::display_transform`).
    public static func displayTransform(_ s: Session, _ st: DocState, display: UInt32? = nil) throws -> ColorTransform {
        let src = compositeProfile(st.doc)
        let dst = monitorProfile(s, display: display)
        let pv = st.view[ProofKey.self]
        do {
            if pv.view.enabled {
                return try ColorTransform.proof(source: src, proof: pv.profile, display: dst, intent: pv.view.intent,
                                                blackPointCompensation: pv.view.blackPointCompensation, simulatePaper: pv.view.simulatePaper)
            }
            return try ColorTransform(source: src, destination: dst, options: .photoshopDefault)
        } catch {
            throw cmsError(error)
        }
    }

    /// How the canvas shows `st`'s document (photocraft `canvas_lut`): the plain or proofed display
    /// LUT through `DisplayColor`, or a simulation's / the 32-bit preview's LUT (`proof_sim`).
    /// `includeHDR` false leaves the 32-bit preview to the GPU canvas shader (photocraft
    /// `gpu_canvas_lut`).
    public static func canvasDisplay(_ s: Session, _ st: DocState, display: UInt32? = nil, includeHDR: Bool = true) throws -> CanvasDisplay {
        let monitor = monitorProfile(s, display: display)
        var pv = st.view[ProofKey.self]
        pv.view.warningColor = warningColor(s)
        if var lut = try ProofSimCommands.displayLUT(s, st, size: PCPlatform.DisplayLUT.defaultSize, includeHDR: includeHDR, display: display) {
            let source = compositeProfile(st.doc)
            if pv.view.gamutWarning, source.colorSpace == .rgb {
                let check: GamutCheck
                do { check = try GamutCheck(source: source, proof: pv.profile, threshold: pv.gamutThreshold) } catch { throw cmsError(error) }
                let n = lut.size, sc = Float(n - 1)
                var d = lut.data
                for i in d.indices where check.isOutOfGamut([Float(i % n) / sc, Float((i / n) % n) / sc, Float(i / (n * n)) / sc]) {
                    d[i] = SIMD4(pv.view.warningColor, 1)
                }
                lut = PCPlatform.DisplayLUT(size: n, data: d)
            }
            let key = "sim:\(pv.kind.id):\(ProofSimCommands.hdrPreview(st).map { "\($0)" } ?? "-"):\(monitor.md5.base64EncodedString()):\(pv.view.gamutWarning)"
            return CanvasDisplay(source: source, monitor: monitor, lut: lut, key: key)
        }
        return try DisplayColor.shared.canvasDisplay(for: st.doc, monitor: monitor, proof: pv.view, proofProfile: pv.profile)
    }

    // MARK: Gamut

    /// Out-of-gamut mask of the document composite against `profile`: one byte per canvas pixel
    /// (255 = out of gamut; transparent pixels never are), plus the count (photocraft `gamut_mask`).
    public static func gamutMask(_ s: Session, _ doc: Document, profile: ICCProfile, threshold: Float) throws -> ([UInt8], Int) {
        let source = compositeProfile(doc)
        let check: GamutCheck
        do { check = try GamutCheck(source: source, proof: profile, threshold: threshold) } catch { throw cmsError(error) }
        let px = try s.services.renderer.render(doc, region: doc.bounds).px
        var count = 0
        let gray = source.channels == 1
        let mask: [UInt8] = px.map { p in
            guard p.w > 0, check.isOutOfGamut(gray ? [p.x] : [p.x, p.y, p.z]) else { return 0 }
            count += 1
            return 255
        }
        return (mask, count)
    }

    // MARK: Commands

    static func assignProfile(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let spec = p["profile"]?.stringValue else { throw EngineError.bad("edit.assignProfile", "missing `profile`") }
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        var bytes: [UInt8]?
        if spec != "none" {
            let prof = try resolve(s, spec, doc: doc, mode: nil)
            if prof.colorSpace != modeSpace(doc.mode) {
                throw EngineError.other("profile `\(prof.profileDescription)` is \(spaceName(prof.colorSpace)); the document is \(modeName(doc.mode))")
            }
            bytes = [UInt8](prof.data)
        }
        let desc = bytes.map { b in (try? profile(fromBytes: b))?.profileDescription ?? "" } ?? "none"
        try s.edit("Assign Profile") { doc, _ in doc.iccProfile = bytes }
        return ["profile": .string(desc)]
    }

    static func convertToProfile(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let spec = p["profile"]?.stringValue else { throw EngineError.bad("edit.convertToProfile", "missing `profile`") }
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        let dst = try resolve(s, spec, doc: doc, mode: nil)
        let c = settings(s)
        let intent = try intentParam(p, default: c.renderingIntent)
        let bpc = p["bpc"]?.boolValue ?? c.bpc
        try s.edit("Convert to Profile") { doc, _ in try convertDocument(&doc, to: dst, intent: intent, bpc: bpc) }
        guard let d = s.active?.doc else { throw EngineError.noDocument }
        return ["profile": .string(dst.profileDescription), "mode": .string(modeName(d.mode)), "intent": .string(intent.id), "bpc": .bool(bpc)]
    }

    static func profileInfo(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let builtins: [JSONValue] = BuiltinProfile.allCases.map { b in
            ["id": .string(b.id), "description": .string(b.profile.profileDescription), "colorSpace": .string(spaceName(b.profile.colorSpace))]
        }
        let doc = s.active?.doc
        var info: JSONValue = .null
        if let spec = p["profile"]?.stringValue {
            info = profileJSON(try resolveProfile(spec, doc: doc, mode: nil, fs: s.services.fileSystem))
        } else if let d = doc {
            info = profileJSON(documentProfile(d)).setting("embedded", .bool(d.iccProfile != nil))
        }
        return ["profile": info, "builtins": .array(builtins)]
    }

    static func proofSetup(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let st = s.active else { throw EngineError.noDocument }
        let name = p["profile"]?.stringValue ?? "working-cmyk"
        let profile = try resolve(s, name, doc: st.doc, mode: .cmyk)
        let intent = try intentParam(p, default: .relativeColorimetric)
        let bpc = p["bpc"]?.boolValue ?? true
        let paper = p["simulatePaper"]?.boolValue ?? false
        let enabled: Bool = try s.updateActive { st in
            var pv = st.view[ProofKey.self]
            pv.view.profile = name
            pv.profile = profile
            pv.view.intent = intent
            pv.view.blackPointCompensation = bpc
            pv.view.simulatePaper = paper
            pv.kind = .profile
            st.view[ProofKey.self] = pv
            return pv.view.enabled
        }
        return ["profile": .string(profile.profileDescription), "intent": .string(intent.id), "bpc": .bool(bpc),
                "simulatePaper": .bool(paper), "proofColors": .bool(enabled)]
    }

    static func proofColors(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let pv: ProofState = try s.updateActive { st in
            var pv = st.view[ProofKey.self]
            pv.view.enabled = p["on"]?.boolValue ?? !pv.view.enabled
            st.view[ProofKey.self] = pv
            return pv
        }
        return ["on": .bool(pv.view.enabled), "profile": .string(pv.profile.profileDescription)]
    }

    static func gamutWarning(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        let pv: ProofState = try s.updateActive { st in
            var pv = st.view[ProofKey.self]
            pv.view.gamutWarning = p["on"]?.boolValue ?? !pv.view.gamutWarning
            if let t = p["threshold"]?.doubleValue { pv.gamutThreshold = Float(max(t, 0)) }
            st.view[ProofKey.self] = pv
            return pv
        }
        var profile = pv.profile
        if let spec = p["profile"]?.stringValue { profile = try resolveProfile(spec, doc: doc, mode: .cmyk, fs: s.services.fileSystem) }
        let (_, count) = try gamutMask(s, doc, profile: profile, threshold: pv.gamutThreshold)
        let total = max(doc.size.width * doc.size.height, 1)
        return ["on": .bool(pv.view.gamutWarning), "profile": .string(profile.profileDescription), "threshold": .float(pv.gamutThreshold),
                "outOfGamut": .int(count), "fraction": .number(Double(count) / Double(total))]
    }

    /// Edit › Color Settings: read or change working spaces, policies and conversion options.
    static func colorSettings(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "edit.colorSettings"
        let current = settings(s)
        var next = p["reset"]?.boolValue == true ? Settings() : current
        if let v = p["workingRgb"]?.stringValue { next.workingRgb = v }
        if let v = p["workingCmyk"]?.stringValue { next.workingCmyk = v }
        if let v = p["workingGray"]?.stringValue { next.workingGray = v }
        if let v = p["monitorProfile"]?.stringValue { next.monitorProfile = v }
        for (k, path) in [("policyRgb", \Settings.policyRgb), ("policyCmyk", \Settings.policyCmyk), ("policyGray", \Settings.policyGray)] {
            if let v = p[k]?.stringValue {
                guard let pol = Policy.parse(v) else { throw EngineError.bad(cmd, "`\(k)` must be preserve|convert|off") }
                next[keyPath: path] = pol
            }
        }
        for (k, path) in [("askOnMismatch", \Settings.askOnMismatch), ("askOnPaste", \Settings.askOnPaste), ("askOnMissing", \Settings.askOnMissing),
                          ("bpc", \Settings.bpc), ("dither", \Settings.dither)] {
            if let v = p[k]?.boolValue { next[keyPath: path] = v }
        }
        if let v = p["intent"]?.stringValue { next.intent = RenderingIntent(parsing: v)?.id ?? v }
        switch p["blendTextGamma"] {
        case .bool(false)?: next.blendTextGamma = 1
        case .bool(true)?: next.blendTextGamma = 1.45
        case let v?:
            guard let g = v.doubleValue, (1.0...2.2).contains(g) else { throw EngineError.bad(cmd, "`blendTextGamma` must be 1.0..2.2 or a bool") }
            next.blendTextGamma = Float(g)
        case nil:
            break
        }
        if let why = validate(next, fs: s.services.fileSystem) { throw EngineError.bad(cmd, why) }
        if next != current { store(s, next) }
        let c = settings(s)
        let (monitor, status) = monitorStatus(s)
        let displays = s.state[DisplaysKey.self]
        let main = s.state[MainDisplayKey.self]
        return [
            "settings": c.json,
            "working": ["rgb": .string(working(s, .rgb).profileDescription), "cmyk": .string(working(s, .cmyk).profileDescription),
                        "gray": .string(working(s, .grayscale).profileDescription)],
            "monitor": .string(monitor.profileDescription),
            "monitorDetected": .bool(!displays.isEmpty),
            "monitorStatus": status,
            "displays": .array(displays.map { d in
                ["id": .int(d.displayID), "name": .string(d.name),
                 "frame": .doubles([Double(d.frame.minX), Double(d.frame.minY), Double(d.frame.width), Double(d.frame.height)]),
                 "profileName": d.profile.map { .string($0.profileDescription) } ?? .null, "main": .bool(main == d.displayID),
                 "status": monitorStatus(s, display: d.displayID).1]
            }),
        ]
    }

    /// Resolves an embedded-profile mismatch reported when opening (the "Embedded Profile Mismatch"
    /// dialog): keep the embedded profile, convert to the working space, or discard it.
    static func profileMismatch(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let action = p["action"]?.stringValue ?? "preserve"
        guard let mode = s.active?.doc.mode else { throw EngineError.noDocument }
        switch action {
        case "preserve", "useEmbedded":
            return ["action": "kept"]
        case "convert", "convertToWorking":
            let dst = working(s, mode)
            let c = settings(s)
            try s.edit("Convert to Working RGB") { doc, _ in try convertDocument(&doc, to: dst, intent: c.renderingIntent, bpc: c.bpc) }
            return ["action": "converted", "profile": .string(dst.profileDescription)]
        case "discard", "off":
            try s.edit("Discard Profile") { doc, _ in doc.iccProfile = nil }
            return ["action": "discarded"]
        case "assignWorking":
            let w = working(s, mode)
            try s.edit("Assign Profile") { doc, _ in doc.iccProfile = [UInt8](w.data) }
            return ["action": "assigned", "profile": .string(w.profileDescription)]
        default:
            throw EngineError.bad("color.profileMismatch", "unknown action `\(action)` (preserve|convert|discard|assignWorking)")
        }
    }

    // MARK: Registration

    public static func register(into r: inout CommandRegistry) {
        r.add([
            CommandSpec("edit.assignProfile", "Assign Profile…", menu: ["Edit"],
                        params: #"{"profile":"working|srgb|display-p3|adobe-rgb-compat|prophoto-compat|linear-srgb|rec2020|gray-gamma-2.2|sgray|lab-d50|coated-cmyk|none" (or a path to an .icc file)}"#,
                        module: m, enabled: Pre.hasDoc, run: assignProfile),
            CommandSpec("edit.convertToProfile", "Convert to Profile…", menu: ["Edit"],
                        params: #"{"profile":"srgb|display-p3|adobe-rgb-compat|prophoto-compat|linear-srgb|rec2020|gray-gamma-2.2|sgray|lab-d50|coated-cmyk|working" (or a path to an .icc file),"intent":"perceptual|relative|saturation|absolute"="relative","bpc":bool=true}"#,
                        module: m, enabled: Pre.hasDoc, run: convertToProfile),
            CommandSpec("edit.colorSettings", "Color Settings…", menu: ["Edit"], shortcut: "Cmd+Shift+K",
                        params: #"{"workingRgb":"srgb|display-p3|adobe-rgb-compat|prophoto-compat|linear-srgb|rec2020","workingCmyk":"coated-cmyk","workingGray":"sgray|gray-gamma-2.2","policyRgb":"preserve|convert|off","policyCmyk":"preserve|convert|off","policyGray":"preserve|convert|off","askOnMismatch":bool=true,"askOnPaste":bool=true,"askOnMissing":bool=false,"intent":"relative|perceptual|saturation|absolute","blendTextGamma":1.0..2.2|bool=1.45,"bpc":bool=true,"dither":bool=true,"monitorProfile":"auto|srgb|display-p3|adobe-rgb-compat|prophoto-compat|rec2020","reset":bool=false} (working spaces and the monitor profile also accept .icc paths; monitor `auto` = the main display's profile when the platform provides it, else sRGB; the reply's `monitorStatus` says which profile is in use and why: source auto|manual|fallback, reason)"#,
                        module: m, run: colorSettings),
            CommandSpec("color.profileMismatch", "Embedded Profile Mismatch", params: #"{"action":"preserve|convert|discard|assignWorking"}"#,
                        module: m, enabled: Pre.hasDoc, run: profileMismatch),
            CommandSpec("edit.profileInfo", "Profile Info", params: #"{"profile":"<builtin id>|document|/path/to/profile.icc"=document}"#,
                        module: m, journal: false, run: profileInfo),
            CommandSpec("view.proofSetup", "Proof Setup…",
                        params: #"{"profile":"working-cmyk|srgb|display-p3|adobe-rgb-compat|prophoto-compat|linear-srgb|rec2020|gray-gamma-2.2|sgray|lab-d50|coated-cmyk" (or a path to an .icc file)="working-cmyk","intent":"perceptual|relative|saturation|absolute"="relative","bpc":bool=true,"simulatePaper":bool=false}"#,
                        module: m, journal: false, enabled: Pre.hasDoc, run: proofSetup),
            CommandSpec("view.proofColors", "Proof Colors", menu: ["View"], shortcut: "Cmd+Y", params: #"{"on":bool=toggle}"#,
                        module: m, journal: false, enabled: Pre.hasDoc, run: proofColors),
            CommandSpec("view.gamutWarning", "Gamut Warning", menu: ["View"], shortcut: "Cmd+Shift+Y",
                        params: #"{"on":bool=toggle,"threshold":deltaE=4,"profile":"<proof profile override>"}"#,
                        module: m, journal: false, enabled: Pre.hasDoc, run: gamutWarning),
        ])
    }
}
