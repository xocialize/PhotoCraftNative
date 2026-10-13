// Port of photocraft-io (crates/io/src/ora.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// OpenRaster (`.ora`) read and write. Layout from the public OpenRaster specification
// (https://www.openraster.org/, `stack.xml` 0.0.x): a ZIP whose first, stored entry is `mimetype`
// = `image/openraster`, a `stack.xml` layer tree, one PNG per layer, and a `mergedimage.png` /
// `Thumbnails/thumbnail.png` rendering.
//
// Read: raster layers (PNG, any position and size), groups (isolated and pass-through), names,
// opacity, visibility, `svg:*` and Krita's `krita:*` composite operations, and the `edit-locked`
// / `alpha-preserve` flags. Everything else is skipped with a warning.
// Write: raster layers and groups as above; other layer kinds are written as their rendered
// pixels, layer masks are applied to the pixels, and whatever ORA cannot hold is warned about.
//
// The layer PNGs go through the injected `FlatImageCodec`; the merged image, the thumbnail and
// the pixels of non-raster layers come from the injected `DocumentCompositor` (photocraft calls
// `photocraft_compose::{flatten, thumbnail, render_layer, composite_bounds}` there). `stack.xml`
// is parsed with Foundation's `XMLParser` (photocraft uses `roxmltree`), external entities off.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore

/// OpenRaster import and export.
public enum OpenRaster {
    /// The `mimetype` entry of an OpenRaster archive.
    public static let mimetype: [UInt8] = Array("image/openraster".utf8)
    /// Decoded pixels across every layer (and the stack.xml) are capped, as for PDN.
    static let maxPixelBytes = 1 << 30
    /// Canvas side limit (Photoshop's PSB limit).
    static let maxSide = 300_000
    /// Layers and groups in one document.
    static let maxNodes = 8192
    static let maxStackXML = 16 << 20
    static let maxEntry = 512 << 20
    static let thumbnailSide = 256

    static func invalid(_ message: String) -> PCIOError { .format("OpenRaster", message) }

    /// `true` for an OpenRaster archive (by its `mimetype` entry, a stored first ZIP entry).
    public static func isORA(_ bytes: [UInt8]) -> Bool {
        ZipReader.mimetype(bytes) == mimetype
    }

    /// Blend modes by Krita composite-op id: Krita's `.kra` `compositeop` attribute and the
    /// `krita:<id>` composite operations Krita writes into ORA for modes SVG has no name for.
    /// Returns the mode and whether it only approximates Krita's formula.
    public static func kritaBlend(_ id: String) -> (mode: BlendMode, approximate: Bool)? {
        switch id {
        case "normal": (.normal, false)
        case "multiply": (.multiply, false)
        case "screen": (.screen, false)
        case "overlay": (.overlay, false)
        case "darken": (.darken, false)
        case "lighten": (.lighten, false)
        case "dodge": (.colorDodge, false)
        case "burn": (.colorBurn, false)
        case "hard_light": (.hardLight, false)
        case "soft_light": (.softLight, false)
        // The W3C soft light curve, close to but not Photoshop's.
        case "soft_light_svg": (.softLight, true)
        case "diff": (.difference, false)
        case "exclusion": (.exclusion, false)
        case "linear_burn": (.linearBurn, false)
        case "linear_dodge", "add": (.linearDodge, false)
        case "subtract": (.subtract, false)
        case "divide": (.divide, false)
        case "vivid_light": (.vividLight, false)
        case "linear light": (.linearLight, false)
        case "pin_light": (.pinLight, false)
        case "hard_mix_photoshop": (.hardMix, false)
        // Krita's own Hard Mix thresholds differently from Photoshop's.
        case "hard mix": (.hardMix, true)
        case "darker color": (.darkerColor, false)
        case "lighter color": (.lighterColor, false)
        case "hue": (.hue, false)
        case "saturation": (.saturation, false)
        case "color": (.color, false)
        case "luminize": (.luminosity, false)
        case "dissolve": (.dissolve, false)
        case "reflect": (.reflect, false)
        case "glow": (.glow, false)
        case "negation": (.negation, false)
        case "xor": (.xor, true)
        default: nil
        }
    }

    /// The Krita composite-op id written for `mode` (nil for modes Krita has no counterpart for).
    public static func kritaID(_ mode: BlendMode) -> String? {
        switch mode {
        case .normal, .passThrough: "normal"
        case .dissolve: "dissolve"
        case .darken: "darken"
        case .multiply: "multiply"
        case .colorBurn: "burn"
        case .linearBurn: "linear_burn"
        case .darkerColor: "darker color"
        case .lighten: "lighten"
        case .screen: "screen"
        case .colorDodge: "dodge"
        case .linearDodge: "linear_dodge"
        case .lighterColor: "lighter color"
        case .overlay: "overlay"
        case .softLight: "soft_light"
        case .hardLight: "hard_light"
        case .vividLight: "vivid_light"
        case .linearLight: "linear light"
        case .pinLight: "pin_light"
        case .hardMix: "hard_mix_photoshop"
        case .difference: "diff"
        case .exclusion: "exclusion"
        case .subtract: "subtract"
        case .divide: "divide"
        case .hue: "hue"
        case .saturation: "saturation"
        case .color: "color"
        case .luminosity: "luminize"
        case .reflect: "reflect"
        case .glow: "glow"
        case .negation: "negation"
        case .xor, .paintNetColorBurn, .paintNetColorDodge: nil
        }
    }

