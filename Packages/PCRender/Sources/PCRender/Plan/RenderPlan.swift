// Port of photocraft-compose (crates/compose/src/lib.rs planner semantics) and photocraft-gpu (crates/gpu/src/plan.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The plan both compositors execute (architecture §7.1): a linear DrawOp program over a stack of
// straight-alpha RGBA buffers covering the render region. It is the only place Photoshop layer
// semantics are encoded — pass-through vs isolated groups, clipping, fill vs opacity, Blend If,
// knockout — so the CPU reference and the Metal compositor cannot diverge on them. Leaves (layer
// pixels, masks, effect shapes) are referenced by `LeafID` and supplied by a `RenderSource`
// (`DocumentPlanner` builds both from a PCDocument).
//
// photocraft's GPU planner emits passes over numbered slots; this port keeps the architecture's
// stack form, which a recursive tree walk emits directly (DocumentPlanner.swift maps compose's
// `composite_stack` / `composite_layer` / `composite_atop` to these ops).

import PCDocument
import PCFoundation

/// Identifies a leaf (layer content, pixel mask, vector-mask coverage, effect shape …).
public struct LeafID: Hashable, Sendable, CustomStringConvertible {
    public let raw: UInt64
    public init(raw: UInt64) { self.raw = raw }
    /// A layer's leaf of `role` (56 bits of layer id, 8 of role).
    public init(layer: UInt64, role: LeafRole) { raw = layer << 8 | UInt64(role.rawValue) }
    public var description: String { "leaf(\(raw >> 8).\(raw & 0xff))" }
}

public enum LeafRole: UInt8, Sendable {
    case content, mask, vectorMask, fillCache, shapeFill, shapeStroke, effectShape, background, other
}

/// The pixels of a leaf.
public enum RenderLeaf: Sendable {
    /// Tiled document pixels (any colour model / depth; read as straight RGBA, or channel 0 for masks
    /// and shapes). Missing tiles read as the surface's default pixel. GPU-resident per
    /// (leaf, tile, `Tile.generation`).
    case surface(Surface)
    /// Pixels rendered over `image.rect` (1–4 channels: grey, grey+alpha, RGB, RGBA); `outside`
    /// beyond it (RGBA for content, `.x` for masks and shapes). `version` changes with the pixels.
    case image(FloatImage, outside: SIMD4<Float>, version: UInt64)
}

/// Supplies the leaves and patterns a plan references (phase 2: a PCDocument adaptor).
public protocol RenderSource: Sendable {
    func leaf(_ id: LeafID) -> RenderLeaf?
    func pattern(id: String, name: String) -> PatternTile?
    /// The identity of a leaf's pixels without building it (cache keys for effect maps and
    /// feathered masks); nil for an unknown leaf.
    func leafVersion(_ id: LeafID) -> UInt64?
}

extension RenderSource {
    public func leafVersion(_ id: LeafID) -> UInt64? { leaf(id).map(LeafReader.version) }
}

/// A dictionary-backed `RenderSource` (tests, tools, simple callers).
public struct LeafTable: RenderSource {
    public var leaves: [LeafID: RenderLeaf]
    public var patterns: [PatternTile]
    public init(leaves: [LeafID: RenderLeaf] = [:], patterns: [PatternTile] = []) { self.leaves = leaves; self.patterns = patterns }
    public func leaf(_ id: LeafID) -> RenderLeaf? { leaves[id] }
    /// Looked up by id, then by name (photocraft-doc `pattern::find`).
    public func pattern(id: String, name: String) -> PatternTile? {
        if !id.isEmpty, let p = patterns.first(where: { $0.id == id }) { return p }
        return patterns.first { $0.name == name }
    }
}

/// A layer's effective mask: pixel mask with density and feather × vector-mask coverage with its
/// feather (`compose::mask_vals` / `masks::combined_mask`).
public struct MaskSpec: Hashable, Sendable {
    /// Grayscale mask (channel 0); outside its pixels its default (`surface`) or `outside.x` (`image`).
    public var pixel: LeafID?
    public var density: Float
    public var feather: Float
    /// Vector-mask coverage (channel 0), rendered by the source over the path bounds (+2 px).
    public var vector: LeafID?
    public var vectorFeather: Float

    public init(pixel: LeafID? = nil, density: Float = 1, feather: Float = 0, vector: LeafID? = nil, vectorFeather: Float = 0) {
        self.pixel = pixel; self.density = density; self.feather = feather; self.vector = vector; self.vectorFeather = vectorFeather
    }

    /// Gaussian sigma of a feather of `px` pixels (sigma = feather, capped at 1000).
    public static func featherSigma(_ px: Float) -> Float { px.isFinite ? min(max(px, 0), 1000) : 0 }

    /// Whether the mask is built canvas-wide (a feathered pixel or vector mask).
    public var hasFeather: Bool {
        (pixel != nil && MaskSpec.featherSigma(feather) > 0) || (vector != nil && MaskSpec.featherSigma(vectorFeather) > 0)
    }
}

