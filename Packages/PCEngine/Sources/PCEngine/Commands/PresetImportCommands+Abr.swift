// Port of photocraft-io (crates/io/src/abr_map.rs), as used by photocraft-engine (crates/engine/src/preset_import_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Photoshop brushes (`.abr`) → brush presets. PCPSD's `PSDAbr` reads the file; this maps its tips
// and `brushPreset` descriptors onto PCPaint's `BrushSettings` (Brush Tip Shape, Shape Dynamics,
// Scattering, Texture, Dual Brush, Color Dynamics, Transfer, Brush Pose, Noise, Wet Edges,
// Build-up, Smoothing and the captured tool options). Settings without an equivalent are listed in
// the warnings instead of being dropped silently. Descriptor key names follow the publicly
// documented ABR v6+ layout. (PCIO does not port `abr_map`: it would need PCPaint's model.)

import Foundation
import PCPaint
import PCPSD

extension PresetImportCommands {
    enum Abr {
        /// Largest sampled tip edge kept as is; bigger tips are downsampled to it.
        static let maxTipEdge = 2500
        /// Largest texture pattern edge kept as is; bigger patterns are downsampled to it.
        static let maxPatternEdge = 1024

        /// The presets read from one file plus everything that could not be mapped.
        struct Import: Sendable {
            var presets: [BrushPreset] = []
            var warnings: [String] = []
            /// File version (1, 2, 6…).
            var version: UInt16 = 0
        }

        struct Failure: Error, CustomStringConvertible {
            var description: String
        }

        /// Parses an `.abr` file into presets in group `group` (photocraft `read_abr_with`): the
        /// file's own folders become each preset's `folder` inside that group. `cancelled` is
        /// checked before each brush (a cancelled import fails with "cancelled").
        static func read(_ bytes: [UInt8], group: String, cancelled: () -> Bool = { false }, progress: (Float) -> Void = { _ in }) throws -> Import {
            let f: PSDAbr.File
            do { f = try PSDAbr.parse(Data(bytes)) } catch { throw Failure(description: "not a readable brush file (.abr): \(error)") }
            // Parsing is the small part; mapping (tip decoding) reports 10–100 %.
            progress(0.1)
            return try map(f, group: group, cancelled: cancelled, progress: { progress(0.1 + 0.9 * $0) })
        }

        /// Maps a parsed file (photocraft `map_file_with`).
        static func map(_ f: PSDAbr.File, group: String, cancelled: () -> Bool = { false }, progress: (Float) -> Void = { _ in }) throws -> Import {
            var out = Import(presets: [], warnings: f.warnings, version: f.version)
            let m = Mapper(f)
            let total = Float(max(f.legacy.count, f.samples.count, f.presets.count, 1))
            func step(_ i: Int) throws {
                if cancelled() { throw Failure(description: "cancelled") }
                progress(Float(i) / total)
            }
            if !f.legacy.isEmpty {
                for (i, b) in f.legacy.enumerated() {
                    try step(i)
                    var base = BrushSettings()
                    base.pressureSize = false
                    base.spacing = b.spacing == 0 ? 0.25 : Float(b.spacing) / 100
                    let brush: BrushSettings
                    let defaultName: String
                    switch b.tip {
                    case let .computed(diameter, hardness, angle, roundness):
                        var c = base
                        c.size = Float(max(diameter, 1))
                        c.hardness = min(max(Float(hardness) / 100, 0), 1)
                        c.angle = Float(angle)
                        c.roundness = min(max(Float(roundness) / 100, 0.01), 1)
                        brush = c
                        defaultName = "\(diameter) px Round"
                    case let .sampled(s):
                        let (tip, size) = m.tip(s)
                        var c = base
                        c.size = size
                        c.tip = tip
                        c.aliased = !b.antiAlias
                        brush = c
                        defaultName = "Sampled Brush \(i + 1)"
                    }
                    let trimmed = b.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    out.presets.append(BrushPreset(name: trimmed.isEmpty ? defaultName : trimmed, brush: brush, builtin: false, group: group, folder: []))
                }
            } else if f.presets.isEmpty {
                // Tips without a settings section (early v6 files): one preset per tip.
                for (i, s) in f.samples.enumerated() {
                    try step(i)
                    let (tip, size) = m.tip(s)
                    var brush = BrushSettings()
                    brush.pressureSize = false
                    brush.spacing = 0.25
                    brush.size = size
                    brush.tip = tip
                    out.presets.append(BrushPreset(name: "Sampled Brush \(i + 1)", brush: brush, builtin: false, group: group, folder: []))
                }
            } else {
                for (i, d) in f.presets.enumerated() {
                    try step(i)
                    let nm = d.text("Nm  ")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let name = nm.isEmpty ? "Brush \(i + 1)" : nm
                    if let brush = m.preset(d) {
                        // The file's folders nest inside `group`, as Photoshop nests them inside a
                        // folder named after the imported file.
                        let folder = i < f.folders.count ? f.folders[i] : []
                        out.presets.append(BrushPreset(name: name, brush: brush, builtin: false, group: group, folder: folder))
                    } else {
                        m.warnings.insert("\"\(name)\": its sampled tip is missing from the file; skipped")
                    }
                }
            }
            out.warnings += m.warnings.sorted()
            if !m.unknown.isEmpty {
                out.warnings.append("settings without a PhotoCraft equivalent were ignored: \(m.unknown.sorted().joined(separator: ", "))")
            }
            progress(1)
            return out
        }

