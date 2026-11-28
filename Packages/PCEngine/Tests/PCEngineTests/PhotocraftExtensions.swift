// The params PhotoCraftNative extends past photocraft's catalogue (which keeps photocraft's own notation): the
// catalogue tests compare a command's params with this entry when it has one. MIT OR Apache-2.0, © ArtCraft Team
// and the PhotoCraft contributors.

@testable import PCEngine

enum PhotocraftExtensions {
    /// Command id → its params as PCEngine registers them.
    static let params: [String: String] = [
        // AB-T-0292: Image Size's enlarger slot.
        "image.imageSize": #"{"width":px,"height":px,"resolution":ppi,"resample":"automatic|preserveDetails|bicubicSmoother|bicubicSharper|bicubicAutomatic|bicubic|nearest|bilinear|lanczos|none"="bicubic","enlarger":bool=false} → {width,height,enlarger?} (the document's size after the command; "none" changes the resolution only. enlarger: to a size larger on both axes, each pixel layer runs the host's ×2 enlarger (PCIntelligence's enlarge slot) until both axes reach the target, then resample fits it; enlarger reports {used,engine,passes,intermediate,fit,fitsUp,layers,chain}, or {used:false,reason} when it falls back to resample alone)"#,
        // AB-T-0300: Scale Effects on any layer.
        "layer.layerStyle.scaleEffects": ##"{"layer":id?,"scale":1..1000=100} (every effect of the layer, shown or hidden)"##,
        // AB-T-0279: the Magic Wand's Sample Size.
        "select.magicWand": #"{"x":px,"y":px,"tolerance":0..255=32,"sampleSize":1|3|5|11|31|51|101=1 (Point Sample, or the N by N Average),"contiguous":bool=true,"antiAlias":bool=true,"sampleAllLayers":bool=false,"mode":"replace|add|subtract|intersect"="replace"} (samples the visible alpha, Quick Mask, or layer mask when that is the picture)"#,
        // AB-T-0279: a Polygonal Lasso step.
        "select.lasso": #"{"points":[[x,y],…],"mode":"replace|add|subtract|intersect"="replace","antiAlias":bool=true,"feather":px=0,"polygonal":bool=false (the step is "Polygonal Lasso")}"#,
        // AB-T-0285: Release takes the clipped run above out too.
        "layer.releaseClippingMask": #"{"layer":id?} (no layer: every selected layer; each takes the layers clipped above it out too)"#,
        // AB-R-1213: whole-layer transforms while a selection is active.
        "edit.transform": ##"{"layer":id?,"rect":[x0,y0,x1,y1]? (source frame; default = layer content ∩ selection),"quad":[[x,y]×4]? (where the frame's corners go, clockwise from top-left),"matrix":[a,b,c,d,e,f]? (affine alternative),"interpolation":"bicubic|bilinear|nearest"="bicubic","target":"pixels"|"mask"|"quickMask"|{"channel":i}=Channels panel target (an unlinked mask, an alpha channel or the Quick Mask transforms alone; a linked mask moves with its layer),"selection":"use|ignore"="use" (ignore: the whole layer transforms and the selection stays where it is)}"##,
        // AB-R-1213: a host's Preserve Transparency.
        "filter.blur.gaussianBlur": ##"{"radius":0.1..1000=1,"preserveTransparency":bool=false (a pixel layer keeps its alpha, as a transparency-locked one does)}"##,
        // photocraft #7437 (502d055c6), taken after the catalogue's revision.
        "file.saveACopy": ##"{"path":str (format from the extension),"quality":0..12? (JPEG),"layers":bool=true,"overwrite":bool=false (replace the document's own file),"tiffLayers":bool=false (TIFF: keep the layers; flat by default),"tgaBits":24|32? (TGA: 32 writes the alpha channel, or else the transparency, as the alpha; unset, 32 with an alpha channel or transparency, else 24)}"##,
    ]

    /// The params a command registered from `c` should have.
    static func expected(_ c: PhotocraftCommand) -> String { params[c.id] ?? c.params }
}
