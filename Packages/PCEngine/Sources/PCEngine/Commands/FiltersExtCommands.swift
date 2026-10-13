// Port of photocraft-engine (crates/engine/src/filters_ext.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The second batch of `filter.*` commands: Pixelate, Stylize, Distort (Displace, Shear, ZigZag),
// Render (Fibers, Lens Flare, Lighting Effects, Relight), Reduce Noise, Smart/Lens/Shape Blur,
// Blur Gallery, Other (Custom, HSB/HSL) and Video.
//
// They run through `FilterCommands.runFilter` (selection, smart objects, history and
// `filter.lastFilter` work the same as for every other filter). This module adds what some of
// them need from the session: the foreground/background colours, a displacement map from another
// document or a file, and a layer mask as Lens Blur depth.

import Foundation
import PCAlgo
import PCDocument
import PCFoundation
import PCIOSmart
import PCPlatform
import PCRender

enum FiltersExtCommands: CommandModule {
    static let name = "filters_ext"

    static func register(into r: inout CommandRegistry) {
        r.add(specs())
        // photocraft's dispatch validates new filter invocations before a floating selection
        // drops (jobs.rs `dispatch`); this module registers ahead of FloatCommands.
        FilterValidation.installDispatchCheck(into: &r)
    }

    // MARK: Params (photocraft's tolerant decoding)

    static func f(_ p: JSONValue, _ k: String, _ d: Float) -> Float { FilterCommands.f(p, k, d) }
    static func b(_ p: JSONValue, _ k: String, _ d: Bool) -> Bool { FilterCommands.b(p, k, d) }
    static func s(_ p: JSONValue, _ k: String, _ d: String) -> String { FilterCommands.s(p, k, d) }
    static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { FilterCommands.clamp(v, lo, hi) }

    /// photocraft's `i`: an integer, or a number rounded (saturating like Rust's `as i64`).
    static func i(_ p: JSONValue, _ k: String, _ d: Int64) -> Int64 {
        guard let v = p[k]?.doubleValue, !v.isNaN else { return d }
        let r = v.rounded()
        if r >= 9.223372036854775807e18 { return .max }
        if r <= -9.223372036854775808e18 { return .min }
        return Int64(r)
    }

    /// photocraft's `seed`: `i(p, "seed", 0) as u32` (truncating).
    static func seed(_ p: JSONValue) -> UInt32 { UInt32(truncatingIfNeeded: i(p, "seed", 0)) }

    /// Straight RGBA colour from `[r, g, b(, a)]` (0–1) or `#rrggbb`.
    static func colour(_ p: JSONValue, _ k: String, _ d: SIMD4<Float>) -> SIMD4<Float> {
        switch p[k] {
        case .array(let a)? where a.count >= 3:
            func c(_ j: Int, _ dv: Float) -> Float { a.indices.contains(j) ? (a[j].doubleValue.map { Float($0) } ?? dv) : dv }
            return SIMD4(c(0, 0), c(1, 0), c(2, 0), c(3, 1))
        case .string(let h)? where h.utf8.count == 7 && h.hasPrefix("#"):
            let bytes = Array(h.utf8)
            func ch(_ j: Int) -> Float {
                let pair = String(decoding: bytes[j..<(j + 2)], as: UTF8.self)
                guard pair.utf8.count == 2, let v = UInt8(pair, radix: 16) else { return 0 }
                return Float(v) / 255
            }
            return SIMD4(ch(1), ch(3), ch(5), 1)
        default:
            return d
        }
    }

    static func undefined(_ p: JSONValue, _ d: String) -> UndefinedAreas {
        switch s(p, "undefinedAreas", d) {
        case "repeat": .repeat
        case "transparent": .transparent
        default: .wrap
        }
    }

    /// A JSON array param decoded into `T`s (invalid entries are skipped); nil when none decode.
    static func list<T: Decodable>(_ p: JSONValue, _ k: String, as: T.Type) -> [T]? {
        guard let a = p[k]?.arrayValue else { return nil }
        let v = a.compactMap { try? $0.decode(as: T.self) }
        return v.isEmpty ? nil : v
    }

    static let black = SIMD4<Float>(0, 0, 0, 1)
    static let white = SIMD4<Float>(1, 1, 1, 1)

    /// Algorithm parameters for the ids this module owns (Photoshop dialog units), then Color to
    /// Alpha's and the Filter Gallery's (photocraft `params_for`).
    static func paramsFor(_ id: String, _ p: JSONValue) -> AnyFilter? {
        guard let filter = filter(id, p) else { return ColorToAlphaCommands.paramsFor(id, p) ?? GalleryCommands.paramsFor(id, p) }
        return AnyFilter(filter)
    }

