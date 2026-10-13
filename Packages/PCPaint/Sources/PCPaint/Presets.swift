// Port of photocraft-paint (crates/paint/src/presets.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Built-in brush presets (photocraft's own designs; sampled tips and textures are generated
// procedurally), grouped like Photoshop's default Brushes panel folders: General, Dry Media, Wet
// Media and Special Effects. Every preset is plain `BrushSettings` data.

public enum BrushPresets {
    /// Preset groups, in panel order.
    public static let groups = ["General", "Dry Media", "Wet Media", "Special Effects"]

    static func preset(_ group: String, _ name: String, _ brush: BrushSettings) -> BrushPreset {
        BrushPreset(name: name, brush: brush, builtin: true, group: group, folder: [])
    }

    static func pressure() -> Dynamic { .controlled(.penPressure) }
    static func pressureMin(_ minimum: Float) -> Dynamic { Dynamic(control: .penPressure, minimum: minimum) }
    static func sizeDyn(_ size: Dynamic) -> ShapeDynamics { ShapeDynamics(enabled: true, size: size) }
    static func transfer(_ opacity: Dynamic, _ flow: Dynamic) -> Transfer { Transfer(enabled: true, opacity: opacity, flow: flow) }
    static func paper(_ seed: UInt32, _ depth: Float) -> Texture {
        Texture(enabled: true, pattern: .procedural(style: .paper, size: 128, seed: seed), depth: depth)
    }

    /// `base` with some fields set (Rust's `BrushSettings { …, ..base.clone() }`).
    static func with(_ base: BrushSettings, _ f: (inout BrushSettings) -> Void) -> BrushSettings {
        var b = base
        f(&b)
        return b
    }

    static func general(_ base: BrushSettings) -> [BrushPreset] {
        func g(_ n: String, _ f: (inout BrushSettings) -> Void) -> BrushPreset { preset("General", n, with(base, f)) }
        return [
            g("Hard Round") { $0.size = 30; $0.hardness = 1 },
            g("Soft Round") { $0.size = 45; $0.hardness = 0 },
            g("Hard Round Fine") { $0.size = 5; $0.hardness = 1; $0.spacing = 0.1 },
            g("Soft Round Large") { $0.size = 300; $0.hardness = 0; $0.spacing = 0.15 },
            g("Hard Round Pressure Size") { $0.size = 30; $0.hardness = 1; $0.shapeDynamics = sizeDyn(pressure()) },
            g("Soft Round Pressure Size") { $0.size = 45; $0.hardness = 0; $0.shapeDynamics = sizeDyn(pressure()) },
            g("Hard Round Pressure Opacity") { $0.size = 30; $0.hardness = 1; $0.transfer = transfer(pressure(), Dynamic()) },
            g("Soft Round Pressure Opacity") { $0.size = 45; $0.hardness = 0; $0.transfer = transfer(pressure(), Dynamic()) },
            g("Hard Round Pressure Opacity and Flow") { $0.size = 30; $0.hardness = 0.9; $0.transfer = transfer(pressure(), pressureMin(0.2)) },
            g("Airbrush Soft") { $0.size = 80; $0.hardness = 0; $0.flow = 0.1; $0.spacing = 0.1; $0.buildUp = true; $0.buildUpRate = 25 },
            g("Airbrush Pressure Flow") {
                $0.size = 120; $0.hardness = 0; $0.flow = 0.15; $0.spacing = 0.1; $0.buildUp = true; $0.buildUpRate = 30
                $0.transfer = transfer(Dynamic(), pressure())
            },
            g("Calligraphy Flat") { $0.size = 28; $0.hardness = 1; $0.roundness = 0.2; $0.angle = 45; $0.spacing = 0.05 },
        ]
    }

