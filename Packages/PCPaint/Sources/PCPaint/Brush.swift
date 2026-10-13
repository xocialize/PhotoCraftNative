// Port of photocraft-paint (crates/paint/src/brush.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The brush model: tip shape plus Photoshop-style dynamics sections, all plain Codable data.
// Every section is optional (an `enabled` flag, or a neutral default), so a partial JSON object
// such as `{"size": 40, "scattering": {"enabled": true, "scatter": {"jitter": 2.0}}}` decodes onto
// the defaults. JSON keys are camelCase and match photocraft's serde names one for one.
//
// Units: sizes are pixels, angles are degrees, every percentage is a 0…1 fraction (scatter and
// texture scale may exceed 1, like Photoshop's 1000 % scatter).

import PCFoundation

/// Largest brush diameter accepted by the rasteriser and brush controls.
public let maxBrushSize: Float = 5000

/// Largest Scatter amount (primary and Dual Brush): 10 = 1000 %, the Brush Settings slider's top.
public let maxScatter: Float = 10

/// What drives a dynamic parameter (Photoshop's "Control" pop-ups).
public enum Control: String, Codable, Sendable, CaseIterable {
    case off
    /// Ramp over `fadeSteps` spacing steps (from full to the minimum).
    case fade
    case penPressure
    case penTilt
    case stylusWheel
    /// Barrel rotation of the stylus.
    case rotation
    /// Angle only: the direction of the first stroke segment.
    case initialDirection
    /// Angle only: the current stroke direction.
    case direction
}

/// One dynamic parameter: random jitter plus a controller with a floor.
public struct Dynamic: Hashable, Sendable {
    /// 0…1 random variation per dab (for scatter: the amount, may exceed 1).
    public var jitter: Float = 0
    public var control: Control = .off
    /// Steps for `Control.fade`.
    public var fadeSteps: UInt32 = 25
    /// 0…1 floor the control/jitter may reduce the value to.
    public var minimum: Float = 0

    public init(jitter: Float = 0, control: Control = .off, fadeSteps: UInt32 = 25, minimum: Float = 0) {
        self.jitter = jitter; self.control = control; self.fadeSteps = fadeSteps; self.minimum = minimum
    }

    public static func controlled(_ c: Control) -> Dynamic { Dynamic(control: c) }
    public static func jitter(_ j: Float) -> Dynamic { Dynamic(jitter: j) }

    public var isActive: Bool { jitter > 0 || control != .off }
}

/// The brush tip bitmap source. A loaded `.stored` tip encodes as `sampled` (its full bitmap).
public enum TipShape: Hashable, Sendable {
    /// Computed round/elliptical tip (hardness, angle, roundness).
    case round
    /// Sampled tip: grayscale bitmap where 1 = full paint, scaled so its larger side equals `size`.
    case sampled(GrayTile)
    /// A sampled tip its owner (the preset store) keeps outside the settings and loads on demand.
    case stored(StoredTile)

    /// The bitmap a sampled tip paints with; nil for a computed tip.
    public var bitmap: GrayTile? {
        switch self {
        case .round: nil
        case .sampled(let g): g
        case .stored(let r): r.bitmap
        }
    }

    /// The tip's real pixel size (a stored tip's, not its preview's); nil for a computed tip.
    public var bitmapSize: (UInt32, UInt32)? {
        switch self {
        case .round: nil
        case .sampled(let g): (g.width, g.height)
        case .stored(let r): (r.width, r.height)
        }
    }
}

/// Shape Dynamics.
public struct ShapeDynamics: Hashable, Sendable {
    public var enabled = false
    /// Size jitter / control; `minimum` is Photoshop's Minimum Diameter.
    public var size = Dynamic()
    /// Tilt Scale, 0…2: with the size control on Pen Tilt, how much a tilted pen squashes the tip.
    public var tiltScale: Float = 0
    /// Angle jitter (fraction of ±180°) / control.
    public var angle = Dynamic()
    /// Roundness jitter / control; `minimum` is Minimum Roundness.
    public var roundness = Dynamic()
    public var flipXJitter = false
    public var flipYJitter = false
    /// Brush Projection: the pen's tilt and barrel rotation are applied to the tip as a projection.
    public var brushProjection = false