    static func filter(_ id: String, _ p: JSONValue) -> (any Filter)? {
        func blur(_ d: Float) -> Float { clamp(f(p, "blur", d), 0, 500) }
        switch id {
        // ---- Pixelate ----
        case "filter.pixelate.colorHalftone":
            return ColorHalftone(maxRadius: clamp(f(p, "maxRadius", 8), 4, 127),
                                 angles: SIMD4(f(p, "channel1", 108), f(p, "channel2", 162), f(p, "channel3", 90), f(p, "channel4", 45)))
        case "filter.pixelate.crystallize":
            return Crystallize(cellSize: clamp(f(p, "cellSize", 10), 3, 300), seed: seed(p))
        case "filter.pixelate.facet":
            return Facet()
        case "filter.pixelate.fragment":
            return Fragment()
        case "filter.pixelate.mezzotint":
            let kind: MezzotintType = switch s(p, "type", "fineDots") {
            case "mediumDots": .mediumDots
            case "grainyDots": .grainyDots
            case "coarseDots": .coarseDots
            case "shortLines": .shortLines
            case "mediumLines": .mediumLines
            case "longLines": .longLines
            case "shortStrokes": .shortStrokes
            case "mediumStrokes": .mediumStrokes
            case "longStrokes": .longStrokes
            default: .fineDots
            }
            return Mezzotint(kind: kind, seed: seed(p))
        case "filter.pixelate.pointillize":
            return Pointillize(cellSize: clamp(f(p, "cellSize", 5), 3, 300), seed: seed(p), background: colour(p, "background", white))
        // ---- Stylize ----
        case "filter.stylize.diffuse":
            let mode: DiffuseMode = switch s(p, "mode", "normal") {
            case "darkenOnly": .darkenOnly
            case "lightenOnly": .lightenOnly
            case "anisotropic": .anisotropic
            default: .normal
            }
            return Diffuse(mode: mode, seed: seed(p))
        case "filter.stylize.extrude":
            return Extrude(kind: s(p, "type", "blocks") == "pyramids" ? .pyramids : .blocks,
                           size: clamp(f(p, "size", 30), 2, 255),
                           depth: clamp(f(p, "depth", 30), 1, 255),
                           levelBased: s(p, "depthMode", "random") == "levelBased",
                           solidFront: b(p, "solidFrontFaces", false),
                           maskIncomplete: b(p, "maskIncompleteBlocks", false),
                           seed: seed(p))
        case "filter.stylize.oilPaint":
            return OilPaint(stylization: clamp(f(p, "stylization", 4), 0.1, 10),
                            cleanliness: clamp(f(p, "cleanliness", 5), 0, 10),
                            scale: clamp(f(p, "scale", 1), 0.1, 10),
                            bristleDetail: clamp(f(p, "bristleDetail", 5), 0, 10),
                            lighting: b(p, "lighting", true),
                            angle: f(p, "angle", -60),
                            shine: clamp(f(p, "shine", 1), 0, 10))
        case "filter.stylize.tiles":
            let fill: TileFill = switch s(p, "fill", "background") {
            case "foreground": .foreground
            case "inverse": .inverse
            case "unaltered": .unaltered
            default: .background
            }
            return Tiles(count: UInt32(min(max(i(p, "count", 10), 1), 99)),
                         maxOffset: clamp(f(p, "maxOffset", 10), 1, 99),
                         fill: fill,
                         foreground: colour(p, "foreground", black),
                         background: colour(p, "background", white),
                         seed: seed(p))
        case "filter.stylize.traceContour":
            return TraceContour(level: clamp(f(p, "level", 128), 0, 255), upper: s(p, "edge", "lower") == "upper")
        case "filter.stylize.wind":
            let method: WindMethod = switch s(p, "method", "wind") {
            case "blast": .blast
            case "stagger": .stagger
            default: .wind
            }
            return Wind(method: method, fromRight: s(p, "direction", "fromRight") != "fromLeft", seed: seed(p))
        // ---- Distort ----
        case "filter.distort.displace":
            // The map a Displace imported from PSD embeds in its params (PCIO's
            // `DisplaceMap.embeddedMap`, photocraft-io `smart_map::displace_embedded_map`);
            // `mapPath` / `mapDocument` resolve later.
            return Displace(horizontal: clamp(f(p, "horizontal", 10), -999, 999),
                            vertical: clamp(f(p, "vertical", 10), -999, 999),
                            stretch: s(p, "fit", "stretch") != "tile",
                            undefined: undefined(p, "repeat"),
                            map: DisplaceMap.embeddedMap(p))
        case "filter.distort.shear":
            let points = list(p, "points", as: SIMD2<Float>.self) ?? {
                let a = clamp(f(p, "amount", 0), -100, 100) / 100
                return [SIMD2(0, 0), SIMD2(0.5, a), SIMD2(1, 0)]
            }()
            return Shear(points: points, undefined: undefined(p, "wrap"))
        case "filter.distort.zigZag":
            let style: ZigZagStyle = switch s(p, "style", "pondRipples") {
            case "outFromCenter": .outFromCenter
            case "aroundCenter": .aroundCenter
            default: .pondRipples
            }
            return ZigZag(amount: clamp(f(p, "amount", 10), -100, 100), ridges: clamp(f(p, "ridges", 5), 0, 20), style: style)
        // ---- Render ----
        case "filter.render.fibers":
            return Fibers(variance: clamp(f(p, "variance", 16), 1, 64), strength: clamp(f(p, "strength", 4), 1, 64), seed: seed(p),
                          foreground: colour(p, "foreground", black), background: colour(p, "background", white))
        case "filter.render.lensFlare":
            let lens: LensType = switch s(p, "lens", "zoom") {
            case "prime35": .prime35
            case "prime105": .prime105
            case "moviePrime": .moviePrime
            default: .zoom
            }
            return LensFlare(brightness: clamp(f(p, "brightness", 100), 10, 300), centerX: clamp(f(p, "centerX", 0.5), -0.5, 1.5),
                             centerY: clamp(f(p, "centerY", 0.5), -0.5, 1.5), lens: lens)
        case "filter.render.relight":
            return Relight(angle: clamp(f(p, "angle", 45), -180, 180), elevation: clamp(f(p, "elevation", 40), 0, 90),
                           intensity: clamp(f(p, "intensity", 40), 0, 100), ambient: clamp(f(p, "ambient", 55), 0, 100),
                           warmth: clamp(f(p, "warmth", 0), -100, 100), softness: clamp(f(p, "softness", 25), 1, 100))
        case "filter.render.lightingEffects":
            let lights = list(p, "lights", as: Light.self) ?? {
                let kind: LightKind = switch s(p, "lightType", "spot") {
                case "point": .point
                case "infinite": .infinite
                default: .spot
                }
                let c = colour(p, "color", white)
                return [Light(kind: kind, x: f(p, "lightX", 0.25), y: f(p, "lightY", 0.2), z: clamp(f(p, "lightZ", 0.6), 0, 10),
                              targetX: f(p, "targetX", 0.5), targetY: f(p, "targetY", 0.55), angle: f(p, "angle", 135),
                              elevation: clamp(f(p, "elevation", 45), 0, 90), color: SIMD3(c.x, c.y, c.z),
                              intensity: clamp(f(p, "intensity", 75), -100, 100), cone: clamp(f(p, "cone", 45), 1, 89),
                              hotspot: clamp(f(p, "hotspot", 50), 0, 100), radius: clamp(f(p, "radius", 0.8), 0.01, 10))]
            }()
            let texture: TextureChannel = switch s(p, "texture", "none") {
            case "red": .red
            case "green": .green
            case "blue": .blue
            case "alpha": .alpha
            case "luminance": .luminance
            default: .none
            }
            return LightingEffects(lights: lights, gloss: clamp(f(p, "gloss", 0), -100, 100), metallic: clamp(f(p, "metallic", 0), -100, 100),
                                   exposure: clamp(f(p, "exposure", 0), -100, 100), ambience: clamp(f(p, "ambience", 8), -100, 100),
                                   texture: texture, height: clamp(f(p, "height", 50), 0, 100), whiteIsHigh: b(p, "whiteIsHigh", true))
        // ---- Noise ----
        case "filter.noise.reduceNoise":
            return ReduceNoise(strength: clamp(f(p, "strength", 6), 0, 10), preserveDetails: clamp(f(p, "preserveDetails", 60), 0, 100),
                               reduceColorNoise: clamp(f(p, "reduceColorNoise", 45), 0, 100),
                               sharpenDetails: clamp(f(p, "sharpenDetails", 25), 0, 100), removeJpegArtifact: b(p, "removeJpegArtifact", false))
        // ---- Blur ----
        case "filter.blur.smartBlur":
            let quality: BlurQuality = switch s(p, "quality", "high") {
            case "low": .low
            case "medium": .medium
            default: .high
            }
            let mode: SmartBlurMode = switch s(p, "mode", "normal") {
            case "edgeOnly": .edgeOnly
            case "overlayEdge": .overlayEdge
            default: .normal
            }
            return SmartBlur(radius: clamp(f(p, "radius", 3), 0.1, 100), threshold: clamp(f(p, "threshold", 25), 0.1, 100), quality: quality, mode: mode)
        case "filter.blur.lensBlur":
            let blades: UInt32 = switch s(p, "shape", "hexagon") {
            case "triangle": 3
            case "square": 4
            case "pentagon": 5
            case "heptagon": 7
            case "octagon": 8
            default: 6
            }
            let depth: DepthSource = switch s(p, "depthMap", "none") {
            case "transparency": .transparency
            case "layerMask": .layerMask
            default: .none
            }
            return LensBlur(radius: clamp(f(p, "radius", 15), 0, 100), blades: blades, curvature: clamp(f(p, "bladeCurvature", 0), 0, 100),
                            rotation: f(p, "rotation", 0), depth: depth, focalDistance: clamp(f(p, "focalDistance", 0), 0, 255),
                            invertDepth: b(p, "invert", false), brightness: clamp(f(p, "brightness", 0), 0, 100),
                            threshold: clamp(f(p, "threshold", 255), 0, 255), noise: clamp(f(p, "noise", 0), 0, 100),
                            distribution: s(p, "distribution", "uniform") == "gaussian" ? .gaussian : .uniform,
                            monochromatic: b(p, "monochromatic", false), seed: seed(p), depthMap: nil)
        case "filter.blur.shapeBlur":
            let shape: BlurShape = switch s(p, "shape", "circle") {
            case "ring": .ring
            case "square": .square
            case "diamond": .diamond
            case "triangle": .triangle
            case "hexagon": .hexagon
            case "star": .star
            case "heart": .heart
            case "cross": .cross
            default: .circle
            }
            return ShapeBlur(radius: clamp(f(p, "radius", 10), 5, 1000), shape: shape)
        // ---- Blur Gallery ----
        case "filter.blurGallery.tiltShift":
            return TiltShift(blur: blur(15), centerX: f(p, "centerX", 0.5), centerY: f(p, "centerY", 0.5), angle: f(p, "angle", 0),
                             focus: clamp(f(p, "focus", 0.1), 0, 2), transition: clamp(f(p, "transition", 0.15), 0.001, 2))
        case "filter.blurGallery.irisBlur":
            let pins = list(p, "pins", as: IrisPin.self) ?? [
                IrisPin(x: f(p, "centerX", 0.5), y: f(p, "centerY", 0.5), radiusX: max(f(p, "radiusX", 0.35), 0.001),
                        radiusY: max(f(p, "radiusY", 0.25), 0.001), angle: f(p, "angle", 0), roundness: clamp(f(p, "roundness", 0), 0, 100),
                        feather: clamp(f(p, "feather", 0.5), 0, 0.99), blur: blur(15)),
            ]
            return IrisBlur(pins: pins)
        case "filter.blurGallery.fieldBlur":
            let pins = list(p, "pins", as: FieldPin.self) ?? [FieldPin(x: f(p, "centerX", 0.5), y: f(p, "centerY", 0.5), blur: blur(15))]
            return FieldBlur(pins: pins)
        case "filter.blurGallery.spinBlur":
            func finiteClamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { v.isFinite ? clamp(v, lo, hi) : 0 }
            let pins: [SpinPin]
            if var v = list(p, "pins", as: SpinPin.self) {
                for k in v.indices {
                    v[k].angle = finiteClamp(v[k].angle, -360, 360)
                    v[k].blurAngle = finiteClamp(v[k].blurAngle, 0, 360)
                }
                pins = v
            } else {
                pins = [SpinPin(x: f(p, "centerX", 0.5), y: f(p, "centerY", 0.5), radiusX: max(f(p, "radiusX", 0.3), 0.001),
                                radiusY: max(f(p, "radiusY", 0.3), 0.001), angle: finiteClamp(f(p, "angle", 0), -360, 360),
                                blurAngle: clamp(f(p, "blurAngle", 15), 0, 360))]
            }
            return SpinBlur(pins: pins)
        case "filter.blurGallery.pathBlur":
            let paths: [BlurPath]
            if var v = list(p, "paths", as: BlurPath.self) {
                // Entry speeds bypass the scalar clamp; the halo casts one to i32 and adds, so an
                // unclamped value overflows (#708).
                for k in v.indices { v[k].speed = clamp(v[k].speed, 0, 500) }
                paths = v
            } else {
                paths = [BlurPath(points: [SIMD2(f(p, "startX", 0.2), f(p, "startY", 0.5)), SIMD2(f(p, "endX", 0.8), f(p, "endY", 0.5))],
                                  speed: clamp(f(p, "speed", 50), 0, 500), taper: clamp(f(p, "taper", 0), 0, 100))]
            }
            return PathBlur(paths: paths)
        // ---- Other ----
        case "filter.other.custom":
            let kernel = p["kernel"]?.arrayValue.map { a in a.prefix(25).map { Float(min(max($0.doubleValue ?? 0, -999), 999)) } }
                ?? (0..<25).map { $0 == 12 ? 1 : 0 }
            return CustomKernel(kernel: kernel, scale: clamp(f(p, "scale", 1), 1, 9999), offset: clamp(f(p, "offset", 0), -9999, 9999))
        case "filter.other.hsbHsl":
            func m(_ k: String, _ d: String) -> HsbModel {
                switch s(p, k, d) {
                case "hsb": .hsb
                case "hsl": .hsl
                default: .rgb
                }
            }
            return HsbHsl(input: m("inputMode", "rgb"), output: m("rowOrder", "hsb"))
        // ---- Video ----
        case "filter.video.deInterlace":
            return DeInterlace(eliminateEven: s(p, "eliminate", "oddFields") == "evenFields", interpolate: s(p, "createBy", "interpolation") != "duplication")
        case "filter.video.ntscColors":
            return NTSCColors()
        default:
            return nil
        }
    }