    /// The SVG compositing names of the OpenRaster specification.
    static let svgOps: [(name: String, mode: BlendMode)] = [
        ("svg:src-over", .normal),
        ("svg:multiply", .multiply),
        ("svg:screen", .screen),
        ("svg:overlay", .overlay),
        ("svg:darken", .darken),
        ("svg:lighten", .lighten),
        ("svg:color-dodge", .colorDodge),
        ("svg:color-burn", .colorBurn),
        ("svg:hard-light", .hardLight),
        ("svg:soft-light", .softLight),
        ("svg:difference", .difference),
        ("svg:color", .color),
        ("svg:luminosity", .luminosity),
        ("svg:hue", .hue),
        ("svg:saturation", .saturation),
    ]

    /// A composite-op attribute as a blend mode; unknown names fall back to Normal with a warning.
    private static func compositeOp(_ op: String, _ layer: String, _ warnings: inout Warnings) -> BlendMode {
        if let hit = svgOps.first(where: { $0.name == op }) {
            if op == "svg:soft-light" {
                warnings.note("svg:soft-light (the W3C curve) opens as Photoshop's Soft Light, which differs slightly")
            }
            return hit.mode
        }
        switch op {
        case "svg:plus": return .linearDodge
        // Not in the specification's list, but written by several applications.
        case "svg:exclusion": return .exclusion
        default: break
        }
        if op.hasPrefix("krita:"), let (mode, approx) = kritaBlend(String(op.dropFirst(6))) {
            if approx {
                warnings.note("Krita's \(op) blend mode is approximated by \(mode.label)")
            }
            return mode
        }
        warnings.layer(layer, "composite operation \(op) is not supported; it opens as Normal")
        return .normal
    }

    /// Warnings gathered during import, each distinct message once; per-layer ones are grouped.
    struct Warnings {
        var general: [String] = []
        var perLayer: [(message: String, layers: [String])] = []

        mutating func note(_ message: String) {
            if !general.contains(message) { general.append(message) }
        }

        mutating func layer(_ layer: String, _ message: String) {
            if let i = perLayer.firstIndex(where: { $0.message == message }) {
                if !perLayer[i].layers.contains(layer) { perLayer[i].layers.append(layer) }
            } else {
                perLayer.append((message, [layer]))
            }
        }

        func finish() -> [String] {
            var out = general
            for (message, layers) in perLayer {
                let shown = layers.prefix(5).map { "\"\($0)\"" }
                let more = max(0, layers.count - 5)
                let tail = more > 0 ? " and \(more) more" : ""
                out.append("\(message) (\(shown.joined(separator: ", "))\(tail))")
            }
            return out
        }
    }

    // MARK: - Attribute parsing

    /// A number attribute; a missing one is `default`, an unparsable one an error.
    private static func num(_ node: StackXMLNode, _ name: String, _ defaultValue: Double) throws -> Double {
        guard let v = node.attributes[name] else { return defaultValue }
        guard let d = parseFloat(v), d.isFinite else { throw invalid("invalid \(name) attribute `\(v)`") }
        return d
    }

    private static func int(_ node: StackXMLNode, _ name: String) throws -> Int32 {
        let v = try num(node, name, 0).rounded()
        if abs(v) > Double(maxSide) * 4 {
            throw invalid("\(name) offset \(rustDisplay(v)) is out of range")
        }
        return Int32(v)
    }

    private static func flag(_ node: StackXMLNode, _ name: String) -> Bool {
        guard let v = node.attributes[name] else { return false }
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return t == "true" || t == "1"
    }