    public init(enabled: Bool = false, size: Dynamic = Dynamic(), tiltScale: Float = 0, angle: Dynamic = Dynamic(),
                roundness: Dynamic = Dynamic(), flipXJitter: Bool = false, flipYJitter: Bool = false, brushProjection: Bool = false) {
        self.enabled = enabled; self.size = size; self.tiltScale = tiltScale; self.angle = angle; self.roundness = roundness
        self.flipXJitter = flipXJitter; self.flipYJitter = flipYJitter; self.brushProjection = brushProjection
    }
}

/// Scattering.
public struct Scattering: Hashable, Sendable {
    public var enabled = false
    /// `jitter` = scatter amount (1 = 100 %: up to one radius of displacement); control scales it.
    public var scatter = Dynamic()
    /// Scatter radially instead of only perpendicular to the stroke.
    public var bothAxes = false
    /// Dabs per spacing step (1…16).
    public var count: UInt32 = 1
    /// Count jitter / control (reduces the count towards 1).
    public var countJitter = Dynamic()

    public init(enabled: Bool = false, scatter: Dynamic = Dynamic(), bothAxes: Bool = false, count: UInt32 = 1, countJitter: Dynamic = Dynamic()) {
        self.enabled = enabled; self.scatter = scatter; self.bothAxes = bothAxes; self.count = count; self.countJitter = countJitter
    }
}

/// How a grayscale mask (texture or dual tip) combines with the brush coverage.
public enum MaskMode: String, Codable, Sendable, CaseIterable {
    case multiply, subtract, darken, overlay, colorDodge, colorBurn, linearBurn, hardMix, linearHeight, height
}

/// Procedural pattern styles (generated deterministically; no bundled pattern files).
public enum PatternStyle: String, Codable, Sendable, CaseIterable {
    /// Smooth value noise.
    case noise
    /// Woven canvas.
    case canvas
    /// Fibrous paper tooth.
    case paper
    /// Halftone-like dots.
    case dots
}

/// A texture pattern: a procedural generator or an explicit grayscale tile (tiled infinitely).
public enum Pattern: Hashable, Sendable {
    case procedural(style: PatternStyle, size: UInt32, seed: UInt32)
    case tile(GrayTile)
    /// A tile its owner (the preset store) keeps outside the settings and loads on demand.
    case stored(StoredTile)

    /// The tile a bitmap pattern textures with; nil for a procedural pattern.
    public var bitmap: GrayTile? {
        switch self {
        case .procedural: nil
        case .tile(let g): g
        case .stored(let r): r.bitmap
        }
    }

    public static let `default` = Pattern.procedural(style: .paper, size: 128, seed: 1)
}

/// Texture.
public struct Texture: Hashable, Sendable {
    public var enabled = false
    public var pattern: Pattern = .default
    public var invert = false
    /// Pattern scale (1 = 100 %).
    public var scale: Float = 1
    /// -1…1 (Photoshop's -150…150 mapped to ±1).
    public var brightness: Float = 0
    /// -1…1: Photoshop's -50…0 mapped to -1…0 and its 0…100 to 0…1.
    public var contrast: Float = 0
    /// Apply the texture to every dab (enables depth jitter) instead of once to the stroke.
    public var eachTip = false
    public var mode: MaskMode = .multiply
    /// 0…1.
    public var depth: Float = 1
    /// Depth jitter / control (per tip only); `minimum` is Minimum Depth.
    public var depthJitter = Dynamic()

    public init(enabled: Bool = false, pattern: Pattern = .default, invert: Bool = false, scale: Float = 1, brightness: Float = 0,
                contrast: Float = 0, eachTip: Bool = false, mode: MaskMode = .multiply, depth: Float = 1, depthJitter: Dynamic = Dynamic()) {
        self.enabled = enabled; self.pattern = pattern; self.invert = invert; self.scale = scale; self.brightness = brightness
        self.contrast = contrast; self.eachTip = eachTip; self.mode = mode; self.depth = depth; self.depthJitter = depthJitter
    }

