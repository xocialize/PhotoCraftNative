// Port of photocraft-engine (crates/engine/src/image_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Image menu: Image Size, Canvas Size, Crop, Trim, Mode (colour model through `ColorCommands`
// and bit depth) conversions, Duplicate. Canvas Size, Crop and Trim move every surface, channel,
// selection and vector of the document exactly (whole pixels); what resamples (Image Size, a
// rotated crop, a crop to a target size) runs PCAlgo's resampler (`ImageCommands+Resample.swift`).

import Foundation
import PCAlgo
import PCDocument
import PCFoundation
import PCRender
import Synchronization

public enum ImageCommands: CommandModule {
    public static let name = "image_cmds"
    static let m = "image_cmds"

    // MARK: Surface walks

    /// Applies `f` to every pixel surface of a layer tree: content (raster or cached text/shape/
    /// smart pixels), fill caches, and (with `masks`) masks and smart-filter masks; `f` is told
    /// whether the surface is a mask (photocraft `for_each_surface`).
    public static func forEachSurface(_ layers: inout [Layer], masks: Bool, _ f: (inout Surface, Bool) throws -> Void) rethrows {
        for i in layers.indices { try forEachSurface(&layers[i], masks: masks, f) }
    }

    static func forEachSurface(_ l: inout Layer, masks: Bool, _ f: (inout Surface, Bool) throws -> Void) rethrows {
        if masks, var mk = l.mask {
            l.mask = nil
            try f(&mk.surface, true)
            l.mask = mk
        }
        if var fc = l.fillCache {
            l.fillCache = nil
            try f(&fc.surface, false)
            l.fillCache = fc
        }
        switch l.content {
        case .raster:
            try l.withRaster { try f(&$0, false) }
        case .text:
            try l.withText { t in
                if var c = t.cache { t.cache = nil; try f(&c, false); t.cache = c }
            }
        case .shape:
            try l.withShape { sh in
                if var c = sh.cache { sh.cache = nil; try f(&c, false); sh.cache = c }
            }
        case .smart:
            try l.withSmartObject { sm in
                if var c = sm.cache { sm.cache = nil; try f(&c, false); sm.cache = c }
                // Selection-derived smart-filter masks live in document coordinates (#3077).
                if masks, var mk = sm.filterMask { sm.filterMask = nil; try f(&mk.surface, true); sm.filterMask = mk }
            }
        case .group:
            try l.withChildren { try forEachSurface(&$0, masks: masks, f) }
        default:
            break
        }
    }

    /// Visits every layer of a tree, parents first (photocraft `for_each_layer`).
    static func forEachLayer(_ layers: inout [Layer], _ f: (inout Layer) -> Void) {
        for i in layers.indices {
            f(&layers[i])
            layers[i].withChildren { forEachLayer(&$0, f) }
        }
    }

    /// Writes `map(tile values)` of every materialised tile of `s` into `out` (same tile grid),
    /// tiles converted in parallel.
    static func mapTiles(_ s: Surface, into out: inout Surface, _ map: @Sendable ([Float]) -> [Float]) {
        let coords = s.tileCoords
        guard !coords.isEmpty else { return }
        let src = s
        let results = Mutex<[Int: [Float]]>([:])
        DispatchQueue.concurrentPerform(iterations: coords.count) { i in
            let v = map(src.readRegion(coords[i].rect))
            results.withLock { $0[i] = v }
        }
        let all = results.withLock { $0 }
        for (i, c) in coords.enumerated() {
            if let v = all[i], v.count >= c.rect.area * out.channels { out.writeRegion(c.rect, v) }
        }
    }

    /// Applies `f` to every colour sample (not alpha), including the default pixel (photocraft
    /// `Surface::map_color`).
    static func mapColor(_ s: Surface, _ f: @escaping @Sendable (Float) -> Float) -> Surface {
        let fmt = s.format
        let color = fmt.mode.colorChannels, n = fmt.channels
        var dp = s.defaultPixelValue
        for k in 0..<min(color, dp.count) { dp[k] = f(dp[k]) }
        var out = Surface(format: fmt, defaultPixel: dp)
        mapTiles(s, into: &out) { raw in
            var o = raw
            for i in stride(from: 0, to: o.count, by: n) { for k in 0..<color { o[i + k] = f(o[i + k]) } }
            return o
        }
        return out
    }