    // MARK: Session inputs

    /// Ids whose rendering uses the foreground/background colours.
    static func usesColours(_ id: String) -> Bool {
        ["filter.render.fibers", "filter.stylize.tiles", "filter.pixelate.pointillize"].contains(id) || GalleryCommands.usesColours(id)
    }

    /// Fills in session state a filter reads (the current colours) as explicit params, so the
    /// recorded params (journal, smart filters) reproduce the result (photocraft `prepare`).
    static func prepare(_ s: Session, _ id: String, _ p: JSONValue) -> JSONValue {
        var o = p.objectValue ?? [:]
        if usesColours(id) {
            if o["foreground"] == nil { o["foreground"] = .rgba(s.tools.foreground) }
            if o["background"] == nil { o["background"] = .rgba(s.tools.background) }
        }
        return .object(o)
    }

    /// A flattened document (or one of its layers) as an RGBA map image (photocraft
    /// `map_from_document`).
    static func mapFromDocument(_ doc: Document, layer: UInt64?, renderer: EngineRenderer) throws -> FloatImage? {
        let buf: RGBABuffer
        do {
            if let id = layer, let l = doc.layer(LayerId(id)) {
                // photocraft `render_layer`: the layer alone, over its pixels' bounds.
                let rect = l.surface.map(\.contentBounds).flatMap { $0.isEmpty ? nil : $0 } ?? doc.bounds
                var solo = doc
                solo.layers = [l]
                buf = try renderer.render(solo, region: rect)
            } else {
                buf = try renderer.render(doc, region: doc.bounds)
            }
        } catch {
            throw EngineError.wrap(error)
        }
        if buf.rect.isEmpty { return nil }
        var data: [Float] = []
        data.reserveCapacity(buf.px.count * 4)
        for c in buf.px { data += [c.x, c.y, c.z, c.w] }
        return FloatImage(rect: buf.rect, channels: 4, data: data)
    }

