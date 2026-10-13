// Port of photocraft-engine (crates/engine/src/multichannel_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Image › Mode › Multichannel, and conversions out of it. A Multichannel document has no layers:
// its image is a set of ink channels kept as spot channels in `Document.channels` (value = ink
// density, 1 = solid; the compositor prints them over white). Like Photoshop the conversion
// flattens and turns each colour channel into an ink: RGB → Cyan, Magenta, Yellow (density =
// 1 − value); CMYK → its plates; Lab → Alpha 1–3 printed in black; Grayscale → Black; Duotone →
// one channel per ink. Alpha channels stay. Converting back (`convertFrom`, called by Image › Mode
// › RGB / CMYK / Lab / Grayscale) reinterprets the channel data when the count matches, otherwise
// converts the printed look.

import Foundation
import PCDocument
import PCFoundation
import PCRender

public enum MultichannelCommands: CommandModule {
    public static let name = "multichannel_cmds"
    static let m = "multichannel_cmds"

    /// Display colours of the process inks (sRGB).
    static let cyan = PCColor.rgb(0, 0.682, 0.937)
    static let magenta = PCColor.rgb(0.925, 0, 0.549)
    static let yellow = PCColor.rgb(1, 0.949, 0)
    static let black = PCColor.rgb(0.137, 0.122, 0.125)

    /// Modes Photoshop converts to Multichannel.
    static let sources: [ColorMode] = [.rgb, .cmyk, .lab, .grayscale, .duotone]

