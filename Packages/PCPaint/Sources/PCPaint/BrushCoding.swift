// Port of photocraft-paint (crates/paint/src/brush.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Codable for the brush model, matching photocraft's serde JSON: camelCase keys, `#[serde(default)]`
// on every section (missing keys keep their defaults), externally tagged enums (`"round"`,
// `{"sampled": {...}}`, `{"procedural": {"style": …}}`), loaded stored tiles encoded as their full
// bitmap, and blend modes as photocraft's variant names (`"Normal"`, `"Multiply"`, …).

import PCFoundation

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer {
    /// `decodeIfPresent` with a default (serde's `#[serde(default)]`).
    @inline(__always) func get<T: Decodable>(_ key: Key, _ fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

// MARK: Dynamic

extension Dynamic: Codable {
    enum CodingKeys: String, CodingKey { case jitter, control, fadeSteps, minimum }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Dynamic()
        self.init(jitter: try c.get(.jitter, d.jitter), control: try c.get(.control, d.control),
                  fadeSteps: try c.get(.fadeSteps, d.fadeSteps), minimum: try c.get(.minimum, d.minimum))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jitter, forKey: .jitter); try c.encode(control, forKey: .control)
        try c.encode(fadeSteps, forKey: .fadeSteps); try c.encode(minimum, forKey: .minimum)
    }
}

// MARK: TipShape / Pattern

extension TipShape: Codable {
    public init(from decoder: any Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            guard s == "round" else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown tip \(s)"))
            }
            self = .round
            return
        }
        let c = try decoder.container(keyedBy: AnyKey.self)
        if c.contains(AnyKey("sampled")) { self = .sampled(try c.decode(GrayTile.self, forKey: AnyKey("sampled"))); return }
        if c.contains(AnyKey("stored")) { self = .stored(try c.decode(StoredTile.self, forKey: AnyKey("stored"))); return }
        if c.contains(AnyKey("round")) { self = .round; return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown tip shape"))
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .round:
            var c = encoder.singleValueContainer()
            try c.encode("round")
        case .sampled(let g):
            var c = encoder.container(keyedBy: AnyKey.self)
            try c.encode(g, forKey: AnyKey("sampled"))
        case .stored(let r):
            var c = encoder.container(keyedBy: AnyKey.self)
            if let full = r.full { try c.encode(full, forKey: AnyKey("sampled")) } else { try c.encode(r, forKey: AnyKey("stored")) }
        }
    }
}

extension Pattern: Codable {
    private struct Proc: Codable { var style: PatternStyle; var size: UInt32; var seed: UInt32 }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        if c.contains(AnyKey("procedural")) {
            let p = try c.decode(Proc.self, forKey: AnyKey("procedural"))
            self = .procedural(style: p.style, size: p.size, seed: p.seed)
        } else if c.contains(AnyKey("tile")) {
            self = .tile(try c.decode(GrayTile.self, forKey: AnyKey("tile")))
        } else if c.contains(AnyKey("stored")) {
            self = .stored(try c.decode(StoredTile.self, forKey: AnyKey("stored")))
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown pattern"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        switch self {
        case .procedural(let style, let size, let seed): try c.encode(Proc(style: style, size: size, seed: seed), forKey: AnyKey("procedural"))
        case .tile(let g): try c.encode(g, forKey: AnyKey("tile"))
        case .stored(let r):
            if let full = r.full { try c.encode(full, forKey: AnyKey("tile")) } else { try c.encode(r, forKey: AnyKey("stored")) }
        }
    }
}

// MARK: Blend mode names

extension BlendMode {
    /// photocraft's serde name for the mode (`"Normal"`, `"LinearDodge"`, `"PaintNetColorBurn"`…).
    public var photocraftName: String {
        let s = String(describing: self)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    public init?(photocraftName: String) {
        guard let m = BlendMode.allCases.first(where: { $0.photocraftName == photocraftName }) else { return nil }
        self = m
    }
}

/// Encodes a `BlendMode` as photocraft's name; decodes the name, a lower-camel case name or the raw index.
struct BlendModeName: Codable {
    var mode: BlendMode
    init(_ m: BlendMode) { mode = m }
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            if let m = BlendMode(photocraftName: s) ?? BlendMode.allCases.first(where: { String(describing: $0) == s }) {
                mode = m
                return
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown blend mode \(s)")
        }
        let raw = try c.decode(UInt32.self)
        guard let m = BlendMode(rawValue: raw) else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "blend mode \(raw)") }
        mode = m
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(mode.photocraftName)
    }
}

// MARK: Sections

