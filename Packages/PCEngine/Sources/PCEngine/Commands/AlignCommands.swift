// Port of photocraft-engine (crates/engine/src/align_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Edit › Auto-Align Layers and Auto-Blend Layers, on the selected pixel layers.
//
// Both share Photomerge's registration and blending (PCAlgo's `Panorama` via `PhotoCommands`).
// Auto-Align matches Harris / steered-BRIEF features between every pair of layers, chains the
// verified pairs from the reference layer (maximum spanning tree) and bundle-adjusts all of them,
// then warps each layer. Layers that nearly coincide (a focus or exposure bracket) have nothing to
// match and register by intensity instead (`DirectAlign`; `registration`: auto falls back to it,
// or ask for it). Projections: Auto, Perspective (homography), Cylindrical and Spherical (rigid
// motion on the cylinder / sphere, focal length from the homographies or EXIF), Collage
// (similarity) and Reposition (translation). The reference stays put in the planar projections.
//
// Auto-Blend gives each selected layer a mask so the composite shows, per pixel, the sharpest
// layer (Stack Images, for focus stacking) or one layer per region with seams routed where the
// layers agree (Panorama). With Seamless Tones and Colors it also adds a merged layer: the
// panorama blended with Laplacian pyramids so transitions are invisible, the stack fused on the
// Laplacian pyramid, each coefficient from the layer sharpest at that scale (`Pyramid.fuseStack`;
// `haloControl` keeps a bright object's defocused glow out of the coarse levels).

import Foundation
import PCAlgo
import PCDocument
import PCFoundation

enum AlignCommands: CommandModule {
    static let name = "align_cmds"
    static let m = "align_cmds"

    /// The selected raster layers, bottom to top.
    static func selectedPixelLayers(_ s: Session) -> [LayerId] {
        guard let st = s.active else { return [] }
        return st.selectedLayers.filter { id in
            if case .raster? = st.doc.layer(id)?.content { return true }
            return false
        }
    }

    static let twoLayers: CommandEnabled = { s, _ in
        guard s.active != nil else { return "no document open" }
        return selectedPixelLayers(s).count < 2 ? "select two or more pixel layers in the Layers panel" : nil
    }

    // MARK: Auto-Align Layers

