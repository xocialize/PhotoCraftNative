// Port of photocraft-engine (crates/engine/src/layer_menu_cmds.rs `mask_all_objects`, `color_decontaminate`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Part of the layer_menu_cmds port: Layer › Mask All Objects, which runs PCAlgo's Select › Subject
// segmentation (`SelectSubject`) over the layer (or the composite) and masks the layer to it, and
// the matting decontamination Layer › Matting › Color Decontaminate runs (`Matting.decontaminate`).

import PCAlgo
import PCDocument
import PCFoundation

extension LayerMenuCommands {
    /// Layer › Mask All Objects: detects the main objects (the Select › Subject segmentation over
    /// the layer, or the composite for non-pixel layers) and masks the layer to them. Photoshop
    /// makes one group per object; here the objects share one mask.
    static func maskAllObjects(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try s.layerParam(p)
        guard let d = s.active else { throw EngineError.noDocument }
        let doc = d.doc
        guard let layer = doc.layer(id) else { throw EngineError.noLayer(id) }
        let sampler: any SegmentSampler
        if case .raster(let surf) = layer.content {
            sampler = SurfaceSegmentSampler(surf)
        } else {
            sampler = SmartSelectCommands.CompositeSampler(doc: doc, renderer: s.services.renderer)
        }
        guard let region = SelectSubject.select(sampler, canvas: doc.bounds) else { throw EngineError.other("no objects were found") }
        let bbox = region.bbox
        try s.edit("Mask All Objects") { doc, _ in
            var mask = LayerMask.hideAll()
            mask.surface.writeRegion(bbox, region.mask.map { Float($0) / 255 })
            mask.surface.prune()
            guard doc.updateLayer(id, { $0.mask = mask }) != nil else { throw EngineError.noLayer(id) }
        }
        return ["bounds": .rect(bbox)]
    }
}

extension LayerMenuCommands {
    /// photocraft-algo `matting::decontaminate` (PCAlgo's `Matting.decontaminate`) with an 8-bit
    /// alpha `alpha` over `bbox`: fringe colours move toward nearby opaque colours.
    static func decontaminate(_ surf: Surface, bbox: PixelRect, alpha: [UInt8], radius: Float, amount: Float) -> Surface {
        guard alpha.count == bbox.area else { return surf }
        return Matting.decontaminate(surf, alpha: SelectionRegion(bbox: bbox, mask: alpha), radius: radius, amount: amount)
    }
}