    /// Resolves inputs that live outside the target layer: Displace's map (`mapPath`, or
    /// `mapDocument` index or name with optional `mapLayer` id) (photocraft `resolve`).
    static func resolve(_ s: Session, _ f: inout AnyFilter, _ p: JSONValue) throws {
        guard var d = f.filter as? Displace, d.map == nil else { return }
        let layer = p["mapLayer"]?.uint64Value
        let img: FloatImage?
        if let path = mapPath(p) {
            img = try mapFromPath(path, layer: layer, services: s.services)
        } else if let v = p["mapDocument"] {
            let docs = s.documents
            let found: DocState? = switch v {
            case .string(let name): docs.first { $0.doc.name == name || $0.path == name }
            default: v.uint64Value.flatMap { k in k < UInt64(docs.count) ? docs[Int(k)] : nil }
            }
            guard let ds = found else { throw EngineError.other("displacement map document not found") }
            img = try mapFromDocument(ds.doc, layer: layer, renderer: s.services.renderer)
        } else {
            throw EngineError.other("Displace needs a displacement map: pass `mapPath` or `mapDocument`")
        }
        guard let img else { throw EngineError.other("the displacement map is empty") }
        d.map = img
        f = AnyFilter(d)
    }

    static func mapPath(_ p: JSONValue) -> String? {
        guard let path = p["mapPath"]?.stringValue, !path.isEmpty else { return nil }
        return path
    }