    /// A pattern value (0…1) after Brightness, Contrast and Invert: the value the mode combines with
    /// the brush (measured against Photoshop, photocraft #3340). Brightness shifts by
    /// `brightness × 150/255`; positive Contrast steepens around mid-grey by `1 / (1 − c)` after the
    /// shift; negative Contrast flattens by `1 + c/2` before it; Invert is last.
    public func level(_ v: Float) -> Float {
        let b: Float = brightness.isFinite ? clampR(brightness, -1, 1) * (150 / 255) : 0
        let c: Float = contrast.isFinite ? clampR(contrast, -1, 1) : 0
        var x = c >= 0 ? (v + b - 0.5) / maxR(1 - c, 1e-4) + 0.5 : (v - 0.5) * (1 + c / 2) + 0.5 + b
        x = x.isFinite ? clampR(x, 0, 1) : 0.5
        return invert ? 1 - x : x
    }

    /// The same texture with a procedural pattern of side `n` (presets).
    func withPatternSize(_ n: UInt32) -> Texture {
        var t = self
        if case .procedural(let style, _, let seed) = t.pattern { t.pattern = .procedural(style: style, size: n, seed: seed) }
        return t
    }
}

/// Dual Brush: a second tip stroked along the same path; the stroke is masked by it.
public struct DualBrush: Hashable, Sendable {
    public var enabled = false
    public var mode: MaskMode = .multiply
    public var tip: TipShape = .round
    public var size: Float = 20
    public var hardness: Float = 1
    public var roundness: Float = 1
    public var angle: Float = 0
    public var spacing: Float = 0.25
    public var scatter: Float = 0
    public var bothAxes = false
    public var count: UInt32 = 1
    public var flip = false

    public init(enabled: Bool = false, mode: MaskMode = .multiply, tip: TipShape = .round, size: Float = 20, hardness: Float = 1,
                roundness: Float = 1, angle: Float = 0, spacing: Float = 0.25, scatter: Float = 0, bothAxes: Bool = false,
                count: UInt32 = 1, flip: Bool = false) {
        self.enabled = enabled; self.mode = mode; self.tip = tip; self.size = size; self.hardness = hardness
        self.roundness = roundness; self.angle = angle; self.spacing = spacing; self.scatter = scatter
        self.bothAxes = bothAxes; self.count = count; self.flip = flip
    }
}

/// Color Dynamics.
public struct ColorDynamics: Hashable, Sendable {
    public var enabled = false
    /// Vary every dab (true) or once per stroke (false).
    public var perTip = true
    /// Foreground/background mix jitter / control.
    public var fgBg = Dynamic()
    /// 0…1 fraction of ±half the hue wheel.
    public var hueJitter: Float = 0
    public var saturationJitter: Float = 0
    public var brightnessJitter: Float = 0
    /// -1 (fully desaturated) … 1 (fully saturated).
    public var purity: Float = 0

    public init(enabled: Bool = false, perTip: Bool = true, fgBg: Dynamic = Dynamic(), hueJitter: Float = 0,
                saturationJitter: Float = 0, brightnessJitter: Float = 0, purity: Float = 0) {
        self.enabled = enabled; self.perTip = perTip; self.fgBg = fgBg; self.hueJitter = hueJitter
        self.saturationJitter = saturationJitter; self.brightnessJitter = brightnessJitter; self.purity = purity
    }
}

/// Transfer: per-dab opacity ceiling and flow, plus the Mixer Brush's wetness and mix.
public struct Transfer: Hashable, Sendable {
    public var enabled = false
    public var opacity = Dynamic()
    public var flow = Dynamic()
    /// Wetness Jitter / control (Mixer Brush only): scales the Wet setting per dab.
    public var wetness = Dynamic()
    /// Mix Jitter / control (Mixer Brush only): scales the Mix setting per dab.
    public var mix = Dynamic()

    public init(enabled: Bool = false, opacity: Dynamic = Dynamic(), flow: Dynamic = Dynamic(), wetness: Dynamic = Dynamic(), mix: Dynamic = Dynamic()) {
        self.enabled = enabled; self.opacity = opacity; self.flow = flow; self.wetness = wetness; self.mix = mix
    }
}

/// The sections a lock can hold: a locked section keeps its settings when another preset is picked.
public struct SectionLocks: Hashable, Sendable {
    public var shapeDynamics = false
    public var scattering = false
    public var texture = false
    public var dualBrush = false
    public var colorDynamics = false
    public var transfer = false
    public var pose = false
    public var noise = false
    public var wetEdges = false
    public var buildUp = false
    public var smoothing = false
    public var protectTexture = false