/// How a layer's buffer blends into the backdrop.
public struct LayerBlend: Hashable, Sendable {
    public var mode: BlendMode
    public var opacity: Float
    /// Fill opacity (part of the blend for the "special eight", coverage otherwise).
    public var fill: Float
    /// Text blending gamma of type layers (1 = off).
    public var textGamma: Float
    public init(_ mode: BlendMode = .normal, opacity: Float = 1, fill: Float = 1, textGamma: Float = 1) {
        self.mode = mode; self.opacity = opacity; self.fill = fill; self.textGamma = textGamma
    }
}

/// A leaf drawn as a layer's own pixels.
public struct DrawTiles: Hashable, Sendable {
    /// `nil`: an empty (transparent) layer.
    public var leaf: LeafID?
    public var mask: MaskSpec?
    public init(leaf: LeafID?, mask: MaskSpec? = nil) { self.leaf = leaf; self.mask = mask }
}

/// A fill layer's content.
public struct FillOp: Hashable, Sendable {
    public var fill: Fill
    /// The frame gradients and linked patterns are laid out in (`compose::fill_frame`).
    public var frame: PixelRect
    public var mask: MaskSpec?
    public init(fill: Fill, frame: PixelRect, mask: MaskSpec? = nil) { self.fill = fill; self.frame = frame; self.mask = mask }
}

/// An adjustment layer's result mixed back over the backdrop.
public struct AdjustMix: Hashable, Sendable {
    public var mode: BlendMode
    /// Opacity × fill.
    public var opacity: Float
    public var mask: MaskSpec?
    public init(mode: BlendMode = .normal, opacity: Float = 1, mask: MaskSpec? = nil) { self.mode = mode; self.opacity = opacity; self.mask = mask }
}

/// Channel restrictions and Blend If applied to a finished layer composite.
public struct FinishLayer: Hashable, Sendable {
    /// Per-channel weights (1 = the layer's result, 0 = the backdrop's value kept); `nil` = all blend.
    public var channels: SIMD3<Float>?
    public var blendIf: BlendIf?
    /// The stack holds the layer's own colours (`render_content`) under the result; adjustment
    /// layers have none ("This Layer" is judged by the result).
    public var hasOwn: Bool
    public init(channels: SIMD3<Float>? = nil, blendIf: BlendIf? = nil, hasOwn: Bool = false) {
        self.channels = channels; self.blendIf = blendIf; self.hasOwn = hasOwn
    }
}

public enum GroupKind: Hashable, Sendable {
    /// Children composite onto a fresh transparent buffer.
    case isolated
    /// Children composite onto (a copy of) the backdrop itself.
    case passThrough
}

public enum PopGroup: Hashable, Sendable {
    /// The group's buffer (top) becomes its content: masked, then blended by a following op.
    case isolated(mask: MaskSpec?)
    /// [before, after] → `after` mixed back toward `before` by opacity × mask (premultiplied).
    case passThrough(opacity: Float, mask: MaskSpec?)
}

/// One instruction. Stack effects are written `[inputs] → [outputs]`, top last; every buffer covers
/// the render region.
public enum DrawOp: Hashable, Sendable {
    // Groups and buffers
    /// `.isolated`: [] → [transparent]; `.passThrough`: [b] → [b, b].
    case pushGroup(GroupKind)
    /// See `PopGroup`.
    case popGroup(PopGroup)
    /// [] → [transparent].
    case pushTransparent
    /// [… x(n) … top] → [… top, x(n)]: a copy of the element `n` below the top (0 = duplicate).
    case pick(Int)
    /// [x] → [].
    case drop
    /// [a, b] → [b, a].
    case swap
    /// Removes the element `n` below the top (0 = drop).
    case remove(Int)

    // Leaves
    /// [] → [layer pixels with masks].
    case drawTiles(DrawTiles)
    /// [] → [fill content with masks].
    case fill(FillOp)
    /// [] → [(0, 0, 0, mask)] (all ones without a mask): knockout shapes, clips, hiding masks.
    case pushMaskShape(MaskSpec?)
    /// [x] → [x with alpha × mask].
    case mask(MaskSpec)

    // Blending
    /// [backdrop, src] → [src blended into backdrop] (`blend_into_fill`, Dissolve included).
    case composite(LayerBlend)
    /// Marker: the top is a clipping base; `.clipped` ops follow (no stack effect).
    case beginClipBase
    /// [base, src] → [src composited atop base, keeping its alpha] (`composite_atop`).
    case clipped(LayerBlend)
    /// [x] → [x adjusted] (`adjust::apply_in`; transparent pixels untouched).
    case adjust(Adjustment)
    /// [backdrop, adjusted] → [backdrop + (blend(backdrop, adjusted) − backdrop) × opacity × mask].
    case adjustMix(AdjustMix)
    /// [x] → [x rounded to `q` steps per unit] (adjustment results in integer documents).
    case quantize(Float)
    /// [before, (own), after] → [after with channel restrictions, then Blend If].
    case finishLayer(FinishLayer)
    /// [backdrop, content] → [content and its effects composited]; `atop`: [base, content] →
    /// effects over the base treated as opaque, keeping its alpha (clipped layers).
    case effect(EffectsSpec, atop: Bool)