    /// Displace's map read from a file (photocraft `map_from_path`): the file imported through
    /// PCIO (flat or layered) and rendered like a `mapDocument` — its composite, or the layer
    /// `mapLayer` names.
    static func mapFromPath(_ path: String, layer: UInt64?, services: EngineServices) throws -> FloatImage? {
        let data: Data
        do { data = try services.fileSystem.read(path) } catch {
            let why = if case EngineError.other(let m)? = error as? EngineError { m } else { "\(error)" }
            throw EngineError.other("cannot read displacement map `\(path)`: \(why)")
        }
        let imported: Document
        do {
            let r = try EngineIO.importFile(name: path, bytes: [UInt8](data), services: services)
            if r.previewOnly { throw EngineError.other("only this Affinity file's embedded preview could be read") }
            imported = r.document
        } catch {
            throw EngineError.other("cannot open displacement map `\(path)`: \(EngineError.wrap(error))")
        }
        return try mapFromDocument(imported, layer: layer, renderer: services.renderer)
    }

    /// The session-free part of `resolve`: Displace's `mapPath` (photocraft `resolve_map_path`).
    /// Smart filters record params, not the map, so their re-render reads the map again here;
    /// without it the filter passes the pixels through. `mapDocument` needs the session and is left
    /// unresolved. Callers with a session pass its file service.
    static func resolveMapPath(_ f: inout AnyFilter, _ p: JSONValue, fs: any FileSystemService = LocalFileSystem()) throws {
        try resolveMapPath(&f, p, services: EngineServices(fileSystem: fs))
    }