    static func autoAlign(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "edit.autoAlignLayers"
        let ids = selectedPixelLayers(s)
        if ids.count < 2 { throw EngineError.bad(cmd, "select two or more pixel layers") }
        let projection = p["projection"]?.stringValue ?? "auto"
        guard let layout = Panorama.Layout(parsing: projection) else {
            throw EngineError.bad(cmd, "unknown projection `\(projection)` (auto|perspective|cylindrical|spherical|collage|reposition)")
        }
        guard let st = s.active else { throw EngineError.noDocument }
        let doc = st.doc
        let reference: LayerId
        switch p["reference"]?.uint64Value {
        case let r? where ids.contains(LayerId(r)): reference = LayerId(r)
        case let r?: throw EngineError.bad(cmd, "reference \(r) is not a selected pixel layer")
        case nil: reference = ids[0]
        }
        let refIdx = ids.firstIndex(of: reference) ?? 0
        let area = doc.bounds
        var images: [(Surface, PixelRect)] = []
        for id in ids {
            guard let surf = doc.layer(id)?.surface else { throw EngineError.noLayer(id) }
            images.append((surf, area))
        }
        let focal35 = doc.metadata.exif.flatMap { Exif.read($0).focalLength35mm }
        let geometric = p["geometricCorrection"]?.boolValue ?? false
        let registration = p["registration"]?.stringValue ?? "auto"
        if !["auto", "features", "intensity"].contains(registration) {
            throw EngineError.bad(cmd, "`registration` must be auto|features|intensity")
        }
        let noDetail = EngineError.other(PhotoCommands.noDetail)
        // Features first (a panorama); layers that nearly coincide (a focus or exposure bracket)
        // have nothing to match, and register by intensity instead.
        let byFeatures = registration != "intensity"
            ? PhotoCommands.registerImages(images, layout, reference: refIdx, geometric: geometric, focal35: focal35) : nil
        let al: PhotoCommands.Aligned, used: String
        switch (byFeatures, registration) {
        case (let a?, _): (al, used) = (a, "features")
        case (nil, "features"): throw noDetail
        case (nil, _):
            switch PhotoCommands.registerDirect(images, layout, refIdx) {
            case .success(let a): (al, used) = (a, "intensity")
            case .failure(let f):
                throw registration == "intensity" && f.message != PhotoCommands.noDetail ? EngineError.bad(cmd, f.message) : noDetail
            }
        }
        let interp = Interp(parsing: p["interpolation"]?.stringValue ?? "bicubic")
        let planar = [.perspective, .collage, .reposition].contains(al.layout)
        var inliers = [Int](repeating: 0, count: ids.count)
        for (a, b, n) in al.pairs where a < ids.count && b < ids.count {
            inliers[a] += n
            inliers[b] += n
        }
        func placement(_ i: Int) -> Panorama.Placement? { i < al.placements.count ? al.placements[i] : nil }
        // Everything but the reference moves in planar layouts; every layer is reprojected otherwise.
        let moves = ids.indices.filter { placement($0) != nil && ($0 != refIdx || !planar) }
        let failed = ids.indices.filter { placement($0) == nil }.map { JSONValue.int(Int(ids[$0].rawValue)) }
        if moves.isEmpty { throw EngineError.other("Auto-Align couldn't find enough matching detail between the layers") }
        var warped: [(LayerId, Surface, Surface?)] = []
        for i in moves {
            guard let pl = placement(i) else { throw EngineError.other("Auto-Align lost a layer's placement") }
            guard let l = doc.layer(ids[i]), let surf = l.surface else { throw EngineError.noLayer(ids[i]) }
            let b = surf.contentBounds
            let px = b.isEmpty ? surf : Panorama.warpPlaced(surf, rect: b, origin: .zero, placement: pl, offset: .zero, interp: interp)
            var mask: Surface?
            if let m = l.mask {
                let mb = m.surface.contentBounds
                mask = mb.isEmpty ? m.surface : Panorama.warpPlaced(m.surface, rect: mb, origin: .zero, placement: pl, offset: .zero, interp: .bilinear)
            }
            warped.append((ids[i], px, mask))
        }
        try s.edit("Auto-Align Layers") { doc, _ in
            for (id, px, mask) in warped {
                guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
                doc.updateLayer(id) { l in
                    l.withRaster { $0 = px }
                    if var m = l.mask, let ms = mask {
                        m.surface = ms
                        l.mask = m
                    }
                }
            }
        }
        let model: String
        switch al.layout {
        case .reposition: model = "reposition"
        case .collage: model = "collage"
        case .perspective, .auto: model = "perspective"
        case .cylindrical: model = "cylindrical"
        case .spherical: model = "spherical"
        }
        let aligned: [JSONValue] = moves.compactMap { i in
            guard let pl = placement(i) else { return nil }
            let matrix = Panorama.planeMatrix(pl, origin: .zero).map { JSONValue.doubles($0.m) } ?? .null
            return ["layer": .int(Int(ids[i].rawValue)), "model": .string(model), "matches": .int(inliers[i]), "matrix": matrix]
        }
        return ["reference": .int(Int(reference.rawValue)), "layout": .string(al.layout.name), "registration": .string(used),
                "focal": .number(al.focal), "rms": .number(al.rms), "aligned": .array(aligned), "failed": .array(failed)]
    }

    // MARK: Auto-Blend Layers

