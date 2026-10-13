// Tests of the layer-effects mapping.
// Port of photocraft-io (crates/io/src/effects_map.rs, `#[cfg(test)] mod tests`, and the block-level
// part of crates/io/tests/effects_multi.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import Testing
@testable import PCIOMaps

private func shadowOf(_ e: Effect) -> Shadow {
    if case let .dropShadow(s) = e { return s }
    return Shadow(common: FxCommon(.multiply, 0.75))
}

private func sampleEffects() -> [Effect] {
    let g = StyleGradient(stops: [ColorStop(0, .rgb(1, 0, 0)), ColorStop(1, .rgb(0, 0, 1))], opacityStops: [OpacityStop(0, 1), OpacityStop(1, 0.5)])
    var cone = shadowOf(Effect.defaultDropShadow())
    cone.distance = 9
    cone.spread = 0.25
    cone.contour = .custom(Contour.CustomContour(name: "Cone", points: [CurvePoint(input: 0, output: 0), CurvePoint(input: 0.5, output: 1),
                                                                         CurvePoint(input: 1, output: 0)], corners: [false, true, false]))
    var inner = shadowOf(Effect.defaultDropShadow())
    inner.knocksOut = false
    return [
        Effect.defaultDropShadow(),
        .dropShadow(cone),
        .innerShadow(inner),
        .outerGlow(Glow(common: FxCommon(.screen, 0.5), paint: .color(.rgb(1, 1, 0)), technique: .precise, spread: 0.1, size: 8, contour: .linear,
                        antiAlias: true, range: 0.5, jitter: 0, noise: 0, source: .edge)),
        .innerGlow(Glow(common: FxCommon(.screen, 0.75), paint: .gradient(g), technique: .softer, spread: 0, size: 5, contour: .linear, antiAlias: false,
                        range: 0.5, jitter: 0, noise: 0, source: .center)),
        .stroke(StrokeFx(common: FxCommon(.normal, 1), size: 3, position: .inside, paint: .color(.rgb(0, 1, 0)))),
        .stroke(StrokeFx(common: FxCommon(.multiply, 0.5), size: 6, position: .center, paint: .gradient(g))),
        .colorOverlay(Effect.ColorOverlay(common: FxCommon(.overlay, 0.5), color: .rgb(0, 0, 1))),
        .gradientOverlay(Effect.GradientOverlay(common: FxCommon(.normal, 1), gradient: g, dither: true)),
        .patternOverlay(Effect.PatternOverlay(common: FxCommon(.normal, 1), name: "Bubbles", id: "abc", scale: 1, angle: 15, link: false, phase: SIMD2(4, 2))),
        .satin(Satin(common: FxCommon(.multiply, 0.5), color: .black, angle: 19, distance: 11, size: 14, contour: .linear, antiAlias: true, invert: true)),
        .bevelEmboss(Bevel(enabled: true, style: .emboss, technique: .chiselSoft, depth: 1.5, up: false, size: 7, soften: 2, angle: 45, altitude: 40,
                           useGlobalLight: false, glossContour: .linear, highlight: FxCommon(.screen, 0.75), highlightColor: .white,
                           shadow: FxCommon(.multiply, 0.6), shadowColor: .black,
                           contour: BevelContour(contour: .linear, range: 0.7, antiAlias: true),
                           texture: BevelTexture(name: "Bubbles", id: "abc", scale: 0.5, depth: -2, invert: true, link: false, phase: SIMD2(3, 1)))),
    ]
}

/// Colours go through 0...255 doubles; compare via re-serialization.
private func approx(_ a: [Effect], _ b: [Effect], sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a.count == b.count, sourceLocation: sourceLocation)
    #expect(EffectsMap.writeLfx2(true, a) == EffectsMap.writeLfx2(true, b), sourceLocation: sourceLocation)
}

private func lfx2(_ d: PSDDescriptor) -> [UInt8] { [0, 0, 0, 0] + Blocks.versionedBytes(d) }

private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

@Suite struct EffectsMapTests {
    @Test func lfx2RoundtripAllKinds() throws {
        let fx = sampleEffects()
        let data = EffectsMap.writeLfx2(false, fx)
        let (master, back) = try #require(EffectsMap.parseLfx2(data))
        #expect(!master)
        approx(fx, back)
        // Kind order is canonical: shadows first ... strokes last.
        if case .dropShadow = back.first {} else { Issue.record("first is \(String(describing: back.first))") }
        if case .stroke = back.last {} else { Issue.record("last is \(String(describing: back.last))") }
    }

