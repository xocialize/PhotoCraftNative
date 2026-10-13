// A layer's pixel-free properties as one value: what Layers-panel and Layer Style edits change
// (the `SetLayerProps` operation of architecture §6).
// Port support for photocraft-doc (crates/doc/src/lib.rs `Layer`), MIT OR Apache-2.0, © ArtCraft
// Team and the PhotoCraft contributors.

import PCFoundation

/// Every property of a layer that holds no pixels and no children: name, visibility, locks,
/// blending, style, label, link group, Blend If, Advanced Blending and the vector mask.
public struct LayerProperties: Equatable, Sendable {
    public var name: String
    public var visible: Bool
    public var locks: Locks
    public var blend: BlendMode
    public var opacity: Float
    public var fillOpacity: Float
    public var clipped: Bool
    public var vectorMask: VectorMask?
    public var effects: Effects
    public var label: LabelColor
    public var linkGroup: UInt64?
    public var excludedChannels: UInt32
    public var blendIf: BlendIf
    public var advanced: AdvancedBlending
}

extension Layer {
    /// This layer's pixel-free properties; setting them leaves id, content, masks' pixels, PSD
    /// data and video untouched.
    public var properties: LayerProperties {
        get {
            LayerProperties(name: name, visible: visible, locks: locks, blend: blend, opacity: opacity, fillOpacity: fillOpacity,
                            clipped: clipped, vectorMask: vectorMask, effects: effects, label: label, linkGroup: linkGroup,
                            excludedChannels: excludedChannels, blendIf: blendIf, advanced: advanced)
        }
        set {
            name = newValue.name
            visible = newValue.visible
            locks = newValue.locks
            blend = newValue.blend
            opacity = newValue.opacity
            fillOpacity = newValue.fillOpacity
            clipped = newValue.clipped
            vectorMask = newValue.vectorMask
            effects = newValue.effects
            label = newValue.label
            linkGroup = newValue.linkGroup
            excludedChannels = newValue.excludedChannels
            blendIf = newValue.blendIf
            advanced = newValue.advanced
        }
    }
}