    /// `resolveMapPath` with a session's services (its file access and renderer).
    static func resolveMapPath(_ f: inout AnyFilter, _ p: JSONValue, services: EngineServices) throws {
        guard var d = f.filter as? Displace, d.map == nil, let path = mapPath(p) else { return }
        d.map = try mapFromPath(path, layer: p["mapLayer"]?.uint64Value, services: services)
        f = AnyFilter(d)
    }

    /// Resolves inputs read from the target layer itself: the layer mask as Lens Blur depth
    /// (photocraft `resolve_in_layer`).
    static func resolveInLayer(_ f: inout AnyFilter, _ layer: Layer, bounds: PixelRect) {
        guard var lb = f.filter as? LensBlur, lb.depth == .layerMask, lb.depthMap == nil, let m = layer.mask else { return }
        lb.depthMap = FloatImage(surface: m.surface, rect: bounds)
        f = AnyFilter(lb)
    }

    // MARK: Relight

    static let relightId = "filter.render.relight"

    static func relightBad(_ msg: String) -> EngineError { .bad(relightId, msg) }

    /// Rust's `{}` for a float: whole numbers without a fraction.
    static func display(_ x: Float) -> String {
        if x.isFinite, x == x.rounded(), abs(x) < 1e15 { return String(Int64(x)) }
        return "\(x)"
    }

    @discardableResult
    static func relightNum(_ p: JSONValue, _ key: String, _ d: Float, _ lo: Float, _ hi: Float) throws -> Float {
        guard let v = p[key] else { return d }
        guard case .number(let n) = v else { throw relightBad("\"\(key)\" must be a number") }
        let x = Float(n)
        if !x.isFinite { throw relightBad("\"\(key)\" must be finite") }
        if x < lo || x > hi { throw relightBad("\"\(key)\" must be in \(display(lo))..\(display(hi))") }
        return x
    }

    /// Relight's own strict params check (photocraft `validate_relight`).
    static func validateRelight(_ p: JSONValue) throws {
        guard p.objectValue != nil else { throw relightBad("params must be a JSON object") }
        try relightNum(p, "angle", 45, -180, 180)
        try relightNum(p, "elevation", 40, 0, 90)
        try relightNum(p, "intensity", 40, 0, 100)
        try relightNum(p, "ambient", 55, 0, 100)
        try relightNum(p, "warmth", 0, -100, 100)
        try relightNum(p, "softness", 25, 1, 100)
    }

    /// photocraft `relight_enabled`: a filterable layer whose pixels aren't locked.
    static let relightEnabled: CommandEnabled = { s, p in
        if let why = FilterCommands.hasFilterableLayer(s, p) { return why }
        if Channels.editsChannel(s) { return nil }
        let l: Layer
        switch s.activeLayer() {
        case .success(let x): l = x
        case .failure(let e): return e.description
        }
        guard let st = s.active else { return "no document open" }
        let locks = st.doc.effectiveLocks(l.id)
        return locks.pixels || locks.all ? "the layer \"\(l.name)\" is locked" : nil
    }

    // MARK: Specs