extension ShapeDynamics: Codable {
    enum CodingKeys: String, CodingKey { case enabled, size, tiltScale, angle, roundness, flipXJitter, flipYJitter, brushProjection }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShapeDynamics()
        self.init(enabled: try c.get(.enabled, d.enabled), size: try c.get(.size, d.size), tiltScale: try c.get(.tiltScale, d.tiltScale),
                  angle: try c.get(.angle, d.angle), roundness: try c.get(.roundness, d.roundness),
                  flipXJitter: try c.get(.flipXJitter, d.flipXJitter), flipYJitter: try c.get(.flipYJitter, d.flipYJitter),
                  brushProjection: try c.get(.brushProjection, d.brushProjection))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled); try c.encode(size, forKey: .size); try c.encode(tiltScale, forKey: .tiltScale)
        try c.encode(angle, forKey: .angle); try c.encode(roundness, forKey: .roundness); try c.encode(flipXJitter, forKey: .flipXJitter)
        try c.encode(flipYJitter, forKey: .flipYJitter); try c.encode(brushProjection, forKey: .brushProjection)
    }
}

extension Scattering: Codable {
    enum CodingKeys: String, CodingKey { case enabled, scatter, bothAxes, count, countJitter }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Scattering()
        self.init(enabled: try c.get(.enabled, d.enabled), scatter: try c.get(.scatter, d.scatter), bothAxes: try c.get(.bothAxes, d.bothAxes),
                  count: try c.get(.count, d.count), countJitter: try c.get(.countJitter, d.countJitter))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled); try c.encode(scatter, forKey: .scatter); try c.encode(bothAxes, forKey: .bothAxes)
        try c.encode(count, forKey: .count); try c.encode(countJitter, forKey: .countJitter)
    }
}

extension Texture: Codable {
    enum CodingKeys: String, CodingKey { case enabled, pattern, invert, scale, brightness, contrast, eachTip, mode, depth, depthJitter }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Texture()
        self.init(enabled: try c.get(.enabled, d.enabled), pattern: try c.get(.pattern, d.pattern), invert: try c.get(.invert, d.invert),
                  scale: try c.get(.scale, d.scale), brightness: try c.get(.brightness, d.brightness), contrast: try c.get(.contrast, d.contrast),
                  eachTip: try c.get(.eachTip, d.eachTip), mode: try c.get(.mode, d.mode), depth: try c.get(.depth, d.depth),
                  depthJitter: try c.get(.depthJitter, d.depthJitter))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled); try c.encode(pattern, forKey: .pattern); try c.encode(invert, forKey: .invert)
        try c.encode(scale, forKey: .scale); try c.encode(brightness, forKey: .brightness); try c.encode(contrast, forKey: .contrast)
        try c.encode(eachTip, forKey: .eachTip); try c.encode(mode, forKey: .mode); try c.encode(depth, forKey: .depth)
        try c.encode(depthJitter, forKey: .depthJitter)
    }
}

extension DualBrush: Codable {
    enum CodingKeys: String, CodingKey { case enabled, mode, tip, size, hardness, roundness, angle, spacing, scatter, bothAxes, count, flip }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DualBrush()
        self.init(enabled: try c.get(.enabled, d.enabled), mode: try c.get(.mode, d.mode), tip: try c.get(.tip, d.tip),
                  size: try c.get(.size, d.size), hardness: try c.get(.hardness, d.hardness), roundness: try c.get(.roundness, d.roundness),
                  angle: try c.get(.angle, d.angle), spacing: try c.get(.spacing, d.spacing), scatter: try c.get(.scatter, d.scatter),
                  bothAxes: try c.get(.bothAxes, d.bothAxes), count: try c.get(.count, d.count), flip: try c.get(.flip, d.flip))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled); try c.encode(mode, forKey: .mode); try c.encode(tip, forKey: .tip)
        try c.encode(size, forKey: .size); try c.encode(hardness, forKey: .hardness); try c.encode(roundness, forKey: .roundness)
        try c.encode(angle, forKey: .angle); try c.encode(spacing, forKey: .spacing); try c.encode(scatter, forKey: .scatter)
        try c.encode(bothAxes, forKey: .bothAxes); try c.encode(count, forKey: .count); try c.encode(flip, forKey: .flip)
    }
}

extension ColorDynamics: Codable {
    enum CodingKeys: String, CodingKey { case enabled, perTip, fgBg, hueJitter, saturationJitter, brightnessJitter, purity }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ColorDynamics()
        self.init(enabled: try c.get(.enabled, d.enabled), perTip: try c.get(.perTip, d.perTip), fgBg: try c.get(.fgBg, d.fgBg),
                  hueJitter: try c.get(.hueJitter, d.hueJitter), saturationJitter: try c.get(.saturationJitter, d.saturationJitter),
                  brightnessJitter: try c.get(.brightnessJitter, d.brightnessJitter), purity: try c.get(.purity, d.purity))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled); try c.encode(perTip, forKey: .perTip); try c.encode(fgBg, forKey: .fgBg)
        try c.encode(hueJitter, forKey: .hueJitter); try c.encode(saturationJitter, forKey: .saturationJitter)
        try c.encode(brightnessJitter, forKey: .brightnessJitter); try c.encode(purity, forKey: .purity)
    }
}