    public static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("image.mode.multichannel", "Multichannel", menu: ["Image", "Mode"],
                          params: #"{} (flattens; RGB → Cyan/Magenta/Yellow, CMYK → Cyan/Magenta/Yellow/Black, Lab → Alpha 1–3, Grayscale → Black, Duotone → its inks)"#,
                          module: m, enabled: enabled, run: toMultichannel))
    }

    /// The mode as photocraft's `{:?}` prints it.
    static func debugName(_ mode: ColorMode) -> String {
        switch mode {
        case .bitmap: "Bitmap"
        case .grayscale: "Grayscale"
        case .indexed: "Indexed"
        case .rgb: "Rgb"
        case .cmyk: "Cmyk"
        case .lab: "Lab"
        case .multichannel: "Multichannel"
        case .duotone: "Duotone"
        }
    }

    static let enabled: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        if sources.contains(d.doc.mode) { return nil }
        return "Multichannel needs an RGB, CMYK, Lab, Grayscale or Duotone image (the document is \(debugName(d.doc.mode)))"
    }

    /// Native colour planes of the flattened image (opaque over white): one array per colour
    /// channel of the document's pixel format. A lone plain layer is read exactly; anything else
    /// goes through the compositor.
    static func flattenedPlanes(_ s: Session, _ doc: Document) throws -> [[Float]] {
        let fmt = doc.pixelFormat, cc = fmt.mode.colorChannels
        let canvas = doc.bounds
        let white = fmt.components(fromRGBA: SIMD4(1, 1, 1, 1))
        var planes = [[Float]](repeating: [], count: cc)
        for k in 0..<cc { planes[k].reserveCapacity(canvas.area) }
        if doc.layers.count == 1, let l = doc.layers.first, l.visible, l.opacity >= 1, l.fillOpacity >= 1, l.mask == nil, l.vectorMask == nil,
           !LayerGeometry.hasEffects(l), case .raster(let surf) = l.content, surf.format.mode == fmt.mode {
            let ch = surf.channels, alpha = surf.format.alpha
            let raw = surf.readRegion(canvas)
            for i in 0..<canvas.area {
                let a: Float = alpha ? raw[i * ch + ch - 1] : 1
                for c in 0..<cc { planes[c].append(raw[i * ch + c] * a + white[c] * (1 - a)) }
            }
            return planes
        }
        let flat = try s.services.renderer.compositeToSurface(doc, rect: canvas, format: fmt, background: SIMD3(1, 1, 1))
        let raw = flat.readRegion(canvas), ch = fmt.channels
        for i in 0..<canvas.area { for c in 0..<cc { planes[c].append(raw[i * ch + c]) } }
        return planes
    }

    static func channelSurface(_ doc: Document, _ vals: [Float]) -> Surface {
        var s = Surface(format: PixelFormat(mode: .grayscale, sample: doc.depth, alpha: false))
        let r = doc.bounds
        if r.isEmpty { return s }
        var v = vals.map { $0.isNaN ? 0 : min(max($0, 0), 1) }
        if v.count < r.area { v += [Float](repeating: 0, count: r.area - v.count) }
        s.writeRegion(r, v)
        s.prune()
        return s
    }

    /// The ink channels (name, display colour, densities) of the flattened document.
    static func inksOf(_ s: Session, _ doc: Document) throws -> [(String, PCColor, [Float])] {
        let planes = try flattenedPlanes(s, doc)
        func inv(_ p: [Float]) -> [Float] { p.map { 1 - $0 } }
        let first = planes.first ?? []
        switch doc.mode {
        case .rgb:
            return zip([("Cyan", cyan), ("Magenta", magenta), ("Yellow", yellow)], planes).map { ($0.0, $0.1, inv($1)) }
        case .cmyk:
            return zip([("Cyan", cyan), ("Magenta", magenta), ("Yellow", yellow), ("Black", black)], planes).map { ($0.0, $0.1, $1) }
        case .lab:
            return planes.enumerated().map { ("Alpha \($0 + 1)", PCColor.black, inv($1)) }
        case .duotone where !(doc.duotone?.inks.isEmpty ?? true):
            return (doc.duotone?.inks ?? []).map { ink in
                (ink.name, PCColor.rgb(ink.color.x, ink.color.y, ink.color.z), first.map { ink.density(1 - $0) })
            }
        default:
            return [("Black", PCColor.black, inv(first))]
        }
    }

    static func toMultichannel(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let names = try s.edit("Multichannel") { doc, active -> [String] in
            let inks = try inksOf(s, doc)
            var channels: [AlphaChannel] = inks.map { name, ink, vals in
                var ch = AlphaChannel(name: name, surface: channelSurface(doc, vals))
                ch.spot = SpotInk(color: ink, solidity: 0)
                return ch
            }
            // Existing alpha / spot channels follow the inks, converted to the document depth.
            let fmt = PixelFormat(mode: .grayscale, sample: doc.depth, alpha: false)
            for var ch in doc.channels {
                if ch.surface.format != fmt { ch.surface = ch.surface.convertedAny(to: fmt) }
                channels.append(ch)
            }
            doc.channels = channels
            doc.layers = []
            active = nil
            doc.mode = .multichannel
            doc.quickMask = nil
            doc.colorTable = nil
            doc.duotone = nil
            doc.iccProfile = nil
            return inks.map(\.0)
        }
        return ["mode": "multichannel", "channels": .strings(names)]
    }

    /// Image › Mode › RGB / CMYK / Lab / Grayscale from a Multichannel document (photocraft
    /// `convert_from`, called by the colour-mode commands). Profiles are not involved.
    public static func convertFrom(_ s: Session, _ mode: ColorMode, _ p: JSONValue) throws -> JSONValue {
        guard [.rgb, .cmyk, .lab, .grayscale].contains(mode) else {
            throw EngineError.other("a Multichannel document can't be converted to \(debugName(mode))")
        }
        let renderer = s.services.renderer
        let how = try s.edit("Mode Change") { doc, active -> String in
            let inks = doc.channels.filter { $0.spot != nil }, others = doc.channels.filter { $0.spot == nil }
            let canvas = doc.bounds, n = canvas.area
            let reinterpret = switch (mode, inks.count) {
            case (.rgb, 3), (.lab, 3), (.cmyk, 4), (.grayscale, 1): true
            default: false
            }
            // The printed look, rendered before the inks leave the document.
            var shown: [SIMD4<Float>]?
            if !reinterpret {
                var d = doc
                d.channels = inks
                shown = try renderer.render(d, region: canvas).px
            }
            doc.mode = mode
            let fmt = doc.pixelFormat
            let cc = fmt.mode.colorChannels, stride = cc + 1
            var data = [Float](repeating: 0, count: n * stride)
            if let px = shown {
                let enc = PixelCodec.fromRGBA(fmt, rgba: px.map { SIMD4($0.x, $0.y, $0.z, 1) })
                let ch = fmt.channels
                for i in 0..<min(n, px.count) { for k in 0..<min(stride, ch) { data[i * stride + k] = enc[i * ch + k] } }
            } else {
                for (k, ch) in inks.enumerated() where k < cc {
                    let vals = ch.surface.readRegion(canvas)
                    let step = ch.surface.channels
                    for i in 0..<n {
                        let v = vals[i * step]
                        // CMYK plates are ink amounts already; other modes store light.
                        data[i * stride + k] = mode == .cmyk ? v : 1 - v
                    }
                }
                for i in 0..<n { data[i * stride + cc] = 1 }
            }
            var surf = Surface(format: fmt)
            if n > 0 && fmt.channels == stride {
                surf.writeRegion(canvas, data)
                surf.prune()
            }
            var bg = Layer(name: "Background", content: .raster(surf))
            bg.locks.transparency = true
            bg.locks.position = true
            active = bg.id
            doc.layers = [bg]
            doc.channels = others
            return reinterpret ? "channels" : "appearance"
        }
        return ["mode": .string(debugName(mode).lowercased()), "from": "multichannel", "converted": .string(how)]
    }

    /// Names of the ink (spot) channels that make up a Multichannel image.
    public static func inkNames(_ doc: Document) -> [String] { doc.channels.filter { $0.spot != nil }.map(\.name) }
}