    static func cmd(_ id: String, _ label: String, _ menu: [String], _ params: String) -> CommandSpec {
        CommandSpec(id, label, menu: menu, params: params, module: name, enabled: FilterCommands.hasFilterableLayer) { s, p in
            try FilterCommands.runFilter(s, id, p)
        }
    }

    /// The command specs of this batch.
    static func specs() -> [CommandSpec] {
        [
            // Pixelate
            cmd("filter.pixelate.colorHalftone", "Color Halftone…", ["Filter", "Pixelate"],
                ##"{"maxRadius":4..127=8,"channel1":-360..360=108,"channel2":-360..360=162,"channel3":-360..360=90,"channel4":-360..360=45}"##),
            cmd("filter.pixelate.crystallize", "Crystallize…", ["Filter", "Pixelate"], ##"{"cellSize":3..300=10,"seed":u32=0}"##),
            cmd("filter.pixelate.facet", "Facet", ["Filter", "Pixelate"], "{}"),
            cmd("filter.pixelate.fragment", "Fragment", ["Filter", "Pixelate"], "{}"),
            cmd("filter.pixelate.mezzotint", "Mezzotint…", ["Filter", "Pixelate"],
                ##"{"type":"fineDots|mediumDots|grainyDots|coarseDots|shortLines|mediumLines|longLines|shortStrokes|mediumStrokes|longStrokes","seed":u32=0}"##),
            cmd("filter.pixelate.pointillize", "Pointillize…", ["Filter", "Pixelate"], ##"{"cellSize":3..300=5,"seed":u32=0,"background":json}"##),
            // Stylize
            cmd("filter.stylize.diffuse", "Diffuse…", ["Filter", "Stylize"], ##"{"mode":"normal|darkenOnly|lightenOnly|anisotropic","seed":u32=0}"##),
            cmd("filter.stylize.extrude", "Extrude…", ["Filter", "Stylize"],
                ##"{"type":"blocks|pyramids","size":2..255=30,"depth":1..255=30,"depthMode":"random|levelBased","solidFrontFaces":bool,"maskIncompleteBlocks":bool,"seed":u32=0}"##),
            cmd("filter.stylize.oilPaint", "Oil Paint…", ["Filter", "Stylize"],
                ##"{"stylization":0.1..10=4,"cleanliness":0..10=5,"scale":0.1..10=1,"bristleDetail":0..10=5,"lighting":bool=true,"angle":-180..180=-60,"shine":0..10=1}"##),
            cmd("filter.stylize.tiles", "Tiles…", ["Filter", "Stylize"],
                ##"{"count":1..99=10,"maxOffset":1..99=10,"fill":"background|foreground|inverse|unaltered","seed":u32=0,"foreground":json,"background":json}"##),
            cmd("filter.stylize.traceContour", "Trace Contour…", ["Filter", "Stylize"], ##"{"level":0..255=128,"edge":"lower|upper"}"##),
            cmd("filter.stylize.wind", "Wind…", ["Filter", "Stylize"], ##"{"method":"wind|blast|stagger","direction":"fromRight|fromLeft","seed":u32=0}"##),
            // Distort
            cmd("filter.distort.displace", "Displace…", ["Filter", "Distort"],
                ##"{"horizontal":-999..999=10,"vertical":-999..999=10,"fit":"stretch|tile","undefinedAreas":"repeat|wrap","mapDocument":doc,"mapPath":text,"mapLayer":json}"##),
            cmd("filter.distort.shear", "Shear…", ["Filter", "Distort"], ##"{"amount":-100..100=0,"undefinedAreas":"wrap|repeat","points":json}"##),
            cmd("filter.distort.zigZag", "ZigZag…", ["Filter", "Distort"],
                ##"{"amount":-100..100=10,"ridges":0..20=5,"style":"pondRipples|outFromCenter|aroundCenter"}"##),
            // Render
            cmd("filter.render.fibers", "Fibers…", ["Filter", "Render"],
                ##"{"variance":1..64=16,"strength":1..64=4,"seed":u32=0,"foreground":json,"background":json}"##),
            cmd("filter.render.lensFlare", "Lens Flare…", ["Filter", "Render"],
                ##"{"brightness":10..300=100,"centerX":0..1=0.5,"centerY":0..1=0.5,"lens":"zoom|prime35|prime105|moviePrime"}"##),
            cmd("filter.render.lightingEffects", "Lighting Effects…", ["Filter", "Render"],
                ##"{"lightType":"spot|point|infinite","intensity":-100..100=75,"lightX":0..1=0.25,"lightY":0..1=0.2,"lightZ":0..2=0.6,"targetX":0..1=0.5,"targetY":0..1=0.55,"cone":1..89=45,"hotspot":0..100=50,"angle":-180..180=135,"elevation":0..90=45,"gloss":-100..100=0,"metallic":-100..100=0,"exposure":-100..100=0,"ambience":-100..100=8,"texture":"none|red|green|blue|alpha|luminance","height":0..100=50,"whiteIsHigh":bool=true,"lights":json}"##),
            CommandSpec(relightId, "Relight…", menu: ["Filter", "Render"],
                        params: ##"{"angle":-180..180=45,"elevation":0..90=40,"intensity":0..100=40,"ambient":0..100=55,"warmth":-100..100=0,"softness":1..100=25}"##,
                        module: name, enabled: relightEnabled) { s, p in
                try validateRelight(p)
                return try FilterCommands.runFilter(s, relightId, p)
            },
            // Noise
            cmd("filter.noise.reduceNoise", "Reduce Noise…", ["Filter", "Noise"],
                ##"{"strength":0..10=6,"preserveDetails":0..100=60,"reduceColorNoise":0..100=45,"sharpenDetails":0..100=25,"removeJpegArtifact":bool}"##),
            // Blur
            cmd("filter.blur.smartBlur", "Smart Blur…", ["Filter", "Blur"],
                ##"{"radius":0.1..100=3,"threshold":0.1..100=25,"quality":"high|medium|low","mode":"normal|edgeOnly|overlayEdge"}"##),
            cmd("filter.blur.lensBlur", "Lens Blur…", ["Filter", "Blur"],
                ##"{"radius":0..100=15,"shape":"hexagon|triangle|square|pentagon|heptagon|octagon","bladeCurvature":0..100=0,"rotation":0..360=0,"depthMap":"none|transparency|layerMask","focalDistance":0..255=0,"invert":bool,"brightness":0..100=0,"threshold":0..255=255,"noise":0..100=0,"distribution":"uniform|gaussian","monochromatic":bool,"seed":u32=0}"##),
            cmd("filter.blur.shapeBlur", "Shape Blur…", ["Filter", "Blur"],
                ##"{"radius":5..1000=10,"shape":"circle|ring|square|diamond|triangle|hexagon|star|heart|cross"}"##),
            // Blur Gallery
            cmd("filter.blurGallery.tiltShift", "Tilt-Shift…", ["Filter", "Blur Gallery"],
                ##"{"blur":0..500=15,"centerX":0..1=0.5,"centerY":0..1=0.5,"angle":-90..90=0,"focus":0..1=0.1,"transition":0.01..1=0.15}"##),
            cmd("filter.blurGallery.irisBlur", "Iris Blur…", ["Filter", "Blur Gallery"],
                ##"{"blur":0..500=15,"centerX":0..1=0.5,"centerY":0..1=0.5,"radiusX":0.01..1=0.35,"radiusY":0.01..1=0.25,"angle":-180..180=0,"roundness":0..100=0,"feather":0..0.99=0.5,"pins":json}"##),
            cmd("filter.blurGallery.fieldBlur", "Field Blur…", ["Filter", "Blur Gallery"],
                ##"{"blur":0..500=15,"centerX":0..1=0.5,"centerY":0..1=0.5,"pins":json}"##),
            cmd("filter.blurGallery.spinBlur", "Spin Blur…", ["Filter", "Blur Gallery"],
                ##"{"blurAngle":0..360=15,"centerX":0..1=0.5,"centerY":0..1=0.5,"radiusX":0.01..1=0.3,"radiusY":0.01..1=0.3,"angle":-180..180=0,"pins":json}"##),
            cmd("filter.blurGallery.pathBlur", "Path Blur…", ["Filter", "Blur Gallery"],
                ##"{"speed":0..500=50,"taper":0..100=0,"startX":0..1=0.2,"startY":0..1=0.5,"endX":0..1=0.8,"endY":0..1=0.5,"paths":json}"##),
            // Other
            cmd("filter.other.custom", "Custom…", ["Filter", "Other"], ##"{"kernel":int[25],"scale":1..9999=1,"offset":-9999..9999=0}"##),
            cmd("filter.other.hsbHsl", "HSB/HSL", ["Filter", "Other"], ##"{"inputMode":"rgb|hsb|hsl","rowOrder":"hsb|hsl|rgb"}"##),
            // Video
            cmd("filter.video.deInterlace", "De-Interlace…", ["Filter", "Video"],
                ##"{"eliminate":"oddFields|evenFields","createBy":"interpolation|duplication"}"##),
            cmd("filter.video.ntscColors", "NTSC Colors", ["Filter", "Video"], "{}"),
        ]
    }
}