    /// Shared node properties: name, visibility, opacity and composite operation.
    private static func props(_ node: StackXMLNode, _ layer: inout Layer, _ index: Int, _ warnings: inout Warnings) throws {
        if let name = node.attributes["name"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            layer.name = name
        } else {
            layer.name = "Layer \(index)"
        }
        layer.visible = node.attributes["visibility"].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) != "hidden" } ?? true
        layer.opacity = Float(min(max(try num(node, "opacity", 1), 0), 1))
        let op = node.attributes["composite-op"].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "svg:src-over"
        layer.blend = compositeOp(op, layer.name, &warnings)
        if flag(node, "edit-locked") { layer.locks.all = true }
        if flag(node, "alpha-preserve") { layer.locks.transparency = true }
    }

    // MARK: - Import

    /// A layer as read, before its pixels are converted to the document's format.
    private indirect enum Node {
        case raster(layer: Layer, image: Int?, x: Int32, y: Int32)
        case group(layer: Layer, children: [Node])
    }

    private struct Reader {
        let zip: ZipReader
        let codec: any FlatImageCodec
        let ctl: Interrupt
        var nodes = 0
        var budget = OpenRaster.maxPixelBytes
        var warnings = Warnings()
        /// Decoded layer images, converted to the document depth once every layer is known.
        var images: [DecodedImage] = []

        mutating func png(_ src: String, _ layer: String) throws -> Int? {
            guard let entry = zip.find(src) else {
                warnings.layer(layer, "the layer's image is missing from the archive; the layer opens empty")
                return nil
            }
            let data: [UInt8]
            do { data = try zip.read(entry, max: OpenRaster.maxEntry) } catch { throw invalid("\(src): \(errorText(error))") }
            // The decoder limits photocraft passes (300,000 px a side, the remaining pixel budget),
            // checked from the PNG header before anything is decoded.
            if let header = OpenRaster.pngHeader(data) {
                if let e = OpenRaster.limitError(header, maxAlloc: budget) { throw invalid("\(src): \(e)") }
            }
            let image: DecodedImage
            do { image = try codec.decode(data) } catch { throw invalid("\(src): \(errorText(error))") }
            let (w, h) = (image.width, image.height)
            if w < 1 || h < 1 || w > OpenRaster.maxSide || h > OpenRaster.maxSide {
                throw invalid("\(src): limit exceeded: dimensions \(w)x\(h) exceed max \(OpenRaster.maxSide)x\(OpenRaster.maxSide)")
            }
            let (n, o1) = w.multipliedReportingOverflow(by: h)
            let (rgba16, o2) = n.multipliedReportingOverflow(by: 8)
            guard !o1, !o2 else { throw invalid("layer image size overflow") }
            guard rgba16 <= budget else { throw invalid("decoded layers exceed the 1 GiB limit") }
            budget -= rgba16
            if !OpenRaster.isPNG(data) {
                warnings.note("some layer images are not PNG, as OpenRaster expects; they were read anyway")
            }
            images.append(image)
            return images.count - 1
        }

        mutating func stack(_ stack: StackXMLNode, _ depth: Int) throws -> [Node] {
            if depth > maxGroupDepthLimit {
                throw PCIOError.unsupported("layer groups nested deeper than \(maxGroupDepthLimit)")
            }
            var out: [Node] = []
            for child in stack.children {
                try ctl.check()
                nodes += 1
                if nodes > OpenRaster.maxNodes {
                    throw invalid("more than \(OpenRaster.maxNodes) layers")
                }
                let index = nodes
                switch child.name {
                case "layer":
                    var layer = Layer.raster("", format: .rgba8)
                    try OpenRaster.props(child, &layer, index, &warnings)
                    let x = try OpenRaster.int(child, "x"), y = try OpenRaster.int(child, "y")
                    let image: Int?
                    if let src = child.attributes["src"] {
                        image = try png(src.trimmingCharacters(in: .whitespacesAndNewlines), layer.name)
                    } else {
                        warnings.layer(layer.name, "the layer has no image; it opens empty")
                        image = nil
                    }
                    out.append(.raster(layer: layer, image: image, x: x, y: y))
                case "stack":
                    var layer = Layer.group("", [])
                    try OpenRaster.props(child, &layer, index, &warnings)
                    // `auto` (the default) isolates only when something needs it: an OpenRaster
                    // group without its own blend mode is a pass-through group.
                    let isolate = child.attributes["isolation"]?.trimmingCharacters(in: .whitespacesAndNewlines) == "isolate"
                    if !isolate && layer.blend == .normal {
                        layer.blend = .passThrough
                    }
                    let children = try self.stack(child, depth + 1)
                    out.append(.group(layer: layer, children: children))
                default:
                    let name = child.attributes["name"] ?? child.name
                    warnings.layer(name, "OpenRaster <\(child.name)> elements are not supported and were skipped")
                }
            }
            return out
        }
    }

    /// Sample depth of the document: the deepest layer image (8 or 16 bit; float stays float).
    private static func documentDepth(_ images: [DecodedImage]) -> SampleType {
        images.reduce(SampleType.u8) { d, i in
            let s = i.surface.format.sample
            if d == .f32 || s == .f32 { return .f32 }
            if d == .u16 || s == .u16 { return .u16 }
            return .u8
        }
    }

    /// Builds the document tree bottom-to-top (stack.xml lists the topmost node first).
    private static func build(_ nodes: [Node], _ images: [DecodedImage], _ fmt: PixelFormat, _ ctl: Interrupt) throws -> [Layer] {
        var out: [Layer] = []
        out.reserveCapacity(nodes.count)
        for node in nodes.reversed() {
            try ctl.check()
            switch node {
            case .raster(var layer, let image, let x, let y):
                var surface = Surface(format: fmt)
                if let i = image, i >= 0, i < images.count {
                    let img = images[i]
                    let (w, h) = (img.width, img.height)
                    let rect = PixelRect(x0: x, y0: y, x1: Int32(clamping: Int(x) + w), y1: Int32(clamping: Int(y) + h))
                    if rect.width != w || rect.height != h {
                        throw invalid("layer image does not fit its position")
                    }
                    writeConverted(img.surface, w, h, into: &surface, at: rect)
                    surface.prune()
                }
                layer.content = .raster(surface)
                out.append(layer)
            case .group(var layer, let children):
                let built = try build(children, images, fmt, ctl)
                layer.withChildren { $0 = built }
                out.append(layer)
            }
        }
        return out
    }

    /// The decoded image's (0, 0)–(w, h) written over `rect` of `dst` as RGBA in `dst`'s depth,
    /// a band of rows at a time (photocraft `Image::convert(Rgba, depth)`).
    static func writeConverted(_ src: Surface, _ w: Int, _ h: Int, into dst: inout Surface, at rect: PixelRect) {
        guard w > 0, h > 0 else { return }
        if src.format == dst.format {
            dst.writeInterleaved(rect, src.readInterleaved(PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h))))
            return
        }
        let rows = max(1, (32 << 20) / max(1, w * 16))
        var y = 0
        while y < h {
            let y1 = min(h, y + rows)
            let band = PixelRect(x0: 0, y0: Int32(y), x1: Int32(w), y1: Int32(y1))
            let rgba = rgbaFloats(src, band)
            dst.writeRegion(PixelRect(x0: rect.x0, y0: rect.y0 + Int32(y), x1: rect.x1, y1: rect.y0 + Int32(y1)), rgba)
            y = y1
        }
    }

    /// Straight RGBA floats of `r` of a Gray, RGB or CMYK surface (gray replicated, CMYK
    /// converted to RGB).
    static func rgbaFloats(_ s: Surface, _ r: PixelRect) -> [Float] {
        let fmt = s.format
        let n = r.area
        var out = [Float](repeating: 0, count: n * 4)
        switch fmt.mode {
        case .rgb, .indexed, .multichannel, .grayscale, .bitmap, .duotone:
            let vals = s.readRegion(r)
            let ch = fmt.channels
            let gray = fmt.mode.isGrayLike
            for i in 0 ..< n {
                let p = i * ch
                if gray {
                    out[i * 4] = vals[p]; out[i * 4 + 1] = vals[p]; out[i * 4 + 2] = vals[p]
                } else {
                    out[i * 4] = vals[p]; out[i * 4 + 1] = vals[p + 1]; out[i * 4 + 2] = vals[p + 2]
                }
                out[i * 4 + 3] = fmt.alpha ? vals[p + ch - 1] : 1
            }
        case .cmyk, .lab:
            let px = s.readRGBA(r)
            for i in 0 ..< n {
                out[i * 4] = px[i].x; out[i * 4 + 1] = px[i].y; out[i * 4 + 2] = px[i].z; out[i * 4 + 3] = px[i].w
            }
        }
        return out
    }

    /// Imports an OpenRaster archive. Layer images are decoded with `codec`.
    public static func importDocument(name: String, bytes: [UInt8], codec: any FlatImageCodec, interrupt ctl: Interrupt) throws -> ImportResult {
        let zip: ZipReader
        do { zip = try ZipReader(bytes) } catch { throw invalid(errorText(error)) }
        let mime: [UInt8]
        do { mime = try zip.read(named: "mimetype", max: 256) } catch { throw invalid(errorText(error)) }
        if trimASCII(mime) != mimetype {
            throw invalid("the archive's mimetype is not image/openraster")
        }
        let xmlBytes: [UInt8]
        do { xmlBytes = try zip.read(named: "stack.xml", max: maxStackXML) } catch { throw invalid(errorText(error)) }
        guard String(validating: xmlBytes, as: UTF8.self) != nil else { throw invalid("stack.xml is not UTF-8") }
        let image: StackXMLNode
        do { image = try StackXMLNode.parse(xmlBytes) } catch let e as StackXMLNode.ParseError { throw invalid("stack.xml: \(e.message)") }
        if image.name != "image" {
            throw invalid("stack.xml has no <image> root")
        }
        func side(_ attr: String) throws -> Int {
            let v = try num(image, attr, 0)
            if !(1.0 ... Double(maxSide)).contains(v) || v.rounded(.towardZero) != v {
                throw invalid("image \(attr) \(rustDisplay(v)) must be a whole number of pixels from 1 to \(maxSide)")
            }
            return Int(v)
        }
        let w = try side("w"), h = try side("h")
        if w * h * 8 > maxPixelBytes {
            throw invalid("the canvas exceeds the 1 GiB pixel limit")
        }
        guard let root = image.children.first(where: { $0.name == "stack" }) else {
            throw invalid("stack.xml has no root <stack>")
        }
        var reader = Reader(zip: zip, codec: codec, ctl: ctl)
        let nodes = try reader.stack(root, 1)
        ctl.progress(0.8)
        let depth = documentDepth(reader.images)
        if depth == .f32 {
            reader.warnings.note("float layer images open as a 32-bit float document")
        }
        let fmt = PixelFormat(mode: .rgb, sample: depth, alpha: true)
        var document = Document(name: name, size: PixelSize(width: w, height: h), mode: .rgb, depth: depth)
        document.layers = try build(nodes, reader.images, fmt, ctl)
        let xres = try num(image, "xres", 72)
        let yres = try num(image, "yres", xres)
        if xres > 0 && xres < 1.0e6 {
            document.resolutionDpi = Float(xres)
            if let warning = unequalResolutionWarning(xres, yres) { reader.warnings.general.append(warning) }
        }
        if document.layers.isEmpty {
            reader.warnings.note("the OpenRaster file has no layers")
        }
        return ImportResult(document: document, warnings: reader.warnings.finish(), sourceReadOnly: false, previewOnly: false)
    }

    // MARK: - Export

    /// Attribute text with XML's five special characters escaped (and control characters dropped).
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for c in s.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t": out += "&#9;"
            case "\n": out += "&#10;"
            default:
                // Rust's `char::is_control`: the Cc category.
                if c.value < 0x20 || (0x7F ... 0x9F).contains(c.value) { continue }
                out.unicodeScalars.append(c)
            }
        }
        return out
    }

    /// The composite-op attribute for `mode`: the SVG name where the specification has one, else
    /// Krita's (`krita:<id>`, which Krita reads back and others treat as Normal).
    public static func opName(_ mode: BlendMode) -> String? {
        switch mode {
        case .passThrough: return "svg:src-over"
        case .linearDodge: return "svg:plus"
        default:
            if let hit = svgOps.first(where: { $0.mode == mode }) { return hit.name }
            return kritaID(mode).map { "krita:\($0)" }
        }
    }

    private struct Writer {
        let doc: Document
        let compositor: any DocumentCompositor
        let codec: any FlatImageCodec
        var zip: ZipWriter
        var xml = ""
        var next = 0
        let sample: SampleType
        var warnings = Warnings()

        mutating func common(_ layer: Layer) -> String {
            let isGroup = layer.isGroup
            // OpenRaster has only one opacity for groups. For ordinary isolated groups, fold fill
            // opacity into that attribute; groups have no pixel payload in which to bake it as
            // raster layers do (photocraft #3048).
            let opacity = isGroup ? min(max(layer.opacity * layer.fillOpacity, 0), 1) : min(max(layer.opacity, 0), 1)
            var attrs = "name=\"\(OpenRaster.escape(layer.name))\" visibility=\"\(layer.visible ? "visible" : "hidden")\" opacity=\"\(rustDisplay(opacity))\""
            let op: String
            if let o = OpenRaster.opName(layer.blend) {
                op = o
            } else {
                warnings.layer(layer.name, "the \(layer.blend.label) blend mode has no OpenRaster equivalent; it was saved as Normal")
                op = "svg:src-over"
            }
            attrs += " composite-op=\"\(op)\""
            if layer.locks.all || layer.locks.pixels { attrs += " edit-locked=\"true\"" }
            if layer.locks.transparency { attrs += " alpha-preserve=\"true\"" }
            if layer.clipped {
                warnings.layer(layer.name, "OpenRaster has no clipping masks; these layers were saved unclipped")
            }
            if !layer.effects.items.isEmpty || layer.effects.psdRaw != nil {
                warnings.layer(layer.name, "layer styles are not saved to OpenRaster")
            }
            if layer.vectorMask?.enabled == true {
                warnings.layer(layer.name, "vector masks are not saved to OpenRaster")
            }
            if layer.fillOpacity < 1 {
                if isGroup {
                    warnings.layer(layer.name, "fill opacity was combined into the layer opacity")
                } else {
                    warnings.layer(layer.name, "fill opacity was applied to the saved layer pixels")
                }
            }
            return attrs
        }

        /// The layer's own pixels (straight RGBA floats) and their bounds; its pixel mask applied.
        ///
        /// A non-raster layer is rendered by compositing a document holding only that layer, as
        /// it shows on its own before its blending options (visible, opaque, Normal, unclipped,
        /// no layer mask, no effects; its vector mask stays), over the canvas (photocraft
        /// `render_layer` over `composite_bounds`; the compositor cannot report bounds, so the
        /// canvas is rendered and transparent margins are cropped).
        mutating func pixels(_ layer: Layer) throws -> (rect: PixelRect, px: [Float]) {
            let canvas = doc.bounds
            var rect: PixelRect
            var buf: [Float]
            if case .raster(let s) = layer.content {
                rect = s.contentBounds
                buf = OpenRaster.rgbaFloats(s, rect)
            } else {
                var solo = layer
                solo.visible = true
                solo.opacity = 1
                solo.fillOpacity = 1
                solo.blend = .normal
                solo.clipped = false
                solo.mask = nil
                solo.effects = Effects()
                var soloDoc = doc
                soloDoc.layers = [solo]
                rect = canvas
                warnings.layer(layer.name, "\(layer.content.kindName.lowercased()) layers are saved to OpenRaster as pixels")
                buf = try OpenRaster.compositeRGBA(compositor, soloDoc, rect)
            }
            if let mask = layer.mask, mask.enabled {
                if mask.feather > 0 {
                    warnings.layer(layer.name, "layer mask feathering is not applied in OpenRaster")
                }
                warnings.layer(layer.name, "layer masks were applied to the layer pixels")
                var values: [Float] = []
                mask.values(rect, into: &values)
                for i in 0 ..< min(values.count, buf.count / 4) { buf[i * 4 + 3] *= values[i] }
            }
            if layer.fillOpacity < 1 {
                let f = min(max(layer.fillOpacity, 0), 1)
                for i in 0 ..< buf.count / 4 { buf[i * 4 + 3] *= f }
            }
            return OpenRaster.crop(rect, buf)
        }

        mutating func layers(_ layers: [Layer], _ depth: Int) throws {
            if depth > maxGroupDepthLimit {
                throw PCIOError.unsupported("layer groups nested deeper than \(maxGroupDepthLimit)")
            }
            // stack.xml lists the topmost layer first.
            for layer in layers.reversed() {
                switch layer.content {
                case .group(let g):
                    let attrs = common(layer)
                    let isolation = layer.blend == .passThrough ? "auto" : "isolate"
                    if layer.mask?.enabled == true {
                        warnings.layer(layer.name, "group masks are not saved to OpenRaster")
                    }
                    xml += "<stack \(attrs) isolation=\"\(isolation)\">"
                    try self.layers(g.children, depth + 1)
                    xml += "</stack>"
                case .adjustment:
                    warnings.layer(layer.name, "adjustment layers cannot be saved to OpenRaster and were left out (the merged image keeps their look)")
                default:
                    let attrs = common(layer)
                    var (rect, px) = try pixels(layer)
                    if rect.isEmpty {
                        rect = PixelRect(x0: 0, y0: 0, x1: 1, y1: 1)
                        px = [0, 0, 0, 0]
                    }
                    let src = "data/layer\(next).png"
                    next += 1
                    let data = try OpenRaster.png(rect.width, rect.height, px, sample, codec)
                    try zip.add(src, data)
                    xml += "<layer \(attrs) src=\"\(src)\" x=\"\(rect.x0)\" y=\"\(rect.y0)\"/>"
                }
            }
        }
    }

    /// The compositor's rendering of `rect` of `doc` as straight RGBA floats.
    static func compositeRGBA(_ compositor: any DocumentCompositor, _ doc: Document, _ rect: PixelRect) throws -> [Float] {
        let fmt = doc.pixelFormat
        let vals = try compositor.composite(doc, rect: rect)
        let ch = fmt.channels
        guard vals.count == rect.area * ch else {
            throw PCIOError.codec("compositor returned \(vals.count) samples for \(rect.area) pixels of \(ch) channels")
        }
        if fmt.mode.isRGBLike && ch == 4 { return vals }
        if fmt.mode.isGrayLike && ch == 2 {
            let n = rect.area
            var out = [Float](repeating: 0, count: n * 4)
            for i in 0 ..< n {
                let g = vals[i * 2]
                out[i * 4] = g; out[i * 4 + 1] = g; out[i * 4 + 2] = g
                out[i * 4 + 3] = vals[i * 2 + 1]
            }
            return out
        }
        // Other models (not written by OpenRaster export) convert through a float surface.
        var s = Surface(format: fmt.with(sample: .f32))
        s.writeRegion(rect, vals)
        return rgbaFloats(s, rect)
    }

    /// Straight RGBA floats as a PNG at `sample` depth (8 or 16 bit), through the codec.
    static func png(_ w: Int, _ h: Int, _ px: [Float], _ sample: SampleType, _ codec: any FlatImageCodec) throws -> [UInt8] {
        let rect = PixelRect(x0: 0, y0: 0, x1: Int32(clamping: w), y1: Int32(clamping: h))
        var s = Surface(format: PixelFormat(mode: .rgb, sample: sample, alpha: true))
        s.writeRegion(rect, px)
        return try codec.encode(s, rect: rect, as: .png, quality: nil, iccProfile: nil)
    }

    /// `px` (row-major over `rect`) cut down to the pixels that aren't fully transparent, with
    /// transparent pixels zeroed, so masked-out or empty margins aren't written.
    static func crop(_ rect: PixelRect, _ input: [Float]) -> (rect: PixelRect, px: [Float]) {
        var px = input
        let w = rect.width
        if w == 0 { return (.empty, []) }
        var (x0, y0, x1, y1) = (Int.max, Int.max, 0, 0)
        let n = px.count / 4
        for i in 0 ..< n {
            if !(px[i * 4 + 3] > 0) {
                px[i * 4] = 0; px[i * 4 + 1] = 0; px[i * 4 + 2] = 0; px[i * 4 + 3] = 0
                continue
            }
            let (x, y) = (i % w, i / w)
            x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x + 1); y1 = max(y1, y + 1)
        }
        if x0 >= x1 { return (.empty, []) }
        if x0 == 0 && y0 == 0 && x1 == w && y1 == n / w { return (rect, px) }
        var out: [Float] = []
        out.reserveCapacity((x1 - x0) * (y1 - y0) * 4)
        for y in y0 ..< y1 {
            out += px[(y * w + x0) * 4 ..< (y * w + x1) * 4]
        }
        return (PixelRect(x0: rect.x0 + Int32(x0), y0: rect.y0 + Int32(y0), x1: rect.x0 + Int32(x1), y1: rect.y0 + Int32(y1)), out)
    }

    /// photocraft `thumbnail_size`: the longest side scaled to `maxSide` (never enlarged).
    static func thumbnailSize(_ width: Int, _ height: Int, _ maxSide: Int) -> (Int, Int) {
        let longest = max(1, max(width, height))
        let scale = min(Float(maxSide) / Float(longest), 1)
        return (max(1, roundCast(Float(width) * scale) as Int), max(1, roundCast(Float(height) * scale) as Int))
    }

    /// photocraft `render_reduced`: straight RGBA `px` (`fw`×`fh`) area-averaged (premultiplied)
    /// down to `w`×`h`; output pixel t covers source pixels [t·f/n, (t+1)·f/n).
    static func reduce(_ px: [Float], _ fw: Int, _ fh: Int, _ wIn: Int, _ hIn: Int) -> [Float] {
        let w = min(max(wIn, 1), max(fw, 1)), h = min(max(hIn, 1), max(fh, 1))
        if fw == 0 || fh == 0 { return [Float](repeating: 0, count: w * h * 4) }
        if w == fw && h == fh { return px }
        func span(_ t: Int, _ f: Int, _ n: Int) -> (Int, Int) {
            let a = t * f / n
            return (a, min(max((t + 1) * f / n, a + 1), f))
        }
        var acc = [Float](repeating: 0, count: w * h * 4)
        var cols = [Int](repeating: 0, count: fw)
        for t in 0 ..< w { let (a, z) = span(t, fw, w); for x in a ..< z { cols[x] = t } }
        for t in 0 ..< h {
            let (a, z) = span(t, fh, h)
            for y in a ..< z {
                for x in 0 ..< fw {
                    let s = (y * fw + x) * 4
                    let o = (t * w + cols[x]) * 4
                    let alpha = px[s + 3]
                    acc[o] += px[s] * alpha
                    acc[o + 1] += px[s + 1] * alpha
                    acc[o + 2] += px[s + 2] * alpha
                    acc[o + 3] += alpha
                }
            }
        }
        for i in 0 ..< w * h {
            let ((x0, x1), (y0, y1)) = (span(i % w, fw, w), span(i / w, fh, h))
            let n = Float(max(1, (y1 - y0) * (x1 - x0)))
            let a = acc[i * 4 + 3]
            if a > 0 {
                acc[i * 4] /= a; acc[i * 4 + 1] /= a; acc[i * 4 + 2] /= a; acc[i * 4 + 3] = a / n
            } else {
                acc[i * 4] = 0; acc[i * 4 + 1] = 0; acc[i * 4 + 2] = 0; acc[i * 4 + 3] = 0
            }
        }
        return acc
    }

    /// Exports `doc` as an OpenRaster archive. Layer PNGs, `mergedimage.png` and the thumbnail
    /// are encoded with `codec`; the merged image, the thumbnail and the pixels of non-raster
    /// layers come from `compositor`.
    public static func export(_ doc: Document, compositor: any DocumentCompositor, codec: any FlatImageCodec) throws -> ExportResult {
        guard doc.mode == .rgb || doc.mode == .grayscale else {
            throw PCIOError.unsupported("OpenRaster holds RGB layers; convert the document to RGB or Grayscale first")
        }
        let sample: SampleType = doc.depth == .u8 ? .u8 : .u16
        var zip = ZipWriter()
        // The mimetype must be the first entry, stored, so the type is readable at a fixed offset.
        try zip.add("mimetype", mimetype)
        var w = Writer(doc: doc, compositor: compositor, codec: codec, zip: zip, sample: sample)
        if doc.depth == .f32 {
            w.warnings.note("32-bit float layers are saved as 16-bit PNGs")
        }
        let res = rustDisplay(Float.maximum(doc.resolutionDpi.rounded(), 1))
        w.xml += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<image version=\"0.0.6\" w=\"\(doc.size.width)\" h=\"\(doc.size.height)\" xres=\"\(res)\" yres=\"\(res)\"><stack>"
        try w.layers(doc.layers, 1)
        w.xml += "</stack></image>\n"
        zip = w.zip
        var warnings = w.warnings
        try zip.add("stack.xml", Array(w.xml.utf8))
        let (cw, ch) = (doc.size.width, doc.size.height)
        let merged = try compositeRGBA(compositor, doc, doc.bounds)
        try zip.add("mergedimage.png", try png(cw, ch, merged, sample, codec))
        let (tw, th) = thumbnailSize(cw, ch, thumbnailSide)
        let thumb = reduce(merged, cw, ch, tw, th)
        let (rw, rh) = (min(max(tw, 1), max(cw, 1)), min(max(th, 1), max(ch, 1)))
        try zip.add("Thumbnails/thumbnail.png", try png(rw, rh, thumb, .u8, codec))
        if !doc.channels.isEmpty {
            warnings.note("alpha channels are not saved to OpenRaster")
        }
        if !doc.metadata.text.isEmpty || doc.metadata.xmp != nil || doc.metadata.exif != nil {
            warnings.note("metadata (XMP, EXIF, text) is not saved to OpenRaster")
        }
        if doc.iccProfile != nil {
            warnings.note("the colour profile is not saved to OpenRaster; readers assume sRGB")
        }
        if doc.mode == .grayscale {
            warnings.note("grayscale layers are saved as RGB")
        }
        return ExportResult(bytes: try zip.finish(), warnings: warnings.finish())
    }

    // MARK: - Shared helpers (also used by Krita)

    /// Width, height, decoded channel count and bytes per sample from a PNG's IHDR, when `data`
    /// starts like a PNG.
    static func pngHeader(_ data: [UInt8]) -> (width: Int, height: Int, channels: Int, bytes: Int)? {
        guard isPNG(data), data.count >= 26, data[12 ..< 16].elementsEqual(Array("IHDR".utf8)) else { return nil }
        func be32(_ o: Int) -> Int { Int(data[o]) << 24 | Int(data[o + 1]) << 16 | Int(data[o + 2]) << 8 | Int(data[o + 3]) }
        let channels: Int
        switch data[25] {
        case 0: channels = 1
        case 4: channels = 2
        case 6: channels = 4
        default: channels = 3
        }
        return (be32(16), be32(20), channels, data[24] == 16 ? 2 : 1)
    }

    /// photocraft-codecs' `Limits::check` for a PNG header: at most 300,000 px a side and
    /// `maxAlloc` bytes decoded.
    static func limitError(_ h: (width: Int, height: Int, channels: Int, bytes: Int), maxAlloc: Int) -> String? {
        if h.width == 0 || h.height == 0 { return "invalid image: zero-sized image \(h.width)x\(h.height)" }
        if h.width > maxSide || h.height > maxSide {
            return "limit exceeded: dimensions \(h.width)x\(h.height) exceed max \(maxSide)x\(maxSide)"
        }
        let bytes = h.width.multipliedReportingOverflow(by: h.height).partialValue.multipliedReportingOverflow(by: h.channels * h.bytes)
        if bytes.overflow || bytes.partialValue > maxAlloc {
            return "limit exceeded: \(bytes.partialValue) bytes exceed max_alloc \(maxAlloc)"
        }
        return nil
    }

    /// `true` when `data` starts with the PNG signature (photocraft `codecs::detect == Png`).
    static func isPNG(_ data: [UInt8]) -> Bool {
        data.count >= 8 && data[0 ..< 8].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// Rust's `trim_ascii`.
    static func trimASCII(_ b: [UInt8]) -> [UInt8] {
        let ws: Set<UInt8> = [9, 10, 12, 13, 32]
        var lo = 0, hi = b.count
        while lo < hi, ws.contains(b[lo]) { lo += 1 }
        while hi > lo, ws.contains(b[hi - 1]) { hi -= 1 }
        return Array(b[lo ..< hi])
    }

    /// An error's message (a PCIOError's own text without its category prefix).
    static func errorText(_ e: Error) -> String {
        if let e = e as? PCIOError {
            switch e {
            case let .corrupt(m), let .unsupported(m), let .limitExceeded(m), let .psd(m), let .codec(m), let .io(m), let .unknownFormat(m): return m
            case let .format(f, m): return "\(f): \(m)"
            case .cancelled: return "cancelled"
            }
        }
        return String(describing: e)
    }

    /// Rust's `str::parse::<f64>`: decimal (with exponent), `inf`/`infinity`/`nan`; no hex.
    static func parseFloat(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.contains(where: { $0 == "x" || $0 == "X" || $0 == "p" || $0 == "P" }) { return nil }
        return Double(t)
    }

    /// Rust's `Display` for floats: the shortest round-trip digits, never in exponent form, and
    /// no `.0` on whole numbers.
    static func rustDisplay(_ v: Float) -> String { rustDisplay(String(describing: v), v.isNaN, v.isInfinite, v < 0) }

    static func rustDisplay(_ v: Double) -> String { rustDisplay(String(describing: v), v.isNaN, v.isInfinite, v < 0) }

    private static func rustDisplay(_ text: String, _ nan: Bool, _ inf: Bool, _ negative: Bool) -> String {
        if nan { return "NaN" }
        if inf { return negative ? "-inf" : "inf" }
        var s = text
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }), let exp = Int(s[s.index(after: e)...]) {
            var mantissa = String(s[..<e])
            let sign = mantissa.hasPrefix("-") ? "-" : ""
            if !sign.isEmpty { mantissa.removeFirst() }
            let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
            let intPart = parts.first.map(String.init) ?? ""
            let frac = parts.count > 1 ? String(parts[1]) : ""
            var digits = intPart + frac
            let point = intPart.count + exp
            // Trailing zeros after the decimal point are not part of the shortest form.
            while digits.count > 1 && digits.hasSuffix("0") && digits.count > point { digits.removeLast() }
            if point <= 0 {
                s = sign + "0." + String(repeating: "0", count: -point) + digits
            } else if point >= digits.count {
                s = sign + digits + String(repeating: "0", count: point - digits.count)
            } else {
                s = sign + String(digits.prefix(point)) + "." + String(digits.dropFirst(point))
            }
        }
        if s.hasSuffix(".0") { s.removeLast(2) }
        return s
    }
}