    /// Keeps only the pixels inside `keep` (photocraft `crop_surface`).
    static func cropSurface(_ s: Surface, _ keep: PixelRect) -> Surface {
        var out = Surface(format: s.format, defaultPixel: s.defaultPixelValue)
        let r = s.contentBounds.intersect(keep)
        if !r.isEmpty { out.writeInterleaved(r, s.readInterleaved(r)) }
        return out
    }

    /// The content moved by (dx, dy) (photocraft `translate_surface`).
    static func translateSurface(_ s: Surface, _ dx: Int32, _ dy: Int32) -> Surface {
        s.translated(dx: dx, dy: dy, content: s.contentBounds)
    }

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }

    // MARK: Document moves

    /// Moves every surface, channel, selection and vector by `(dx, dy)` (photocraft `translate_doc`).
    /// Fails, before moving anything, when some pixels would land outside the 32-bit coordinate
    /// range (#959).
    public static func translateDocument(_ doc: inout Document, _ cmd: String, _ dx: Int32, _ dy: Int32) throws {
        if dx == 0 && dy == 0 { return }
        func fits(_ r: PixelRect) -> Bool {
            if r.isEmpty { return true }
            func ok(_ v: Int32, _ d: Int32) -> Bool { Int32(exactly: Int64(v) + Int64(d)) != nil }
            return ok(r.x0, dx) && ok(r.x1, dx) && ok(r.y0, dy) && ok(r.y1, dy)
        }
        var ok = true
        forEachSurface(&doc.layers, masks: true) { surf, _ in ok = ok && fits(surf.contentBounds) }
        ok = ok && doc.channels.allSatisfy { fits($0.surface.contentBounds) } && (doc.quickMask.map { fits($0.surface.contentBounds) } ?? true)
            && (doc.selection.map { fits($0.contentBounds) } ?? true)
        if !ok {
            throw bad(cmd, "moving the document by (\(dx), \(dy)) would push its pixels outside the 32-bit coordinate range")
        }
        forEachSurface(&doc.layers, masks: true) { surf, _ in surf = translateSurface(surf, dx, dy) }
        for i in doc.channels.indices { doc.channels[i].surface = translateSurface(doc.channels[i].surface, dx, dy) }
        if var q = doc.quickMask { q.surface = translateSurface(q.surface, dx, dy); doc.quickMask = q }
        if let sel = doc.selection { doc.selection = translateSurface(sel, dx, dy) }
        // Type, shapes, smart objects, vector masks, paths, guides, slices, notes… (caches above
        // are already translated exactly).
        CanvasGeometry.transformGeometry(&doc, .translate(Double(dx), Double(dy)))
    }

    /// Crops the document to `r` (current document coordinates) (photocraft `crop_doc`). A frame
    /// that extends past the canvas fills the Background's new area with `extension` (the
    /// background colour); other layers get transparent pixels there.
    static func cropDocument(_ doc: inout Document, _ cmd: String, _ r: PixelRect, deletePixels: Bool, extension ext: SIMD4<Float>) throws {
        // The origin moves to (0, 0); `-Int32.min` has no Int32 value (#959).
        guard r.x0 != .min, r.y0 != .min else {
            throw bad(cmd, "the crop origin (\(r.x0), \(r.y0)) can't be moved to (0, 0) within the 32-bit coordinate range")
        }
        let (dx, dy) = (-r.x0, -r.y0)
        let oldCanvas = doc.bounds
        let extends = r.x0 < oldCanvas.x0 || r.y0 < oldCanvas.y0 || r.x1 > oldCanvas.x1 || r.y1 > oldCanvas.y1
        if deletePixels {
            forEachSurface(&doc.layers, masks: false) { surf, _ in surf = cropSurface(surf, r) }
        }
        try translateDocument(&doc, cmd, dx, dy)
        doc.size = PixelSize(width: r.width, height: r.height)
        // A Background can't hold transparent pixels: the area an extending Crop adds is filled with
        // the extension (background) colour.
        if extends {
            let old = oldCanvas.offsetBy(dx: dx, dy: dy)
            let full = PixelRect(x: 0, y: 0, width: r.width, height: r.height)
            doc.updateBackground { bg in
                bg.withRaster { surf in
                    let px = surf.format.components(fromRGBA: SIMD4(ext.x, ext.y, ext.z, 1))
                    let keep = surf.contentBounds.intersect(old)
                    let saved = surf.readInterleaved(keep)
                    surf.fill(full, with: px)
                    if !keep.isEmpty { surf.writeInterleaved(keep, saved) }
                }
            }
        }
        CanvasGeometry.refresh(&doc, .shapes)
    }

    // MARK: Canvas Size

    /// The nine documented canvas-size anchors and their (x, y) factors.
    static let anchors: [(String, (Double, Double))] = [
        ("topLeft", (0, 0)), ("top", (0.5, 0)), ("topRight", (1, 0)),
        ("left", (0, 0.5)), ("center", (0.5, 0.5)), ("right", (1, 0.5)),
        ("bottomLeft", (0, 1)), ("bottom", (0.5, 1)), ("bottomRight", (1, 1)),
    ]

    /// An anchor name's factors, matching the nine documented values exactly (#2946).
    static func anchorFactors(_ cmd: String, _ a: String) throws -> (Double, Double) {
        if let f = anchors.first(where: { $0.0 == a }) { return f.1 }
        throw bad(cmd, "`anchor` must be one of \(anchors.map(\.0).joined(separator: "|"))")
    }

    /// photocraft `extension_color`.
    static func extensionColor(_ s: Session, _ p: JSONValue) -> SIMD4<Float> {
        switch p["extensionColor"]?.stringValue ?? "background" {
        case "foreground": return s.tools.foreground
        case "white": return SIMD4(repeating: 1)
        case "black": return SIMD4(0, 0, 0, 1)
        case "transparent": return .zero
        case let hex where hex.hasPrefix("#"):
            let h = Array(hex.drop { $0 == "#" }.utf8)
            func c(_ i: Int) -> Float {
                guard i + 2 <= h.count, let v = UInt8(String(decoding: h[i..<(i + 2)], as: UTF8.self), radix: 16) else { return 0 }
                return Float(v) / 255
            }
            return SIMD4(c(0), c(2), c(4), 1)
        default:
            return s.tools.background
        }
    }

    /// Image › Canvas Size.
    static func canvasSize(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.canvasSize"
        guard let d = s.active else { throw EngineError.noDocument }
        let (ow, oh) = (Double(d.doc.size.width), Double(d.doc.size.height))
        let relative = p["relative"]?.boolValue ?? false
        let w = p["width"]?.doubleValue ?? (relative ? 0 : ow)
        let h = p["height"]?.doubleValue ?? (relative ? 0 : oh)
        let (rw, rh) = relative ? (ow + w, oh + h) : (w, h)
        func side(_ v: Double) -> Int { v.isNaN ? 1 : Int(min(max(v.rounded(), 1), 300_000)) }
        let (nw, nh) = (side(rw), side(rh))
        let (ax, ay) = try anchorFactors(cmd, p["anchor"]?.stringValue ?? "center")
        let dx = Int32(((Double(nw) - ow) * ax).rounded())
        let dy = Int32(((Double(nh) - oh) * ay).rounded())
        let ext = extensionColor(s, p)
        SamplerMap.set(s, .translate(Double(dx), Double(dy)))
        try s.edit("Canvas Size") { doc, _ in
            try translateDocument(&doc, cmd, dx, dy)
            doc.size = PixelSize(width: nw, height: nh)
            CanvasGeometry.refresh(&doc, .shapes)
            let canvas = doc.bounds
            let old = PixelRect(x: Int(dx), y: Int(dy), width: Int(ow), height: Int(oh))
            // A Background can't contain transparent pixels: a transparent extension that adds
            // canvas area makes it a normal layer first; a shrink or no-op keeps it.
            if ext.w == 0 && (nw > Int(ow) || nh > Int(oh)) {
                doc.updateBackground { LayerOps.unlockBackground(&$0) }
            }
            // The locked Background is extended with the extension colour.
            if ext.w > 0 {
                doc.updateBackground { bg in
                    bg.withRaster { surf in
                        let px = surf.format.components(fromRGBA: ext)
                        let keep = surf.contentBounds.intersect(old)
                        let saved = surf.readInterleaved(keep)
                        surf.fill(canvas, with: px)
                        if !keep.isEmpty { surf.writeInterleaved(keep, saved) }
                    }
                }
            }
        }
        return ["width": .int(nw), "height": .int(nh), "offset": [.int(Int(dx)), .int(Int(dy))]]
    }

    // MARK: Crop

    /// The largest side an explicit crop may give the canvas (the `file.new` limit).
    static let maxCropSide: Int32 = 300_000
    /// The highest resolution (ppi) a crop may set.
    static let maxCropResolution = 10_000.0
    /// The largest crop angle accepted (degrees).
    static let maxCropAngle = 3600.0

    /// The Crop tool's W x H x Resolution: the size (px) the cropped area is resampled to and the
    /// resolution the document gets, both optional (photocraft `CropTarget`).
    struct CropTarget {
        var size: (Int, Int)?
        var resolution: Float?
        var filter: Resample

        /// Applies the target to a document that has just been cropped (inside the crop's history
        /// step).
        func apply(_ doc: inout Document) {
            if let (w, h) = size { resampleDocument(&doc, w, h, filter) }
            if let r = resolution { doc.resolutionDpi = r }
        }
    }

    /// `image.crop`'s optional `targetWidth`/`targetHeight` (whole px, both or neither),
    /// `resolution` (ppi) and `resample` (as for `image.imageSize`; "none" is refused with a target
    /// size) (photocraft `crop_target`).
    static func cropTarget(_ p: JSONValue) throws -> CropTarget {
        let cmd = "image.crop"
        func side(_ key: String) throws -> Int? {
            guard let v = p[key], v != .null else { return nil }
            guard let n = v.uint64Value, n >= 1, n <= UInt64(maxCropSide) else {
                throw bad(cmd, "`\(key)` = \(v.serialized()) must be a whole number of pixels from 1 to \(maxCropSide)")
            }
            return Int(n)
        }
        let size: (Int, Int)?
        switch (try side("targetWidth"), try side("targetHeight")) {
        case let (w?, h?): size = (w, h)
        case (nil, nil): size = nil
        default: throw bad(cmd, "`targetWidth` and `targetHeight` go together")
        }
        var resolution: Float?
        if let v = p["resolution"], v != .null {
            guard let r = v.doubleValue, r.isFinite, r >= 1, r <= maxCropResolution else {
                throw bad(cmd, "`resolution` = \(v.serialized()) must be a number of pixels per inch from 1 to \(Int(maxCropResolution))")
            }
            resolution = Float(r)
        }
        var filter: Resample? = .bicubic
        if let v = p["resample"], v != .null {
            guard let str = v.stringValue else { throw bad(cmd, "`resample` must be a string") }
            switch parseResample(str) {
            case .none: filter = nil
            case .filter(let f): filter = f
            // The direction is known only once the frame is: bicubic's own automatic choice.
            case .automatic: filter = .bicubicAutomatic
            }
        }
        switch (filter, size) {
        case (let f?, _): return CropTarget(size: size, resolution: resolution, filter: f)
        case (nil, nil): return CropTarget(size: nil, resolution: resolution, filter: .bicubic)
        case (nil, _?): throw bad(cmd, "a `targetWidth` x `targetHeight` crop needs resampling: `resample` can't be \"none\"")
        }
    }

    /// `image.crop`'s optional `angle`, normalised to (-180, 180]; nil when absent, null or zero.
    static func cropAngle(_ p: JSONValue) throws -> Double? {
        guard let v = p["angle"], v != .null else { return nil }
        guard let a = v.doubleValue else { throw bad("image.crop", "`angle` must be a number of degrees") }
        if !a.isFinite || abs(a) > maxCropAngle {
            throw bad("image.crop", "`angle` must be a finite number of degrees within ±\(Int(maxCropAngle))")
        }
        var r = a.truncatingRemainder(dividingBy: 360)
        if r < 0 { r += 360 }
        if r > 180 { r -= 360 }
        return abs(r) >= 1e-9 ? r : nil
    }

    /// A crop's result: the frame plus the document's size and resolution afterwards.
    static func cropResult(_ s: Session, _ frame: JSONValue) -> JSONValue {
        guard let d = s.active?.doc else { return frame }
        return frame.merging(["documentWidth": .int(d.size.width), "documentHeight": .int(d.size.height),
                              "resolution": .float(d.resolutionDpi)])
    }

    /// Image › Crop (to the selection bounds, or an explicit rectangle that may extend past the
    /// canvas).
    static func crop(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.crop"
        let delete = p["deleteCroppedPixels"]?.boolValue ?? true
        // Values beyond Int32 are rejected (photocraft `int_i32`).
        let x = try Params.i32(cmd, p, "x"), y = try Params.i32(cmd, p, "y")
        let w = try Params.i32(cmd, p, "width"), h = try Params.i32(cmd, p, "height")
        var explicit: PixelRect?
        if let x, let y, let w, let h, w > 0, h > 0 {
            if w > maxCropSide || h > maxCropSide { throw bad(cmd, "\(w) x \(h) exceeds the \(maxCropSide) px limit per side") }
            func end(_ o: Int32, _ len: Int32, _ ko: String, _ kl: String) throws -> Int32 {
                guard let e = Int32(exactly: Int64(o) + Int64(len)) else {
                    throw bad(cmd, "`\(ko)` + `\(kl)` = \(Int64(o) + Int64(len)) is outside the 32-bit coordinate range")
                }
                return e
            }
            explicit = PixelRect(x0: x, y0: y, x1: try end(x, w, "x", "width"), y1: try end(y, h, "y", "height"))
        }
        let target = try cropTarget(p)
        if let (tw, th) = target.size {
            guard let d = s.active else { throw EngineError.noDocument }
            try checkResampleBudget(cmd, d.doc, tw, th, "")
        }
        if let a = try cropAngle(p) {
            guard let rect = explicit else { throw bad(cmd, "an `angle` needs an explicit `x`, `y`, `width` and `height`") }
            return try rotatedCrop(s, rect, a, delete, target)
        }
        // An explicit rectangle (the Crop tool) may extend past the canvas; a selection crop is clamped.
        var r = explicit ?? .empty
        if explicit == nil, let d = s.active?.doc, let sel = d.selection { r = sel.contentBounds.intersect(d.bounds) }
        if r.isEmpty { throw EngineError.other("nothing to crop: pass x/y/width/height or make a selection") }
        SamplerMap.set(s, .translate(-Double(r.x0), -Double(r.y0)))
        let ext = s.tools.background
        try s.edit("Crop") { doc, _ in
            try cropDocument(&doc, cmd, r, deletePixels: delete, extension: ext)
            doc.selection = nil
            target.apply(&doc)
        }
        return cropResult(s, ["x": .int(Int(r.x0)), "y": .int(Int(r.y0)), "width": .int(r.width), "height": .int(r.height)])
    }

    // MARK: Trim

    /// Image › Trim.
    static func trim(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let canvas = d.doc.bounds
        let px = try s.services.renderer.render(d.doc, region: canvas).px
        let w = canvas.width
        let reference: SIMD4<Float>?
        switch p["basedOn"]?.stringValue ?? "transparent" {
        case "topLeft": reference = px.first
        case "bottomRight": reference = px.last
        default: reference = nil
        }
        func differs(_ q: SIMD4<Float>) -> Bool {
            guard let r = reference else { return q.w > 0 }
            for c in 0..<4 {
                if abs(q[c] * q.w - r[c] * r.w) > 0.5 / 255 || (c == 3 && abs(q.w - r.w) > 0.5 / 255) { return true }
            }
            return false
        }
        var (x0, y0, x1, y1) = (Int.max, Int.max, Int.min, Int.min)
        for (i, q) in px.enumerated() where differs(q) {
            let (x, y) = (i % max(w, 1), i / max(w, 1))
            x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x + 1); y1 = max(y1, y + 1)
        }
        if x0 > x1 { throw EngineError.other("nothing to trim to") }
        func side(_ k: String) -> Bool { p[k]?.boolValue ?? true }
        let r = PixelRect(x0: side("left") ? canvas.x0 + Int32(x0) : canvas.x0, y0: side("top") ? canvas.y0 + Int32(y0) : canvas.y0,
                          x1: side("right") ? canvas.x0 + Int32(x1) : canvas.x1, y1: side("bottom") ? canvas.y0 + Int32(y1) : canvas.y1)
        SamplerMap.set(s, .translate(-Double(r.x0), -Double(r.y0)))
        let ext = s.tools.background
        try s.edit("Trim") { doc, _ in try cropDocument(&doc, "image.trim", r, deletePixels: true, extension: ext) }
        return ["x": .int(Int(r.x0)), "y": .int(Int(r.y0)), "width": .int(r.width), "height": .int(r.height)]
    }

    // MARK: Depth

    /// Converts every pixel surface of a layer tree (masks included) to `depth`.
    static func convertLayersDepth(_ layers: inout [Layer], _ depth: SampleType) {
        forEachSurface(&layers, masks: true) { surf, _ in surf = surf.converted(to: surf.format.withSample(depth)) }
    }

    /// Image › Mode › 8/16/32 Bits/Channel.
    static func convertDepth(_ s: Session, _ depth: SampleType) throws -> JSONValue {
        guard let current = s.active?.doc.depth else { throw EngineError.noDocument }
        // History.record clears redo even when the edit leaves the document unchanged.
        if current == depth { return .null }
        try s.edit("Bit Depth") { doc, _ in
            // 32-bit documents hold linear light (Photoshop: grey 128 becomes 0.2159), so the
            // colour samples cross the document's tone curve when the depth crosses 32 bits:
            // decoded after widening, encoded before narrowing. Masks, alpha and channels are not
            // colour.
            let crosses = (current == .f32) != (depth == .f32) && (doc.mode == .rgb || doc.mode == .grayscale)
            let toLinear = depth == .f32
            let transfer = Transfer.forDocument(mode: doc.mode, depth: toLinear ? current : depth)
            if crosses && !toLinear {
                forEachSurface(&doc.layers, masks: false) { surf, _ in surf = mapColor(surf) { min(max(transfer.encode($0), 0), 1) } }
            }
            convertLayersDepth(&doc.layers, depth)
            if crosses && toLinear {
                forEachSurface(&doc.layers, masks: false) { surf, _ in surf = mapColor(surf) { transfer.decode($0) } }
            }
            for i in doc.channels.indices { doc.channels[i].surface = doc.channels[i].surface.converted(to: doc.channels[i].surface.format.withSample(depth)) }
            if var q = doc.quickMask { q.surface = q.surface.converted(to: q.surface.format.withSample(depth)); doc.quickMask = q }
            doc.depth = depth
        }
        return .null
    }

    // MARK: Duplicate

    /// Image › Duplicate.
    static func duplicate(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        var doc = d.doc
        doc.id = .fresh()
        doc.name = p["name"]?.stringValue ?? "\(d.doc.name) copy"
        if p["mergedOnly"]?.boolValue ?? false {
            let fmt = doc.pixelFormat
            var surf = try s.services.renderer.compositeToSurface(doc, rect: doc.bounds, format: fmt)
            surf.prune()
            doc.layers = [Layer(name: "Background", content: .raster(surf))]
            // A merged-only copy has no original layers for saved comps to restore.
            doc.layerComps = []
            doc.lastAppliedComp = nil
            doc.lastDocumentState = nil
        }
        doc.reassignLayerIds()
        let name = doc.name
        let index = s.addDocument(doc)
        return ["document": .int(index), "name": .string(name)]
    }

    // MARK: Registration

    static let modeParams = #"{"profile":"<builtin id>|working|/path/to/profile.icc"=working,"intent":"perceptual|relative|saturation|absolute"="relative","bpc":bool=true}"#

    public static func register(into r: inout CommandRegistry) {
        r.add([
            CommandSpec("image.imageSize", "Image Size…", menu: ["Image"],
                        params: #"{"width":px,"height":px,"resolution":ppi,"resample":"automatic|preserveDetails|bicubicSmoother|bicubicSharper|bicubicAutomatic|bicubic|nearest|bilinear|lanczos|none"="bicubic"} → {width,height} (the document's size after the command; "none" changes the resolution only)"#,
                        module: m, enabled: Pre.hasDoc, run: imageSize),
            CommandSpec("image.canvasSize", "Canvas Size…", menu: ["Image"],
                        params: ##"{"width":px,"height":px,"relative":bool=false,"anchor":"topLeft|top|topRight|left|center|right|bottomLeft|bottom|bottomRight"="center","extensionColor":"background|foreground|white|black|transparent|#rrggbb"="background"}"##,
                        module: m, enabled: Pre.hasDoc, run: canvasSize),
            CommandSpec("image.crop", "Crop", menu: ["Image"],
                        params: #"{"x":px,"y":px,"width":px,"height":px,"angle":-3600..3600=0,"deleteCroppedPixels":bool=true,"targetWidth":px,"targetHeight":px,"resolution":ppi,"resample":"bicubic|bilinear|nearest|lanczos|preserveDetails"="bicubic"} → {x,y,width,height,documentWidth,documentHeight,resolution} (targetWidth/targetHeight, both or neither: the cropped area is resampled to exactly that size, as Image Size, in the same undo step; resolution: the document's new ppi)"#,
                        module: m, enabled: Pre.hasDoc, run: crop),
            CommandSpec("image.trim", "Trim…", menu: ["Image"],
                        params: #"{"basedOn":"transparent|topLeft|bottomRight"="transparent","top":bool=true,"bottom":bool=true,"left":bool=true,"right":bool=true}"#,
                        module: m, enabled: Pre.hasDoc, run: trim),
            CommandSpec("image.mode.rgb", "RGB Color", menu: ["Image", "Mode"], params: modeParams, module: m, enabled: Pre.hasDoc) { s, p in
                try ColorCommands.convertMode(s, .rgb, p)
            },
            CommandSpec("image.mode.grayscale", "Grayscale", menu: ["Image", "Mode"], params: modeParams, module: m, enabled: Pre.hasDoc) { s, p in
                try ColorCommands.convertMode(s, .grayscale, p)
            },
            CommandSpec("image.mode.cmyk", "CMYK Color", menu: ["Image", "Mode"], params: modeParams, module: m, enabled: Pre.hasDoc) { s, p in
                try ColorCommands.convertMode(s, .cmyk, p)
            },
            CommandSpec("image.mode.lab", "Lab Color", menu: ["Image", "Mode"], params: modeParams, module: m, enabled: Pre.hasDoc) { s, p in
                try ColorCommands.convertMode(s, .lab, p)
            },
            CommandSpec("image.mode.bits8", "8 Bits/Channel", menu: ["Image", "Mode"], module: m, enabled: Pre.hasDoc) { s, _ in try convertDepth(s, .u8) },
            CommandSpec("image.mode.bits16", "16 Bits/Channel", menu: ["Image", "Mode"], module: m, enabled: Pre.hasDoc) { s, _ in try convertDepth(s, .u16) },
            CommandSpec("image.mode.bits32", "32 Bits/Channel", menu: ["Image", "Mode"], module: m, enabled: Pre.hasDoc) { s, _ in try convertDepth(s, .f32) },
            CommandSpec("image.duplicate", "Duplicate…", menu: ["Image"], params: #"{"name":str,"mergedOnly":bool=false}"#,
                        module: m, enabled: Pre.hasDoc, run: duplicate),
        ])
    }
}