extension Transfer: Codable {
    enum CodingKeys: String, CodingKey { case enabled, opacity, flow, wetness, mix }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Transfer()
        self.init(enabled: try c.get(.enabled, d.enabled), opacity: try c.get(.opacity, d.opacity), flow: try c.get(.flow, d.flow),
                  wetness: try c.get(.wetness, d.wetness), mix: try c.get(.mix, d.mix))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled); try c.encode(opacity, forKey: .opacity); try c.encode(flow, forKey: .flow)
        try c.encode(wetness, forKey: .wetness); try c.encode(mix, forKey: .mix)
    }
}

extension SectionLocks: Codable {
    enum CodingKeys: String, CodingKey {
        case shapeDynamics, scattering, texture, dualBrush, colorDynamics, transfer, pose, noise, wetEdges, buildUp, smoothing, protectTexture
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(shapeDynamics: try c.get(.shapeDynamics, false), scattering: try c.get(.scattering, false), texture: try c.get(.texture, false),
                  dualBrush: try c.get(.dualBrush, false), colorDynamics: try c.get(.colorDynamics, false), transfer: try c.get(.transfer, false),
                  pose: try c.get(.pose, false), noise: try c.get(.noise, false), wetEdges: try c.get(.wetEdges, false),
                  buildUp: try c.get(.buildUp, false), smoothing: try c.get(.smoothing, false), protectTexture: try c.get(.protectTexture, false))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shapeDynamics, forKey: .shapeDynamics); try c.encode(scattering, forKey: .scattering); try c.encode(texture, forKey: .texture)
        try c.encode(dualBrush, forKey: .dualBrush); try c.encode(colorDynamics, forKey: .colorDynamics); try c.encode(transfer, forKey: .transfer)
        try c.encode(pose, forKey: .pose); try c.encode(noise, forKey: .noise); try c.encode(wetEdges, forKey: .wetEdges)
        try c.encode(buildUp, forKey: .buildUp); try c.encode(smoothing, forKey: .smoothing); try c.encode(protectTexture, forKey: .protectTexture)
    }
}

extension Pose: Codable {
    enum CodingKeys: String, CodingKey { case enabled, tiltX, tiltY, rotation, pressure, overrideTilt, overrideRotation, overridePressure }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Pose()
        self.init(enabled: try c.get(.enabled, d.enabled), tiltX: try c.get(.tiltX, d.tiltX), tiltY: try c.get(.tiltY, d.tiltY),
                  rotation: try c.get(.rotation, d.rotation), pressure: try c.get(.pressure, d.pressure),
                  overrideTilt: try c.get(.overrideTilt, d.overrideTilt), overrideRotation: try c.get(.overrideRotation, d.overrideRotation),
                  overridePressure: try c.get(.overridePressure, d.overridePressure))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled); try c.encode(tiltX, forKey: .tiltX); try c.encode(tiltY, forKey: .tiltY)
        try c.encode(rotation, forKey: .rotation); try c.encode(pressure, forKey: .pressure); try c.encode(overrideTilt, forKey: .overrideTilt)
        try c.encode(overrideRotation, forKey: .overrideRotation); try c.encode(overridePressure, forKey: .overridePressure)
    }
}

extension Smoothing: Codable {
    enum CodingKeys: String, CodingKey { case amount, pulledString, catchUp, catchUpOnEnd, adjustForZoom }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Smoothing()
        self.init(amount: try c.get(.amount, d.amount), pulledString: try c.get(.pulledString, d.pulledString),
                  catchUp: try c.get(.catchUp, d.catchUp), catchUpOnEnd: try c.get(.catchUpOnEnd, d.catchUpOnEnd),
                  adjustForZoom: try c.get(.adjustForZoom, d.adjustForZoom))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(amount, forKey: .amount); try c.encode(pulledString, forKey: .pulledString); try c.encode(catchUp, forKey: .catchUp)
        try c.encode(catchUpOnEnd, forKey: .catchUpOnEnd); try c.encode(adjustForZoom, forKey: .adjustForZoom)
    }
}

// MARK: BrushSettings

