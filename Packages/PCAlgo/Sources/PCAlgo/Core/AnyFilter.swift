// Port of photocraft-algo (crates/algo/src/lib.rs: the serde-tagged `FilterParams` enum), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// photocraft serialises a filter as one JSON object tagged by `"filter"` with its parameters
// alongside (`{"filter":"gaussianBlur","radius":2}`, camelCase variant and field names). AnyFilter
// reads and writes that shape for every ported filter, so stored smart filters, presets and the
// engine's command parameters decode into the matching Swift type.

import Foundation

/// A type-erased filter that encodes and decodes as photocraft's tagged `FilterParams` JSON.
public struct AnyFilter: Codable, Sendable {
    public let filter: any Filter

    public init(_ filter: any Filter) { self.filter = filter }

    /// photocraft's tag for each ported filter type (the variant name in camelCase; engine
    /// presets and engine-implemented filters carry the command's name).
    public static let registry: [(tag: String, type: any Filter.Type)] = [
            ("gaussianBlur", GaussianBlur.self), ("boxBlur", BoxBlur.self), ("motionBlur", MotionBlur.self),
            ("radialBlur", RadialBlur.self), ("surfaceBlur", SurfaceBlur.self), ("smartBlur", SmartBlur.self),
            ("lensBlur", LensBlur.self), ("shapeBlur", ShapeBlur.self), ("average", AverageBlur.self), ("blurPreset", BlurPreset.self),
            ("tiltShift", TiltShift.self), ("irisBlur", IrisBlur.self), ("fieldBlur", FieldBlur.self), ("spinBlur", SpinBlur.self),
            ("pathBlur", PathBlur.self),
            ("unsharpMask", UnsharpMask.self), ("smartSharpen", SmartSharpen.self), ("highPass", HighPass.self),
            ("sharpenPreset", SharpenPreset.self),
            ("addNoise", AddNoise.self), ("median", Median.self), ("dustAndScratches", DustAndScratches.self),
            ("despeckle", Despeckle.self), ("reduceNoise", ReduceNoise.self),
            ("minimum", Minimum.self), ("maximum", Maximum.self), ("offset", Offset.self), ("custom", CustomKernel.self),
            ("twirl", Twirl.self), ("pinch", Pinch.self), ("spherize", Spherize.self), ("wave", Wave.self), ("ripple", Ripple.self),
            ("polarCoordinates", PolarCoordinates.self), ("displace", Displace.self), ("shear", Shear.self), ("zigZag", ZigZag.self),
            ("fibers", Fibers.self), ("lensFlare", LensFlare.self), ("lightingEffects", LightingEffects.self), ("relight", Relight.self),
            ("clouds", Clouds.self),
            ("hsbHsl", HsbHsl.self), ("colorToAlpha", ColorToAlpha.self), ("deInterlace", DeInterlace.self), ("ntscColors", NTSCColors.self),
            ("shadowsHighlights", ShadowsHighlights.self), ("cameraRaw", CameraRawFilter.self), ("replaceColor", ReplaceColor.self),
            ("matchColor", MatchColorFilter.self), ("hdrToning", HdrToning.self), ("hdrToneMap", HDRToneMap.self),
            ("mosaic", Mosaic.self), ("emboss", Emboss.self), ("findEdges", FindEdges.self), ("solarize", Solarize.self),
            ("invert", Invert.self), ("desaturate", Desaturate.self), ("diffuse", Diffuse.self), ("extrude", Extrude.self),
            ("oilPaint", OilPaint.self), ("tiles", Tiles.self), ("traceContour", TraceContour.self), ("wind", Wind.self),
            ("glowingEdges", GlowingEdges.self), ("colorHalftone", ColorHalftone.self), ("crystallize", Crystallize.self),
            ("facet", Facet.self), ("fragment", Fragment.self), ("mezzotint", Mezzotint.self), ("pointillize", Pointillize.self),
            ("lensCorrection", LensCorrection.self), ("filterGallery", FilterGallery.self),
    ]

    static let byTag: [String: any Filter.Type] = Dictionary(registry.map { ($0.tag, $0.type) }, uniquingKeysWith: { a, _ in a })

    /// The tag of a filter value's type, if registered.
    public static func tag(of filter: any Filter) -> String? {
        let t = type(of: filter)
        return registry.first { $0.type == t }?.tag
    }

    enum TagKey: String, CodingKey { case filter }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: TagKey.self)
        let tag = try c.decode(String.self, forKey: .filter)
        guard let t = Self.byTag[tag] else {
            throw DecodingError.dataCorruptedError(forKey: .filter, in: c, debugDescription: "unknown filter \"\(tag)\"")
        }
        filter = try t.init(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        guard let tag = Self.tag(of: filter) else {
            throw EncodingError.invalidValue(filter, .init(codingPath: encoder.codingPath, debugDescription: "unregistered filter \(type(of: filter))"))
        }
        try filter.encode(to: encoder)
        var c = encoder.container(keyedBy: TagKey.self)
        try c.encode(tag, forKey: .filter)
    }
}