    static func dryMedia(_ base: BrushSettings) -> [BrushPreset] {
        func g(_ n: String, _ f: (inout BrushSettings) -> Void) -> BrushPreset { preset("Dry Media", n, with(base, f)) }
        return [
            g("Hard Pencil") { $0.size = 3; $0.hardness = 1; $0.aliased = true; $0.spacing = 0.1 },
            g("Soft Pencil") {
                $0.size = 6; $0.hardness = 0.6; $0.spacing = 0.08
                $0.shapeDynamics = sizeDyn(pressureMin(0.4))
                $0.transfer = transfer(pressureMin(0.15), Dynamic())
                var t = paper(21, 0.8); t.scale = 0.5
                $0.texture = t
            },
            g("Chalk") {
                $0.size = 40; $0.tip = .sampled(Procedural.chalkTip(64, 7)); $0.spacing = 0.2
                $0.shapeDynamics = ShapeDynamics(enabled: true, size: Dynamic(jitter: 0.15), angle: .jitter(1))
                $0.texture = paper(3, 0.6)
            },
            g("Charcoal") {
                $0.size = 45; $0.tip = .sampled(Procedural.charcoalTip(64, 4)); $0.spacing = 0.12
                $0.shapeDynamics = ShapeDynamics(enabled: true, size: pressureMin(0.5), angle: .controlled(.direction))
                $0.transfer = transfer(pressureMin(0.3), Dynamic())
                // Subtract takes paint away where the pattern is light (#3340); inverting keeps
                // these presets as they were designed, with the dark parts taking it away.
                var t = paper(5, 0.7); t.mode = .subtract; t.invert = true
                $0.texture = t
            },
            g("Pastel") {
                $0.size = 50; $0.tip = .sampled(Procedural.chalkTip(64, 31)); $0.spacing = 0.15
                $0.shapeDynamics = ShapeDynamics(enabled: true, angle: .jitter(1), roundness: Dynamic(jitter: 0.3, minimum: 0.5))
                $0.scattering = Scattering(enabled: true, scatter: .jitter(0.25))
                $0.texture = Texture(enabled: true, pattern: .procedural(style: .canvas, size: 64, seed: 2), invert: true, mode: .subtract, depth: 0.55)
            },
            g("Wax Crayon") {
                $0.size = 22; $0.hardness = 0.85; $0.roundness = 0.7; $0.spacing = 0.08
                $0.shapeDynamics = ShapeDynamics(enabled: true, angle: .controlled(.direction))
                var t = paper(17, 0.9); t.eachTip = true; t.mode = .hardMix; t.depthJitter = .jitter(0.3)
                $0.texture = t
            },
            g("Dry Bristle") {
                $0.size = 50; $0.tip = .sampled(Procedural.bristleTip(64, 5)); $0.spacing = 0.04
                $0.shapeDynamics = ShapeDynamics(enabled: true, angle: .controlled(.direction))
                $0.transfer = Transfer(enabled: true, flow: Dynamic(control: .fade, fadeSteps: 400, minimum: 0.1))
            },
            g("Rake") {
                $0.size = 60; $0.tip = .sampled(Procedural.rakeTip(64, 3, 7)); $0.spacing = 0.03
                $0.shapeDynamics = ShapeDynamics(enabled: true, angle: .controlled(.direction))
                $0.transfer = transfer(pressureMin(0.25), Dynamic())
            },
        ]
    }

    static func wetMedia(_ base: BrushSettings) -> [BrushPreset] {
        func g(_ n: String, _ f: (inout BrushSettings) -> Void) -> BrushPreset { preset("Wet Media", n, with(base, f)) }
        return [
            g("Watercolor Wet Edges") {
                $0.size = 60; $0.hardness = 0.3; $0.wetEdges = true
                var t = paper(9, 0.35); t.scale = 1.5
                $0.texture = t.withPatternSize(256)
            },
            g("Watercolor Wash") {
                $0.size = 140; $0.hardness = 0; $0.flow = 0.35; $0.spacing = 0.12; $0.wetEdges = true
                $0.shapeDynamics = sizeDyn(pressureMin(0.35))
                $0.transfer = transfer(Dynamic(), Dynamic(jitter: 0.2, control: .penPressure))
                var t = paper(13, 0.25); t.scale = 2
                $0.texture = t.withPatternSize(256)
            },
            g("Ink Pen") {
                $0.size = 8; $0.hardness = 1; $0.spacing = 0.05
                $0.shapeDynamics = sizeDyn(pressureMin(0.15))
                $0.smoothing = Smoothing(amount: 0.35)
            },
            g("Oil Bristle") {
                $0.size = 70; $0.tip = .sampled(Procedural.bristleTip(64, 41)); $0.spacing = 0.03
                $0.shapeDynamics = ShapeDynamics(enabled: true, size: pressureMin(0.6), angle: .controlled(.direction))
                $0.colorDynamics = ColorDynamics(enabled: true, perTip: false, fgBg: .jitter(0.15), brightnessJitter: 0.05)
                $0.texture = Texture(enabled: true, pattern: .procedural(style: .canvas, size: 64, seed: 4), depth: 0.3)
            },
            g("Gouache Flat") {
                $0.size = 40; $0.hardness = 0.9; $0.roundness = 0.35; $0.spacing = 0.05
                $0.shapeDynamics = ShapeDynamics(enabled: true, angle: .controlled(.direction))
                $0.transfer = transfer(Dynamic(), Dynamic(control: .fade, fadeSteps: 600, minimum: 0.35))
            },
            g("Ink Wash Sponge") {
                $0.size = 70; $0.tip = .sampled(Procedural.spongeTip(96, 8)); $0.spacing = 0.3; $0.flow = 0.6; $0.wetEdges = true
                $0.shapeDynamics = ShapeDynamics(enabled: true, size: .jitter(0.2), angle: .jitter(1))
            },
        ]
    }

