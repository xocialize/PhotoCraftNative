// Port of photocraft-algo's colour-model handling (crates/algo/src/fxutil.rs `rgba`/`set_rgba`, tone.rs, render.rs, relight.rs, artistic_fx.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filters whose CPU reference works on straight sRGB (`to_rgba` in, `from_rgba` out) — so CMYK and
// Lab documents run on the GPU as their sRGB conversion (`FilterEngine` converts on the CPU with the
// same functions). Each is verified by RGBAEquivalenceTests (the identity holds to float rounding);
// filters that read native channels (Smart Blur, Diffuse, Wind, Facet, Extrude, Oil Paint, Halftone,
// Mezzotint, NTSC, Color to Alpha, Reduce Noise, Lighting Effects' height map) are not listed.

extension AverageBlur { public var rgbaEquivalent: Bool { true } }
extension CameraRawFilter { public var rgbaEquivalent: Bool { true } }
extension Clouds { public var rgbaEquivalent: Bool { true } }
extension Desaturate { public var rgbaEquivalent: Bool { true } }
extension Emboss { public var rgbaEquivalent: Bool { true } }
extension Fibers { public var rgbaEquivalent: Bool { true } }
extension FilterGallery { public var rgbaEquivalent: Bool { true } }
extension GlowingEdges { public var rgbaEquivalent: Bool { true } }
extension HDRToneMap { public var rgbaEquivalent: Bool { true } }
extension HdrToning { public var rgbaEquivalent: Bool { true } }
extension HsbHsl { public var rgbaEquivalent: Bool { true } }
extension LensFlare { public var rgbaEquivalent: Bool { true } }
extension MatchColorFilter { public var rgbaEquivalent: Bool { true } }
extension Relight { public var rgbaEquivalent: Bool { true } }
extension ReplaceColor { public var rgbaEquivalent: Bool { true } }
extension ShadowsHighlights { public var rgbaEquivalent: Bool { true } }