    @Test func lfx2IgnoresAbsentEffectsButKeepsDisabledConfiguredEffects() throws {
        let d = PSDDescriptor(classID: "null")
            .with("DrSh", .descriptor(PSDDescriptor(classID: "DrSh").with("present", .boolean(false)).with("enab", .boolean(false))))
            .with("FrFX", .descriptor(PSDDescriptor(classID: "FrFX").with("present", .boolean(true)).with("enab", .boolean(false))))
            .with("SoFi", .descriptor(PSDDescriptor(classID: "SoFi").with("enab", .boolean(false))))
        let (_, effects) = try #require(EffectsMap.parseLfx2(lfx2(d)))
        #expect(effects.count == 2)
        #expect(effects.allSatisfy { !$0.isEnabled })
        #expect(effects.contains { $0.label == "Stroke" })
        #expect(effects.contains { $0.label == "Color Overlay" })
    }

    @Test func multiInstancesUseMultiKeys() throws {
        let data = EffectsMap.writeLfx2(true, sampleEffects())
        let d = try #require(Blocks.parsePrefixVersioned(data, from: 4))
        #expect(d["dropShadowMulti"] != nil)
        #expect(d["frameFXMulti"] != nil)
        #expect(d["SoFi"] != nil)
    }

    @Test func blendNamesAreUnique() {
        let names = Blocks.blendNames.map(\.1)
        #expect(Set(names).count == names.count)
    }

