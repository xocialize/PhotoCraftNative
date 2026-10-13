// Port of photocraft-paint (crates/paint/src/mixer.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Mixer Brush: a reservoir of loaded paint plus a pickup well that mixes in canvas colour.
// Model (photocraft's own, behavioural): each dab samples the canvas colour under its footprint.
// The pickup colour P moves towards it by `wet`. The deposited colour mixes the reservoir R
// (weight `amount × (1 − mix·wet)`) with the pickup (weight `mix·wet`); it lands at `flow` times
// the total weight. The reservoir amount drains per dab unless Load is 100 %, so low-Load strokes
// dry out. A dry brush (`wet = 0`) paints only reservoir colour; an empty, wet brush smears canvas
// colour.

import PCFoundation

/// Fraction of the way the pickup colour moves towards the canvas colour per dab at 100 % Wet.
public let pickupRate: Float = 0.25

/// Mixer Brush options (all 0…1).
public struct MixerSettings: Hashable, Sendable {
    public var wet: Float = 0.5
    public var load: Float = 0.5
    public var mix: Float = 0.5
    public var flow: Float = 1
    /// Pick up colour from all visible layers instead of the target layer only.
    public var sampleAllLayers = false

    public init(wet: Float = 0.5, load: Float = 0.5, mix: Float = 0.5, flow: Float = 1, sampleAllLayers: Bool = false) {
        self.wet = wet; self.load = load; self.mix = mix; self.flow = flow; self.sampleAllLayers = sampleAllLayers
    }
}

extension MixerSettings: Codable {
    enum CodingKeys: String, CodingKey { case wet, load, mix, flow, sampleAllLayers }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MixerSettings()
        self.init(wet: try c.get(.wet, d.wet), load: try c.get(.load, d.load), mix: try c.get(.mix, d.mix), flow: try c.get(.flow, d.flow),
                  sampleAllLayers: try c.get(.sampleAllLayers, d.sampleAllLayers))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(wet, forKey: .wet); try c.encode(load, forKey: .load); try c.encode(mix, forKey: .mix)
        try c.encode(flow, forKey: .flow); try c.encode(sampleAllLayers, forKey: .sampleAllLayers)
    }
}

/// Paint carried between strokes (session tool state).
public struct MixerState: Hashable, Sendable {
    /// Loaded paint (straight RGBA), nil = clean/unloaded.
    public var reservoir: SIMD4<Float>?
    /// Remaining reservoir amount 0…1.
    public var amount: Float = 0
    /// Colour picked up from the canvas (straight RGBA), nil = clean.
    public var pickup: SIMD4<Float>?

    public init() {}

    /// Load the reservoir with a colour (full).
    public mutating func load(_ color: SIMD4<Float>) {
        reservoir = color
        amount = 1
    }

    /// Clean the brush (drop the picked-up colour).
    public mutating func clean() { pickup = nil }
}

extension MixerState: Codable {
    enum CodingKeys: String, CodingKey { case reservoir, amount, pickup }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        reservoir = try c.decodeIfPresent(SIMD4<Float>.self, forKey: .reservoir)
        amount = try c.get(.amount, 0)
        pickup = try c.decodeIfPresent(SIMD4<Float>.self, forKey: .pickup)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reservoir, forKey: .reservoir)
        try c.encode(amount, forKey: .amount)
        try c.encode(pickup, forKey: .pickup)
    }
}

public enum MixerBrush {
    /// Paint a Mixer Brush stroke. `sample` is the surface colour is picked up from (the layer
    /// itself when nil; a flattened composite for Sample All Layers). Returns the damage.
    @discardableResult
    public static func apply(_ target: inout Surface, sample: Surface?, stroke: Stroke, settings m: MixerSettings, state: inout MixerState,
                             selection: Surface?, lockTransparency: Bool) -> PixelRect {
        let fmt = target.format
        let n = fmt.channels
        let a = alphaIndex(fmt)
        let nc = fmt.mode.colorChannels
        func native(_ c: SIMD4<Float>) -> [Float] {
            var v = fromRGBA(fmt, c)
            if let ai = a { v[ai] = 1 }
            return v
        }
        let res = state.reservoir.map(native)
        var amount: Float = res != nil ? clampR(state.amount, 0, 1) : 0
        var pickup: [Float]? = state.pickup.map(native)
        let wet0 = clampR(m.wet, 0, 1), mix0 = clampR(m.mix, 0, 1), flow = clampR(m.flow, 0, 1), load = clampR(m.load, 0, 1)
        var st = stroke
        st.brush.opacity = 1
        var acc = [Float](repeating: 0, count: n)
        var paint = [Float](repeating: 0, count: n)
        let dmg = Retouch.applyDabStroke(&target, st, selection: selection, lockTransparency: lockTransparency, halo: 0) { work, fp in
            // Transfer › Wetness / Mix Jitter scale the settings per dab.
            let wet = wet0 * clampR(fp.dab.wet, 0, 1), mix = mix0 * clampR(fp.dab.mix, 0, 1)
            // Sample the canvas under the dab.
            for i in acc.indices { acc[i] = 0 }
            var wsum: Float = 0, asum: Float = 0
            let r = fp.rect.intersect(work.rect)
            if !r.isEmpty {
                for y in r.y0..<r.y1 {
                    for x in r.x0..<r.x1 {
                        let w = fp.at(x, y)
                        if w <= 0 { continue }
                        let px: [Float]
                        if let s = sample {
                            let v = s.pixel(x: x, y: y)
                            px = s.format == fmt ? v : fromRGBA(fmt, s.rgba(x, y))
                        } else {
                            px = Array(work.px(x, y))
                        }
                        let al: Float = a.map { px[$0] } ?? 1
                        for c in 0..<nc { acc[c] += px[c] * w * al }
                        wsum += w
                        asum += w * al
                    }
                }
            }
            if asum > 1e-6 && wet > 0 {
                let ca = asum / maxR(wsum, 1e-6)
                let canvas: [Float] = (0..<n).map { c in c < nc ? acc[c] / asum : 1 }
                if let p = pickup {
                    pickup = (0..<n).map { i in p[i] + (canvas[i] - p[i]) * pickupRate * wet * ca }
                } else {
                    pickup = canvas
                }
            }
            let wr: Float = res != nil ? amount * (1 - mix * wet) : 0
            let wp: Float = pickup != nil ? mix * wet : 0
            let total = wr + wp
            if total > 1e-6 {
                for c in 0..<n {
                    let rv = res?[c] ?? 0
                    let pv = pickup?[c] ?? 0
                    paint[c] = (rv * wr + pv * wp) / total
                }
                let dep = minR(total, 1) * flow
                if !r.isEmpty {
                    for y in r.y0..<r.y1 {
                        for x in r.x0..<r.x1 {
                            let k = fp.at(x, y) * dep
                            if k > 0 {
                                work.withPixel(x, y) { px in
                                    paint.withUnsafeBufferPointer { overNative(fmt, px.baseAddress!, $0.baseAddress!, k, lockTransparency) }
                                }
                            }
                        }
                    }
                }
            }
            amount *= 1 - 0.08 * (1 - load)
        }
        state.amount = amount
        state.pickup = pickup.map { toRGBA(fmt, $0) }
        return dmg
    }
}
