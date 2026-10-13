// Port of photocraft-engine (crates/engine/src/channel_cmds.rs: the commands — Save / Load Selection, Quick Mask, alpha and spot channel management, channel targeting and visibility, Apply Image / Calculations, Split / Merge Channels, Merge Spot Channel, `channels_json`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Alpha channels live in `Document.channels` (white = selected). Quick Mask is a temporary channel
// in `Document.quickMask`, so entering and leaving it are history steps as in Photoshop. Which
// channel is targeted and which are visible is view state (`DocState.channelView`, not history).
// The targeting core (what pixel commands edit, `Channels.*`) is in Core/ChannelTargets.swift.

import Foundation
import PCDocument
import PCFoundation

public enum ChannelCommands: CommandModule {
    public static let name = "channel_cmds"
    static let m = "channel_cmds"

    public static func register(into r: inout CommandRegistry) {
        let specs: [CommandSpec] = [
            CommandSpec("select.saveSelection", "Save Selection…", menu: ["Select"],
                        params: #"{"name":str?,"channel":"new"|index|name="new","document":index?,"operation":"new|replace|add|subtract|intersect"="new"}"#,
                        module: m, enabled: hasSelection, run: saveSelection),
            CommandSpec("select.loadSelection", "Load Selection…", menu: ["Select"],
                        params: #"{"channel":index|name|"composite"|"red|green|blue|…"|"transparency"|"mask"|"vectorMask"|"quickMask"|"selection","layer":id?,"document":index?,"invert":bool=false,"operation":"new|add|subtract|intersect"="new"}"#,
                        module: m, enabled: Pre.hasDoc, run: loadSelection),
            CommandSpec("select.editInQuickMaskMode", "Edit in Quick Mask Mode", menu: ["Select"], shortcut: "Q", params: #"{"on":bool?=toggle}"#,
                        module: m, enabled: Pre.hasDoc, run: quickMask),
            CommandSpec("image.applyImage", "Apply Image…", menu: ["Image"],
                        params: #"{"source":{"document":index?,"layer":id|"merged"="merged","channel":"composite"|"red|…"|index|"selection"|"transparency"|"mask"="composite","invert":bool=false},"blending":"normal|multiply|screen|overlay|softLight|hardLight|colorDodge|colorBurn|darken|lighten|difference|exclusion|linearBurn|linearDodge|add|subtract|…"="multiply","opacity":0..100=100,"scale":1..2=1,"offset":-255..255=0,"preserveTransparency":bool=false,"mask":{"document","layer","channel","invert"}?,"sourceChannel|sourceDocument|sourceLayer|sourceInvert|maskChannel|…":flat form of source/mask?}"#,
                        module: m, enabled: hasApplyTarget, run: applyImage),
            CommandSpec("image.calculations", "Calculations…", menu: ["Image"],
                        params: #"{"source1":{"document","layer","channel","invert"},"source2":{…},"blending":"multiply|…"="multiply","opacity":0..100=100,"scale":1..2=1,"offset":-255..255=0,"mask":{…}?,"result":"newChannel|newDocument|selection"="newChannel","name":str?}"#,
                        module: m, enabled: Pre.hasDoc, run: calculations),
            CommandSpec("channel.new", "New Channel…",
                        params: ##"{"name":str?,"fill":"black|white|selection"="black","color":"#rrggbb"="#ff0000","opacity":0..100=50,"indicates":"masked|selected"="masked"}"##,
                        module: m, enabled: Pre.hasDoc, run: newChannel),
            CommandSpec("channel.newSpot", "New Spot Channel…",
                        params: ##"{"name":str?,"color":"#rrggbb"="#ff0000","solidity":0..100=0,"fromSelection":bool=true}"##,
                        module: m, enabled: Pre.hasDoc, run: newSpot),
            CommandSpec("channel.duplicate", "Duplicate Channel…",
                        params: #"{"channel":index|name|"red|…"|"composite"|"quickMask","name":str?,"document":index|"new"?=active,"invert":bool=false}"#,
                        module: m, enabled: Pre.hasDoc, run: duplicateChannel),
            CommandSpec("channel.delete", "Delete Channel", params: #"{"channel":index|name?=targeted}"#, module: m, enabled: hasChannels, run: deleteChannel),
            CommandSpec("channel.rename", "Rename Channel", params: #"{"channel":index|name,"name":str}"#, module: m, enabled: hasChannels, run: renameChannel),
            CommandSpec("channel.move", "Reorder Channel", params: #"{"channel":index|name,"to":index}"#, module: m, enabled: hasChannels, run: moveChannel),
            CommandSpec("channel.target", "Target Channel",
                        params: #"{"channel":"composite"|"mask"|"vectorMask"|"red|green|blue|…"|index|name="composite"}"#,
                        module: m, enabled: Pre.hasDoc, run: targetCommand),
            CommandSpec("channel.setVisible", "Channel Visibility",
                        params: #"{"channel":"composite"|"red|…"|index|name|"quickMask","visible":bool?=toggle}"#,
                        module: m, enabled: Pre.hasDoc, run: setVisible),
            CommandSpec("channel.options", "Channel Options…",
                        params: ##"{"channel":index|name|"quickMask","name":str?,"indicates":"masked|selected|spot"?,"color":"#rrggbb"?,"opacity":0..100?,"solidity":0..100?}"##,
                        module: m, enabled: Pre.hasDoc, run: options),
            CommandSpec("channel.mergeSpot", "Merge Spot Channel", params: #"{"channel":index|name?=targeted or first spot}"#,
                        module: m, enabled: hasSpot, run: mergeSpot),
            CommandSpec("channel.split", "Split Channels", params: #"{"closeOriginal":bool=true}"#, module: m, enabled: canSplit, run: split),
            CommandSpec("channel.merge", "Merge Channels…",
                        params: #"{"mode":"rgb|cmyk|lab"="rgb","documents":[index,…]?=open grayscale docs of the active size,"name":str?}"#,
                        module: m, enabled: canMerge, run: merge),
            CommandSpec("channel.list", "Channels", params: "{}", module: m, journal: false, enabled: Pre.hasDoc) { s, _ in list(s) },
            CommandSpec("channel.target.composite", "Target Composite Channel", shortcut: "Cmd+2", params: "{}", module: m, enabled: Pre.hasDoc) { s, _ in
                try targetSlot(s, 2)
            },
            // ⌘\ targets the active layer's mask, as clicking its thumbnail does.
            CommandSpec("channel.target.layerMask", "Target Layer Mask", shortcut: #"Cmd+\"#, params: "{}", module: m, enabled: hasLayerMask) { s, _ in
                try targetCommand(s, ["channel": "mask"])
            },
            // ⌘⌥2 loads the image's luminosity as a selection (⌘-click on the composite channel).
            CommandSpec("select.loadLuminosity", "Load Luminosity", shortcut: "Cmd+Alt+2", params: "{}", module: m, enabled: Pre.hasDoc) { s, _ in
                try loadSelection(s, ["channel": "composite"])
            },
        ]
        r.add(specs)
        // photocraft's `inspect` reports the Channels panel as `channels_json` (installed after the
        // core's targeting hooks, so this shape is the one `document.inspect` returns).
        r.hooks.documentInspectors.append { st, o in o["channels"] = channelsJSON(st) }
        for n in 3...9 {
            r.add(CommandSpec("channel.target.slot\(n)", "Target Channel \(n)", shortcut: "Cmd+\(n)", params: "{}", module: m, enabled: slotOK(n)) { s, _ in
                try targetSlot(s, n)
            })
        }
    }

    // MARK: Helpers

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }

    /// Bump the revision for a view-only change without dirtying a clean document.
    static func touch(_ st: inout DocState) { Session.noEditRevision(&st) }

    static func fixViewNow(_ st: inout DocState) {
        st.fixChannelView()
        touch(&st)
    }

    /// Next free "Alpha N" name.
    static func nextAlphaName(_ doc: Document, _ base: String) -> String {
        for n in 1...(doc.channels.count + 1) {
            let name = "\(base) \(n)"
            if !doc.channels.contains(where: { $0.name == name }) { return name }
        }
        return base
    }

    /// Channel 0 of `s` over `r`.
    static func readPlane(_ s: Surface, _ r: PixelRect) -> [Float] { s.coverage(r) }

    /// A surface of `fmt` holding `vals` (clamped) over `r`.
    static func planeSurface(_ vals: [Float], _ r: PixelRect, _ fmt: PixelFormat) -> Surface {
        var s = Surface(format: fmt)
        if r.isEmpty { return s }
        var clamped = vals.map { $0.isNaN ? 0 : min(max($0, 0), 1) }
        if clamped.count < r.area { clamped += [Float](repeating: 0, count: r.area - clamped.count) }
        if fmt.channels == 1 {
            s.writeRegion(r, clamped)
        } else {
            // A plane into a multi-channel format: every channel takes it, alpha (if any) is opaque.
            var data = [Float](repeating: 1, count: r.area * fmt.channels)
            let colors = fmt.mode.colorChannels
            for i in 0..<r.area { for c in 0..<colors { data[i * fmt.channels + c] = clamped[i] } }
            s.writeRegion(r, data)
        }
        s.prune()
        return s
    }

    static func luminosity(_ c: SIMD4<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }

    /// ASCII lowercase (Rust `to_ascii_lowercase`).
    static func asciiLower(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            out.append(u.value >= 65 && u.value <= 90 ? Unicode.Scalar(u.value + 32) ?? u : u)
        }
        return String(out)
    }

    /// The document mode's colour count.
    static func colorCount(_ doc: Document) -> Int { Channels.colorCount(doc) }

    // MARK: Channel references

    /// A channel named in params: `"composite"`, a colour name (`"red"`, `"cyan"`, `"lightness"`…),
    /// an alpha index (number) or name, `"quickMask"`, `"selection"`, `"transparency"`, `"mask"`.
    public enum ChanRef: Hashable, Sendable {
        case composite
        case color(Int)
        case alpha(Int)
        case quickMask
        case selection
        case transparency
        case layerMask
        /// The layer's vector mask, rasterized.
        case vectorMask
    }

    /// photocraft `parse_ref`.
    public static func parseRef(_ v: JSONValue?, _ doc: Document) -> ChanRef? {
        let mode = doc.pixelFormat.mode
        switch v {
        case .number?:
            return v?.uint64Value.map { .alpha(Int(clamping: $0)) }
        case .object(let o)?:
            if let k = o["color"]?.uint64Value { return .color(Int(clamping: k)) }
            return o["alpha"]?.uint64Value.map { .alpha(Int(clamping: $0)) }
        case .string(let s)?:
            let l = asciiLower(s)
            switch l {
            case "composite", "merged": return .composite
            case "quickmask", "quick mask": return .quickMask
            case "selection": return .selection
            case "transparency": return .transparency
            case "mask", "layermask": return .layerMask
            case "vectormask", "vector mask": return .vectorMask
            default: break
            }
            if l == asciiLower(Channels.compositeName(mode)) { return .composite }
            let names = Channels.colorNames(mode)
            if let k = names.firstIndex(where: { asciiLower($0) == l }) { return names.count == 1 ? .composite : .color(k) }
            return doc.channels.firstIndex { $0.name == s }.map { .alpha($0) }
        default:
            return nil
        }
    }

    /// The `key` document index param, else the active document.
    static func docIndex(_ s: Session, _ p: JSONValue, _ key: String) throws -> Int {
        if let i = Params.int(p, key), i >= 0 {
            guard i < s.documents.count else { throw EngineError.other("no open document \(i)") }
            return i
        }
        guard let a = s.activeIndex else { throw EngineError.noDocument }
        return a
    }

    /// Alpha channel index from `p[key]` (number or name), checked against the document.
    static func alphaIndex(_ doc: Document, _ p: JSONValue, _ key: String, _ cmd: String) throws -> Int {
        switch parseRef(p[key], doc) {
        case .alpha(let i)? where i < doc.channels.count: return i
        case .alpha(let i)?: throw bad(cmd, "no alpha channel \(i) (document has \(doc.channels.count))")
        default: throw bad(cmd, "`\(key)` must name an alpha channel (index or name)")
        }
    }

    // MARK: Sources (Load Selection, Apply Image, Calculations)

    /// Native pixel values of a layer or of the merged image over the canvas.
    static func nativePixels(_ s: Session, _ doc: Document, _ layer: LayerId?) throws -> ([Float], Int) {
        let r = doc.bounds, fmt = doc.pixelFormat, n = fmt.channels
        if let id = layer {
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            guard let surf = l.surface else { throw EngineError.other("layer \"\(l.name)\" has no pixels") }
            if surf.format == fmt { return (surf.readRegion(r), n) }
            return (PixelCodec.fromRGBA(fmt, rgba: PixelCodec.toRGBA(surf.format, raw: surf.readRegion(r))), n)
        }
        let buf = try s.services.renderer.render(doc, region: r)
        return (PixelCodec.fromRGBA(fmt, rgba: buf.px), n)
    }

    /// Planes of channel `r` of `doc` (`layer` nil = merged): a composite gives one plane per
    /// colour channel, everything else one plane.
    static func refPlanes(_ s: Session, _ doc: Document, _ layer: LayerId?, _ active: LayerId?, _ r: ChanRef) throws -> [[Float]] {
        let area = doc.bounds
        let colors = colorCount(doc)
        switch r {
        case .composite, .color:
            let (px, n) = try nativePixels(s, doc, layer)
            let count = n > 0 ? px.count / n : 0
            let planes: [[Float]] = (0..<colors).map { c in (0..<count).map { px[$0 * n + c] } }
            if case .color(let k) = r {
                guard k < planes.count else { throw EngineError.other("no colour channel \(k)") }
                return [planes[k]]
            }
            return planes
        case .alpha(let i):
            guard i < doc.channels.count else { throw EngineError.other("no alpha channel \(i)") }
            return [readPlane(doc.channels[i].surface, area)]
        case .quickMask:
            guard let q = doc.quickMask else { throw EngineError.other("not in Quick Mask mode") }
            return [readPlane(q.surface, area)]
        case .selection:
            return [SelectionMath.mask(from: doc.selection, area)]
        case .transparency:
            guard let id = layer ?? active else { throw EngineError.other("transparency needs a layer") }
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            if let surf = l.surface { return [surf.readRGBA(area).map(\.w)] }
            if case .shape(let shape) = l.content {
                // A shape can have no pixel cache yet: render its outline.
                let fmt = PixelFormat(mode: .rgb, sample: .f32, alpha: true)
                let rendered = s.services.renderer.rasterizer.renderShape(shape, format: fmt, clip: area)
                return [rendered.map { $0.readRGBA(area).map(\.w) } ?? [Float](repeating: 0, count: area.area)]
            }
            // Adjustment and fill layers cover the whole canvas.
            return [[Float](repeating: 1, count: area.area)]
        case .layerMask:
            guard let id = layer ?? active else { throw EngineError.other("layer mask needs a layer") }
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            guard let mk = l.mask else { throw EngineError.other("layer \"\(l.name)\" has no mask") }
            return [readPlane(mk.surface, area)]
        case .vectorMask:
            guard let id = layer ?? active else { throw EngineError.other("vector mask needs a layer") }
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            guard let vm = l.vectorMask else { throw EngineError.other("layer \"\(l.name)\" has no vector mask") }
            // The path's shape, whether or not the mask is enabled (as Photoshop loads it).
            let cov = s.services.renderer.rasterizer.coverage(of: vm.path, in: area) ?? []
            return [cov.count == area.area ? cov.map { min(max($0, 0), 1) } : [Float](repeating: 0, count: area.area)]
        }
    }

    /// One grayscale plane (composites reduce to luminosity, as in Calculations).
    static func grayPlane(_ s: Session, _ doc: Document, _ layer: LayerId?, _ active: LayerId?, _ r: ChanRef) throws -> [Float] {
        let planes = try refPlanes(s, doc, layer, active, r)
        if planes.count == 1 { return planes[0] }
        let fmt = doc.pixelFormat, ch = fmt.channels
        let n = planes.first?.count ?? 0
        var raw = [Float](repeating: 1, count: n * ch)
        for (c, pl) in planes.enumerated() where c < ch { for i in 0..<n { raw[i * ch + c] = pl[i] } }
        return PixelCodec.toRGBA(fmt, raw: raw).map(luminosity)
    }

    /// A source spec `{document?, layer?, channel, invert?}`, reduced to planes over the canvas of
    /// the active document (sizes must match, as in Photoshop).
    static func source(_ s: Session, _ p: JSONValue, _ cmd: String, gray: Bool) throws -> [[Float]] {
        let di = try docIndex(s, p, "document")
        let st = s.documents[di]
        guard let target = s.active else { throw EngineError.noDocument }
        if st.doc.size != target.doc.size {
            throw bad(cmd, "source document \"\(st.doc.name)\" is \(st.doc.size.width)×\(st.doc.size.height); it must match the target size")
        }
        let r: ChanRef
        if let v = p["channel"] {
            guard let rr = parseRef(v, st.doc) else { throw bad(cmd, "unknown `channel`") }
            r = rr
        } else {
            r = .composite
        }
        let layer = p["layer"]?.uint64Value.map { LayerId($0) }
        var planes = gray ? [try grayPlane(s, st.doc, layer, st.activeLayer, r)] : try refPlanes(s, st.doc, layer, st.activeLayer, r)
        if planes.isEmpty || planes[0].isEmpty && st.doc.bounds.area > 0 { throw bad(cmd, "the source has no channels") }
        if p["invert"]?.boolValue ?? false {
            for k in planes.indices { planes[k] = planes[k].map { 1 - $0 } }
        }
        return planes
    }

    // MARK: Blending (Apply Image / Calculations)

    /// Apply Image / Calculations blending: the separable layer modes plus Add and Subtract with
    /// scale and offset.
    public enum Blending: Hashable, Sendable {
        case mode(BlendMode)
        case add(scale: Float, offset: Float)
        case subtract(scale: Float, offset: Float)

        public static func parse(_ p: JSONValue) -> Result<Blending, EngineError> {
            let name = p["blending"]?.stringValue ?? "multiply"
            let scale = Float(min(max(p["scale"]?.doubleValue ?? 1, 1), 2))
            let offset = Float(min(max(p["offset"]?.doubleValue ?? 0, -255), 255)) / 255
            let lower = asciiLower(name)
            switch lower {
            case "add": return .success(.add(scale: scale, offset: offset))
            case "subtract": return .success(.subtract(scale: scale, offset: offset))
            default:
                if let m = Params.blendMode(lower), m.isSeparable, m != .dissolve, m != .passThrough { return .success(.mode(m)) }
                return .failure(.other("unsupported blending `\(lower)`"))
            }
        }

        /// Blend `top` (the source) onto `base` (the target).
        public func apply(_ base: Float, _ top: Float) -> Float {
            let v: Float
            switch self {
            case .mode(let m): v = Blend.channel(m, base, top)
            case .add(let scale, let offset): v = (base + top) / scale + offset
            case .subtract(let scale, let offset): v = (base - top) / scale + offset
            }
            return v.isNaN ? 0 : min(max(v, 0), 1)
        }
    }

    static func blending(_ p: JSONValue, _ cmd: String) throws -> Blending {
        switch Blending.parse(p) {
        case .success(let b): return b
        case .failure(let e): throw bad(cmd, e.description)
        }
    }

    /// A source spec from `p[key]`, or from flat `<prefix>Document` / `<prefix>Layer` /
    /// `<prefix>Channel` / `<prefix>Invert` keys (what a generic dialog form sends).
    static func sourceSpec(_ p: JSONValue, _ key: String, _ prefix: String) -> JSONValue? {
        if let v = p[key] { return v }
        var m: [String: JSONValue] = [:]
        for (k, field) in [("document", "Document"), ("layer", "Layer"), ("channel", "Channel"), ("invert", "Invert")] {
            switch p["\(prefix)\(field)"] {
            case nil, .null?: continue
            case .string(let s)? where s.isEmpty || (k == "layer" && s == "merged"): continue
            case let v?: m[k] = v
            }
        }
        return m.isEmpty ? nil : .object(m)
    }

    static func maskPlane(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> [Float]? {
        switch sourceSpec(p, "mask", "mask") {
        case nil, .null?, .bool(false)?: return nil
        case let mk? where mk["channel"] == nil || mk["channel"] == .string("none"): return nil
        case let mk?: return try source(s, mk, cmd, gray: true).first
        }
    }

    // MARK: Preconditions

    static let hasChannels: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return d.doc.channels.isEmpty ? "the document has no alpha channels" : nil
    }
    static let hasSelection: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return d.doc.selection == nil ? "no selection" : nil
    }
    static let hasSpot: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return d.doc.channels.contains { $0.spot != nil } ? nil : "the document has no spot channels"
    }
    static let canSplit: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return colorCount(d.doc) + d.doc.channels.count < 2 ? "only one channel to split" : nil
    }
    static let canMerge: CommandEnabled = { s, _ in
        guard s.active != nil else { return "no document open" }
        return mergeable(s).count >= 2 ? nil : "Merge Channels needs at least two open grayscale documents of the same size"
    }
    /// Target Layer Mask: the active layer has a mask.
    static let hasLayerMask: CommandEnabled = { s, _ in
        guard let st = s.active else { return "no document open" }
        guard let l = st.activeLayer.flatMap({ st.doc.layer($0) }) else { return "no active layer" }
        return l.mask == nil ? "the active layer has no layer mask" : nil
    }
    static func slotOK(_ n: Int) -> CommandEnabled {
        { s, _ in
            guard let d = s.active else { return "no document open" }
            let colors = colorCount(d.doc)
            let shown = colors > 1 ? colors : 0
            return n - 3 < shown + d.doc.channels.count ? nil : "no channel for \(slotKey)\(n)"
        }
    }
    static let hasApplyTarget: CommandEnabled = { s, _ in
        if Channels.editsChannel(s) { return nil }
        guard let d = s.active else { return "no document open" }
        guard let l = d.activeLayer.flatMap({ d.doc.layer($0) }) else { return "no active layer" }
        if case .raster = l.content { return nil }
        return "Apply Image needs a pixel layer (active layer is \(l.content.article) \(l.content.kindName) layer)"
    }

    /// The channel shortcuts' modifier as the platform writes it (`⌘4`, `Ctrl+4`).
    #if os(macOS)
    static let slotKey = "⌘"
    #else
    static let slotKey = "Ctrl+"
    #endif

    // MARK: Save / Load Selection

    static func saveSelection(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "select.saveSelection"
        let op = p["operation"]?.stringValue ?? "new"
        guard ["new", "replace", "add", "subtract", "intersect"].contains(op) else { throw bad(cmd, "unknown operation `\(op)`") }
        let di = try docIndex(s, p, "document")
        guard let src = s.active else { throw EngineError.noDocument }
        let area = src.doc.bounds
        let selection = SelectionMath.mask(from: src.doc.selection, area)
        if s.documents[di].doc.size != src.doc.size { throw bad(cmd, "the destination document must have the same size") }
        let channel = p["channel"] ?? .null
        let name = p["name"]?.stringValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let prev = s.activeIndex
        _ = s.setActive(di)
        let r = Result { () throws -> Int in
            try s.edit("Save Selection") { doc, _ -> Int in
                let fmt = Channels.channelFormat(doc)
                var existing: Int?
                switch channel {
                case .null, .string("new"): existing = nil
                default:
                    guard case .alpha(let i)? = parseRef(channel, doc), i < doc.channels.count else {
                        throw bad(cmd, "`channel` must be \"new\" or an existing alpha channel")
                    }
                    existing = i
                }
                guard let i = existing, op != "new" else {
                    doc.channels.append(AlphaChannel(name: name ?? nextAlphaName(doc, "Alpha"), surface: planeSurface(selection, area, fmt)))
                    return doc.channels.count - 1
                }
                let old = readPlane(doc.channels[i].surface, area)
                let vals: [Float] = switch op {
                case "add": zip(old, selection).map { max($0, $1) }
                case "subtract": zip(old, selection).map { max($0 - $1, 0) }
                case "intersect": zip(old, selection).map { min($0, $1) }
                default: selection
                }
                doc.channels[i].surface = planeSurface(vals, area, fmt)
                if let n = name { doc.channels[i].name = n }
                return i
            }
        }
        if let i = prev { _ = s.setActive(i) }
        let i = try r.get()
        let channels = s.documents[di].doc.channels
        let chName = i < channels.count ? channels[i].name : ""
        return ["channel": .int(i), "name": .string(chName), "document": .int(di)]
    }

    static func loadSelection(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "select.loadSelection"
        let mode: SelectionMath.Mode
        switch p["operation"]?.stringValue ?? "new" {
        case "new", "replace": mode = .replace
        case "add": mode = .add
        case "subtract": mode = .subtract
        case "intersect": mode = .intersect
        case let other: throw bad(cmd, "unknown operation `\(other)`")
        }
        if p["channel"] == nil { throw bad(cmd, "missing `channel`") }
        // Composite and colour channels load their luminosity / values, as ⌘-clicking them does.
        guard let plane = try source(s, p, cmd, gray: true).first else { throw bad(cmd, "the channel has no pixels") }
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        let label = switch parseRef(p["channel"], doc) {
        case .transparency?: "Load Transparency"
        case .layerMask?: "Load Layer Mask"
        default: "Load Selection"
        }
        let selected = try s.edit(label) { doc, _ -> Bool in
            let area = doc.bounds
            var pl = plane
            if pl.count < area.area { pl += [Float](repeating: 0, count: area.area - pl.count) }
            doc.selection = SelectionMath.combine(doc.selection, pl, area, mode)
            return doc.selection != nil
        }
        return ["selected": .bool(selected)]
    }

    // MARK: Quick Mask

    /// Quick Mask channel for the current selection: white where selected. No selection is an
    /// empty mask that shows no colour (photocraft `quick_mask_from`).
    static func quickMaskFrom(_ doc: Document, _ o: QuickMaskOptions) -> AlphaChannel {
        let area = doc.bounds, fmt = Channels.channelFormat(doc)
        let surface = doc.selection.map { planeSurface(SelectionMath.mask(from: $0, area), area, fmt) } ?? unselectedSurface(area, fmt, o.indicates)
        var ch = AlphaChannel(name: "Quick Mask", surface: surface)
        ch.color = o.color
        ch.opacity = o.opacity
        ch.indicates = o.indicates
        return ch
    }

    /// The colourless, nothing-selected Quick Mask for `indicates`.
    static func unselectedSurface(_ area: PixelRect, _ fmt: PixelFormat, _ indicates: ColorIndicates) -> Surface {
        var s = Surface(format: fmt)
        if indicates != .selectedAreas && !area.isEmpty { s.fill(area, with: [Float](repeating: 1, count: fmt.channels)) }
        return s
    }

    /// Every pixel of `vals` reads as `target` on the 8-bit grid.
    static func uniform(_ vals: [Float], _ target: Float) -> Bool { vals.allSatisfy { abs($0 - target) <= 0.5 / 255 } }

    /// The selection a Quick Mask channel turns back into. All white is Select All, unless Quick
    /// Mask was entered with no selection and the white is its untouched start.
    static func selectionFrom(_ doc: Document, _ ch: AlphaChannel) -> Surface? {
        let area = doc.bounds
        let vals = readPlane(ch.surface, area)
        if doc.quickMaskUnselected && ch.indicates != .selectedAreas && uniform(vals, 1) { return nil }
        return SelectionMath.combine(nil, vals, area, .replace)
    }

    static func quickMask(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let st = s.active else { throw EngineError.noDocument }
        let on = st.doc.quickMask != nil
        let want = p["on"]?.boolValue ?? !on
        if want == on { return ["quickMask": .bool(on)] }
        let opts = s.state[QuickMaskOptionsKey.self]
        if want {
            try s.edit("Edit in Quick Mask") { doc, _ in
                doc.quickMask = quickMaskFrom(doc, opts)
                doc.quickMaskUnselected = doc.selection == nil
                doc.selection = nil
            }
            try s.updateActive { st in
                st.channelView.target = .composite
                st.channelView.quickMaskHidden = false
            }
        } else {
            try s.edit("Exit Quick Mask") { doc, _ in
                if let q = doc.quickMask {
                    doc.quickMask = nil
                    doc.selection = selectionFrom(doc, q)
                }
            }
        }
        return ["quickMask": .bool(want)]
    }

    // MARK: Channel management

    static func indicatesParam(_ v: JSONValue?) -> ColorIndicates? {
        switch v?.stringValue {
        case "masked"?, "maskedAreas"?: .maskedAreas
        case "selected"?, "selectedAreas"?: .selectedAreas
        default: nil
        }
    }

    static func colorValue(_ p: JSONValue, _ key: String) -> PCColor? {
        guard p[key] != nil else { return nil }
        let c = Params.color(p, key, SIMD4(1, 0, 0, 1))
        return .rgb(c.x, c.y, c.z)
    }

    static func percent(_ p: JSONValue, _ key: String) -> Float? {
        p[key]?.doubleValue.map { min(max(Float($0) / 100, 0), 1) }
    }

    static func newChannel(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let fill = p["fill"]?.stringValue ?? "black"
        let name = p["name"]?.stringValue
        let indicates = indicatesParam(p["indicates"])
        let color = colorValue(p, "color")
        let opacity = percent(p, "opacity")
        let i = try s.edit("New Channel") { doc, _ -> Int in
            let area = doc.bounds, fmt = Channels.channelFormat(doc)
            let surface: Surface = switch fill {
            case "white": planeSurface([Float](repeating: 1, count: area.area), area, fmt)
            case "selection": planeSurface(SelectionMath.mask(from: doc.selection, area), area, fmt)
            default: Surface(format: fmt)
            }
            var ch = AlphaChannel(name: name ?? nextAlphaName(doc, "Alpha"), surface: surface)
            if let v = indicates { ch.indicates = v }
            if let c = color { ch.color = c }
            if let o = opacity { ch.opacity = o }
            doc.channels.append(ch)
            return doc.channels.count - 1
        }
        // Photoshop targets and shows a new channel on its own.
        target(s, .alpha(i))
        return ["channel": .int(i)]
    }

    static func newSpot(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let color = colorValue(p, "color") ?? .rgb(1, 0, 0)
        let solidity = Float(min(max(p["solidity"]?.doubleValue ?? 0, 0), 100)) / 100
        let name = p["name"]?.stringValue
        let fromSel = p["fromSelection"]?.boolValue ?? true
        let i = try s.edit("New Spot Channel") { doc, _ -> Int in
            let area = doc.bounds, fmt = Channels.channelFormat(doc)
            let surface = fromSel && doc.selection != nil ? planeSurface(SelectionMath.mask(from: doc.selection, area), area, fmt) : Surface(format: fmt)
            var ch = AlphaChannel(name: name ?? nextAlphaName(doc, "Spot Color"), surface: surface)
            ch.spot = SpotInk(color: color, solidity: solidity)
            doc.channels.append(ch)
            return doc.channels.count - 1
        }
        try s.updateActive { st in
            st.channelView.setAlphaVisible(i, true)
            touch(&st)
        }
        return ["channel": .int(i)]
    }

    static func duplicateChannel(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "channel.duplicate"
        guard let src = s.active else { throw EngineError.noDocument }
        let area = src.doc.bounds
        guard let r = parseRef(p["channel"], src.doc) else { throw bad(cmd, "missing or unknown `channel`") }
        var ch: AlphaChannel
        switch r {
        case .alpha(let i):
            guard i < src.doc.channels.count else { throw bad(cmd, "no alpha channel \(i)") }
            ch = src.doc.channels[i]
        case .quickMask:
            guard let q = src.doc.quickMask else { throw bad(cmd, "not in Quick Mask mode") }
            ch = q
        default:
            let plane = try grayPlane(s, src.doc, nil, src.activeLayer, r)
            ch = AlphaChannel(name: "", surface: planeSurface(plane, area, Channels.channelFormat(src.doc)))
        }
        let mode = src.doc.pixelFormat.mode
        let base: String = switch r {
        case .alpha, .quickMask: ch.name
        case .color(let k): k < Channels.colorNames(mode).count ? Channels.colorNames(mode)[k] : Channels.compositeName(mode)
        default: Channels.compositeName(mode)
        }
        ch.name = p["name"]?.stringValue ?? "\(base) copy"
        if p["invert"]?.boolValue ?? false {
            ch.surface = planeSurface(readPlane(ch.surface, area).map { 1 - $0 }, area, ch.surface.format)
        }
        if p["document"] == .string("new") {
            // Photoshop makes a multichannel document; ours is grayscale with the channel as pixels.
            let doc = grayDocument(ch.name, src.doc, readPlane(ch.surface, area))
            let i = s.addDocument(doc)
            return ["document": .int(i)]
        }
        let di = try docIndex(s, p, "document")
        if s.documents[di].doc.size != src.doc.size { throw bad(cmd, "the destination document must have the same size") }
        let prev = s.activeIndex
        _ = s.setActive(di)
        let res = Result { () throws -> Int in
            try s.edit("Duplicate Channel") { doc, _ -> Int in
                let fmt = Channels.channelFormat(doc)
                var c = ch
                if c.surface.format != fmt { c.surface = c.surface.convertedAny(to: fmt) }
                doc.channels.append(c)
                return doc.channels.count - 1
            }
        }
        if let i = prev { _ = s.setActive(i) }
        return ["channel": .int(try res.get()), "document": .int(di)]
    }

    /// A one-layer grayscale document whose pixels are `plane` (Split Channels, Duplicate
    /// Channel to a new document).
    static func grayDocument(_ name: String, _ like: Document, _ plane: [Float]) -> Document {
        var d = Document(name: name, size: like.size, mode: .grayscale, depth: like.depth)
        d.resolutionDpi = like.resolutionDpi
        let fmt = d.pixelFormat
        var surf = Surface(format: fmt)
        let area = like.bounds
        if !area.isEmpty {
            let ch = fmt.channels
            var data = [Float](repeating: 1, count: area.area * ch)
            for i in 0..<area.area { data[i * ch] = i < plane.count ? min(max(plane[i], 0), 1) : 0 }
            surf.writeRegion(area, data)
            surf.prune()
        }
        var bg = Layer.raster("Background", surface: surf)
        bg.locks.transparency = true
        bg.locks.position = true
        d.layers.append(bg)
        return d
    }

    static func deleteChannel(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "channel.delete"
        guard let st = s.active else { throw EngineError.noDocument }
        let i: Int
        if p["channel"] != nil {
            i = try alphaIndex(st.doc, p, "channel", cmd)
        } else if case .alpha(let t) = st.channelView.target, t < st.doc.channels.count {
            i = t
        } else {
            throw bad(cmd, "missing `channel`")
        }
        // `edit` validates the view against the shorter channel list before it can be remapped:
        // keep the original indices and eyes so a surviving channel keeps its target and eye.
        let view = st.channelView
        try s.edit("Delete Channel") { doc, _ in
            guard i < doc.channels.count else { throw bad(cmd, "no alpha channel \(i) (document has \(doc.channels.count))") }
            doc.channels.remove(at: i)
        }
        try s.updateActive { st in
            var v = view
            if i < v.alphaVisible.count { v.alphaVisible.remove(at: i) }
            switch v.target {
            case .alpha(let t) where t == i:
                v.colorHidden.removeAll()
                v.target = .composite
            case .alpha(let t) where t > i:
                v.target = .alpha(t - 1)
            default:
                break
            }
            st.channelView = v
            fixViewNow(&st)
        }
        return .null
    }

    static func renameChannel(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "channel.rename"
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        let i = try alphaIndex(doc, p, "channel", cmd)
        guard let name = p["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { throw bad(cmd, "missing `name`") }
        try s.edit("Rename Channel") { doc, _ in doc.channels[i].name = name }
        return .null
    }

    static func moveChannel(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "channel.move"
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        let n = doc.channels.count
        let i = try alphaIndex(doc, p, "channel", cmd)
        guard let toRaw = p["to"]?.uint64Value else { throw bad(cmd, "missing `to`") }
        let to = Int(min(toRaw, UInt64(max(n - 1, 0))))
        if to == i { return ["channel": .int(i)] }
        try s.edit("Channel Order") { doc, _ in
            let c = doc.channels.remove(at: i)
            doc.channels.insert(c, at: to)
        }
        try s.updateActive { st in
            var v = st.channelView
            if v.alphaVisible.count < n { v.alphaVisible += [Bool](repeating: false, count: n - v.alphaVisible.count) }
            if v.alphaVisible.count > n { v.alphaVisible.removeLast(v.alphaVisible.count - n) }
            let vis = v.alphaVisible.remove(at: i)
            v.alphaVisible.insert(vis, at: to)
            if case .alpha(let t) = v.target {
                let nt: Int
                if t == i { nt = to } else if i < t && t <= to { nt = t - 1 } else if to <= t && t < i { nt = t + 1 } else { nt = t }
                v.target = .alpha(nt)
            }
            st.channelView = v
            touch(&st)
        }
        return ["channel": .int(to)]
    }

    /// Make `t` the edit target and show it the way Photoshop does when its row is clicked.
    static func target(_ s: Session, _ t: ChannelTarget) {
        try? s.updateActive { st in
            let colors = colorCount(st.doc), n = st.doc.channels.count
            var v = st.channelView
            v.target = t
            switch t {
            case .composite, .layerMask, .vectorMask:
                v.colorHidden.removeAll()
            case .color(let k):
                v.colorHidden = (0..<colors).map { $0 != k }
                v.alphaVisible.removeAll()
            case .alpha(let i):
                v.colorHidden = [Bool](repeating: true, count: colors)
                v.alphaVisible = (0..<n).map { $0 == i }
            }
            st.channelView = v
            fixViewNow(&st)
        }
        s.tools.targetMask(t == .layerMask)
    }

    static func parseTarget(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> ChannelTarget {
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        let r: ChanRef? = p["channel"].map { parseRef($0, doc) } ?? .composite
        let colors = colorCount(doc)
        switch r {
        case .composite?: return .composite
        case .color(let k)? where k < colors && colors > 1: return .color(k)
        case .alpha(let i)? where i < doc.channels.count: return .alpha(i)
        case .layerMask?:
            switch s.activeLayer() {
            case .failure(let e): throw bad(cmd, e.description)
            case .success(let l): if l.mask == nil { throw bad(cmd, "the active layer has no layer mask") }
            }
            return .layerMask
        case .vectorMask?:
            switch s.activeLayer() {
            case .failure(let e): throw bad(cmd, e.description)
            case .success(let l): if l.vectorMask == nil { throw bad(cmd, "the active layer has no vector mask") }
            }
            return .vectorMask
        default:
            throw bad(cmd, "`channel` must be \"composite\", \"mask\", \"vectorMask\", a colour channel name or an alpha channel")
        }
    }

    static func targetCommand(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let t = try parseTarget(s, p, "channel.target")
        target(s, t)
        return list(s)
    }

    /// ⌘2 composite, ⌘3… colour channels then alpha channels (Photoshop CC defaults).
    static func targetSlot(_ s: Session, _ slot: Int) throws -> JSONValue {
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        let colors = colorCount(doc)
        let shown = colors > 1 ? colors : 0
        let t: ChannelTarget
        if slot == 2 {
            t = .composite
        } else if slot >= 3 && slot - 3 < shown {
            t = .color(slot - 3)
        } else if slot >= 3 && slot - 3 - shown < doc.channels.count {
            t = .alpha(slot - 3 - shown)
        } else {
            throw EngineError.other("no channel for \(slotKey)\(slot)")
        }
        target(s, t)
        return list(s)
    }

    static func setVisible(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "channel.setVisible"
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        guard let r = parseRef(p["channel"], doc) else { throw bad(cmd, "missing or unknown `channel`") }
        let colors = colorCount(doc), n = doc.channels.count
        let requested = p["visible"]?.boolValue
        try s.updateActive { st in
            var v = st.channelView
            func visible(_ cur: Bool) -> Bool { requested ?? !cur }
            switch r {
            case .composite:
                let on = visible(v.visibleColors(colors) == colors)
                v.colorHidden = [Bool](repeating: !on, count: colors)
            case .color(let k) where k < colors:
                v.setColorVisible(k, visible(v.colorVisible(k)))
            case .alpha(let i) where i < n:
                v.setAlphaVisible(i, visible(v.alphaShown(i)))
            case .quickMask:
                v.quickMaskHidden = !visible(!v.quickMaskHidden)
            default:
                throw bad(cmd, "that channel has no visibility")
            }
            st.channelView = v
            fixViewNow(&st)
        }
        return list(s)
    }

    static func options(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "channel.options"
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        guard let r = parseRef(p["channel"], doc) else { throw bad(cmd, "missing or unknown `channel`") }
        let name = p["name"]?.stringValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let color = colorValue(p, "color")
        let opacity = percent(p, "opacity"), solidity = percent(p, "solidity")
        let kind = p["indicates"]?.stringValue
        func apply(_ ch: inout AlphaChannel) throws {
            if let n = name { ch.name = n }
            switch kind {
            case "spot"?:
                let c = ch.spot?.color ?? ch.color, sol = ch.spot?.solidity ?? 0
                ch.spot = SpotInk(color: color ?? c, solidity: solidity ?? sol)
                return
            case let k?:
                guard let ind = indicatesParam(.string(k)) else { throw bad(cmd, "unknown `indicates` \(k)") }
                ch.indicates = ind
                ch.spot = nil
            case nil:
                break
            }
            if var sp = ch.spot {
                sp.color = color ?? sp.color
                sp.solidity = solidity ?? opacity ?? sp.solidity
                ch.spot = sp
            } else {
                ch.color = color ?? ch.color
                ch.opacity = opacity ?? ch.opacity
            }
        }
        switch r {
        case .alpha(let i) where i < doc.channels.count:
            try s.edit("Channel Options") { doc, _ in try apply(&doc.channels[i]) }
        case .quickMask:
            // Quick Mask Options persist for the session; the live Quick Mask follows them.
            let cur = s.state[QuickMaskOptionsKey.self]
            var probe = AlphaChannel(name: "Quick Mask", surface: Surface(format: .gray8))
            probe.color = cur.color
            probe.opacity = cur.opacity
            probe.indicates = cur.indicates
            try apply(&probe)
            if probe.spot != nil { throw bad(cmd, "Quick Mask can't be a spot channel") }
            var o = QuickMaskOptions()
            o.color = probe.color
            o.opacity = probe.opacity
            o.indicates = probe.indicates
            s.state[QuickMaskOptionsKey.self] = o
            if s.active?.doc.quickMask != nil {
                try s.edit("Quick Mask Options") { doc, _ in
                    let area = doc.bounds, fmt = Channels.channelFormat(doc)
                    let unselected = doc.quickMaskUnselected
                    guard var q = doc.quickMask else { return }
                    // An untouched no-selection mask stays colourless (nothing selected) when the
                    // colour switches between masked and selected areas.
                    if unselected && q.indicates != o.indicates {
                        let empty: Float = q.indicates == .selectedAreas ? 0 : 1
                        if uniform(readPlane(q.surface, area), empty) { q.surface = unselectedSurface(area, fmt, o.indicates) }
                    }
                    q.color = o.color
                    q.opacity = o.opacity
                    q.indicates = o.indicates
                    doc.quickMask = q
                }
            }
        default:
            throw bad(cmd, "`channel` must be an alpha/spot channel or \"quickMask\"")
        }
        return list(s)
    }

    /// Merge Spot Channel: flattens the image and prints the spot ink into the colour channels.
    static func mergeSpot(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "channel.mergeSpot"
        guard let st = s.active else { throw EngineError.noDocument }
        let doc = st.doc
        let i: Int
        if p["channel"] != nil {
            i = try alphaIndex(doc, p, "channel", cmd)
        } else if case .alpha(let t) = st.channelView.target, t < doc.channels.count {
            i = t
        } else if let f = doc.channels.firstIndex(where: { $0.spot != nil }) {
            i = f
        } else {
            throw bad(cmd, "no spot channel")
        }
        guard let spot = doc.channels[i].spot else { throw bad(cmd, "not a spot channel") }
        let renderer = s.services.renderer
        try s.edit("Merge Spot Channel") { doc, active in
            let area = doc.bounds, fmt = doc.pixelFormat
            let comp = try renderer.render(doc, region: area).px
            let k = readPlane(doc.channels[i].surface, area)
            let ink = spot.color.rgb, sol = spot.solidity
            // Ink over the image: opaque at 100% solidity, multiplied (transparent ink) at 0%.
            let rgba: [SIMD4<Float>] = zip(comp, k).map { c, v in
                let cv = SIMD3(c.x, c.y, c.z)
                let over = sol * ink + (1 - sol) * cv * ink
                let w = v.isNaN ? 0 : min(max(v, 0), 1)
                return SIMD4(cv + (over - cv) * w, 1)
            }
            var surf = Surface(format: fmt)
            if !area.isEmpty && rgba.count == area.area {
                surf.writeRegion(area, PixelCodec.fromRGBA(fmt, rgba: rgba))
                surf.prune()
            }
            var bg = Layer.raster("Background", surface: surf)
            bg.locks.transparency = true
            bg.locks.position = true
            doc.layers = [bg]
            doc.channels.remove(at: i)
            active = bg.id
        }
        try s.updateActive { st in
            st.channelView = ChannelView()
            fixViewNow(&st)
        }
        return .null
    }

    /// Split Channels: one grayscale document per colour and alpha channel; closes the original.
    static func split(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let idx = s.activeIndex, idx < s.documents.count else { throw EngineError.noDocument }
        let doc = s.documents[idx].doc
        let area = doc.bounds
        let (px, n) = try nativePixels(s, doc, nil)
        let count = n > 0 ? px.count / n : 0
        let names = Channels.colorNames(doc.pixelFormat.mode)
        func short(_ name: String) -> String { name.first.map { String($0).uppercased() } ?? "" }
        var docs: [Document] = []
        for (c, cname) in names.enumerated() where c < n {
            let plane = (0..<count).map { px[$0 * n + c] }
            docs.append(grayDocument("\(doc.name)_\(short(cname))", doc, plane))
        }
        for ch in doc.channels {
            docs.append(grayDocument("\(doc.name)_\(ch.name)", doc, readPlane(ch.surface, area)))
        }
        if p["closeOriginal"]?.boolValue ?? true { s.close(idx) }
        let made = docs.map { s.addDocument($0) }
        return ["documents": .array(made.map { .int($0) })]
    }

    /// Open grayscale documents with the active document's size, active first.
    static func mergeable(_ s: Session) -> [Int] {
        guard let a = s.active, let ai = s.activeIndex else { return [] }
        func ok(_ d: DocState) -> Bool { d.doc.mode == .grayscale && d.doc.size == a.doc.size }
        var v: [Int] = ok(a) ? [ai] : []
        v += s.documents.indices.filter { $0 != ai && ok(s.documents[$0]) }
        return v
    }

    /// Merge Channels: grayscale documents of one size become the channels of an RGB, CMYK or
    /// Lab document (extra documents become alpha channels); the sources close.
    static func merge(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "channel.merge"
        let mode: ColorMode
        let modeName: String
        switch p["mode"]?.stringValue ?? "rgb" {
        case "rgb": (mode, modeName) = (.rgb, "Rgb")
        case "cmyk": (mode, modeName) = (.cmyk, "Cmyk")
        case "lab": (mode, modeName) = (.lab, "Lab")
        case let other: throw bad(cmd, "unknown mode `\(other)`")
        }
        let srcs: [Int]
        if let a = p["documents"]?.arrayValue {
            srcs = try a.map { v in
                guard let i = v.uint64Value, i < UInt64(s.documents.count) else { throw bad(cmd, "bad document index") }
                return Int(i)
            }
        } else {
            srcs = Array(mergeable(s).prefix(mode.colorChannels))
        }
        let cc = mode.colorChannels
        if srcs.count < cc { throw bad(cmd, "\(modeName) needs \(cc) grayscale documents, got \(srcs.count)") }
        // Each source closes by its current index, so a repeated index would shift the later
        // removals onto a document that was never named (#934).
        var seen = Set<Int>()
        if let dup = srcs.first(where: { !seen.insert($0).inserted }) { throw bad(cmd, "document \(dup) is listed more than once") }
        guard let firstIndex = srcs.first, firstIndex < s.documents.count else { throw bad(cmd, "bad document index") }
        let first = s.documents[firstIndex].doc
        var planes: [[Float]] = []
        for i in srcs {
            let d = s.documents[i].doc
            if d.size != first.size || d.mode != .grayscale { throw bad(cmd, "\"\(d.name)\" is not a grayscale document of the same size") }
            planes.append(try grayPlane(s, d, nil, nil, .composite))
        }
        var out = Document(name: p["name"]?.stringValue ?? "Untitled", size: first.size, mode: mode, depth: first.depth)
        out.resolutionDpi = first.resolutionDpi
        let fmt = out.pixelFormat, ch = fmt.channels
        let area = out.bounds
        let npx = area.area
        var data = [Float](repeating: 1, count: npx * ch)
        for i in 0..<npx {
            for (c, pl) in planes.prefix(cc).enumerated() { data[i * ch + c] = i < pl.count ? min(max(pl[i], 0), 1) : 0 }
        }
        var surf = Surface(format: fmt)
        if npx > 0 {
            surf.writeRegion(area, data)
            surf.prune()
        }
        var bg = Layer.raster("Background", surface: surf)
        bg.locks.transparency = true
        bg.locks.position = true
        out.layers.append(bg)
        let cf = Channels.channelFormat(out)
        for (k, pl) in planes.dropFirst(cc).enumerated() {
            out.channels.append(AlphaChannel(name: "Alpha \(k + 1)", surface: planeSurface(pl, area, cf)))
        }
        for i in srcs.sorted().reversed() { s.close(i) }
        let i = s.addDocument(out)
        return ["document": .int(i)]
    }

    // MARK: Apply Image / Calculations

    static func applyImage(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.applyImage"
        let blend = try blending(p, cmd)
        let opacity = Float(min(max(p["opacity"]?.doubleValue ?? 100, 0), 100)) / 100
        let preserve = p["preserveTransparency"]?.boolValue ?? false
        let srcSpec = sourceSpec(p, "source", "source") ?? .object([:])
        let src = try source(s, srcSpec, cmd, gray: false)
        let mask = try maskPlane(s, p, cmd)
        let layer = s.active?.activeLayer
        try s.edit("Apply Image") { doc, _ in
            let area = doc.bounds
            let selection = doc.selection.map { SelectionMath.mask(from: $0, area) }
            func at(_ a: [Float]?, _ i: Int) -> Float { a.map { i < $0.count ? $0[i] : 0 } ?? 1 }
            func weight(_ i: Int) -> Float { opacity * at(mask, i) * at(selection, i) }
            if Channels.isChannelTarget(p) {
                // A grayscale target gets the average of a colour source (one plane).
                let srcp: [Float] = src.count == 1 ? src[0] : (0..<src[0].count).map { i in src.reduce(0) { $0 + $1[i] } / Float(src.count) }
                try Channels.withTargetSurface(&doc, layer: nil, p) { surf, _ in
                    let base = readPlane(surf, area)
                    let out = base.enumerated().map { i, b in b + (blend.apply(b, at(srcp, i)) - b) * weight(i) }
                    surf = planeSurface(out, area, surf.format)
                }
                return
            }
            guard let id = layer else { throw EngineError.other("no active layer") }
            let fmt = doc.pixelFormat
            try LayerOps.withPaintSurface(&doc, id, .null) { surf in
                let sf = surf.format
                if sf != fmt { throw EngineError.other("the target layer's format doesn't match the document") }
                let n = sf.channels, colors = sf.mode.colorChannels
                var v = surf.readRegion(area)
                for i in 0..<area.area {
                    let o = i * n
                    let baseA: Float = sf.alpha ? min(max(v[o + colors], 0), 1) : 1
                    var w = weight(i)
                    if preserve { w *= baseA }
                    if w <= 0 { continue }
                    // Painted over the layer like a brush: the blend acts only where the layer has
                    // pixels, and the alpha grows by source-over.
                    let outA = preserve ? baseA : w + baseA * (1 - w)
                    for c in 0..<colors {
                        let plane = c < src.count ? src[c] : src[0]
                        let top = at(plane, i)
                        let b = v[o + c]
                        let blended = top + (blend.apply(b, top) - top) * baseA
                        v[o + c] = preserve ? b + (blended - b) * w : (w * blended + baseA * (1 - w) * b) / outA
                    }
                    if sf.alpha { v[o + colors] = outA }
                }
                surf.writeRegion(area, v)
                surf.prune()
            }
        }
        return .null
    }

    static func calculations(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.calculations"
        let blend = try blending(p, cmd)
        let opacity = Float(min(max(p["opacity"]?.doubleValue ?? 100, 0), 100)) / 100
        guard let s1 = try source(s, sourceSpec(p, "source1", "source1") ?? .object([:]), cmd, gray: true).first,
              let s2 = try source(s, sourceSpec(p, "source2", "source2") ?? .object([:]), cmd, gray: true).first else {
            throw bad(cmd, "the source has no channels")
        }
        let mask = try maskPlane(s, p, cmd)
        // Source 1 is blended onto Source 2.
        let out: [Float] = zip(s2, s1).enumerated().map { i, bt in
            let (b, t) = bt
            let m = mask.map { i < $0.count ? $0[i] : 0 } ?? 1
            return b + (blend.apply(b, t) - b) * opacity * m
        }
        let name = p["name"]?.stringValue
        switch p["result"]?.stringValue ?? "newChannel" {
        case "newChannel":
            let i = try s.edit("Calculations") { doc, _ -> Int in
                let area = doc.bounds
                doc.channels.append(AlphaChannel(name: name ?? nextAlphaName(doc, "Alpha"), surface: planeSurface(out, area, Channels.channelFormat(doc))))
                return doc.channels.count - 1
            }
            return ["channel": .int(i)]
        case "newDocument":
            guard let like = s.active?.doc else { throw EngineError.noDocument }
            let i = s.addDocument(grayDocument(name ?? "Untitled", like, out))
            return ["document": .int(i)]
        case "selection":
            let selected = try s.edit("Calculations") { doc, _ -> Bool in
                let area = doc.bounds
                var o = out
                if o.count < area.area { o += [Float](repeating: 0, count: area.area - o.count) }
                doc.selection = SelectionMath.combine(nil, o, area, .replace)
                return doc.selection != nil
            }
            return ["selected": .bool(selected)]
        case let other:
            throw bad(cmd, "unknown result `\(other)` (newChannel|newDocument|selection)")
        }
    }

    // MARK: State as JSON

    static func rgbJSON(_ c: PCColor) -> JSONValue {
        let v = c.rgb
        return [.float(v.x), .float(v.y), .float(v.z)]
    }

    /// The Channels panel rows and view state of a document (photocraft `channels_json`).
    public static func channelsJSON(_ st: DocState) -> JSONValue {
        let doc = st.doc, mode = doc.pixelFormat.mode, v = st.channelView
        let colors = colorCount(doc)
        return [
            "composite": .string(Channels.compositeName(mode)),
            "colors": .array(Channels.colorNames(mode).enumerated().map { k, n in ["name": .string(n), "visible": .bool(v.colorVisible(k))] }),
            "alpha": .array(doc.channels.enumerated().map { i, c in
                [
                    "index": .int(i), "name": .string(c.name), "visible": .bool(v.alphaShown(i)),
                    "spot": c.spot.map { ["color": rgbJSON($0.color), "solidity": .float($0.solidity)] } ?? .null,
                    "color": rgbJSON(c.color), "opacity": .float(c.opacity), "indicates": .string(c.indicates.rawValue),
                ]
            }),
            "quickMask": doc.quickMask.map { q in
                ["visible": .bool(!v.quickMaskHidden), "color": rgbJSON(q.color), "opacity": .float(q.opacity), "indicates": .string(q.indicates.rawValue)]
            } ?? .null,
            "target": v.target.json,
            "compositeVisible": .bool(v.visibleColors(colors) == colors),
            "layerMaskView": st.currentMaskView.map { ["layer": .id($0.layer), "mode": .string($0.mode.rawValue)] } ?? .null,
        ]
    }

    static func list(_ s: Session) -> JSONValue { s.active.map(channelsJSON) ?? .null }
}
