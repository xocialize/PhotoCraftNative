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
    ]

    /// The params a command registered from `c` should have.
    static func expected(_ c: PhotocraftCommand) -> String { params[c.id] ?? c.params }
}