    static func autoBlend(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "edit.autoBlendLayers"
        let ids = selectedPixelLayers(s)
        if ids.count < 2 { throw EngineError.bad(cmd, "select two or more pixel layers") }
        let method = p["method"]?.stringValue ?? "panorama"
        if method != "panorama" && method != "stack" { throw EngineError.bad(cmd, "`method` must be panorama|stack") }
        let seamless = p["seamlessTones"]?.boolValue ?? true
        var halo = Pyramid.StackFusion().halo
        if let v = p["haloControl"], v != .null {
            guard let hv = v.doubleValue, hv >= 0, hv <= Double(Pyramid.haloMax) else {
                throw EngineError.bad(cmd, "`haloControl` must be a number from 0 to \(BrushCommands.rustDisplay(Double(Pyramid.haloMax)))")
            }
            halo = Float(hv)
        }
        guard let st = s.active else { throw EngineError.noDocument }
        let doc = st.doc
        var area = PixelRect.empty
        for id in ids {
            if let b = doc.layer(id)?.surface?.contentBounds { area = area.union(b) }
        }
        area = area.intersect(doc.bounds)
        if area.isEmpty { throw EngineError.other("the selected layers are empty") }
        let (w, h) = (area.width, area.height)
        var imgs: [[Float]] = [], luma: [[Float]] = [], alpha: [[Float]] = []
        var fmt: PixelFormat?
        for id in ids {
            guard let surf = doc.layer(id)?.surface else { throw EngineError.noLayer(id) }
            let f = surf.format
            let px = surf.readRegion(area)
            let n = f.channels
            var lv = [Float](repeating: 0, count: w * h), av = lv
            px.withUnsafeBufferPointer { b in
                for i in 0..<(w * h) where (i + 1) * n <= b.count {
                    let c = PixelCodec.toRGBA(f, b, i * n)
                    lv[i] = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
                    av[i] = c.w
                }
            }
            if let g = fmt, g != f { throw EngineError.other("the layers have different pixel formats") }
            fmt = f
            imgs.append(px)
            luma.append(lv)
            alpha.append(av)
        }
        guard let fmt else { throw EngineError.noDocument }
        let weights: [[Float]], blended: [Float]?
        if method == "stack" {
            weights = Pyramid.stackWeights(width: w, height: h, luma: luma, alpha: alpha)
            blended = seamless ? try Pyramid.fuseStack(width: w, height: h, channels: fmt.channels, images: imgs, luma: luma, alpha: alpha,
                                                       Pyramid.StackFusion(halo: halo)) : nil
        } else {
            // Panorama: seams routed through agreement, multi-band blended (PhotoCommands).
            var surfs: [Surface] = []
            for id in ids {
                guard let surf = doc.layer(id)?.surface else { throw EngineError.noLayer(id) }
                surfs.append(surf)
            }
            let order = PhotoCommands.seamOrder(surfs, 0)
            let b = try PhotoCommands.seamBlend(surfs, area, order, seamless: seamless, gains: false, nil)
            weights = b.layers.map { $0.1.readRegion(area) }
            blended = seamless ? b.composite.readRegion(area) : nil
        }
        guard let top = ids.last else { throw EngineError.other("Auto-Blend needs two or more layers") }
        let newLayer = try s.edit("Auto-Blend Layers") { doc, active -> LayerId? in
            for (id, wt) in zip(ids, weights) {
                guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
                var mask = LayerMask.hideAll()
                mask.surface.writeRegion(area, wt)
                mask.surface.prune()
                doc.updateLayer(id) { $0.mask = mask }
            }
            guard let px = blended else { return nil }
            var l = Layer.raster(doc.nextLayerName("Blended"), format: fmt)
            l.withRaster { surf in
                surf.writeRegion(area, px)
                surf.prune()
            }
            let nid = doc.insertAbove(top, l)
            active = nid
            return nid
        }
        return ["method": .string(method), "layers": .array(ids.map { .int(Int($0.rawValue)) }),
                "blended": newLayer.map { .int(Int($0.rawValue)) } ?? .null]
    }

    // MARK: Registration

    static func register(into r: inout CommandRegistry) {
        r.add([
            CommandSpec("edit.autoAlignLayers", "Auto-Align Layers…", menu: ["Edit"],
                        params: #"{"projection":"auto|perspective|cylindrical|spherical|collage|reposition","reference":layer id?=bottom selected layer,"geometricCorrection":bool=false,"interpolation":"bicubic|bilinear|nearest","registration":"auto|features|intensity"}"#,
                        module: m, enabled: twoLayers, run: autoAlign),
            CommandSpec("edit.autoBlendLayers", "Auto-Blend Layers…", menu: ["Edit"],
                        params: #"{"method":"panorama|stack","seamlessTones":bool=true,"haloControl":0..8=2}"#,
                        module: m, enabled: twoLayers, run: autoBlend),
        ])
    }
}