    @Test func longStringBlendIdsParse() throws {
        // Some writers store effect modes as long string IDs (`BlnM` `multiply`, `colorDodge`) instead
        // of the four-character codes (psd-tools effects/blend-modes.psd).
        func long(_ v: String) -> DValue { Blocks.enumValue("BlnM", v) }
        let d = PSDDescriptor(classID: "null")
            .with("masterFXSwitch", .boolean(true))
            .with("DrSh", .descriptor(PSDDescriptor(classID: "DrSh").with("enab", .boolean(true)).with("Md  ", long("linearBurn"))))
            .with("ebbl", .descriptor(PSDDescriptor(classID: "ebbl").with("hglM", long("colorDodge")).with("sdwM", long("colorBurn"))))
            .with("SoFi", .descriptor(PSDDescriptor(classID: "SoFi").with("Md  ", long("hue"))))
        let (_, fx) = try #require(EffectsMap.parseLfx2(lfx2(d)))
        let modes: [BlendMode] = fx.flatMap { e -> [BlendMode] in
            switch e {
            case let .dropShadow(s): [s.common.blend]
            case let .bevelEmboss(b): [b.highlight.blend, b.shadow.blend]
            case let .colorOverlay(o): [o.common.blend]
            default: []
            }
        }
        #expect(modes == [.linearBurn, .colorDodge, .colorBurn, .hue])
        for (m, n) in Blocks.blendLongNames { #expect(Blocks.blendFromId(n) == m) }
    }

    @Test func garbageIsNil() {
        #expect(EffectsMap.parseLfx2([0, 0]) == nil)
        #expect(EffectsMap.parseLrfx([0, 0, 0, 1, UInt8(ascii: "X")]) == nil)
    }

    @Test func lrfxDropShadow() throws {
        // version 0, count 1, 'dsdw' v2 record.
        var d: [UInt8] = [0, 0, 0, 1] + Array("8BIMdsdw".utf8)
        var rec: [UInt8] = []
        rec += be32(2) // version
        rec += be32(7 << 16) // blur (16.16)
        rec += be32(0) // intensity
        rec += be32(90 << 16) // angle
        rec += be32(4 << 16) // distance
        rec += [0, 0, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0] // color: red
        rec += Array("8BIMmul ".utf8)
        rec += [1, 1, 128]
        rec += [UInt8](repeating: 0, count: 10)
        d += be32(UInt32(rec.count))
        d += rec
        let (_, fx) = try #require(EffectsMap.parseLrfx(d))
        guard case let .dropShadow(s) = fx.first else { Issue.record("\(fx)"); return }
        #expect(s.size == 7)
        #expect(s.distance == 4)
        #expect(s.angle == 90)
        #expect(s.common.blend == .multiply)
        #expect(abs(s.common.opacity - 128.0 / 255.0) < 1e-6)
        #expect(s.color.c[0] == 1)
        // A truncated record or a bad signature fails the whole block, as in photocraft.
        #expect(EffectsMap.parseLrfx(Array(d.dropLast(12))) == nil)
        var bad = d
        bad[4] = UInt8(ascii: "X")
        #expect(EffectsMap.parseLrfx(bad) == nil)
    }

    @Test func lrfxGlowsAndSolidFill() throws {
        // Outer glow v2 and solid fill records laid out per the Adobe spec.
        var glow: [UInt8] = be32(2) + be32(10 << 16) + be32(0)
        glow += [0, 0, 0, 0, 0xFF, 0xFF, 0, 0, 0, 0] // colour: green
        glow += Array("8BIMscrn".utf8) + [1, 191] + [UInt8](repeating: 0, count: 10)
        var fill: [UInt8] = be32(2) + Array("8BIMnorm".utf8)
        fill += [0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0, 0] // colour: blue
        fill += [255, 1] + [UInt8](repeating: 0, count: 10)
        var d: [UInt8] = [0, 0, 0, 2]
        for (k, r) in [("oglw", glow), ("sofi", fill)] { d += Array("8BIM\(k)".utf8) + be32(UInt32(r.count)) + r }
        let (enabled, fx) = try #require(EffectsMap.parseLrfx(d))
        #expect(enabled && fx.count == 2)
        guard case let .outerGlow(g) = fx[0], case let .colorOverlay(o) = fx[1] else { Issue.record("\(fx)"); return }
        #expect(g.size == 10 && g.common.blend == .screen && g.common.enabled && abs(g.common.opacity - 191.0 / 255.0) < 1e-6)
        #expect(g.paint == .color(.rgb(0, 1, 0)))
        #expect(o.color == .rgb(0, 0, 1) && o.common.opacity == 1 && o.common.enabled && o.common.blend == .normal)
    }

    /// Multiple instances of an effect (Photoshop CC's several strokes / shadows) survive the block
    /// round trip (effects_multi.rs, block level).
    @Test func severalStrokesAndShadowsRoundtrip() throws {
        func stroke(_ size: Float, _ position: StrokePosition, _ paint: FxPaint, _ opacity: Float) -> Effect {
            .stroke(StrokeFx(common: FxCommon(.normal, opacity), size: size, position: position, paint: paint))
        }
        let g = StyleGradient(stops: [ColorStop(0, .rgb(0, 0, 1)), ColorStop(1, .rgb(1, 1, 0))], angle: 30)
        var moved = shadowOf(Effect.defaultDropShadow())
        moved.distance = 9
        moved.angle = 45
        moved.useGlobalLight = false
        let items: [Effect] = [
            stroke(2, .outside, .color(.rgb(1, 1, 1)), 1),
            stroke(5, .outside, .gradient(g), 0.8),
            stroke(3, .inside, .color(.rgb(0, 0.5, 0)), 1),
            stroke(4, .center, .color(.rgb(0, 0, 0)), 0.5),
            Effect.defaultDropShadow(),
            .dropShadow(moved),
        ]
        let (_, fx) = try #require(EffectsMap.parseLfx2(EffectsMap.writeLfx2(true, items)))
        let strokes: [StrokeFx] = fx.compactMap { if case let .stroke(s) = $0 { s } else { nil } }
        #expect(strokes.count == 4)
        #expect(strokes.map(\.size) == [2, 5, 3, 4])
        #expect(strokes.map(\.position) == [.outside, .outside, .inside, .center])
        if case .gradient = strokes[1].paint {} else { Issue.record("gradient stroke") }
        #expect(abs(strokes[3].common.opacity - 0.5) < 1e-3)
        #expect(fx.filter { if case .dropShadow = $0 { true } else { false } }.count == 2)
    }

    @Test func groupsAndLmfxUseTheSameLayout() throws {
        // `lfxs` (groups) and `lmfx` are read with the same parser; a corrupt descriptor is nil.
        let data = EffectsMap.writeLfx2(true, [Effect.defaultDropShadow()])
        #expect(try #require(EffectsMap.parseLfx2(data)).items == [Effect.defaultDropShadow()])
        #expect(EffectsMap.parseLfx2(Array(data.prefix(20))) == nil)
        // A truncated or garbage block never traps.
        for n in 0 ..< data.count { _ = EffectsMap.parseLfx2(Array(data.prefix(n))) }
        for n in 0 ..< 64 { _ = EffectsMap.parseLrfx((0 ..< n).map { UInt8(truncatingIfNeeded: $0 * 31 + 7) }) }
    }
}