    static func specialEffects(_ base: BrushSettings) -> [BrushPreset] {
        func g(_ n: String, _ f: (inout BrushSettings) -> Void) -> BrushPreset { preset("Special Effects", n, with(base, f)) }
        return [
            g("Spatter") {
                $0.size = 60; $0.tip = .sampled(Procedural.spatterTip(64, 11, 14)); $0.spacing = 0.6
                $0.shapeDynamics = ShapeDynamics(enabled: true, size: Dynamic(jitter: 0.6, minimum: 0.2), angle: .jitter(1),
                                                 flipXJitter: true, flipYJitter: true)
                $0.scattering = Scattering(enabled: true, scatter: .jitter(1.5), bothAxes: true, count: 2, countJitter: .jitter(0.5))
            },
            g("Stipple") {
                $0.size = 40; $0.tip = .sampled(Procedural.spatterTip(64, 77, 40)); $0.spacing = 0.5
                $0.shapeDynamics = ShapeDynamics(enabled: true, angle: .jitter(1), flipXJitter: true)
                $0.scattering = Scattering(enabled: true, scatter: .jitter(0.6), bothAxes: true)
                $0.transfer = transfer(pressure(), Dynamic())
            },
            g("Confetti") {
                $0.size = 24; $0.hardness = 1; $0.roundness = 0.5; $0.spacing = 1.2
                $0.shapeDynamics = ShapeDynamics(enabled: true, size: .jitter(0.5), angle: .jitter(1))
                $0.scattering = Scattering(enabled: true, scatter: .jitter(3), bothAxes: true, count: 3)
                $0.colorDynamics = ColorDynamics(enabled: true, perTip: true, hueJitter: 1, saturationJitter: 0.2, purity: 0.5)
            },
            g("Foliage") {
                $0.size = 50; $0.tip = .sampled(Procedural.leafTip(64)); $0.spacing = 0.35
                $0.shapeDynamics = ShapeDynamics(enabled: true, size: Dynamic(jitter: 0.5, minimum: 0.3), angle: .jitter(1),
                                                 roundness: Dynamic(jitter: 0.4, minimum: 0.4), flipYJitter: true)
                $0.scattering = Scattering(enabled: true, scatter: .jitter(1.2), bothAxes: true, count: 2, countJitter: .jitter(0.5))
                $0.colorDynamics = ColorDynamics(enabled: true, perTip: true, fgBg: .jitter(0.6), hueJitter: 0.04, brightnessJitter: 0.12)
            },
            g("Grass") {
                $0.size = 70; $0.tip = .sampled(Procedural.grassTip(96, 6, 11)); $0.spacing = 0.25
                $0.shapeDynamics = ShapeDynamics(enabled: true, size: Dynamic(jitter: 0.4, control: .penPressure, minimum: 0.4),
                                                 angle: .jitter(0.06), flipXJitter: true)
                $0.scattering = Scattering(enabled: true, scatter: .jitter(0.3))
                $0.colorDynamics = ColorDynamics(enabled: true, perTip: true, fgBg: .jitter(0.7), hueJitter: 0.03)
            },
            g("Sparkle") {
                $0.size = 40; $0.tip = .sampled(Procedural.starTip(64)); $0.spacing = 1.5
                $0.shapeDynamics = ShapeDynamics(enabled: true, size: Dynamic(jitter: 0.8, minimum: 0.15))
                $0.scattering = Scattering(enabled: true, scatter: .jitter(2.5), bothAxes: true)
                $0.transfer = transfer(.jitter(0.5), Dynamic())
            },
            g("Sponge Texture") {
                $0.size = 60; $0.tip = .sampled(Procedural.spongeTip(64, 19)); $0.spacing = 0.45
                $0.shapeDynamics = ShapeDynamics(enabled: true, angle: .jitter(1))
                $0.transfer = transfer(.jitter(0.3), Dynamic())
            },
            g("Canvas Texture") {
                $0.size = 50; $0.hardness = 0.8
                $0.texture = Texture(enabled: true, pattern: .procedural(style: .canvas, size: 64, seed: 1), invert: true, mode: .subtract, depth: 0.7)
            },
            g("Halftone Dots") {
                $0.size = 80; $0.hardness = 0.5
                $0.texture = Texture(enabled: true, pattern: .procedural(style: .dots, size: 64, seed: 1), mode: .hardMix, depth: 1)
            },
            g("Dual Grain") {
                $0.size = 50; $0.hardness = 0.6; $0.noise = true
                $0.dualBrush = DualBrush(enabled: true, tip: .sampled(Procedural.spatterTip(48, 23, 20)), size: 30, spacing: 0.3,
                                         scatter: 1, bothAxes: true, count: 2, flip: true)
            },
        ]
    }

    /// The built-in preset set, in display order (grouped by `groups`).
    public static func builtin() -> [BrushPreset] {
        var base = BrushSettings()
        base.pressureSize = false
        base.spacing = 0.25
        return general(base) + dryMedia(base) + wetMedia(base) + specialEffects(base)
    }

    /// Find a preset by name (case-insensitive).
    public static func find(_ presets: [BrushPreset], _ name: String) -> BrushPreset? {
        presets.first { $0.name.lowercased() == name.lowercased() }
    }
}