    // Advanced blending
    /// Saves a copy of the top as the current stack's knockout floor (no stack effect).
    case saveFloor
    /// [] → [floor].
    case pushFloor
    /// Forgets the innermost floor.
    case dropFloor
    /// [target, shape, backdrop] → [before, shape, knocked, knocked]: inside the shape (its alpha)
    /// the backdrop becomes the target; `clipAlpha` keeps alpha from growing (clipped layers).
    case knockoutBegin(clipAlpha: Bool)
    /// [before, shape, knocked, after] → [result]: layer opacity sets the knockout's strength.
    case knockoutEnd(opacity: Float)
    /// [before, after, shape] → [mix(before, after, shape.alpha × k)] (`advanced::mix`): clipped layers
    /// blended individually, masks hiding effects.
    case mixBy(Float)
    /// [a, with, without] → [a + with − without] premultiplied (layers clipped to pass-through groups).
    case addDifference
    /// [before, after] → [after inside `rect`, before outside] (artboards).
    case restrictTo(PixelRect)
}

/// Document-level inputs of a plan.
public struct RenderContext: Hashable, Sendable {
    public var canvas: PixelRect
    public var mode: ColorMode
    public var depth: SampleType
    public var globalLight: GlobalLight
    /// What the buffers hold (display RGB, or a Lab / CMYK document's own channels).
    public var native: NativeSpace

    public init(canvas: PixelRect, mode: ColorMode = .rgb, depth: SampleType = .u8, globalLight: GlobalLight = GlobalLight(),
                native: NativeSpace = .none) {
        self.canvas = canvas; self.mode = mode; self.depth = depth; self.globalLight = globalLight; self.native = native
    }

    public var transfer: Transfer { Transfer.forDocument(mode: mode, depth: depth) }
    public var space: BlendSpace { BlendSpace(lab: mode == .lab && native == .none, hdr: depth == .f32, native: native, ps8: depth == .u8) }
    public var quantum: Float? { adjustmentQuantum(depth) }
    /// Steps per unit of the document's stored samples (fill layers render at this depth, as a
    /// PSD stores their pixels); nil for 32-bit.
    public var storageQuantum: Float? {
        switch depth {
        case .u8: 255
        case .u16: 65535
        case .f32: nil
        }
    }
}

/// A DrawOp program and its document context.
public struct RenderPlan: Hashable, Sendable {
    public var context: RenderContext
    public var ops: [DrawOp]
    public init(context: RenderContext, ops: [DrawOp]) { self.context = context; self.ops = ops }

    /// Checks the program's stack discipline: no underflow, one buffer at the end, floors balanced.
    public func validate() throws(PlanError) {
        var depth = 0, floors = 0
        func need(_ n: Int, _ i: Int) throws(PlanError) { if depth < n { throw .stackUnderflow(op: i) } }
        for (i, op) in ops.enumerated() {
            switch op {
            case .pushGroup(.isolated), .pushTransparent, .drawTiles, .fill, .pushMaskShape: depth += 1
            case .pushGroup(.passThrough): try need(1, i); depth += 1
            case .popGroup(.isolated): try need(1, i)
            case .popGroup(.passThrough): try need(2, i); depth -= 1
            case .pick(let n): try need(n + 1, i); depth += 1
            case .drop: try need(1, i); depth -= 1
            case .swap: try need(2, i)
            case .remove(let n): try need(n + 1, i); depth -= 1
            case .mask, .adjust, .quantize: try need(1, i)
            case .beginClipBase: try need(1, i)
            case .composite, .clipped, .adjustMix, .effect, .restrictTo: try need(2, i); depth -= 1
            case .finishLayer(let f): try need(f.hasOwn ? 3 : 2, i); depth -= f.hasOwn ? 2 : 1
            case .saveFloor: try need(1, i); floors += 1
            case .pushFloor: if floors == 0 { throw .noFloor(op: i) }; depth += 1
            case .dropFloor: if floors == 0 { throw .noFloor(op: i) }; floors -= 1
            case .knockoutBegin: try need(3, i); depth += 1
            case .knockoutEnd: try need(4, i); depth -= 3
            case .mixBy, .addDifference: try need(3, i); depth -= 2
            }
        }
        if depth != 1 { throw .unbalanced(finalDepth: depth) }
        if floors != 0 { throw .floorsLeft(floors) }
    }
}

public enum PlanError: Error, Equatable, CustomStringConvertible {
    case stackUnderflow(op: Int)
    case unbalanced(finalDepth: Int)
    case noFloor(op: Int)
    case floorsLeft(Int)
    case missingLeaf(LeafID)

    public var description: String {
        switch self {
        case .stackUnderflow(let i): "plan: stack underflow at op \(i)"
        case .unbalanced(let d): "plan: \(d) buffers left at the end (want 1)"
        case .noFloor(let i): "plan: no knockout floor at op \(i)"
        case .floorsLeft(let n): "plan: \(n) floors left"
        case .missingLeaf(let l): "plan: missing \(l)"
        }
    }
}