    public init(shapeDynamics: Bool = false, scattering: Bool = false, texture: Bool = false, dualBrush: Bool = false,
                colorDynamics: Bool = false, transfer: Bool = false, pose: Bool = false, noise: Bool = false,
                wetEdges: Bool = false, buildUp: Bool = false, smoothing: Bool = false, protectTexture: Bool = false) {
        self.shapeDynamics = shapeDynamics; self.scattering = scattering; self.texture = texture; self.dualBrush = dualBrush
        self.colorDynamics = colorDynamics; self.transfer = transfer; self.pose = pose; self.noise = noise
        self.wetEdges = wetEdges; self.buildUp = buildUp; self.smoothing = smoothing; self.protectTexture = protectTexture
    }
}

/// Brush Pose: stylus values used instead of (override) or for missing device data.
public struct Pose: Hashable, Sendable {
    public var enabled = false
    /// Degrees, -90…90 (W3C Pointer Events convention).
    public var tiltX: Float = 0
    public var tiltY: Float = 0
    /// Degrees 0…360.
    public var rotation: Float = 0
    /// 0…1.
    public var pressure: Float = 1
    public var overrideTilt = false
    public var overrideRotation = false
    public var overridePressure = false

    public init(enabled: Bool = false, tiltX: Float = 0, tiltY: Float = 0, rotation: Float = 0, pressure: Float = 1,
                overrideTilt: Bool = false, overrideRotation: Bool = false, overridePressure: Bool = false) {
        self.enabled = enabled; self.tiltX = tiltX; self.tiltY = tiltY; self.rotation = rotation; self.pressure = pressure
        self.overrideTilt = overrideTilt; self.overrideRotation = overrideRotation; self.overridePressure = overridePressure
    }
}

/// Stroke smoothing (Photoshop's Smoothing % and its options).
public struct Smoothing: Hashable, Sendable {
    /// 0…1.
    public var amount: Float = 0
    /// Lazy-mouse: paint only when the pointer pulls a string of `amount × 100 px` taut.
    public var pulledString = false
    /// Keep catching up with the pointer while it pauses (uses point timestamps).
    public var catchUp = true
    /// Finish the stroke at the last pointer position.
    public var catchUpOnEnd = true
    /// Divide the string length by the view zoom.
    public var adjustForZoom = true

    public init(amount: Float = 0, pulledString: Bool = false, catchUp: Bool = true, catchUpOnEnd: Bool = true, adjustForZoom: Bool = true) {
        self.amount = amount; self.pulledString = pulledString; self.catchUp = catchUp
        self.catchUpOnEnd = catchUpOnEnd; self.adjustForZoom = adjustForZoom
    }
}

/// A complete brush: tip shape, dynamics, and stroke-level options.
public struct BrushSettings: Hashable, Sendable {
    /// Diameter in pixels.
    public var size: Float = 20
    /// 0 (soft) … 1 (hard). Computed tips only.
    public var hardness: Float = 1
    /// Spacing between dabs as a fraction of the diameter.
    public var spacing: Float = 0.1
    /// Photoshop's Spacing checkbox. Off: the pointer's speed sets the spacing.
    public var spacingEnabled = true
    /// Maximum coverage for the whole stroke.
    public var opacity: Float = 1
    /// Per-dab coverage.
    public var flow: Float = 1
    /// Shortcut for Shape Dynamics › Size › Pen Pressure (the options-bar button).
    public var pressureSize = true
    /// Shortcut for Transfer › Opacity › Pen Pressure.
    public var pressureOpacity = false
    /// Straight RGBA colour (display RGB). Commands fill it from the foreground colour.
    public var color: SIMD4<Float> = SIMD4(0, 0, 0, 1)
    /// Background colour for Color Dynamics' foreground/background jitter.
    public var background: SIMD4<Float> = SIMD4(1, 1, 1, 1)
    /// Erase instead of paint.
    public var erase = false
    /// Brush blend mode (Normal, Multiply, Dissolve…).
    public var mode: BlendMode = .normal
    // Brush Tip Shape
    public var tip: TipShape = .round
    /// Degrees, counter-clockwise.
    public var angle: Float = 0
    /// 0…1 (1 = circle).
    public var roundness: Float = 1
    public var flipX = false
    public var flipY = false
    /// Pencil: no anti-aliasing (coverage is 0 or 1).
    public var aliased = false
    /// With `aliased`, a square tip: every pixel of the dab's whole-pixel square (Eraser Block).
    public var square = false
    // Dynamics sections
    public var shapeDynamics = ShapeDynamics()
    public var scattering = Scattering()
    public var texture = Texture()
    public var dualBrush = DualBrush()
    public var colorDynamics = ColorDynamics()
    public var transfer = Transfer()
    public var pose = Pose()
    /// Add grain to the soft parts of the tip.
    public var noise = false
    /// Watercolour look: lighter interior, darker rims; overlapping dabs don't build up.
    public var wetEdges = false
    /// Airbrush: keep depositing dabs over time while the pointer lingers.
    public var buildUp = false
    /// Build-up rate in dabs per second.
    public var buildUpRate: Float = 20
    public var smoothing = Smoothing()
    /// Keep the current texture (pattern + scale) when switching to another textured preset.
    public var protectTexture = false
    /// Sections whose settings stay when another preset is picked.
    public var locks = SectionLocks()
    /// Mixer Brush options used by the Mixer Brush stroke.
    public var mixer = MixerSettings()
    /// Random seed for jitters, so strokes replay.
    public var seed: UInt64 = 0