extension BrushSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case size, hardness, spacing, spacingEnabled, opacity, flow, pressureSize, pressureOpacity, color, background, erase, mode
        case tip, angle, roundness, flipX, flipY, aliased, square
        case shapeDynamics, scattering, texture, dualBrush, colorDynamics, transfer, pose
        case noise, wetEdges, buildUp, buildUpRate, smoothing, protectTexture, locks, mixer, seed
        case pressureSizeAlias = "pressure_size", pressureOpacityAlias = "pressure_opacity"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BrushSettings()
        self.init()
        size = try c.get(.size, d.size)
        hardness = try c.get(.hardness, d.hardness)
        spacing = try c.get(.spacing, d.spacing)
        spacingEnabled = try c.get(.spacingEnabled, d.spacingEnabled)
        opacity = try c.get(.opacity, d.opacity)
        flow = try c.get(.flow, d.flow)
        pressureSize = try c.decodeIfPresent(Bool.self, forKey: .pressureSize) ?? c.get(.pressureSizeAlias, d.pressureSize)
        pressureOpacity = try c.decodeIfPresent(Bool.self, forKey: .pressureOpacity) ?? c.get(.pressureOpacityAlias, d.pressureOpacity)
        color = try c.get(.color, d.color)
        background = try c.get(.background, d.background)
        erase = try c.get(.erase, d.erase)
        mode = try c.decodeIfPresent(BlendModeName.self, forKey: .mode)?.mode ?? d.mode
        tip = try c.get(.tip, d.tip)
        angle = try c.get(.angle, d.angle)
        roundness = try c.get(.roundness, d.roundness)
        flipX = try c.get(.flipX, d.flipX)
        flipY = try c.get(.flipY, d.flipY)
        aliased = try c.get(.aliased, d.aliased)
        square = try c.get(.square, d.square)
        shapeDynamics = try c.get(.shapeDynamics, d.shapeDynamics)
        scattering = try c.get(.scattering, d.scattering)
        texture = try c.get(.texture, d.texture)
        dualBrush = try c.get(.dualBrush, d.dualBrush)
        colorDynamics = try c.get(.colorDynamics, d.colorDynamics)
        transfer = try c.get(.transfer, d.transfer)
        pose = try c.get(.pose, d.pose)
        noise = try c.get(.noise, d.noise)
        wetEdges = try c.get(.wetEdges, d.wetEdges)
        buildUp = try c.get(.buildUp, d.buildUp)
        buildUpRate = try c.get(.buildUpRate, d.buildUpRate)
        smoothing = try c.get(.smoothing, d.smoothing)
        protectTexture = try c.get(.protectTexture, d.protectTexture)
        locks = try c.get(.locks, d.locks)
        mixer = try c.get(.mixer, d.mixer)
        seed = try c.get(.seed, d.seed)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(size, forKey: .size); try c.encode(hardness, forKey: .hardness); try c.encode(spacing, forKey: .spacing)
        try c.encode(spacingEnabled, forKey: .spacingEnabled); try c.encode(opacity, forKey: .opacity); try c.encode(flow, forKey: .flow)
        try c.encode(pressureSize, forKey: .pressureSize); try c.encode(pressureOpacity, forKey: .pressureOpacity)
        try c.encode(color, forKey: .color); try c.encode(background, forKey: .background); try c.encode(erase, forKey: .erase)
        try c.encode(BlendModeName(mode), forKey: .mode)
        try c.encode(tip, forKey: .tip); try c.encode(angle, forKey: .angle); try c.encode(roundness, forKey: .roundness)
        try c.encode(flipX, forKey: .flipX); try c.encode(flipY, forKey: .flipY); try c.encode(aliased, forKey: .aliased)
        if square { try c.encode(square, forKey: .square) }
        try c.encode(shapeDynamics, forKey: .shapeDynamics); try c.encode(scattering, forKey: .scattering)
        try c.encode(texture, forKey: .texture); try c.encode(dualBrush, forKey: .dualBrush)
        try c.encode(colorDynamics, forKey: .colorDynamics); try c.encode(transfer, forKey: .transfer); try c.encode(pose, forKey: .pose)
        try c.encode(noise, forKey: .noise); try c.encode(wetEdges, forKey: .wetEdges); try c.encode(buildUp, forKey: .buildUp)
        try c.encode(buildUpRate, forKey: .buildUpRate); try c.encode(smoothing, forKey: .smoothing)
        try c.encode(protectTexture, forKey: .protectTexture); try c.encode(locks, forKey: .locks); try c.encode(mixer, forKey: .mixer)
        try c.encode(seed, forKey: .seed)
    }
}

extension BrushPreset: Codable {
    enum CodingKeys: String, CodingKey { case name, brush, builtin, group, folder }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name), brush: try c.decode(BrushSettings.self, forKey: .brush),
                  builtin: try c.get(.builtin, false), group: try c.get(.group, ""), folder: try c.get(.folder, []))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name); try c.encode(brush, forKey: .brush); try c.encode(builtin, forKey: .builtin)
        if !group.isEmpty { try c.encode(group, forKey: .group) }
        if !folder.isEmpty { try c.encode(folder, forKey: .folder) }
    }
}
