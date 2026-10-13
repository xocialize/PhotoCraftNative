// Port of photocraft-algo (crates/algo/src/lib.rs `FilterParams` serde, params_ext.rs; tests.rs `params_serde_roundtrip`, `radial_blur_quality_defaults_for_older_serialized_parameters`, `minimum_maximum_old_params_default_to_squareness`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Interop with photocraft's serialised filters: one hand-written sample per `FilterParams` variant
// exactly as photocraft's serde writes it (`#[serde(tag = "filter", rename_all = "camelCase",
// rename_all_fields = "camelCase")]`, every field present, `#[serde(skip)]` maps absent), decoded
// through `AnyFilter`, checked for the right type, and re-encoded to an equivalent object.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

enum QAJSON {
    /// photocraft `FilterParams` as serde_json writes each variant.
    static let samples: [(tag: String, json: String)] = [
        ("gaussianBlur", #"{"filter":"gaussianBlur","radius":2.5}"#),
        ("boxBlur", #"{"filter":"boxBlur","radius":2.0}"#),
        ("motionBlur", #"{"filter":"motionBlur","angle":30.0,"distance":7.0}"#),
        ("radialBlur", #"{"filter":"radialBlur","amount":20.0,"method":"zoom","quality":"best","centerX":0.3,"centerY":0.6}"#),
        ("surfaceBlur", #"{"filter":"surfaceBlur","radius":3.0,"threshold":20.0}"#),
        ("unsharpMask", #"{"filter":"unsharpMask","amount":150.0,"radius":1.5,"threshold":2.0}"#),
        ("smartSharpen", #"{"filter":"smartSharpen","amount":100.0,"radius":1.0,"reduceNoise":20.0}"#),
        ("highPass", #"{"filter":"highPass","radius":3.0}"#),
        ("addNoise", #"{"filter":"addNoise","amount":25.0,"distribution":"gaussian","monochromatic":true,"seed":3}"#),
        ("median", #"{"filter":"median","radius":2.0}"#),
        ("dustAndScratches", #"{"filter":"dustAndScratches","radius":2.0,"threshold":10.0}"#),
        ("minimum", #"{"filter":"minimum","radius":2.5,"preserve":"roundness"}"#),
        ("maximum", #"{"filter":"maximum","radius":3.0,"preserve":"squareness"}"#),
        ("offset", #"{"filter":"offset","horizontal":7,"vertical":-3,"undefined":"transparent"}"#),
        ("mosaic", #"{"filter":"mosaic","cellSize":6.0}"#),
        ("emboss", #"{"filter":"emboss","angle":135.0,"height":2.0,"amount":100.0}"#),
        ("findEdges", #"{"filter":"findEdges"}"#),
        ("solarize", #"{"filter":"solarize"}"#),
        ("invert", #"{"filter":"invert"}"#),
        ("desaturate", #"{"filter":"desaturate"}"#),
        ("twirl", #"{"filter":"twirl","angle":90.0}"#),
        ("pinch", #"{"filter":"pinch","amount":50.0}"#),
        ("spherize", #"{"filter":"spherize","amount":-60.0,"mode":"horizontalOnly"}"#),
        ("wave", #"{"filter":"wave","generators":3,"wavelengthMin":5.0,"wavelengthMax":20.0,"amplitudeMin":1.0,"amplitudeMax":4.0,"waveType":"triangle","undefined":"repeat","seed":9}"#),
        ("ripple", #"{"filter":"ripple","amount":200.0,"size":"small"}"#),
        ("polarCoordinates", #"{"filter":"polarCoordinates","mode":"polarToRectangular"}"#),
        ("colorHalftone", #"{"filter":"colorHalftone","maxRadius":4.0,"angles":[108.0,162.0,90.0,45.0]}"#),
        ("crystallize", #"{"filter":"crystallize","cellSize":6.0,"seed":1}"#),
        ("facet", #"{"filter":"facet"}"#),
        ("fragment", #"{"filter":"fragment"}"#),
        ("mezzotint", #"{"filter":"mezzotint","kind":"mediumLines","seed":2}"#),
        ("pointillize", #"{"filter":"pointillize","cellSize":5.0,"seed":3,"background":[1.0,0.5,0.25,1.0]}"#),
        ("diffuse", #"{"filter":"diffuse","mode":"anisotropic","seed":4}"#),
        ("extrude", #"{"filter":"extrude","kind":"pyramids","size":6.0,"depth":30.0,"levelBased":true,"solidFront":false,"maskIncomplete":true,"seed":5}"#),
        ("oilPaint", #"{"filter":"oilPaint","stylization":3.0,"cleanliness":4.0,"scale":1.0,"bristleDetail":5.0,"lighting":true,"angle":-60.0,"shine":2.0}"#),
        ("tiles", #"{"filter":"tiles","count":4,"maxOffset":20.0,"fill":"inverse","foreground":[0.0,0.0,0.0,1.0],"background":[1.0,1.0,1.0,1.0],"seed":6}"#),
        ("traceContour", #"{"filter":"traceContour","level":128.0,"upper":true}"#),
        ("wind", #"{"filter":"wind","method":"stagger","fromRight":true,"seed":7}"#),
        ("displace", #"{"filter":"displace","horizontal":10.0,"vertical":-5.0,"stretch":true,"undefined":"wrap"}"#),
        ("shear", #"{"filter":"shear","points":[[0.0,0.0],[0.5,0.3],[1.0,0.0]],"undefined":"repeat"}"#),
        ("zigZag", #"{"filter":"zigZag","amount":50.0,"ridges":4.0,"style":"outFromCenter"}"#),
        ("fibers", #"{"filter":"fibers","variance":16.0,"strength":4.0,"seed":8,"foreground":[0.0,0.0,0.0,1.0],"background":[1.0,1.0,1.0,1.0]}"#),
        ("lensFlare", #"{"filter":"lensFlare","brightness":100.0,"centerX":0.3,"centerY":0.3,"lens":"prime105"}"#),
        ("lightingEffects", #"{"filter":"lightingEffects","lights":[{"kind":"point","x":0.1,"y":0.5,"z":0.2,"targetX":0.5,"targetY":0.55,"angle":135.0,"elevation":45.0,"color":[1.0,0.9,0.8],"intensity":50.0,"cone":45.0,"hotspot":50.0,"radius":1.0}],"gloss":-100.0,"metallic":0.0,"exposure":0.0,"ambience":10.0,"texture":"luminance","height":50.0,"whiteIsHigh":true}"#),
        ("relight", #"{"filter":"relight","angle":45.0,"elevation":40.0,"intensity":40.0,"ambient":55.0,"warmth":-20.0,"softness":25.0}"#),
        ("reduceNoise", #"{"filter":"reduceNoise","strength":6.0,"preserveDetails":60.0,"reduceColorNoise":45.0,"sharpenDetails":25.0,"removeJpegArtifact":true}"#),
        ("smartBlur", #"{"filter":"smartBlur","radius":3.0,"threshold":25.0,"quality":"low","mode":"overlayEdge"}"#),
        ("lensBlur", #"{"filter":"lensBlur","radius":4.0,"blades":6,"curvature":20.0,"rotation":10.0,"depth":"transparency","focalDistance":30.0,"invertDepth":true,"brightness":30.0,"threshold":200.0,"noise":5.0,"distribution":"gaussian","monochromatic":true,"seed":9}"#),
        ("shapeBlur", #"{"filter":"shapeBlur","radius":3.0,"shape":"star"}"#),
        ("tiltShift", #"{"filter":"tiltShift","blur":6.0,"centerX":0.5,"centerY":0.4,"angle":10.0,"focus":0.1,"transition":0.2}"#),
        ("irisBlur", #"{"filter":"irisBlur","pins":[{"x":0.5,"y":0.5,"radiusX":0.35,"radiusY":0.25,"angle":10.0,"roundness":20.0,"feather":0.5,"blur":6.0}]}"#),
        ("fieldBlur", #"{"filter":"fieldBlur","pins":[{"x":0.2,"y":0.2,"blur":0.0},{"x":0.8,"y":0.8,"blur":6.0}]}"#),
        ("spinBlur", #"{"filter":"spinBlur","pins":[{"x":0.5,"y":0.5,"radiusX":0.3,"radiusY":0.3,"angle":0.0,"blurAngle":30.0}]}"#),
        ("pathBlur", #"{"filter":"pathBlur","paths":[{"points":[[0.1,0.2],[0.9,0.8]],"speed":8.0,"taper":30.0}]}"#),
        ("custom", #"{"filter":"custom","kernel":[0.0,0.0,0.0,0.0,0.0,0.0,0.0,-1.0,0.0,0.0,0.0,-1.0,5.0,-1.0,0.0,0.0,0.0,-1.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0],"scale":1.0,"offset":0.0}"#),
        ("hsbHsl", #"{"filter":"hsbHsl","input":"rgb","output":"hsl"}"#),
        ("colorToAlpha", #"{"filter":"colorToAlpha","color":[0.5,0.25,0.75,1.0],"transparencyThreshold":0.1,"opacityThreshold":0.9}"#),
        ("deInterlace", #"{"filter":"deInterlace","eliminateEven":false,"interpolate":true}"#),
        ("ntscColors", #"{"filter":"ntscColors"}"#),
    ]

    /// Every `FilterParams` variant tag photocraft can write.
    static let photocraftTags: [String] = samples.map(\.tag) + ["filterGallery"]

    static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    /// Differences between photocraft's object `want` and the Swift encoding `got` at `path`
    /// (numbers compared as Double within 1e-6 relative; keys only in `got` are reported apart).
    static func differences(_ want: Any, _ got: Any?, _ path: String) -> [String] {
        guard let got else { return ["\(path): missing in the Swift encoding"] }
        switch want {
        case let w as [String: Any]:
            guard let g = got as? [String: Any] else { return ["\(path): object vs \(type(of: got))"] }
            return w.keys.sorted().flatMap { differences(w[$0]!, g[$0], path.isEmpty ? $0 : "\(path).\($0)") }
        case let w as [Any]:
            guard let g = got as? [Any] else { return ["\(path): array vs \(got)"] }
            if w.count != g.count { return ["\(path): \(w.count) elements vs \(g.count)"] }
            return zip(w, g).enumerated().flatMap { differences($0.element.0, $0.element.1, "\(path)[\($0.offset)]") }
        case let w as NSNumber where CFGetTypeID(w) == CFBooleanGetTypeID():
            guard let g = got as? NSNumber, CFGetTypeID(g) == CFBooleanGetTypeID(), g.boolValue == w.boolValue else { return ["\(path): \(w.boolValue) vs \(got)"] }
            return []
        case let w as NSNumber:
            guard let g = got as? NSNumber, CFGetTypeID(g) != CFBooleanGetTypeID() else { return ["\(path): \(w) vs \(got)"] }
            let a = w.doubleValue, b = g.doubleValue
            return abs(a - b) <= 1e-6 * max(1, abs(a)) ? [] : ["\(path): \(a) vs \(b)"]
        case let w as String:
            return (got as? String) == w ? [] : ["\(path): \"\(w)\" vs \(got)"]
        default:
            return ["\(path): unexpected \(want)"]
        }
    }

    /// Keys the Swift encoding adds (photocraft's serde ignores unknown fields when reading).
    static func extraKeys(_ want: [String: Any], _ got: [String: Any]) -> [String] {
        got.keys.filter { want[$0] == nil }.sorted()
    }

    /// Decodes photocraft JSON through AnyFilter: the problems found (empty when it round-trips).
    static func check(_ tag: String, _ json: String) -> (problems: [String], extra: [String]) {
        let want = object(json)
        let decoded: AnyFilter
        do {
            decoded = try JSONDecoder().decode(AnyFilter.self, from: Data(json.utf8))
        } catch {
            return (["does not decode: \(error)"], [])
        }
        guard let regType = AnyFilter.registry.first(where: { $0.tag == tag })?.type else { return (["tag not registered"], []) }
        var problems: [String] = []
        if type(of: decoded.filter) != regType { problems.append("decoded as \(type(of: decoded.filter))") }
        guard let data = try? JSONEncoder().encode(decoded), let got = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (problems + ["does not re-encode"], [])
        }
        problems += differences(want, got, "")
        return (problems, extraKeys(want, got))
    }
}

@Suite struct QAJSONTests {
    /// Every `FilterParams` variant decodes from photocraft's JSON into its Swift type and
    /// re-encodes to the same object (photocraft `params_serde_roundtrip`, `new_params_serde_roundtrip`).
    @Test(arguments: QAJSON.samples.map(\.tag))
    func photocraftJSONDecodesAndRoundTrips(_ tag: String) {
        let json = QAJSON.samples.first { $0.tag == tag }!.json
        let (problems, extra) = QAJSON.check(tag, json)
        #expect(problems.isEmpty, "\(tag): \(problems.joined(separator: "; "))")
        if !extra.isEmpty { print("QAJSON\textra-keys\t\(tag)\t\(extra.joined(separator: ","))") }
    }

    /// Every variant photocraft can serialise has a registered Swift type.
    @Test func everyPhotocraftVariantIsRegistered() {
        let registered = Set(AnyFilter.registry.map(\.tag))
        let missing = QAJSON.photocraftTags.filter { !registered.contains($0) }
        do {
        #expect(missing.isEmpty, "unregistered photocraft variants: \(missing)")
    }
        // Swift-only tags (presets and engine-level filters photocraft stores as command params).
        let photocraft = Set(QAJSON.photocraftTags)
        let swiftOnly = AnyFilter.registry.map(\.tag).filter { !photocraft.contains($0) }
        print("QAJSON\tswift-only-tags\t\(swiftOnly.joined(separator: ","))")
    }

    /// photocraft `radial_blur_quality_defaults_for_older_serialized_parameters`: `quality` is
    /// `#[serde(default)]` (Good).
    @Test func radialBlurQualityDefaultsForOlderParameters() throws {
        do {
        let r = try JSONDecoder().decode(AnyFilter.self, from: Data(#"{"filter":"radialBlur","amount":20.0,"method":"spin","centerX":0.5,"centerY":0.5}"#.utf8))
        #expect(r.filter as? RadialBlur == RadialBlur(amount: 20, method: .spin, quality: .good, centerX: 0.5, centerY: 0.5))
    }
    }

    /// photocraft `minimum_maximum_old_params_default_to_squareness`: `preserve` is
    /// `#[serde(default)]` (Squareness).
    @Test func minimumMaximumOldParamsDefaultToSquareness() throws {
        do {
        let mn = try JSONDecoder().decode(AnyFilter.self, from: Data(#"{"filter":"minimum","radius":3}"#.utf8))
        #expect(mn.filter as? Minimum == Minimum(radius: 3, preserve: .squareness))
    }
        do {
        let mx = try JSONDecoder().decode(AnyFilter.self, from: Data(#"{"filter":"maximum","radius":3}"#.utf8))
        #expect(mx.filter as? Maximum == Maximum(radius: 3, preserve: .squareness))
    }
        let mx = try JSONDecoder().decode(AnyFilter.self, from: Data(#"{"filter":"maximum","radius":2,"preserve":"roundness"}"#.utf8))
        #expect(mx.filter as? Maximum == Maximum(radius: 2, preserve: .roundness))
    }

    /// photocraft's parameter objects are `#[serde(rename_all = "camelCase", default)]`: any field
    /// may be absent and takes the struct's `Default` (Light does; the blur-gallery pins don't).
    @Test func parameterObjectsTakeTheirDefaults() throws {
        let dec = JSONDecoder()
        let l = try dec.decode(AnyFilter.self, from: Data(#"{"filter":"lightingEffects","lights":[{"kind":"point","x":0.1}],"gloss":0,"metallic":0,"exposure":0,"ambience":10,"texture":"none","height":50,"whiteIsHigh":true}"#.utf8))
        #expect((l.filter as? LightingEffects)?.lights == [Light(kind: .point, x: 0.1)])
        do {
        let f = try dec.decode(AnyFilter.self, from: Data(#"{"filter":"irisBlur","pins":[{"blur":6}]}"#.utf8))
        #expect((f.filter as? IrisBlur)?.pins == [IrisPin(blur: 6)])
    }
        do {
        let f = try dec.decode(AnyFilter.self, from: Data(#"{"filter":"fieldBlur","pins":[{"x":0.2}]}"#.utf8))
        #expect((f.filter as? FieldBlur)?.pins == [FieldPin(x: 0.2)])
    }
        do {
        let f = try dec.decode(AnyFilter.self, from: Data(#"{"filter":"spinBlur","pins":[{"blurAngle":30}]}"#.utf8))
        #expect((f.filter as? SpinBlur)?.pins == [SpinPin(blurAngle: 30)])
    }
        do {
        let f = try dec.decode(AnyFilter.self, from: Data(#"{"filter":"pathBlur","paths":[{"speed":8}]}"#.utf8))
        #expect((f.filter as? PathBlur)?.paths == [BlurPath(speed: 8)])
    }
    }

    /// Engine-level filters photocraft keeps as smart-filter command params (`SmartFilter {
    /// command, params }` in photocraft-doc): Camera Raw's params are the `CameraRaw` fields at the
    /// top level (engine `lens_cmds::raw_params`), not nested.
    @Test func cameraRawParamsAreTopLevelSettings() throws {
        let json = #"{"filter":"cameraRaw","exposure":0.5,"contrast":20,"gradeShadows":{"hue":220,"sat":20,"lum":0}}"#
        do {
        let f = try JSONDecoder().decode(AnyFilter.self, from: Data(json.utf8)).filter as? CameraRawFilter
        #expect(f?.settings.exposure == 0.5 && f?.settings.contrast == 20 && f?.settings.gradeShadows.hue == 220)
    }
    }

    /// photocraft's Lens Correction command params (engine `lens_cmds::lens_params`, what a smart
    /// filter stores): `correctCA`, `edge` as a name with `edgeColor`, `profile` as
    /// `none|generic|auto` with `focalLength`; `LensCorrection` encodes the same shape.
    @Test func lensCorrectionCommandParams() throws {
        let dec = JSONDecoder()
        func lens(_ json: String) throws -> LensCorrection? { try dec.decode(AnyFilter.self, from: Data(json.utf8)).filter as? LensCorrection }
        let json = #"{"filter":"lensCorrection","correctCA":false,"distortion":20,"edge":"edgeExtension","profile":"generic","focalLength":16}"#
        #expect(try lens(json) == LensCorrection(profile: Lens.genericProfile(focal35mm: 16), correctCa: false, distortion: 20, edge: .edgeExtension))
        // What the engine stores after `{"profile":"auto","autoScale":true,"edge":"edgeExtension"}` with 24 mm EXIF
        // (`resolved_lens_params`: autoScale / straighten removed, profile / angle / scale resolved).
        let stored = #"{"filter":"lensCorrection","profile":"generic","focalLength":24.0,"edge":"edgeExtension","angle":0.0,"scale":104.5}"#
        #expect(try lens(stored) == LensCorrection(profile: Lens.genericProfile(focal35mm: 24), scale: 104.5, edge: .edgeExtension))
        // Every field defaulted as the engine does.
        #expect(try lens(#"{"filter":"lensCorrection"}"#) == LensCorrection())
        #expect(try lens(##"{"filter":"lensCorrection","edge":"color","edgeColor":"#ff8000"}"##)?.edge == .color(SIMD4(1, 128.0 / 255, 0, 1)))
        // The shape LensCorrection encodes is the engine's, and reads back exactly.
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let lc = LensCorrection(profile: Lens.genericProfile(focal35mm: 35), correctVignette: false, redCyan: -12, vignetteAmount: 30,
                                vertical: -20, angle: 2.5, scale: 110, edge: .color(SIMD4(0.25, 0.5, 0.75, 1)))
        let data = try enc.encode(AnyFilter(lc))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["profile"] as? String == "generic" && object["focalLength"] as? Double == 35 && object["correctCA"] as? Bool == true)
        #expect(object["edge"] as? String == "color" && object["edgeColor"] as? [Double] == [0.25, 0.5, 0.75, 1] && object["correctCa"] == nil)
        #expect(try lens(String(decoding: data, as: UTF8.self)) == lc)
    }
}