        // MARK: Descriptor helpers

        static func num(_ d: PSDDescriptor, _ k: String) -> Double? { d.number(k).flatMap { $0.isFinite ? $0 : nil } }
        /// A percentage as a 0…1 fraction.
        static func pct(_ d: PSDDescriptor, _ k: String) -> Float? { num(d, k).map { Float($0 / 100) } }
        static func boolean(_ d: PSDDescriptor, _ k: String) -> Bool? { d.bool(k) }
        static func text(_ d: PSDDescriptor, _ k: String) -> String? { d.text(k) }
        static func obj(_ d: PSDDescriptor, _ k: String) -> PSDDescriptor? { d.descriptor(k) }
        static func enumValue(_ d: PSDDescriptor, _ k: String) -> String? { d.enumValue(k) }
        static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }
        static func clampD(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

        static func maskMode(_ code: String?) -> MaskMode? {
            switch code {
            case "Mltp": .multiply
            case "Sbtr": .subtract
            case "Drkn": .darken
            case "Ovrl": .overlay
            case "CDdg": .colorDodge
            case "CBrn": .colorBurn
            case "linearBurn": .linearBurn
            case "hardMix": .hardMix
            case "linearHeight": .linearHeight
            case "height", "Hght": .height
            default: nil
            }
        }

        /// Preset-level keys this mapper understands (anything else is reported as unmapped).
        static let known: Set<String> = [
            "Nm  ", "Brsh", "useTipDynamics", "flipX", "flipY", "brushProjection", "minimumDiameter", "minimumRoundness", "tiltScale", "szVr",
            "angleDynamics", "roundnessDynamics", "useScatter", "Spcn", "Cnt ", "bothAxes", "countDynamics", "scatterDynamics", "dualBrush",
            "brushGroup", "useTexture", "TxtC", "interpretation", "textureBlendMode", "textureDepth", "minimumDepth", "textureDepthDynamics",
            "Txtr", "textureScale", "InvT", "protectTexture", "textureBrightness", "textureContrast", "usePaintDynamics", "prVr", "opVr",
            "wtVr", "mxVr", "useColorDynamics", "clVr", "H   ", "Strt", "Brgh", "purity", "colorDynamicsPerTip", "Wtdg", "Nose", "Rpt ",
            "useLegacy", "useBrushPose", "overridePoseAngle", "overridePoseTiltX", "overridePoseTiltY", "overridePosePressure",
            "brushPosePressure", "brushPoseTiltX", "brushPoseTiltY", "brushPoseAngle", "toolOptions",
        ]

        /// Saturating float → unsigned conversion (Rust's `as u32` / `as u16`).
        static func sat<T: FixedWidthInteger & UnsignedInteger>(_ v: Float, _: T.Type) -> T {
            if !(v > 0) { return 0 }
            if v >= Float(T.max) { return T.max }
            return T(v)
        }

        final class Mapper {
            let file: PSDAbr.File
            var warnings = Set<String>()
            var unknown = Set<String>()

            init(_ file: PSDAbr.File) { self.file = file }

            /// A sampled tip (downsampled to `maxTipEdge`) and its size (larger side).
            func tip(_ s: PSDAbr.Sample) -> (TipShape, Float) {
                let (w, h, v) = Abr.fit(s.width, s.height, s.unit, maxTipEdge)
                if w != s.width || h != s.height { warnings.insert("tips larger than \(maxTipEdge) px were downsampled") }
                let data = v.map { Abr.sat(Abr.clamp($0, 0, 1) * 65535 + 0.5, UInt16.self) }
                return (.sampled(GrayTile(width: UInt32(w), height: UInt32(h), data: data)), Float(max(s.width, s.height)))
            }

            func dynamic(_ d: PSDDescriptor?) -> Dynamic {
                guard let d else { return Dynamic() }
                let control: Control
                let v = Abr.num(d, "bVTy") ?? 0
                switch v.isFinite && abs(v) < 1e18 ? Int64(v) : 0 {
                case 1: control = .fade
                case 2: control = .penPressure
                case 3: control = .penTilt
                case 4: control = .stylusWheel
                case 5: control = .initialDirection
                case 6: control = .direction
                case 7:
                    warnings.insert("\"Initial Rotation\" control mapped to Rotation")
                    control = .rotation
                case 8: control = .rotation
                default: control = .off
                }
                return Dynamic(jitter: max(Abr.pct(d, "jitter") ?? 0, 0), control: control,
                               fadeSteps: Abr.num(d, "fStp").map { UInt32(Abr.clampD($0, 1, 9999)) } ?? 25,
                               minimum: Abr.clamp(Abr.pct(d, "Mnm ") ?? 0, 0, 1))
            }

            /// Tip-shape fields from a `computedBrush` / `sampledBrush` object; nil when the
            /// sampled tip it references is missing.
            func tipShape(_ t: PSDDescriptor) -> (TipShape, Float?)? {
                let sampled = t.classID.is("sampledBrush") || t["sampledData"] != nil
                if !sampled { return (.round, nil) }
                let id = Abr.text(t, "sampledData") ?? ""
                guard let s = file.samples.first(where: { $0.id == id }) ?? (file.samples.count == 1 ? file.samples.first : nil) else { return nil }
                let (tip, size) = tip(s)
                return (tip, size)
            }

            func pattern(_ t: PSDDescriptor) -> PCPaint.Pattern {
                let id = Abr.text(t, "Idnt") ?? ""
                let name = Abr.text(t, "Nm  ") ?? ""
                let found = file.patterns.first { !id.isEmpty && $0.id == id } ?? file.patterns.first { !name.isEmpty && $0.name == name }
                if let tile = found.flatMap(Abr.patternTile) { return .tile(tile) }
                let label = name.isEmpty ? id : name
                warnings.insert("texture pattern \"\(label)\" is not embedded in the file; a procedural paper texture stands in")
                return .procedural(style: .paper, size: 128, seed: 1)
            }

            /// Mixer Brush tool options captured with a preset (Wet, Load, Mix, Flow, Sample All
            /// Layers). Key names are best effort; several spellings are read.
            func mixerOptions(_ to: PSDDescriptor, _ m: inout MixerSettings) {
                func first(_ keys: [String]) -> Float? { keys.lazy.compactMap { Abr.pct(to, $0) }.first }
                let wet = first(["wetness", "Wtns", "wet"])
                let load = first(["dryness", "load", "Ld  "])
                let mix = first(["mix", "mixRatio", "Mx  "])
                if wet == nil && load == nil && mix == nil { return }
                m.wet = Abr.clamp(wet ?? m.wet, 0, 1)
                m.load = Abr.clamp(load ?? m.load, 0, 1)
                m.mix = Abr.clamp(mix ?? m.mix, 0, 1)
                m.flow = Abr.clamp(Abr.pct(to, "flow") ?? m.flow, 0, 1)
                if let v = ["sampleMerged", "useAllLayers", "sampleAllLayers", "Mrgd"].lazy.compactMap({ Abr.boolean(to, $0) }).first {
                    m.sampleAllLayers = v
                }
            }

            func preset(_ d: PSDDescriptor) -> BrushSettings? {
                for item in d.items where !Abr.known.contains(item.key.name) { unknown.insert(item.key.name) }
                var b = BrushSettings()
                b.pressureSize = false
                b.spacing = 0.25
                if let t = Abr.obj(d, "Brsh") {
                    guard let shape = tipShape(t) else { return nil }
                    b.tip = shape.0
                    b.size = Abr.clamp(Abr.num(t, "Dmtr").map { Float($0) } ?? shape.1 ?? b.size, 1, 5000)
                    if let v = Abr.pct(t, "Hrdn") { b.hardness = Abr.clamp(v, 0, 1) }
                    b.angle = Float(Abr.num(t, "Angl") ?? 0)
                    b.roundness = Abr.clamp(Abr.pct(t, "Rndn") ?? 1, 0.01, 1)
                    // `Intr` off = the Spacing checkbox is off: the pointer's speed sets the spacing.
                    b.spacing = Abr.clamp(Abr.pct(t, "Spcn") ?? 0.25, 0.01, 10)
                    b.spacingEnabled = Abr.boolean(t, "Intr") != false
                    b.flipX = Abr.boolean(t, "flipX") ?? false
                    b.flipY = Abr.boolean(t, "flipY") ?? false
                }
                // Shape Dynamics.
                if Abr.boolean(d, "useTipDynamics") == true {
                    var size = dynamic(Abr.obj(d, "szVr"))
                    size.minimum = Abr.clamp(Abr.pct(d, "minimumDiameter") ?? size.minimum, 0, 1)
                    let angle = dynamic(Abr.obj(d, "angleDynamics"))
                    var roundness = dynamic(Abr.obj(d, "roundnessDynamics"))
                    roundness.minimum = Abr.clamp(Abr.pct(d, "minimumRoundness") ?? roundness.minimum, 0, 1)
                    b.shapeDynamics.enabled = true
                    b.shapeDynamics.size = size
                    b.shapeDynamics.angle = angle
                    b.shapeDynamics.roundness = roundness
                    b.shapeDynamics.flipXJitter = Abr.boolean(d, "flipX") ?? false
                    b.shapeDynamics.flipYJitter = Abr.boolean(d, "flipY") ?? false
                    b.shapeDynamics.tiltScale = Abr.clamp(Abr.pct(d, "tiltScale") ?? 0, 0, 2)
                    b.shapeDynamics.brushProjection = Abr.boolean(d, "brushProjection") ?? false
                }
                // Scattering.
                if Abr.boolean(d, "useScatter") == true {
                    b.scattering.enabled = true
                    b.scattering.scatter = dynamic(Abr.obj(d, "scatterDynamics"))
                    b.scattering.bothAxes = Abr.boolean(d, "bothAxes") ?? false
                    b.scattering.count = Abr.num(d, "Cnt ").map { UInt32(Abr.clampD($0, 1, 16)) } ?? 1
                    b.scattering.countJitter = dynamic(Abr.obj(d, "countDynamics"))
                }
                // Texture.
                if Abr.boolean(d, "useTexture") == true {
                    b.texture.enabled = true
                    b.texture.eachTip = Abr.boolean(d, "TxtC") ?? false
                    b.texture.invert = Abr.boolean(d, "InvT") ?? false
                    b.texture.scale = Abr.clamp(Abr.pct(d, "textureScale") ?? 1, 0.01, 10)
                    b.texture.brightness = Float(Abr.clampD((Abr.num(d, "textureBrightness") ?? 0) / 150, -1, 1))
                    // Photoshop's -50..100 onto the model's -1..1 (negative and positive scale apart).
                    let c = Abr.num(d, "textureContrast") ?? 0
                    b.texture.contrast = Float(Abr.clampD(c < 0 ? c / 50 : c / 100, -1, 1))
                    b.texture.mode = Abr.maskMode(Abr.enumValue(d, "textureBlendMode")) ?? .multiply
                    b.texture.depth = Abr.clamp(Abr.pct(d, "textureDepth") ?? 1, 0, 1)
                    var dj = dynamic(Abr.obj(d, "textureDepthDynamics"))
                    dj.minimum = Abr.clamp(Abr.pct(d, "minimumDepth") ?? dj.minimum, 0, 1)
                    b.texture.depthJitter = dj
                    if let p = Abr.obj(d, "Txtr") { b.texture.pattern = pattern(p) }
                }
                b.protectTexture = Abr.boolean(d, "protectTexture") ?? false
                // Dual Brush.
                if let db = Abr.obj(d, "dualBrush"), Abr.boolean(db, "useDualBrush") == true {
                    var dual = DualBrush()
                    dual.enabled = true
                    if let t = Abr.obj(db, "Brsh") {
                        if let shape = tipShape(t) {
                            dual.tip = shape.0
                            dual.size = Abr.clamp(Abr.num(t, "Dmtr").map { Float($0) } ?? shape.1 ?? dual.size, 1, 5000)
                        } else {
                            warnings.insert("a dual brush tip is missing from the file; a round tip stands in")
                        }
                        dual.hardness = Abr.clamp(Abr.pct(t, "Hrdn") ?? 1, 0, 1)
                        dual.roundness = Abr.clamp(Abr.pct(t, "Rndn") ?? 1, 0.01, 1)
                        dual.angle = Float(Abr.num(t, "Angl") ?? 0)
                        dual.spacing = Abr.clamp(Abr.pct(t, "Spcn") ?? dual.spacing, 0.01, 10)
                    }
                    dual.mode = Abr.maskMode(Abr.enumValue(db, "BlnM")) ?? .multiply
                    dual.flip = Abr.boolean(db, "Flip") ?? false
                    if let v = Abr.pct(db, "Spcn") { dual.spacing = Abr.clamp(v, 0.01, 10) }
                    dual.scatter = dynamic(Abr.obj(db, "scatterDynamics")).jitter
                    dual.bothAxes = Abr.boolean(db, "bothAxes") ?? false
                    dual.count = Abr.num(db, "Cnt ").map { UInt32(Abr.clampD($0, 1, 16)) } ?? 1
                    b.dualBrush = dual
                }
                // Color Dynamics.
                if Abr.boolean(d, "useColorDynamics") == true {
                    b.colorDynamics.enabled = true
                    b.colorDynamics.perTip = Abr.boolean(d, "colorDynamicsPerTip") ?? true
                    b.colorDynamics.hueJitter = Abr.clamp(Abr.pct(d, "H   ") ?? 0, 0, 1)
                    b.colorDynamics.saturationJitter = Abr.clamp(Abr.pct(d, "Strt") ?? 0, 0, 1)
                    b.colorDynamics.brightnessJitter = Abr.clamp(Abr.pct(d, "Brgh") ?? 0, 0, 1)
                    b.colorDynamics.purity = Abr.clamp(Abr.pct(d, "purity") ?? 0, -1, 1)
                    b.colorDynamics.fgBg = dynamic(Abr.obj(d, "clVr"))
                }
                // Transfer.
                if Abr.boolean(d, "usePaintDynamics") == true {
                    let opacity = dynamic(Abr.obj(d, "opVr"))
                    let flow = dynamic(Abr.obj(d, "prVr"))
                    let wetness = dynamic(Abr.obj(d, "wtVr"))
                    let mix = dynamic(Abr.obj(d, "mxVr"))
                    b.transfer = Transfer(enabled: true, opacity: opacity, flow: flow, wetness: wetness, mix: mix)
                }
                // Brush Pose (Photoshop's tilt is ±100 %; ours is ±90°).
                if Abr.boolean(d, "useBrushPose") == true {
                    b.pose.enabled = true
                    b.pose.tiltX = Float(Abr.clampD((Abr.num(d, "brushPoseTiltX") ?? 0) * 0.9, -90, 90))
                    b.pose.tiltY = Float(Abr.clampD((Abr.num(d, "brushPoseTiltY") ?? 0) * 0.9, -90, 90))
                    let r = (Abr.num(d, "brushPoseAngle") ?? 0).truncatingRemainder(dividingBy: 360)
                    b.pose.rotation = Float(r < 0 ? r + 360 : r)
                    b.pose.pressure = Abr.clamp(Abr.pct(d, "brushPosePressure") ?? 1, 0, 1)
                    b.pose.overrideTilt = (Abr.boolean(d, "overridePoseTiltX") ?? false) || (Abr.boolean(d, "overridePoseTiltY") ?? false)
                    b.pose.overrideRotation = Abr.boolean(d, "overridePoseAngle") ?? false
                    b.pose.overridePressure = Abr.boolean(d, "overridePosePressure") ?? false
                }
                b.noise = Abr.boolean(d, "Nose") ?? false
                b.wetEdges = Abr.boolean(d, "Wtdg") ?? false
                b.buildUp = Abr.boolean(d, "Rpt ") ?? false
                // Tool options captured with the preset ("Include tool settings").
                if let to = Abr.obj(d, "toolOptions") {
                    if let v = Abr.pct(to, "Opct") { b.opacity = Abr.clamp(v, 0, 1) }
                    if let v = Abr.pct(to, "flow") { b.flow = Abr.clamp(v, 0, 1) }
                    b.pressureSize = Abr.boolean(to, "usePressureOverridesSize") ?? false
                    b.pressureOpacity = Abr.boolean(to, "usePressureOverridesOpacity") ?? false
                    if Abr.boolean(to, "smoothing") ?? true, let v = Abr.pct(to, "smoothingValue") { b.smoothing.amount = Abr.clamp(v, 0, 1) }
                    if let v = Abr.boolean(to, "smoothingRadiusMode") { b.smoothing.pulledString = v }
                    if let v = Abr.boolean(to, "smoothingCatchup") { b.smoothing.catchUp = v }
                    if let v = Abr.boolean(to, "smoothingCatchupAtEnd") { b.smoothing.catchUpOnEnd = v }
                    if let v = Abr.boolean(to, "smoothingZoomCompensation") { b.smoothing.adjustForZoom = v }
                    mixerOptions(to, &b.mixer)
                    if let mode = Abr.enumValue(to, "Md  "), mode != "Nrml" { warnings.insert("tool blend modes stored with presets are not applied") }
                }
                return b
            }
        }

        /// Box-downsamples a `w × h` plane so neither side exceeds `limit`.
        static func fit(_ w: Int, _ h: Int, _ v: [Float], _ limit: Int) -> (Int, Int, [Float]) {
            if w <= limit && h <= limit { return (w, h, v) }
            let k = max(Float(max(w, h)) / Float(limit), 1)
            let nw = min(max(Int((Float(w) / k).rounded()), 1), limit)
            let nh = min(max(Int((Float(h) / k).rounded()), 1), limit)
            var out = [Float](repeating: 0, count: nw * nh)
            for y in 0..<nh {
                let y0 = y * h / nh
                let y1 = min(max((y + 1) * h / nh, y0 + 1), h)
                for x in 0..<nw {
                    let x0 = x * w / nw
                    let x1 = min(max((x + 1) * w / nw, x0 + 1), w)
                    var sum: Float = 0
                    var n = 0
                    for yy in y0..<max(y1, y0) {
                        for xx in x0..<max(x1, x0) {
                            let i = yy * w + xx
                            if i < v.count { sum += v[i]; n += 1 }
                        }
                    }
                    out[y * nw + x] = n > 0 ? sum / Float(n) : 0
                }
            }
            return (nw, nh, out)
        }

        /// A pattern as a grayscale texture tile (luminance; transparent areas count as white).
        static func patternTile(_ p: PSDPattern) -> GrayTile? {
            let (w, h) = (p.width, p.height)
            let n = w * h
            if w <= 0 || h <= 0 { return nil }
            func plane(_ c: Int) -> [Float]? {
                guard c < p.channels.count else { return nil }
                let ch = p.channels[c]
                var v: [Float] = []
                switch p.depth {
                case 8:
                    v = ch.prefix(n).map { Float($0) / 255 }
                case 16:
                    let k = min(ch.count / 2, n)
                    v = (0..<k).map { Float(UInt16(ch[2 * $0]) << 8 | UInt16(ch[2 * $0 + 1])) / 65535 }
                case 32:
                    let k = min(ch.count / 4, n)
                    v = (0..<k).map { i in
                        let bits = UInt32(ch[4 * i]) << 24 | UInt32(ch[4 * i + 1]) << 16 | UInt32(ch[4 * i + 2]) << 8 | UInt32(ch[4 * i + 3])
                        return min(max(Float(bitPattern: bits), 0), 1)
                    }
                default: return nil
                }
                return v.count == n ? v : nil
            }
            let gray: [Float]
            switch p.mode {
            case 3:
                guard let r = plane(0), let g = plane(1), let b = plane(2) else { return nil }
                gray = (0..<n).map { 0.299 * r[$0] + 0.587 * g[$0] + 0.114 * b[$0] }
            case 2:
                guard let pal = p.palette, let idx = p.channels.first else { return nil }
                gray = (0..<n).map { i in
                    let k = Int(i < idx.count ? idx[i] : 0) * 3
                    func c(_ o: Int) -> Float { Float(k + o < pal.count ? pal[k + o] : 0) / 255 }
                    return 0.299 * c(0) + 0.587 * c(1) + 0.114 * c(2)
                }
            case 4:
                // CMYK planes are stored inverted (0 = full ink).
                guard let k = plane(3), let c = plane(0) else { return nil }
                gray = (0..<n).map { min(max(c[$0] * k[$0], 0), 1) }
            default:
                guard let g = plane(0) else { return nil }
                gray = g
            }
            let (fw, fh, fitted) = fit(w, h, gray, maxPatternEdge)
            return GrayTile(width: UInt32(fw), height: UInt32(fh), data: fitted.map { sat(clamp($0, 0, 1) * 65535 + 0.5, UInt16.self) })
        }
    }
}
