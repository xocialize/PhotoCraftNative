// Port of photocraft-engine (crates/engine/src/commands.rs: the core table — File › New/Close, Undo/Redo, Clear, Select All/Deselect/Inverse/Rectangular Marquee, the Layer menu basics, adjustment layers and destructive adjustments generated from one list, Image Rotation, the tool colours and the session queries; new_layer.rs; inspect.rs commands), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCHistory
import PCRender

enum CoreCommands: CommandModule {
    static let name = "commands"
    static let m = "commands"

    static func register(into r: inout CommandRegistry) {
        Channels.installHooks(&r)
        r.add(fileCommands())
        r.add(editAndSelect())
        r.add(layerCommands())
        r.add(imageRotation())
        r.add(toolsAndQueries())
        r.add(adjustmentCommands())
    }

    // MARK: File

    static let maxDimension = 300_000
    static let maxResolution = 30_000.0

    static func fileCommands() -> [CommandSpec] {
        [
            CommandSpec("file.new", "New…", menu: ["File"], shortcut: "Cmd+N",
                        params: #"{"width":1..300000=1920,"height":1..300000=1080 (pixel counts are rounded),"mode":"rgb|gray|grayscale|cmyk|lab"="rgb","depth":8|16|32=8,"background":"white|black|backgroundColor|transparent|#rrggbb"="white","backgroundColor":[r,g,b]? (0..1; defaults to toolbox colour),"resolution":1..30000=72 (ppi),"name":str}"#,
                        module: m, run: fileNew),
            CommandSpec("file.close", "Close", menu: ["File"], shortcut: "Cmd+W", params: #"{"document":index?}"#, module: m, enabled: Pre.hasDoc) { s, p in
                let i = p["document"]?.uint64Value.map { Int($0) } ?? s.activeIndex
                guard let i, s.close(i) != nil else { throw EngineError.noDocument }
                return .null
            },
        ]
    }

    static func colorMode(_ s: String) -> ColorMode? {
        switch s.lowercased() {
        case "rgb": .rgb
        case "gray", "grayscale": .grayscale
        case "cmyk": .cmyk
        case "lab": .lab
        default: nil
        }
    }

    static func sampleType(_ bits: Int) -> SampleType? {
        switch bits {
        case 8: .u8
        case 16: .u16
        case 32: .f32
        default: nil
        }
    }