// MARK: - stack.xml

/// A minimal element tree of `stack.xml`: local element names, un-prefixed attributes, element
/// children only (what photocraft reads through `roxmltree`).
private final class StackXMLNode {
    let name: String
    let attributes: [String: String]
    var children: [StackXMLNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    struct ParseError: Error { let message: String }

    /// The root element of `bytes` (UTF-8 XML). External entities are never resolved.
    static func parse(_ bytes: [UInt8]) throws -> StackXMLNode {
        let builder = Builder()
        let parser = XMLParser(data: Data(bytes))
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        let ok = parser.parse()
        guard ok, let root = builder.root, builder.stack.isEmpty else {
            let e = parser.parserError.map { ($0 as NSError).localizedDescription } ?? "malformed XML"
            throw ParseError(message: "\(e) (line \(parser.lineNumber), column \(parser.columnNumber))")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: StackXMLNode?
        var stack: [StackXMLNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            // Namespaced attributes (`krita:x`, `xmlns:…`) are not the plain names ORA defines.
            let attrs = attributeDict.filter { !$0.key.contains(":") && $0.key != "xmlns" }
            let node = StackXMLNode(name: local, attributes: attrs)
            if let parent = stack.last {
                parent.children.append(node)
            } else if root == nil {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if !stack.isEmpty { stack.removeLast() }
        }
    }
}