    public init() {}

    /// A copy with the primary and dual diameters and Scatter amounts constrained for
    /// rasterisation: malformed dimensions never become giant allocations nor non-finite dab
    /// centres (photocraft #977).
    public func boundedForRender() -> BrushSettings {
        func safeSize(_ s: Float) -> Float { s.isFinite ? clampR(s, 0.5, maxBrushSize) : 0.5 }
        func safeScatter(_ a: Float) -> Float { a.isNaN ? 0 : clampR(a, 0, maxScatter) }
        var b = self
        b.size = safeSize(b.size)
        b.dualBrush.size = safeSize(b.dualBrush.size)
        b.scattering.scatter.jitter = safeScatter(b.scattering.scatter.jitter)
        b.dualBrush.scatter = safeScatter(b.dualBrush.scatter)
        return b
    }

    /// This brush (a preset) picked while `current` is the tool's brush: Smoothing is a tool
    /// option, so it stays the tool's, a protected texture stays too, and so does every section
    /// `current` has locked (the locks themselves are tool state and carry over).
    public func pickedOver(_ current: BrushSettings) -> BrushSettings {
        var b = withProtectedTexture(current)
        b.smoothing = current.smoothing
        let l = current.locks
        if l.shapeDynamics { b.shapeDynamics = current.shapeDynamics }
        if l.scattering { b.scattering = current.scattering }
        if l.texture { b.texture = current.texture }
        if l.dualBrush { b.dualBrush = current.dualBrush }
        if l.colorDynamics { b.colorDynamics = current.colorDynamics }
        if l.transfer { b.transfer = current.transfer }
        if l.pose { b.pose = current.pose }
        if l.noise { b.noise = current.noise }
        if l.wetEdges { b.wetEdges = current.wetEdges }
        if l.buildUp { b.buildUp = current.buildUp; b.buildUpRate = current.buildUpRate }
        if l.protectTexture { b.protectTexture = current.protectTexture }
        b.locks = current.locks
        return b
    }

    /// Protect Texture: if `current` protects its texture, a newly chosen textured brush keeps
    /// `current`'s pattern and scale.
    public func withProtectedTexture(_ current: BrushSettings) -> BrushSettings {
        var b = self
        if current.protectTexture && current.texture.enabled && b.texture.enabled {
            b.texture.pattern = current.texture.pattern
            b.texture.scale = current.texture.scale
            b.protectTexture = true
        }
        return b
    }
}

/// A named brush preset (session tool state; Codable round-trips).
public struct BrushPreset: Hashable, Sendable {
    public var name: String
    public var brush: BrushSettings
    /// Shipped with PhotoCraft (regenerated on reset).
    public var builtin: Bool = false
    /// Preset group (folder) in the Brushes panel.
    public var group: String = ""
    /// Folders inside `group`, outermost first.
    public var folder: [String] = []

    public init(name: String, brush: BrushSettings, builtin: Bool = false, group: String = "", folder: [String] = []) {
        self.name = name; self.brush = brush; self.builtin = builtin; self.group = group; self.folder = folder
    }
}