    /// photocraft `document_preset_cmds::background_color`: `[r,g,b]` in 0…1 (fallback when absent).
    static func backgroundColor(_ p: JSONValue, fallback: SIMD4<Float>, cmd: String) throws -> SIMD4<Float> {
        guard let v = p["backgroundColor"] else { return SIMD4(fallback.x, fallback.y, fallback.z, 1) }
        guard let a = v.arrayValue, a.count == 3, let c = Optional(a.compactMap(\.doubleValue)), c.count == 3,
              c.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
            throw EngineError.bad(cmd, "`backgroundColor` must be [r,g,b] in 0..1")
        }
        return SIMD4(Float(c[0]), Float(c[1]), Float(c[2]), 1)
    }

    /// photocraft `document_preset_cmds::validate_new_params`: every field typed and in range,
    /// unknown fields refused, before anything changes (dispatch runs it first).
    static func validateNew(_ p: JSONValue) throws {
        let cmd = "file.new"
        if p == .null { return }
        guard let fields = p.objectValue else { throw EngineError.bad(cmd, "params must be a JSON object") }
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            let valid: Bool
            let expected: String
            switch key {
            case "width", "height", "resolution":
                let mx = key == "resolution" ? maxResolution : Double(maxDimension)
                valid = value.doubleValue.map { $0.isFinite && $0 >= 1 && $0 <= mx } ?? false
                expected = "a number within 1..=\(key == "resolution" ? "30000" : "\(maxDimension)")"
            case "mode":
                valid = value.stringValue.flatMap(colorMode) != nil
                expected = "rgb, gray, grayscale, cmyk or lab"
            case "depth":
                valid = value.uint64Value.flatMap { sampleType(Int($0)) } != nil
                expected = "8, 16 or 32"
            case "background":
                valid = value.stringValue.map { v in
                    ["white", "black", "transparent", "backgroundColor"].contains(v)
                        || ((v.hasPrefix("#") ? v.dropFirst() : Substring(v)).allSatisfy(\.isHexDigit) && Params.parseHex(v) != nil)
                } ?? false
                expected = "white, black, transparent, backgroundColor or a valid hex colour"
            case "backgroundColor":
                _ = try backgroundColor(p, fallback: SIMD4(1, 1, 1, 1), cmd: cmd)
                continue
            case "name":
                valid = value.stringValue != nil
                expected = "a string"
            case "coalesce":
                continue
            default:
                throw EngineError.bad(cmd, "unknown parameter `\(key)`")
            }
            if !valid { throw EngineError.bad(cmd, "`\(key)` must be \(expected)") }
        }
    }

    static func fileNew(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        try validateNew(p)
        func px(_ k: String, _ d: Int) -> Int {
            guard let v = p[k]?.doubleValue, v.isFinite else { return d }
            return Int(min(max(v.rounded(), 1), Double(maxDimension)))
        }
        let (w, h) = (px("width", 1920), px("height", 1080))
        let mode = colorMode(p["mode"]?.stringValue ?? "rgb") ?? .rgb
        let depth = sampleType(p["depth"]?.intValue ?? 8) ?? .u8
        let name = p["name"]?.stringValue ?? "Untitled"
        let res = Float(min(max(p["resolution"]?.doubleValue ?? 72, 1), maxResolution))
        let size = PixelSize(width: w, height: h)
        var doc: Document
        switch p["background"]?.stringValue ?? "white" {
        case "transparent":
            doc = Document(name: name, size: size, mode: mode, depth: depth)
            doc.layers.append(.raster("Layer 1", format: doc.pixelFormat))
        case let bg:
            let c: SIMD4<Float>
            switch bg {
            case "backgroundColor": c = try backgroundColor(p, fallback: s.tools.background, cmd: "file.new")
            case "black": c = SIMD4(0, 0, 0, 1)
            default: c = Params.parseHex(bg) ?? SIMD4(1, 1, 1, 1)
            }
            // One shared tile per whole tile and per edge shape: a 300 000² canvas costs a few
            // tiles, not 360 GB (#705).
            doc = Document.withBackground(name: name, size: size, mode: mode, depth: depth, fill: .rgb(c.x, c.y, c.z, c.w))
        }
        doc.resolutionDpi = res
        let i = s.addDocument(doc)
        return ["document": .int(i)]
    }

    // MARK: Edit and Select

    static func editAndSelect() -> [CommandSpec] {
        [
            CommandSpec("edit.undo", "Undo", menu: ["Edit"], shortcut: "Cmd+Z", module: m, enabled: Pre.canUndo) { s, _ in .bool(s.undo()) },
            CommandSpec("edit.redo", "Redo", menu: ["Edit"], shortcut: "Cmd+Shift+Z", module: m, enabled: Pre.canRedo) { s, _ in .bool(s.redo()) },
            CommandSpec("edit.clear", "Clear", menu: ["Edit"], shortcut: "Delete", params: "{} (a targeted channel or Quick Mask is cleared alone)",
                        module: m, enabled: hasPixelOrChannel, run: clear),
            CommandSpec("select.all", "All", menu: ["Select"], shortcut: "Cmd+A", module: m, enabled: Pre.hasDoc) { s, _ in
                try s.edit("Select All") { doc, _ in
                    var sel = Surface(format: .gray8)
                    sel.fill(doc.bounds, with: [1])
                    doc.selection = sel
                }
                return .null
            },
            CommandSpec("select.deselect", "Deselect", menu: ["Select"], shortcut: "Cmd+D", module: m, enabled: Pre.hasSelection) { s, _ in
                try s.edit("Deselect") { doc, _ in doc.selection = nil }
                return .null
            },
            CommandSpec("select.inverse", "Inverse", menu: ["Select"], shortcut: "Cmd+Shift+I", module: m, enabled: Pre.hasSelection) { s, _ in
                try s.edit("Inverse") { doc, _ in
                    let old = doc.selection ?? Surface(format: .gray8)
                    let b = doc.bounds
                    let data = old.coverage(b).map { 1 - $0 }
                    var sel = Surface(format: .gray8)
                    sel.writeRegion(b, data)
                    sel.prune()
                    // Inverting everything leaves nothing selected: Photoshop deselects (AB-T-0279).
                    doc.selection = sel.tileCount > 0 ? sel : nil
                }
                return .null
            },
            CommandSpec("select.rect", "Rectangular Selection",
                        params: #"{"x":i32,"y":i32,"width":u32,"height":u32,"mode":"replace|add|subtract|intersect"="replace","ellipse":bool=false,"line":"row|column"?,"antiAlias":bool=true,"feather":px=0}"#,
                        module: m, enabled: Pre.hasDoc, run: selectRect),
        ]
    }

    static let hasPixelOrChannel: CommandEnabled = { s, p in Channels.editsChannel(s) ? nil : Pre.hasPixelLayer(s, p) }

    static func clear(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let bg = s.tools.background
        if let t = Channels.targetedChannel(s) {
            try s.edit("Clear") { doc, _ in try Channels.clearChannel(&doc, t, background: bg) }
            return .null
        }
        let id = try s.layerParam(p)
        if let k = Channels.targetedColor(s) {
            try s.edit("Clear") { doc, _ in try Channels.clearColorChannel(&doc, id, k, background: bg) }
            return .null
        }
        try s.edit("Clear") { doc, _ in
            let sel = doc.selection
            let area = sel?.contentBounds ?? doc.bounds
            try clearArea(&doc, id, area, sel, background: bg)
        }
        return .null
    }

    /// Clear on a layer: transparent pixels, or the background colour on the Background (or a
    /// layer with locked transparency), as Photoshop does (photocraft `edit_cmds::clear_area`).
    static func clearArea(_ doc: inout Document, _ id: LayerId, _ area: PixelRect, _ sel: Surface?, background: SIMD4<Float>) throws {
        let fill = doc.isBackground(id) || doc.effectiveLocks(id).transparency
        try LayerOps.withPaintSurface(&doc, id, .null) { surf in
            if fill || !surf.format.alpha {
                Pixels.fillSurface(&surf, area, color: SIMD4(background.x, background.y, background.z, 1), selection: sel, lockTransparency: true)
            } else {
                Pixels.clearSurface(&surf, area, selection: sel)
            }
        }
    }

    static func selectRect(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "select.rect"
        let x = try Params.requiredI32(cmd, p, "x"), y = try Params.requiredI32(cmd, p, "y")
        let w = max(try Params.requiredI32(cmd, p, "width"), 0), h = max(try Params.requiredI32(cmd, p, "height"), 0)
        let r = PixelRect(x0: x, y0: y, x1: Int32(clamping: Int64(x) + Int64(w)), y1: Int32(clamping: Int64(y) + Int64(h)))
        let mode = SelectionMath.Mode.parse(p["mode"]?.stringValue ?? "replace")
        let ellipse = p["ellipse"]?.boolValue ?? false
        let step: String
        switch p["line"]?.stringValue {
        case "row": step = "Single Row Marquee"
        case "column": step = "Single Column Marquee"
        case .some(let other): throw EngineError.bad(cmd, "unknown `line` \"\(other)\" (row|column)")
        case nil: step = ellipse ? "Elliptical Marquee" : "Rectangular Marquee"
        }
        let aa = p["antiAlias"]?.boolValue ?? true
        let feather = Float(min(max(p["feather"]?.doubleValue ?? 0, 0), 1000))
        try s.edit(step) { doc, _ in
            let area = doc.bounds
            let shape: Surface
            if ellipse {
                shape = SelectionMath.ellipseSurface(r, area: area, antiAlias: aa)
            } else {
                var sh = Surface(format: .gray8)
                sh.fill(r.intersect(area), with: [1])
                shape = sh
            }
            if feather > 0 {
                let m = SelectionMath.feather(SelectionMath.mask(from: shape, area), area.width, area.height, feather)
                doc.selection = SelectionMath.combine(doc.selection, m, area, mode)
                return
            }
            doc.selection = SelectionMath.combineShape(doc.selection, shape, area, mode)
        }
        return .null
    }

    // MARK: Layer

    static func layerCommands() -> [CommandSpec] {
        [
            CommandSpec("layer.new.layer", "Layer…", menu: ["Layer", "New"], shortcut: "Cmd+Shift+N",
                        params: #"{"name":str?,"clipToPrevious":bool=false (Use Previous Layer to Create Clipping Mask; inside a clip group the layer joins it anyway),"color":"none|red|orange|yellow|green|seafoam|blue|indigo|magenta|fuchsia|violet|gray"="none","mode":"Normal|Multiply|…"="Normal","opacity":0..1=1,"fillNeutral":bool=false (fill with the mode's neutral color: modes without one are an error)}"#,
                        module: m, enabled: Pre.hasDoc, run: newLayer),
            CommandSpec("layer.new.group", "Group…", menu: ["Layer", "New"], params: #"{"name":str?}"#, module: m, enabled: Pre.hasDoc) { s, p in
                let id = try s.edit("New Group") { doc, active -> LayerId in
                    let name = p["name"]?.stringValue ?? doc.nextLayerName("Group")
                    let id = doc.insertAbove(active, .group(name, []))
                    active = id
                    return id
                }
                return ["layer": .id(id)]
            },
            CommandSpec("layer.groupLayers", "Group Layers", menu: ["Layer"], shortcut: "Cmd+G",
                        params: #"{"layer":id?,"name":str?} (no layer: every selected layer)"#, module: m, enabled: Pre.hasLayer, run: LayerMulti.groupLayers),
            CommandSpec("layer.duplicate", "Duplicate Layer…", menu: ["Layer"],
                        params: #"{"layer":id?,"inPlace":bool=false (artboards: keep the copy on the original instead of beside it),"name":str? (one layer: the copy's name)} (no layer: every selected layer)"#,
                        module: m, enabled: Pre.hasLayer, run: duplicate),
            CommandSpec("layer.delete", "Delete Layer", menu: ["Layer", "Delete"], params: #"{"layer":id?} (no layer: every selected layer)"#,
                        module: m, enabled: Pre.hasLayer, run: deleteLayer),
            CommandSpec("layer.select", "Select Layer", params: #"{"layer":id,"mode":"replace|toggle|range|add"="replace"} (toggle = ⌘-click, range = ⇧-click)"#,
                        module: m, enabled: Pre.hasDoc, run: LayerMulti.select),
            CommandSpec("layer.setProps", "Layer Properties",
                        params: #"{"layer":id?,"name":str?,"visible":bool?,"opacity":0..1?,"fill":0..1?,"blend":"Multiply|…"?,"clipped":bool?,"locked":bool?,"locks":{"transparency","pixels","position","artboard","all":bool}?,"channels":[bool,…]? (Advanced Blending: which colour channels blend, R G B / C M Y K / L a b)}"#,
                        module: m, enabled: Pre.hasLayer, run: setProps),
            CommandSpec("layer.arrange.bringForward", "Bring Forward", menu: ["Layer", "Arrange"], shortcut: "Cmd+]", params: #"{"layer":id?}"#,
                        module: m, enabled: Pre.hasLayer) { s, p in try arrange(s, p, 1) },
            CommandSpec("layer.arrange.sendBackward", "Send Backward", menu: ["Layer", "Arrange"], shortcut: "Cmd+[", params: #"{"layer":id?}"#,
                        module: m, enabled: Pre.hasLayer) { s, p in try arrange(s, p, -1) },
            CommandSpec("layer.arrange.bringToFront", "Bring to Front", menu: ["Layer", "Arrange"], shortcut: "Cmd+Shift+]", params: #"{"layer":id?}"#,
                        module: m, enabled: Pre.hasLayer) { s, p in try arrange(s, p, 10_000) },
            CommandSpec("layer.arrange.sendToBack", "Send to Back", menu: ["Layer", "Arrange"], shortcut: "Cmd+Shift+[", params: #"{"layer":id?}"#,
                        module: m, enabled: Pre.hasLayer) { s, p in try arrange(s, p, -10_000) },
            CommandSpec("layer.createClippingMask", "Create Clipping Mask", menu: ["Layer"], shortcut: "Cmd+Alt+G",
                        params: #"{"layer":id?} (no layer: every selected layer but the lowest clips to the layer below it)"#,
                        module: m, enabled: Pre.hasLayer) { s, p in try setClipped(s, p, true) },
            CommandSpec("layer.releaseClippingMask", "Release Clipping Mask", menu: ["Layer"],
                        params: #"{"layer":id?} (no layer: every selected layer; each takes the layers clipped above it out too)"#,
                        module: m, enabled: Pre.hasLayer) { s, p in try setClipped(s, p, false) },
            CommandSpec("layer.layerMask.revealAll", "Reveal All", menu: ["Layer", "Layer Mask"],
                        params: #"{"layer":id?} (no layer: every selected layer that can take a mask)"#, module: m, enabled: Pre.hasLayer) { s, p in
                try setMask(s, p, "Add Layer Mask", .revealAll())
            },
            CommandSpec("layer.layerMask.hideAll", "Hide All", menu: ["Layer", "Layer Mask"],
                        params: #"{"layer":id?} (no layer: every selected layer that can take a mask)"#, module: m, enabled: Pre.hasLayer) { s, p in
                try setMask(s, p, "Add Layer Mask", .hideAll())
            },
            CommandSpec("layer.layerMask.revealSelection", "Reveal Selection", menu: ["Layer", "Layer Mask"],
                        params: #"{"layer":id?} (no layer: every selected layer that can take a mask)"#, module: m, enabled: Pre.hasSelection) { s, p in
                guard let sel = s.active?.doc.selection else { throw EngineError.other("no selection") }
                var mask = LayerMask.revealAll()
                mask.surface = sel
                // The selection is used up, as Hide Selection's is and Photoshop's both are (AB-T-0285).
                return try setMask(s, p, "Add Layer Mask", mask, deselect: true)
            },
            CommandSpec("layer.layerMask.delete", "Delete", menu: ["Layer", "Layer Mask"], params: #"{"layer":id?}"#, module: m, enabled: Pre.hasLayer) { s, p in
                try setMask(s, p, "Delete Layer Mask", nil)
            },
            CommandSpec("layer.mergeDown", "Merge Down", menu: ["Layer"], params: #"{"layer":id?}"#, module: m, enabled: Pre.hasLayer, run: mergeDown),
            CommandSpec("layer.mergeGroup", "Merge Group", menu: ["Layer"], params: #"{"layer":id?}"#, module: m, enabled: Pre.hasLayer) { s, p in
                let id = try s.layerParam(p)
                guard s.active?.doc.layer(id)?.isGroup == true else { throw EngineError.other("Merge Group needs a group") }
                return try mergeGroup(s, id)
            },
            CommandSpec("layer.flattenImage", "Flatten Image", menu: ["Layer"], module: m, enabled: Pre.hasDoc) { s, _ in
                try s.edit("Flatten Image") { doc, active in
                    let fmt = doc.pixelFormat
                    var bg = Layer.raster("Background", format: fmt)
                    bg.locks.transparency = true
                    bg.locks.position = true
                    let flat = try s.services.renderer.compositeToSurface(doc, format: fmt, background: SIMD3(1, 1, 1))
                    bg.withRaster { $0 = flat }
                    active = bg.id
                    doc.layers = [bg]
                }
                return .null
            },
            CommandSpec("layer.newFillLayer.solidColor", "Solid Color…", menu: ["Layer", "New Fill Layer"],
                        params: ##"{"color":"#rrggbb"=foreground,"path":"work"|saved path name|{…path}? (the active path: becomes the vector mask, making a shape; else the selection is the layer mask)}"##,
                        module: m, enabled: Pre.hasDoc) { s, p in
                let c = Params.color(p, "color", s.tools.foreground)
                let id = try s.edit("New Color Fill Layer") { doc, active -> LayerId in
                    let fill = Fill.solid(.rgb(c.x, c.y, c.z, c.w)).inMode(doc.mode)
                    var l = Layer(name: doc.nextLayerName("Color Fill"), content: .fill(fill))
                    try maskNewLayer(doc, &l, p, "layer.newFillLayer.solidColor")
                    let id = doc.insertAbove(active, l)
                    active = id
                    return id
                }
                return ["layer": .id(id)]
            },
            CommandSpec("layer.newFillLayer.gradient", "Gradient…", menu: ["Layer", "New Fill Layer"],
                        params: ##"{"from":"#rrggbb","to":"#rrggbb","angle":deg=90,"style":"linear|radial|angle|reflected|diamond","reverse":bool,"path":"work"|saved path name|{…path}? (the active path: becomes the vector mask; else the selection is the layer mask)}"##,
                        module: m, enabled: Pre.hasDoc) { s, p in
                let a = Params.color(p, "from", s.tools.foreground), b = Params.color(p, "to", s.tools.background)
                let angle = Params.float(p, "angle", 90)
                let style = gradientStyle(p["style"]?.stringValue ?? "linear")
                let reverse = p["reverse"]?.boolValue ?? false
                let id = try s.edit("New Gradient Fill Layer") { doc, active -> LayerId in
                    let g = GradientFill(stops: [ColorStop(0, .rgb(a.x, a.y, a.z, a.w)), ColorStop(1, .rgb(b.x, b.y, b.z, b.w))], angle: angle, scale: 1,
                                         style: style, reverse: reverse)
                    var l = Layer(name: doc.nextLayerName("Gradient Fill"), content: .fill(Fill.gradient(g).inMode(doc.mode)))
                    try maskNewLayer(doc, &l, p, "layer.newFillLayer.gradient")
                    let id = doc.insertAbove(active, l)
                    active = id
                    return id
                }
                return ["layer": .id(id)]
            },
            CommandSpec("layer.setAdjustment", "Adjustment Properties",
                        params: #"{"layer":id?, …params of that adjustment kind} (Levels, Curves: "eyedropper":{"point":"black|gray|white","at":[x,y],"size":1..101=1} or {"point",…,"color":[r,g,b] 0..1} = the Properties panel's Set Black/Neutral Gray/White Point, sampling the image below the layer, RGB and Grayscale (no gray) only)"#,
                        module: m, enabled: Pre.hasLayer, run: setAdjustment),
            CommandSpec("layer.moveTo", "Reorder Layer",
                        params: #"{"layer":id?| "layers":[id,…]?, "target":id,"position":"above|below|into"="above","copy":bool=false} (layers: one undoable move, document order preserved; copy: place duplicates there and leave the layers, as ⌥-dragging a Layers panel row)"#,
                        module: m, enabled: Pre.hasLayer, run: LayerMulti.moveTo),
            CommandSpec("layer.translate", "Move Layer",
                        params: #"{"layer":id?,"dx":i32,"dy":i32,"target":"pixels"|"mask"="pixels"} (no layer: every selected layer; linked layers follow; target mask: a layer whose mask is unlinked moves that mask alone, a linked mask moves with the layer)"#,
                        module: m, enabled: Pre.hasLayer, run: LayerMulti.translate),
        ]
    }

    static func gradientStyle(_ s: String) -> GradientStyle {
        switch s.lowercased() {
        case "radial": .radial
        case "angle": .angle
        case "reflected": .reflected
        case "diamond": .diamond
        default: .linear
        }
    }

    /// The neutral colour of a blend mode and its name (photocraft `new_layer::neutral_color`).
    static func neutralColor(_ mode: BlendMode) -> (SIMD3<Float>, String)? {
        switch mode {
        case .darken, .multiply, .colorBurn, .linearBurn, .darkerColor, .divide: (SIMD3(repeating: 1), "white")
        case .lighten, .screen, .colorDodge, .linearDodge, .lighterColor, .difference, .exclusion, .subtract: (SIMD3(repeating: 0), "black")
        case .overlay, .softLight, .hardLight, .vividLight, .linearLight, .pinLight: (SIMD3(repeating: 0.5), "50% gray")
        default: nil
        }
    }

    static func newLayer(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "layer.new.layer"
        func flag(_ k: String) throws -> Bool {
            guard let v = p[k], v != .null else { return false }
            guard let b = v.boolValue else { throw EngineError.bad(cmd, "`\(k)` must be true or false") }
            return b
        }
        let clip = try flag("clipToPrevious"), fillNeutral = try flag("fillNeutral")
        var mode = BlendMode.normal
        if let v = p["mode"], v != .null {
            guard let n = v.stringValue else { throw EngineError.bad(cmd, "`mode` must be a blend mode name") }
            guard let b = Params.blendMode(n), b != .passThrough else { throw EngineError.bad(cmd, "unknown layer blend mode `\(n)`") }
            mode = b
        }
        var opacity: Float = 1
        if let v = p["opacity"], v != .null {
            guard let o = v.doubleValue, o.isFinite else { throw EngineError.bad(cmd, "`opacity` must be a number from 0 to 1") }
            opacity = Float(min(max(o, 0), 1))
        }
        var label = LabelColor.none
        if let v = p["color"], v != .null {
            guard let id = v.stringValue, let l = LabelColor(id: id) else { throw EngineError.bad(cmd, "`color` must be a layer color id, not \(v.serialized())") }
            label = l
        }
        var neutral: SIMD3<Float>?
        if fillNeutral {
            guard let n = neutralColor(mode) else { throw EngineError.bad(cmd, "\(mode.label) has no neutral color to fill with") }
            neutral = n.0
        }
        var name: String?
        if let v = p["name"], v != .null {
            guard let n = v.stringValue else { throw EngineError.bad(cmd, "`name` must be a string") }
            name = n
        }
        let id = try s.edit("New Layer") { doc, active -> LayerId in
            var layer = Layer.raster(name ?? doc.nextLayerName("Layer"), format: doc.pixelFormat)
            layer.blend = mode
            layer.opacity = opacity
            layer.label = label
            if let rgb = neutral {
                let b = doc.bounds
                layer.withRaster { $0.fill(b, with: $0.format.components(fromRGBA: SIMD4(rgb, 1))) }
            }
            let id = doc.insertAbove(active, layer)
            ClipGroup.settle(&doc, placed: [id], force: clip)
            active = id
            return id
        }
        return ["layer": .id(id)]
    }

    static func duplicate(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let inPlace = p["inPlace"]?.boolValue ?? false
        let name = p["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if LayerMulti.multi(s, p) { return try LayerMulti.duplicateSelected(s, inPlace: inPlace, label: "Duplicate Layers") }
        let id = try s.layerParam(p)
        let nid = try s.edit("Duplicate Layer") { doc, active -> LayerId in
            var dup = try LayerOps.layerCopy(doc, id)
            if let name { dup.name = name }
            let nid = doc.insertAbove(id, dup)
            if !inPlace { try LayerOps.placeCopy(&doc, nid) }
            active = nid
            return nid
        }
        return ["layer": .id(nid)]
    }

    static func deleteLayer(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        if LayerMulti.multi(s, p) { return try LayerMulti.deleteSelected(s) }
        let id = try s.layerParam(p)
        try s.edit("Delete Layer") { doc, active in
            let neighbours = LayerMulti.deletionNeighbours(doc, id)
            let before = ClipGroup.Before.read(doc, [id])
            guard doc.remove(id) != nil else { throw EngineError.noLayer(id) }
            ClipGroup.settle(&doc, placed: [], before: before)
            if doc.layers.isEmpty { throw EngineError.other("a document must keep at least one layer") }
            if let a = active, doc.layer(a) == nil { active = neighbours.first { doc.layer($0) != nil } }
        }
        return .null
    }

    static func setProps(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try s.layerParam(p)
        let keys = Set(p.members.keys)
        let onlyVisibility = keys.contains("visible") && keys.isSubset(of: ["layer", "visible", "coalesce"])
        try s.edit(onlyVisibility ? "Layer Visibility" : "Layer Properties") { doc, _ in
            guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
            var failure: EngineError?
            doc.updateLayer(id) { l in
                if let v = p["name"]?.stringValue { l.name = v }
                if let v = p["visible"]?.boolValue { l.visible = v }
                if let v = p["opacity"]?.doubleValue { l.opacity = Float(min(max(v, 0), 1)) }
                if let v = p["fill"]?.doubleValue { l.fillOpacity = Float(min(max(v, 0), 1)) }
                if let v = p["blend"]?.stringValue {
                    guard let b = Params.blendMode(v) else { failure = .bad("layer.setProps", "unknown blend mode `\(v)`"); return }
                    l.blend = b
                }
                if let v = p["clipped"]?.boolValue { l.clipped = v }
                if let v = p["locked"]?.boolValue { l.locks.all = v }
                if let ch = p["channels"]?.arrayValue {
                    var mask: UInt32 = 0
                    for (i, v) in ch.prefix(32).enumerated() where v.boolValue == false { mask |= 1 << UInt32(i) }
                    l.excludedChannels = mask
                }
                for (k, v) in p["locks"]?.members ?? [:] {
                    let b = v.boolValue ?? false
                    switch k {
                    case "transparency": l.locks.transparency = b
                    case "pixels": l.locks.pixels = b
                    case "position": l.locks.position = b
                    case "artboard": l.locks.artboard = b
                    case "all": l.locks.all = b
                    default: failure = .bad("layer.setProps", "unknown lock `\(k)`")
                    }
                }
            }
            if let failure { throw failure }
        }
        return .null
    }

    static func arrange(_ s: Session, _ p: JSONValue, _ steps: Int) throws -> JSONValue {
        let id = try s.layerParam(p)
        try s.edit("Arrange") { doc, _ in
            let bg = LayerOps.backgroundId(doc)
            if bg == id { throw EngineError.other("the Background layer can't be moved") }
            let dir = steps.signum()
            let before = ClipGroup.Before.read(doc, [id])
            var moved = false
            for _ in 0..<abs(steps) {
                if !doc.shift(id, by: dir) { break }
                if (try? LayerOps.keepBackgroundAtBottom(bg, doc)) == nil {
                    doc.shift(id, by: -dir)
                    break
                }
                moved = true
            }
            if !moved { throw EngineError.other("layer can't move further") }
            ClipGroup.settle(&doc, placed: [id], before: before)
        }
        return .null
    }

    /// Create / Release Clipping Mask: with a `layer` param, that layer; otherwise the selection
    /// (Create clips every selected layer but the lowest; Release releases every selected layer).
    /// Release takes the clipped run above each layer it releases out too, as Photoshop's does: the
    /// layers below it stay clipped (measured in Photoshop 27, AB-T-0285).
    static func setClipped(_ s: Session, _ p: JSONValue, _ clip: Bool) throws -> JSONValue {
        let label = clip ? "Create Clipping Mask" : "Release Clipping Mask"
        var ids: [LayerId]
        if p.has("layer") {
            ids = [try s.layerParam(p)]
        } else {
            let sel = s.active?.selectedLayers ?? []
            switch sel.count {
            case 0: ids = [try s.layerParam(p)]
            case 1: ids = sel
            default: ids = clip ? Array(sel.dropFirst()) : sel
            }
        }
        let changed = try s.edit(label) { doc, _ -> [LayerId] in
            var changed: [LayerId] = []
            for id in ids {
                // A base isn't released, and keeps its group (Photoshop greys the item out for it).
                let run = clip || doc.layer(id)?.clipped != true ? [] : ClipGroup.clippedAbove(doc, id)
                guard doc.updateLayer(id, { $0.clipped = clip }) != nil else { throw EngineError.noLayer(id) }
                if !changed.contains(id) { changed.append(id) }
                for above in run where !changed.contains(above) {
                    doc.updateLayer(above) { $0.clipped = false }
                    changed.append(above)
                }
            }
            return changed
        }
        return ["layers": .ids(changed)]
    }

    /// Adds (`mask` non-nil) or removes a layer mask. Adding acts on every selected layer that can
    /// take one, in one step.
    /// `deselect` drops the selection in the same step (Reveal Selection).
    static func setMask(_ s: Session, _ p: JSONValue, _ label: String, _ mask: LayerMask?, deselect: Bool = false) throws -> JSONValue {
        let ids = mask != nil ? try LayerMulti.maskTargets(s, p) : [try s.layerParam(p)]
        try s.edit(label) { doc, _ in
            if deselect { doc.selection = nil }
            let m = mask.map { LayerOps.maskAtDepth($0, doc.depth) }
            for id in ids {
                if m != nil { LayerOps.backgroundToLayer(&doc, id) }
                guard doc.updateLayer(id, { $0.mask = m }) != nil else { throw EngineError.noLayer(id) }
            }
        }
        return .null
    }

    static func mergeDown(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try s.layerParam(p)
        let renderer = s.services.renderer
        try s.edit("Merge Down") { doc, active in
            guard let path = doc.path(of: id), let idx = path.last else { throw EngineError.noLayer(id) }
            if idx == 0 { throw EngineError.other("no layer below to merge into") }
            let below = Array(path.dropLast()) + [idx - 1]
            guard let lower = doc.layer(at: below), let upper = doc.layer(id) else { throw EngineError.noLayer(id) }
            let merged = try Pixels.mergeDown(doc, lower: lower, upper: upper, renderer: renderer)
            doc.remove(id)
            doc.updateLayer(at: below) { $0 = merged }
            active = lower.id
        }
        return .null
    }

    /// Layer › Merge Group: the group's visible contents become one pixel layer in its place,
    /// keeping its opacity, blend mode (Pass Through becomes Normal), clipping and locks.
    static func mergeGroup(_ s: Session, _ id: LayerId) throws -> JSONValue {
        let renderer = s.services.renderer
        try s.edit("Merge Group") { doc, active in
            guard let group = doc.layer(id) else { throw EngineError.noLayer(id) }
            if !group.visible { throw EngineError.other("the group is hidden") }
            let fmt = doc.pixelFormat.with(alpha: true)
            var solo = group
            solo.opacity = 1
            solo.blend = .normal
            solo.clipped = false
            var tmp = doc
            tmp.layers = [solo]
            var merged = Layer(name: group.name, content: .raster(try Pixels.compositeLayers(tmp, format: fmt, renderer: renderer)))
            merged.id = group.id
            merged.opacity = group.opacity
            merged.blend = group.blend == .passThrough ? .normal : group.blend
            merged.clipped = group.clipped
            merged.locks = group.locks
            doc.updateLayer(id) { $0 = merged }
            active = id
        }
        return ["layer": .id(id)]
    }

    /// Masks a new fill or adjustment layer: the given path becomes its vector mask; else the
    /// selection is its layer mask; else a white mask (photocraft `mask_new_layer`).
    static func maskNewLayer(_ doc: Document, _ l: inout Layer, _ p: JSONValue, _ cmd: String) throws {
        var path: VectorPath?
        switch p["path"] {
        case nil, .null?: path = nil
        case .string(let n)? where n.isEmpty || n.lowercased() == "work" || n == "Work Path":
            guard let wp = doc.workPath else { throw EngineError.bad(cmd, "no work path") }
            path = wp
        case .string(let n)?:
            guard let sp = doc.paths.first(where: { $0.name == n }) else { throw EngineError.bad(cmd, "no path named \"\(n)\"") }
            path = sp.path
        case let v?:
            do { path = try v.decode(as: VectorPath.self) } catch { throw EngineError.bad(cmd, "bad `path`: \(error)") }
        }
        if let path {
            l.vectorMask = VectorMask(path: path)
        } else {
            l.mask = LayerOps.maskAtDepth(LayerOps.selectionMask(doc) ?? .revealAll(), doc.depth)
        }
    }

    static func setAdjustment(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try s.layerParam(p)
        let eyedropped = try AdjustParams.layerEyedropper(s, layer: id, p)
        try s.edit("Modify Adjustment") { doc, _ in
            let mode = doc.mode
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            guard case .adjustment(let adj) = l.content else { throw EngineError.other("not an adjustment layer") }
            if case .unsupported = adj { throw EngineError.other("this adjustment can't be edited (kept as imported)") }
            let kind = AdjustParams.kind(of: adj)
            var new: Adjustment
            if let eyedropped {
                new = eyedropped
            } else if AdjustParams.userKeys(p).isEmpty {
                new = try AdjustParams.defaultFor(kind, mode: mode)
                // Resetting Grain or Add Noise keeps the layer's pattern.
                if case .filter(.grain(let old)) = adj, case .filter(.grain(var g)) = new { g.seed = old.seed; new = .filter(.grain(g)) }
                if case .filter(.addNoise(let old)) = adj, case .filter(.addNoise(var n)) = new { n.seed = old.seed; new = .filter(.addNoise(n)) }
            } else {
                new = try AdjustParams.fromParams(kind, p, base: adj, mode: mode)
            }
            doc.updateLayer(id) { $0.content = .adjustment(new) }
        }
        return .null
    }

    // MARK: Image Rotation

    static func imageRotation() -> [CommandSpec] {
        let items: [(String, String, String, CanvasGeometry.Turn)] = [
            ("image.imageRotation.flipCanvasHorizontal", "Flip Canvas Horizontal", "Flip Canvas Horizontal", .flipHorizontal),
            ("image.imageRotation.flipCanvasVertical", "Flip Canvas Vertical", "Flip Canvas Vertical", .flipVertical),
            ("image.imageRotation.180", "180°", "Rotate Canvas", .rotate180),
            ("image.imageRotation.90cw", "90° Clockwise", "Rotate Canvas", .cw90),
            ("image.imageRotation.90ccw", "90° Counter Clockwise", "Rotate Canvas", .ccw90),
        ]
        return items.map { id, label, step, t in
            CommandSpec(id, label, menu: ["Image", "Image Rotation"], module: m, enabled: Pre.hasDoc) { s, _ in
                if let d = s.active { SamplerMap.set(s, t.affine(Double(d.doc.size.width), Double(d.doc.size.height))) }
                try s.edit(step) { doc, _ in CanvasGeometry.turnCanvas(&doc, t) }
                return .null
            }
        }
    }

    // MARK: Tools and queries

    static func toolsAndQueries() -> [CommandSpec] {
        [
            CommandSpec("tools.setColors", "Set Colors", params: ##"{"foreground":"#rrggbb"?,"background":"#rrggbb"?}"##, module: m) { s, p in
                s.tools.foreground = Params.color(p, "foreground", s.tools.foreground)
                s.tools.background = Params.color(p, "background", s.tools.background)
                s.emit(.toolsChanged)
                return .null
            },
            CommandSpec("tools.swapColors", "Switch Foreground and Background Colors", shortcut: "X", module: m) { s, _ in
                (s.tools.foreground, s.tools.background) = (s.tools.background, s.tools.foreground)
                s.emit(.toolsChanged)
                return .null
            },
            CommandSpec("tools.defaultColors", "Default Foreground and Background Colors", shortcut: "D", module: m) { s, _ in
                if s.tools.maskTargeted {
                    (s.tools.foreground, s.tools.background) = ToolState.maskColors
                } else {
                    s.tools.foreground = SIMD4(0, 0, 0, 1)
                    s.tools.background = SIMD4(1, 1, 1, 1)
                }
                s.emit(.toolsChanged)
                return .null
            },
            CommandSpec("session.inspect", "Inspect Session", module: m, journal: false) { s, _ in Inspect.session(s) },
            CommandSpec("document.inspect", "Inspect Document", params: #"{"document":index?}"#, module: m, journal: false, enabled: Pre.hasDoc) { s, p in
                if let v = p["document"], v != .null {
                    guard let i = v.uint64Value else { throw EngineError.bad("document.inspect", "`document` must be an index") }
                    guard Int(i) < s.documents.count else { throw EngineError.other("no document at index \(i)") }
                    return Inspect.document(s.documents[Int(i)], registry: s.registry)
                }
                guard let d = s.active else { throw EngineError.noDocument }
                return Inspect.document(d, registry: s.registry)
            },
            CommandSpec("document.activate", "Activate Document", params: #"{"document":index}"#, module: m, journal: false, enabled: Pre.hasDoc) { s, p in
                guard let i = p["document"]?.uint64Value else { throw EngineError.bad("document.activate", "missing `document`") }
                guard s.setActive(Int(i)) else { throw EngineError.other("no document at index \(i)") }
                return .null
            },
            CommandSpec("document.move", "Move Document", params: #"{"document":index?,"to":index}"#, module: m, journal: false, enabled: Pre.hasDoc) { s, p in
                let from: Int
                if let v = p["document"] {
                    guard let i = v.uint64Value else { throw EngineError.bad("document.move", "`document` must be a tab index") }
                    from = Int(i)
                } else {
                    guard let a = s.activeIndex else { throw EngineError.noDocument }
                    from = a
                }
                guard let tv = p["to"] else { throw EngineError.bad("document.move", "missing `to`") }
                guard let to = tv.uint64Value else { throw EngineError.bad("document.move", "`to` must be a tab index") }
                guard let t = s.moveDocument(from: from, to: Int(to)) else { throw EngineError.noDocument }
                return ["document": .int(t)]
            },
            CommandSpec("command.list", "List Commands", module: m, journal: false) { s, _ in
                .array(s.registry.specs.map { s.listEntry($0) })
            },
            CommandSpec("document.pixel", "Read Composite Pixel", params: #"{"x":i32,"y":i32}"#, module: m, journal: false, enabled: Pre.hasDoc) { s, p in
                func coord(_ k: String) throws -> Int32 {
                    guard let v = Params.int(p, k) ?? 0 as Int?, let r = Int32(exactly: v) else { throw EngineError.bad("document.pixel", "\(k) must fit in 32 bits") }
                    return r
                }
                let (x, y) = (try coord("x"), try coord("y"))
                guard let d = s.active else { throw EngineError.noDocument }
                return .rgba(try s.services.renderer.pixel(d.doc, x: x, y: y))
            },
        ]
    }

    // MARK: Adjustments

    /// Adjustment layers + destructive adjustments, generated from one list (photocraft `ADJ`).
    static let adjustments: [(String, String, String)] = [
        ("brightnessContrast", "Brightness/Contrast…", #"{"brightness":-150..150=0,"contrast":-100..100=0,"legacy":bool=false,"mode":"legacy|modern|light"?,"exposure":-5..5=0,"whites":-100..100=0,"blacks":-100..100=0,"highlights":-100..100=0,"shadows":-100..100=0} (mode: Photoshop 27's algorithm, default modern (legacy when "legacy" is true); modern's contrast is -50..100; light reads exposure/whites/blacks/highlights/shadows and ignores brightness)"#),
        ("levels", "Levels…", #"{"inBlack":0..253=0,"gamma":0.01..9.99=1,"inWhite":2..255=255,"outBlack":0..255=0,"outWhite":0..255=255,"red":json,"green":json,"blue":json,"eyedropper":json} (top level = composite; per channel {"inBlack","gamma","inWhite","outBlack","outWhite"} under red/green/blue, gray, cyan/magenta/yellow/black or lightness/a/b; eyedropper = the dialog's Set Black/Neutral Gray/White Point picker {"point":"black|gray|white","at":[x,y],"size":1..101=1} or {"point",…,"color":[r,g,b] 0..1})"#),
        ("curves", "Curves…", #"{"points":json,"red":json,"green":json,"blue":json,"pencil":bool=false,"smooth":0..10=0,"eyedropper":json} (curves as [[in,out],…] in 0..255, 2..19 points: points = composite; red/green/blue, gray, cyan/magenta/yellow/black or lightness/a/b per channel; pencil = drawn curves of 256 output levels)"#),
        ("exposure", "Exposure…", #"{"exposure":-20..20=0,"offset":-0.5..0.5=0,"gamma":0.01..9.99=1}"#),
        ("vibrance", "Vibrance…", #"{"vibrance":-100..100=0,"saturation":-100..100=0}"#),
        ("hueSaturation", "Hue/Saturation…", #"{"hue":-180..180=0,"saturation":-100..100=0,"lightness":-100..100=0,"colorize":bool=false,"reds":json,"yellows":json,"greens":json,"cyans":json,"blues":json,"magentas":json} (per range {"hue","saturation","lightness","range":[4 hue degrees]}; colorize: hue 0..360, saturation 0..100)"#),
        ("colorBalance", "Color Balance…", #"{"shadows":json,"midtones":json,"highlights":json,"preserveLuminosity":bool=true} (each tone [cyan-red, magenta-green, yellow-blue] in -100..100)"#),
        ("blackWhite", "Black & White…", ##"{"reds":-200..300=40,"yellows":-200..300=60,"greens":-200..300=40,"cyans":-200..300=60,"blues":-200..300=20,"magentas":-200..300=80,"tint":bool=false,"tintColor":"#rrggbb"}"##),
        ("photoFilter", "Photo Filter…", ##"{"filter":"warming85|warmingLBA|warming81|cooling80|coolingLBB|cooling82|red|orange|yellow|green|cyan|blue|violet|magenta|sepia|deepRed|deepBlue|deepEmerald|deepYellow|underwater","color":"#rrggbb","density":0..100=25,"preserveLuminosity":bool=true}"##),
        ("channelMixer", "Channel Mixer…", #"{"red":json,"green":json,"blue":json,"gray":json,"monochrome":bool=false} (per output channel [red %, green %, blue %, constant %] in -200..200; gray = the monochrome mix)"#),
        ("invert", "Invert", "{}"),
        ("posterize", "Posterize…", #"{"levels":2..255=4}"#),
        ("threshold", "Threshold…", #"{"level":1..255=128}"#),
        ("gradientMap", "Gradient Map…", ##"{"stops":json,"reverse":bool=false,"dither":bool=false} (stops [[location 0..1, "#rrggbb"], …], 2..64)"##),
        ("selectiveColor", "Selective Color…", #"{"method":"relative|absolute"="relative","colors":"reds|yellows|greens|cyans|blues|magentas|whites|neutrals|blacks"="reds","cyan":-100..100=0,"magenta":-100..100=0,"yellow":-100..100=0,"black":-100..100=0,"reds":json} (per-range [c,m,y,k] arrays: reds yellows greens cyans blues magentas whites neutrals blacks)"#),
        ("colorLookup", "Color Lookup…", #"{"lut":"none|warm|cool|tealOrange|bleachBypass|fadedFilm|dayForNight|monoContrast|crossProcess"="none","file":text,"interpolation":"trilinear|tetrahedral"="trilinear","dither":bool=false,"data":json} (file: .cube/.3dl/.look path; data: file text + "fileName")"#),
    ]

    static let newLayerPath = #""path":"work"|saved path name|{…path}? (the active path: becomes the vector mask; else the selection is the layer mask, or white with no selection)"#

    /// Filter adjustment layers (AB-T-0258: Compositor's Grain, Add Noise, Gaussian Blur and Motion
    /// Blur over everything beneath, live). No Photoshop counterpart and no Image › Adjustments twin
    /// (the Filter menu's filters are their own commands); PSD keeps none of them.
    static let filterAdjustments: [(String, String, String)] = [
        ("grain", "Grain…", #"{"amount":0..100=25,"size":0.5..20=1.5,"roughness":0..100=50,"seed":0..4294967295?} (size in document pixels; seed: the pattern, fixed in the document; default one of the layer's own)"#),
        ("addNoise", "Add Noise…", #"{"amount":0.1..400=10,"distribution":"uniform|gaussian"="uniform","monochromatic":bool=false,"seed":0..4294967295?} (amount in percent; seed: the pattern, fixed in the document; default one of the layer's own)"#),
        ("gaussianBlur", "Gaussian Blur…", #"{"radius":0.1..250=10} (the blur's standard deviation in document pixels)"#),
        ("motionBlur", "Motion Blur…", #"{"angle":-90..90=0,"distance":1..2000=10} (angle counterclockwise from horizontal; distance: the streak's length in document pixels)"#),
    ]

    static func adjustmentCommands() -> [CommandSpec] {
        var out: [CommandSpec] = []
        for (kind, label, params) in adjustments {
            out.append(CommandSpec("layer.newAdjustmentLayer.\(kind)", label, menu: ["Layer", "New Adjustment Layer"],
                                   params: "\(params) + {\(newLayerPath)}", module: m, enabled: Pre.hasDoc) { s, p in
                let eyedropped = ["levels", "curves"].contains(kind) ? try AdjustParams.eyedropperFromParams(s, kind: kind, p) : nil
                let mode = s.active?.doc.mode ?? .rgb
                let adj = try eyedropped ?? AdjustParams.fromParams(kind, p, base: nil, mode: mode)
                return try newAdjustment(s, adj, p, "layer.newAdjustmentLayer.\(kind)")
            })
            let shortcut: String? = switch kind {
            case "levels": "Cmd+L"
            case "curves": "Cmd+M"
            case "hueSaturation": "Cmd+U"
            case "colorBalance": "Cmd+B"
            case "invert": "Cmd+I"
            case "blackWhite": "Cmd+Alt+Shift+B"
            default: nil
            }
            out.append(CommandSpec("image.adjustments.\(kind)", label, menu: ["Image", "Adjustments"], shortcut: shortcut, params: params,
                                   module: m, enabled: hasAdjustable) { s, p in
                let eyedropped = ["levels", "curves"].contains(kind) ? try AdjustParams.eyedropperFromParams(s, kind: kind, p) : nil
                let mode = s.active?.doc.mode ?? .rgb
                let adj = try eyedropped ?? AdjustParams.fromParams(kind, p, base: nil, mode: mode)
                // On a smart object the adjustment is recorded as a smart filter (photocraft
                // `adjust_as_smart_filter`), with an eyedropper's result as its params.
                let recorded = eyedropped.map { p.removing("eyedropper").merging(AdjustParams.toParams($0)) }
                if try AdjustCommands.adjustAsSmartFilter(s, kind: kind, label: adj.label, recorded ?? p) { return .null }
                return try destructiveAdjust(s, adj.label, adj, p)
            })
        }
        for (kind, label, params) in filterAdjustments {
            let id = "layer.newAdjustmentLayer.\(kind)"
            out.append(CommandSpec(id, label, menu: ["Layer", "New Adjustment Layer"], params: "\(params) + {\(newLayerPath)}",
                                   module: m, enabled: Pre.hasDoc) { s, p in
                let adj = try AdjustParams.fromParams(kind, p, base: nil, mode: s.active?.doc.mode ?? .rgb)
                return try newAdjustment(s, adj, p, id)
            })
        }
        out.append(CommandSpec("image.adjustments.desaturate", "Desaturate", menu: ["Image", "Adjustments"], shortcut: "Cmd+Shift+U",
                               module: m, enabled: Pre.hasPixelLayer) { s, _ in
            var hs = Adjustment.HueSaturation()
            hs.saturation = -100
            return try destructiveAdjust(s, "Desaturate", .hueSaturation(hs), .object([:]))
        })
        return out
    }

    /// A pixel layer (or a cached smart object), or a targeted channel (photocraft `has_adjustable`).
    static let hasAdjustable: CommandEnabled = { s, _ in
        if Channels.editsChannel(s) { return nil }
        switch s.activeLayer() {
        case .failure(let e): return e.description
        case .success(let l):
            switch l.content {
            case .raster: return nil
            case .smart(let sm) where sm.cache != nil: return nil
            default: return "active layer is \(l.content.article) \(l.content.kindName) layer, not a pixel layer"
            }
        }
    }

    static func newAdjustment(_ s: Session, _ adj: Adjustment, _ p: JSONValue, _ cmd: String) throws -> JSONValue {
        let id = try s.edit("New \(adj.label) Layer") { doc, active -> LayerId in
            var l = Layer(name: doc.nextLayerName(adj.label), content: .adjustment(adj))
            // Grain and Add Noise without a `seed` get a pattern of the layer's own.
            if p["seed"] == nil || p["seed"] == .null, case .filter(var f) = adj {
                switch f {
                case .grain(var g): g.seed = AdjustParams.seed(for: l.id); f = .grain(g)
                case .addNoise(var n): n.seed = AdjustParams.seed(for: l.id); f = .addNoise(n)
                case .gaussianBlur, .motionBlur: break
                }
                l.content = .adjustment(.filter(f))
            }
            try maskNewLayer(doc, &l, p, cmd)
            let id = doc.insertAbove(active, l)
            active = id
            return id
        }
        return ["layer": .id(id)]
    }

    /// Image › Adjustments on pixels, a targeted mask, or a targeted channel (photocraft
    /// `destructive_adjust`).
    static func destructiveAdjust(_ s: Session, _ label: String, _ adj: Adjustment, _ p: JSONValue) throws -> JSONValue {
        if LayerOps.isMaskTarget(p) {
            let id = try s.layerParam(.null)
            try s.edit(label) { doc, _ in
                let sel = doc.selection
                var failure: EngineError?
                doc.updateLayer(id) { l in
                    guard var m = l.mask else { failure = .other("layer has no mask"); return }
                    Pixels.adjustMask(&m.surface, adj, selection: sel)
                    l.mask = m
                }
                if let failure { throw failure }
            }
            return .null
        }
        if Channels.isChannelTarget(p) {
            try s.edit(label) { doc, _ in
                let sel = doc.selection, b = doc.bounds
                try Channels.withTargetSurface(&doc, layer: nil, p) { surf, _ in
                    Channels.materialize(&surf, b)
                    Pixels.adjustSurface(&surf, adj, selection: sel, mode: .grayscale)
                    surf.prune()
                }
            }
            return .null
        }
        let id = try s.layerParam(.null)
        try s.edit(label) { doc, _ in
            let sel = doc.selection, mode = doc.mode
            try LayerOps.withPaintSurface(&doc, id, .null) { surf in Pixels.adjustSurface(&surf, adj, selection: sel, mode: mode) }
        }
        return .null
    }
}

/// Moves Color Sampler points with a canvas-size change (photocraft `set_sampler_map`): the
/// samplers module reads it after the edit.
public enum SamplerMap {
    public enum Key: StateKey { public static let defaultValue: PCAffine? = nil }
    public static func set(_ s: Session, _ a: PCAffine) { s.state[Key.self] = a }
    public static func take(_ s: Session) -> PCAffine? {
        let a = s.state[Key.self]
        s.state[Key.self] = nil
        return a
    }
}
