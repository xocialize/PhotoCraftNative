// Port of photocraft-compose (crates/compose/src/lib.rs `composite_stack_at`, `composite_layer*`, `composite_atop*`, `render_content`; advanced.rs) and photocraft-gpu (crates/gpu/src/plan.rs `plan`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// `plan(document:region:)`: the document's layer tree as a DrawOp program. Each function below
// emits the ops for the compose function it is named after, so the stack machine reproduces the
// CPU oracle step for step:
//
//   composite_stack_at       stack()          floors for shallow knockouts, clipping groups, the
//                                             adjustment quantum after adjustment bases
//   composite_layer          compositeLayer() channel restrictions + Blend If (`finishLayer`),
//                                             knockouts (`knockoutBegin/End`)
//   composite_artboard       artboard()       board background, `restrictTo`
//   composite_layer_plain    plain()          pass-through groups, adjustment layers, effects,
//                                             split shapes, plain content
//   composite_layer_effects  layerEffects()   `effect` with an EffectsSpec
//   composite_atop           atop()           clipped layers (`clipped`, `effect(atop:)`)
//   advanced::*              knockout(), clippedIndividually(), compositeClipped()
//   render_content           renderContent()  isolated groups, fills, pixels with masks
//
// Pass-through groups composite their children straight into the backdrop (`pushGroup
// (.passThrough)` only when opacity / masks need the original); isolated groups (any other mode,
// or fill < 100 %, or effects) render onto a transparent buffer and blend as one layer; adjustment
// layers transform everything beneath them inside their group; fill opacity is part of the blend
// (special eight) or coverage; clipped layers composite atop their base's content; hidden layers
// and clipping groups of hidden bases are skipped; layers that can't reach the region are pruned
// (`empty_in`), as are layers under an opaque Normal fill layer at the root (`occludes_below`).

import Foundation
import PCDocument
import PCFoundation

/// Planner settings.
public struct PlanOptions: Sendable {
    /// Text blending gamma of type layers (Photoshop's default 1.45; 1 = off).
    public var textGamma: Float = 1.45
    /// A layer comp to render instead of the document's current state: its recorded visibility
    /// and appearance (blend mode, opacity, fill, layer style) are applied. Positions are not:
    /// moving pixels is a document edit (the engine applies comps that way).
    public var comp: LayerComp? = nil
    /// Skip root layers beneath the topmost opaque Normal fill layer (not in Lab documents, where
    /// Normal mixes in CIELAB).
    public var pruneOccluded = true
    /// Composite Lab and CMYK documents in their own colour model, as Photoshop does (`NativeSpace`;
    /// CMYK documents with adjustments that mix channels composite in display RGB).
    public var nativeCompositing = true
    public init() {}
}

/// A planned document render: the program and the leaves it reads.
public struct DocumentPlan: Sendable {
    public let plan: RenderPlan
    public let source: DocumentRenderSource
    /// The region the plan was made for (region-dependent pruning).
    public let region: PixelRect
    /// The CMYK black plane's plan (`plan` is then the C, M, Y plane).
    public let black: (plan: RenderPlan, source: DocumentRenderSource)?
    /// What `plan`'s result holds (display RGB, Lab channels or CMY ink brightness).
    public var native: NativeSpace { plan.context.native }
    /// What the rasterizer could not provide (complete after a render: derived leaves are lazy).
    public var misses: [RasterMiss] { source.misses }

    init(plan: RenderPlan, source: DocumentRenderSource, region: PixelRect, black: (plan: RenderPlan, source: DocumentRenderSource)? = nil) {
        self.plan = plan; self.source = source; self.region = region; self.black = black
    }
}

public enum DocumentPlanner {
    /// The DrawOp program compositing `document` over `region` (leaves resolved by the
    /// `DocumentRenderSource` of `build`).
    public static func plan(document: Document, region: PixelRect) -> [DrawOp] {
        build(document: document, region: region).plan.ops
    }

    /// Plans `document` over `region`: the program plus its render source.
    public static func build(document: Document, region: PixelRect, rasterizer: any LayerRasterizer = PlaceholderRasterizer(),
                             cache: DocumentLeafCache = DocumentLeafCache(), subRenderer: CPUCompositor = CPUCompositor(),
                             options: PlanOptions = PlanOptions()) -> DocumentPlan {
        var doc = document
        if let comp = options.comp { doc = applying(comp, to: doc) }
        func one(_ native: NativeSpace) -> (RenderPlan, DocumentRenderSource) {
            let ctx = RenderContext(canvas: doc.bounds, mode: doc.mode, depth: doc.depth, globalLight: doc.globalLight, native: native)
            let source = DocumentRenderSource(document: doc, context: ctx, cache: cache, rasterizer: rasterizer, subRenderer: subRenderer)
            let e = PlanEmitter(doc: doc, region: region, source: source, cache: cache, rasterizer: rasterizer, options: options)
            e.root()
            return (RenderPlan(context: ctx, ops: e.ops), source)
        }
        switch nativeSpace(doc, options) {
        case .lab:
            let (p, s) = one(.lab)
            return DocumentPlan(plan: p, source: s, region: region)
        case .cmykInk:
            let (p, s) = one(.cmykInk), (pk, sk) = one(.cmykBlack)
            return DocumentPlan(plan: p, source: s, region: region, black: (pk, sk))
        default:
            let (p, s) = one(.none)
            return DocumentPlan(plan: p, source: s, region: region)
        }
    }

    /// The space `doc` composites in (`.cmykInk` stands for the two CMYK planes).
    static func nativeSpace(_ doc: Document, _ options: PlanOptions) -> NativeSpace {
        guard options.nativeCompositing else { return .none }
        switch doc.mode {
        case .lab: return .lab
        case .cmyk: return NativeConvert.planeSafe(doc.layers) ? .cmykInk : .none
        default: return .none
        }
    }

    /// `document` with `comp`'s visibility and appearance applied (positions are not).
    public static func applying(_ comp: LayerComp, to document: Document) -> Document {
        var d = document
        d.forEachLayerMut { l in
            guard let s = comp.state(l.id) else { return }
            if comp.applyVisibility, let v = s.visible { l.visible = v }
            if comp.applyAppearance, let a = s.appearance {
                l.blend = a.blend; l.opacity = a.opacity; l.fillOpacity = a.fillOpacity; l.effects = a.effects
            }
        }
        return d
    }
}

/// Where a layer stack sits, for knockouts (`advanced::Scope`).
struct PlanScope {
    var root: Bool
    var isolated: Bool
    static let root = PlanScope(root: true, isolated: false)
    static let isolated = PlanScope(root: false, isolated: true)
    var passThrough: PlanScope { PlanScope(root: false, isolated: isolated) }
}

/// What a knockout reveals.
enum KnockoutTarget { case floor, transparent, deep }

final class PlanEmitter {
    let doc: Document
    let region: PixelRect
    let canvas: PixelRect
    let mode: ColorMode
    let depth: SampleType
    let source: DocumentRenderSource
    let cache: DocumentLeafCache
    let rasterizer: any LayerRasterizer
    let options: PlanOptions
    /// The plan's buffer space (`RenderContext.native`).
    let native: NativeSpace
    var ops: [DrawOp] = []
    /// The area the ops being emitted will run over (the region, or an effect region for nested
    /// plans): `empty_in` pruning is decided against it.
    var rect: PixelRect
    private var rasterMemo: [LayerId: Surface?] = [:]
    private var identityMemo: [LayerId: UInt64] = [:]

    init(doc: Document, region: PixelRect, source: DocumentRenderSource, cache: DocumentLeafCache, rasterizer: any LayerRasterizer, options: PlanOptions) {
        self.doc = doc; self.region = region; canvas = doc.bounds; mode = doc.mode; depth = doc.depth
        self.source = source; self.cache = cache; self.rasterizer = rasterizer; self.options = options
        native = source.context.native
        // Blurs read their backdrop past the region (their programs run over it plus their reach,
        // nested blurs adding up): layers there must stay in the plan.
        rect = FilterMath.backdropArea(region, reach: LayerGeometry.filterReach(doc.layers, nested: true), canvas: doc.bounds)
    }

    // MARK: Pixels and leaves

    /// The pixels a layer shows: its surface or cache, else the rasterizer's (recorded on a miss).
    func pixels(_ l: Layer) -> Surface? {
        switch l.content {
        case .raster(let s): return s
        case .text, .shape, .smart:
            if let s = l.surface { return s }
            if let m = rasterMemo[l.id] { return m }
            let s = cache.raster(l, in: doc, rasterizer)
            if s == nil { source.recordMiss(RasterMiss(layer: l.id, kind: .layerPixels)) }
            rasterMemo[l.id] = s
            return s
        default: return nil
        }
    }

    func leafID(_ l: Layer, _ role: LeafRole) -> LeafID { LeafID(layer: l.id.rawValue, role: role) }

    func contentLeaf(_ l: Layer) -> LeafID? {
        guard let s = pixels(l) else { return nil }
        return surfaceLeaf(leafID(l, .content), s)
    }

    /// A layer surface as a leaf: the surface itself, or its pixels in the plan's native space.
    func surfaceLeaf(_ id: LeafID, _ s: Surface) -> LeafID {
        if native == .none {
            source.register(id, .surface(s))
            return id
        }
        let nid = id.native(native.plane)
        let version = ContentBounds.fingerprint(s) ^ (native.plane << 60)
        let space = native
        source.register(nid, version: version, level: { _, l, _ in
            NativeConvert.image(TileReduction.surface(s, level: l), space, version: LevelOfDetail.version(version, l))
        }) { _ in NativeConvert.image(s, space, version: version) }
        return nid
    }

    /// Text blending gamma: Photoshop's "Blend Text Colors Using Gamma" applies to RGB documents
    /// (ps-corpus text-cmyk: type coverage mixes ink values linearly, 14 levels off with 1.45).
    var textGamma: Float { native == .none ? options.textGamma : 1 }

    /// [B] → [B, B adjusted]: an adjustment layer's result over its backdrop (the top). A filter
    /// that reads around each pixel (a blur) gets its backdrop from a program of its own
    /// (`BackdropFilter`): the ops so far, left with the backdrop alone. When the backdrop is the
    /// only buffer (an adjustment layer on the root stack), those ops are replaced by the program
    /// itself, rendered once over the backdrop area and read for both.
    func adjusted(_ adj: Adjustment) {
        guard let f = adj.asFilter else {
            ops.append(.pick(0))
            ops.append(.adjust(planAdjustment(adj)))
            return
        }
        let spec = FilterSpec(f)
        guard f.samplesNeighbours else {
            ops.append(.pick(0))
            ops.append(.filter(spec))
            return
        }
        let (depth, floors) = RenderPlan.stackState(ops)
        let program = ops + Array(repeating: DrawOp.remove(1), count: max(depth - 1, 0)) + Array(repeating: DrawOp.dropFloor, count: floors)
        if depth == 1 && floors == 0 {
            ops = [.backdropFilter(BackdropFilter(spec: spec, program: program, pushesBackdrop: true))]
        } else {
            ops.append(.backdropFilter(BackdropFilter(spec: spec, program: program, pushesBackdrop: false)))
        }
    }

    /// An adjustment as this plan applies it (CMYK planes: per channel, see `NativeConvert`).
    func planAdjustment(_ a: Adjustment) -> Adjustment {
        switch native {
        case .cmykInk, .cmykBlack: NativeConvert.planeAdjustment(a, native) ?? a
        default: a
        }
    }

    /// `mask_vals` as a MaskSpec (pixel mask with density and feather × vector coverage).
    func maskSpec(_ l: Layer, pixel: Bool = true, vector: Bool = true) -> MaskSpec? {
        var spec: MaskSpec?
        if pixel, let m = l.mask, m.enabled {
            let id = leafID(l, .mask)
            source.register(id, .surface(m.surface))
            spec = MaskSpec(pixel: id, density: m.density, feather: m.feather)
        }
        if vector, let vm = l.vectorMask, vm.enabled {
            let id = vectorLeaf(l, vm)
            var s = spec ?? MaskSpec()
            s.vector = id
            s.vectorFeather = vm.feather
            spec = s
        }
        return spec
    }

    /// `advanced::hiding_mask`: the masks that hide the layer's effects.
    func hidingMask(_ l: Layer) -> MaskSpec? {
        guard LayerGeometry.hidesEffects(l) else { return nil }
        return maskSpec(l, pixel: l.advanced.layerMaskHidesEffects, vector: l.advanced.vectorMaskHidesEffects) ?? MaskSpec()
    }

    func vectorLeaf(_ l: Layer, _ vm: VectorMask) -> LeafID {
        let id = leafID(l, .vectorMask)
        let area = canvas.union(region)
        var fp = Fingerprint()
        fp.mix(hashable: vm)
        fp.mix(area)
        source.register(id, version: fp.value, level: { src, l, _ in
            var scaled = vm
            scaled.path = vm.path.atLevel(l)
            return DerivedLeaves.vectorMask(scaled, area: LevelOfDetail.region(area, level: l), rasterizer: src.rasterizer)
        }) { src in DerivedLeaves.vectorMask(vm, area: area, rasterizer: src.rasterizer) }
        return id
    }

    /// A stroked shape's (fill, vector stroke, masks) leaves (`split_parts`).
    func splitParts(_ l: Layer) -> (fill: LeafID, stroke: LeafID, mask: MaskSpec?)? {
        guard case .shape(let sh) = l.content, sh.stroke != nil else { return nil }
        guard let parts = cache.split(l, sh, canvas: canvas, depth: depth, rasterizer) else {
            source.recordMiss(RasterMiss(layer: l.id, kind: .shapeSplit))
            return nil
        }
        let f = surfaceLeaf(leafID(l, .shapeFill), parts.fill), s = surfaceLeaf(leafID(l, .shapeStroke), parts.stroke)
        return (f, s, maskSpec(l))
    }

    /// Order-independent identity of what a layer's effect shape depends on (`layer_identity`).
    func identity(_ l: Layer) -> UInt64 {
        if let v = identityMemo[l.id] { return v }
        var h = Fingerprint()
        h.mix(l.id.rawValue)
        h.mix(l.fillOpacity)
        switch l.content {
        case .group(let g):
            for c in g.children {
                h.mix(UInt64(c.visible ? 1 : 0) | UInt64(c.clipped ? 2 : 0))
                h.mix(c.opacity)
                h.mix(UInt64(c.blend.rawValue))
                h.mix(hashable: c.blendIf)
                h.mix(UInt64(c.excludedChannels))
                h.mix(identity(c))
            }
            h.mix(hashable: g.artboard)
        case .fill(let f):
            h.mix(hashable: f)
            if let c = l.fillCache, c.fill == f { h.mix(ContentBounds.fingerprint(c.surface)) }
        case .adjustment(let a):
            h.mix(hashable: a)
        case .shape(let sh):
            h.mix(hashable: sh.path)
            h.mix(hashable: sh.fill)
            h.mix(hashable: sh.stroke)
            h.mix(pixels(l).map(ContentBounds.fingerprint) ?? 0)
        default:
            h.mix(pixels(l).map(ContentBounds.fingerprint) ?? 0)
        }
        if let m = l.mask {
            h.mix(ContentBounds.fingerprint(m.surface)); h.mix(UInt64(m.enabled ? 1 : 0)); h.mix(m.density); h.mix(m.feather)
        }
        h.mix(hashable: l.vectorMask)
        h.mix(hashable: l.effects)
        h.mix(hashable: l.advanced)
        identityMemo[l.id] = h.value
        return h.value
    }

    /// Ops emitted by `body` over `area`, returned instead of appended.
    func subProgram(rect area: PixelRect, _ body: () -> Void) -> [DrawOp] {
        let (savedOps, savedRect) = (ops, rect)
        ops = []; rect = area
        body()
        let out = ops
        ops = savedOps; rect = savedRect
        return out
    }

    // MARK: Blends

    func blendMode(_ l: Layer) -> BlendMode { l.blend == .passThrough ? .normal : l.blend }

    func layerBlend(_ l: Layer) -> LayerBlend {
        LayerBlend(blendMode(l), opacity: l.opacity, fill: l.fillOpacity, textGamma: LayerGeometry.textGamma(l, gamma: textGamma))
    }

    // MARK: Root and stacks

    func rootBackdrop() {
        if mode == .multichannel {
            let id = LeafID(layer: 0, role: .background)
            let area = canvas.union(region)
            var fp = Fingerprint()
            fp.mix(area)
            for ch in doc.channels { fp.mix(ContentBounds.fingerprint(ch.surface)); fp.mix(hashable: ch.spot) }
            let (d, r) = (doc, area)
            source.register(id, version: fp.value, level: { _, l, _ in
                var dl = d
                for i in dl.channels.indices { dl.channels[i].surface = TileReduction.surface(d.channels[i].surface, level: l) }
                return DerivedLeaves.inks(dl, LevelOfDetail.region(r, level: l))
            }) { _ in DerivedLeaves.inks(d, r) }
            ops.append(.drawTiles(DrawTiles(leaf: id)))
        } else {
            ops.append(.pushTransparent)
        }
    }

    func root() {
        rootBackdrop()
        var start = doc.layers.startIndex
        if options.pruneOccluded && mode != .lab, let s = doc.layers.lastIndex(where: { LayerGeometry.occludesBelow($0, mode: mode) }) {
            start = s
        }
        stack(doc.layers[start...], scope: .root)
    }

    /// `composite_stack_at`.
    func stack(_ layers: ArraySlice<Layer>, scope: PlanScope) {
        let floor = !scope.root && LayerGeometry.needsFloor(layers)
        if floor { ops.append(.saveFloor) }
        var i = layers.startIndex
        while i < layers.endIndex {
            let base = layers[i]
            var j = i + 1
            if !base.clipped { while j < layers.endIndex && layers[j].clipped { j += 1 } }
            if base.visible {
                let ko = knockoutTarget(base, floorAvailable: floor, scope: scope)
                compositeLayer(base, layers[(i + 1)..<j], ko: ko, scope: scope)
                if case .adjustment = base.content, let q = adjustmentQuantum(depth) { ops.append(.quantize(q)) }
            }
            i = max(j, i + 1)
        }
        if floor { ops.append(.dropFloor) }
    }

    /// `knockout_target`.
    func knockoutTarget(_ l: Layer, floorAvailable: Bool, scope: PlanScope) -> KnockoutTarget? {
        let deep: KnockoutTarget = scope.isolated ? .transparent : .deep
        switch l.advanced.knockout {
        case .none: return nil
        case .shallow: return floorAvailable ? .floor : deep
        case .deep: return deep
        }
    }

    /// Pushes a knockout target (`deep_target`: the document's backdrop with its Background).
    func pushTarget(_ t: KnockoutTarget) {
        switch t {
        case .floor: ops.append(.pushFloor)
        case .transparent: ops.append(.pushTransparent)
        case .deep:
            rootBackdrop()
            if let bg = doc.layers.first, bg.visible, bg.hasBackgroundTraits {
                compositeLayer(bg, [], ko: nil, scope: .root)
            }
        }
    }

    // MARK: Layers

    /// `composite_layer`.
    func compositeLayer(_ l: Layer, _ clipped: ArraySlice<Layer>, ko: KnockoutTarget?, scope: PlanScope) {
        if LayerGeometry.clipsIndividually(l, clipped) {
            clippedIndividually(l, clipped, ko: ko, scope: scope)
            return
        }
        let w = LayerGeometry.channelWeights(l, mode: mode)
        let bi = LayerGeometry.blendIfActive(l, mode: mode)
        let finish = w != nil || bi
        if finish { ops.append(.pick(0)) }
        if let ko {
            knockout(l, clipAlpha: false, target: ko) { self.compositeAny(l, clipped, scope: scope) }
        } else {
            compositeAny(l, clipped, scope: scope)
        }
        if finish { finishLayer(l, w, bi) }
    }

    /// [before, after] → finished (channel restrictions, then Blend If judged on the layer's own
    /// colours, or on the result for adjustment layers).
    func finishLayer(_ l: Layer, _ w: SIMD3<Float>?, _ bi: Bool) {
        var hasOwn = false
        if bi, renderContent(l) {
            ops.append(.swap)
            hasOwn = true
        }
        ops.append(.finishLayer(FinishLayer(channels: w, blendIf: bi ? l.blendIf : nil, hasOwn: hasOwn)))
    }

    /// `advanced::knockout`: [B] → [result]; `draw` composites the layer onto the knocked-out top.
    func knockout(_ l: Layer, clipAlpha: Bool, target: KnockoutTarget, draw: () -> Void) {
        pushTarget(target)
        knockoutShape(l)
        ops.append(.pick(2))
        ops.append(.knockoutBegin(clipAlpha: clipAlpha))
        draw()
        ops.append(.knockoutEnd(opacity: l.opacity))
        ops.append(.remove(1))
    }

    /// `knockout_shape`: the content's alpha with masks; the masks alone with Transparency Shapes
    /// Layer off (and for adjustment layers).
    func knockoutShape(_ l: Layer) {
        if !l.advanced.transparencyShapes || !renderContent(l) { ops.append(.pushMaskShape(maskSpec(l))) }
    }

    func compositeAny(_ l: Layer, _ clipped: ArraySlice<Layer>, scope: PlanScope) {
        if case .group(let g) = l.content, let ab = g.artboard {
            artboard(l, ab, clipped, scope: scope)
        } else {
            plain(l, clipped, scope: scope)
        }
    }

    /// `composite_artboard`: background and contents only inside the board.
    func artboard(_ l: Layer, _ ab: Artboard, _ clipped: ArraySlice<Layer>, scope: PlanScope) {
        if ab.rect.intersect(rect).isEmpty { return }
        ops.append(.pick(0))
        if let bg = ab.background.rgba {
            ops.append(.fill(FillOp(fill: NativeConvert.fill(.solid(PCColor.rgb(bg.x, bg.y, bg.z, bg.w)), native), frame: canvas)))
            ops.append(.composite(LayerBlend(.normal)))
        }
        plain(l, clipped, scope: scope)
        ops.append(.restrictTo(ab.rect))
    }

    /// `composite_layer_plain`.
    func plain(_ l: Layer, _ clipped: ArraySlice<Layer>, scope: PlanScope) {
        if (clipped.isEmpty || LayerGeometry.shapelessStrokeBounds(l, pixels: pixels) == nil) && LayerGeometry.emptyIn(l, rect, pixels: pixels) {
            return
        }
        let opacity = l.opacity * l.fillOpacity
        let hasFx = LayerGeometry.hasEffects(l)
        if case .group(let g) = l.content, l.blend == .passThrough, l.fillOpacity >= 1, !hasFx {
            passThrough(l, g, clipped, opacity: opacity, scope: scope)
            return
        }
        if case .adjustment(let adj) = l.content {
            adjusted(adj)
            compositeClipped(clipped)
            ops.append(.adjustMix(AdjustMix(mode: blendMode(l), opacity: opacity, mask: maskSpec(l), coverage: adj.asFilter?.samplesNeighbours == true)))
            return
        }
        if hasFx {
            let hide = hidingMask(l)
            if hide != nil { ops.append(.pick(0)) }
            layerEffects(LayerGeometry.effectsSource(l), clipped)
            if let hide {
                ops.append(.pushMaskShape(hide))
                ops.append(.mixBy(1))
            }
            return
        }
        if clipped.contains(where: \.visible), let parts = splitParts(l) {
            ops.append(.drawTiles(DrawTiles(leaf: parts.fill)))
            compositeClipped(clipped)
            ops.append(.drawTiles(DrawTiles(leaf: parts.stroke)))
            ops.append(.composite(LayerBlend(.normal)))
            if let m = parts.mask { ops.append(.mask(m)) }
            ops.append(.composite(LayerBlend(blendMode(l), opacity: l.opacity, fill: l.fillOpacity)))
            return
        }
        guard renderContent(l) else { return }
        compositeClipped(clipped)
        ops.append(.composite(layerBlend(l)))
    }

    /// A pass-through group at full fill without effects: children straight into the backdrop.
    func passThrough(_ l: Layer, _ g: LayerGroup, _ clipped: ArraySlice<Layer>, opacity: Float, scope: PlanScope) {
        let needsMix = opacity < 1 || l.mask != nil || l.vectorMask != nil
        let hasClipped = clipped.contains(where: \.visible)
        if hasClipped { ops.append(.pick(0)) }
        if needsMix {
            ops.append(.pushGroup(.passThrough))
            stack(g.children[...], scope: scope.passThrough)
            ops.append(.popGroup(.passThrough(opacity: opacity, mask: maskSpec(l))))
        } else {
            stack(g.children[...], scope: scope.passThrough)
        }
        guard hasClipped else { return }
        // [before, result]: add (before + clipped isolated) − (before + isolated).
        ops.append(.pick(1))
        _ = renderContent(l)
        ops.append(.composite(LayerBlend(.normal, opacity: opacity)))
        ops.append(.pick(2))
        _ = renderContent(l)
        compositeClipped(clipped)
        ops.append(.composite(LayerBlend(.normal, opacity: opacity)))
        ops.append(.swap)
        ops.append(.addDifference)
        ops.append(.remove(1))
    }

    /// `composite_layer_effects`.
    func layerEffects(_ src: Layer, _ clipped: ArraySlice<Layer>) {
        let split = splitParts(src)
        if let split {
            ops.append(.drawTiles(DrawTiles(leaf: split.fill)))
        } else if !renderContent(src) {
            return
        }
        compositeClipped(clipped)
        ops.append(.effect(effectsSpec(src, split: split), atop: false))
    }

    /// The EffectsSpec of `src` (an `effects_source` layer).
    func effectsSpec(_ src: Layer, split: (fill: LeafID, stroke: LeafID, mask: MaskSpec?)?) -> EffectsSpec {
        let m = LayerGeometry.margin(src)
        let region = LayerGeometry.effectSourceBounds(src, canvas: canvas, pixels: pixels).inflated(m).intersect(canvas.inflated(m))
        let bounds = LayerGeometry.paintBounds(src) ?? LayerGeometry.layerBounds(src, canvas: canvas, pixels: pixels)
        var isShape = false
        if case .shape = src.content { isShape = true }
        return EffectsSpec(layerID: src.id.rawValue, effects: NativeConvert.effects(src.effects, native), shape: effectShape(src, region: region),
                           region: region, bounds: bounds,
                           blend: blendMode(src), opacity: src.opacity, fillOpacity: src.fillOpacity,
                           textGamma: LayerGeometry.textGamma(src, gamma: textGamma),
                           vectorShape: isShape, outline: LayerGeometry.effectOutline(src) != nil,
                           shapeless: !src.advanced.transparencyShapes, blendInterior: src.advanced.blendInterior,
                           vectorStroke: split?.stroke, vectorStrokeMask: split?.mask,
                           clip: LayerGeometry.transparentOutside(src, pixels: pixels) ? region : nil)
    }

    /// The leaf of `effect_shape(src, region)`, built on first use by nested CPU plans.
    func effectShape(_ src: Layer, region: PixelRect) -> LeafID {
        let id = leafID(src, .effectShape)
        var fp = Fingerprint()
        fp.mix(identity(src))
        fp.mix(region)
        fp.mix(UInt64(mode.rawValue) << 8 | UInt64(depth.bytes))
        let version = fp.value
        if region.isEmpty {
            source.register(id, version: version) { _ in .image(FloatImage(rect: .empty, channels: 1), outside: .zero, version: version) }
            return id
        }
        @Sendable func image(_ v: [Float]) -> RenderLeaf { .image(FloatImage(rect: region, channels: 1, data: v), outside: .zero, version: version) }
        // At a level: over the level pixels covering the region (the region of the level EffectsSpec).
        @Sendable func image(_ v: [Float], level l: Int) -> RenderLeaf {
            .image(FloatImage(rect: LevelOfDetail.region(region, level: l), channels: 1, data: v), outside: .zero, version: LevelOfDetail.version(version, l))
        }
        if !src.advanced.transparencyShapes {
            let prog: [DrawOp] = [.pushMaskShape(maskSpec(src))]
            source.register(id, version: version, level: { s, l, sampled in image(try s.alpha(of: prog, over: region, level: l, sampled: sampled), level: l) },
                            program: .init(ops: prog, region: region)) { s in
                image(try s.alpha(of: prog, over: region))
            }
            return id
        }
        let content = subProgram(rect: region) { if !self.renderContent(src) { self.ops.append(.pushTransparent) } }
        if let path = LayerGeometry.effectOutline(src) {
            let alphaProg: [DrawOp] = [.drawTiles(DrawTiles(leaf: contentLeaf(src)))]
            let maskProg: [DrawOp]? = maskSpec(src).map { [.pushMaskShape($0)] }
            source.register(id, version: version, level: { s, l, sampled in
                let r = LevelOfDetail.region(region, level: l), p = path.atLevel(l)
                let cov = s.rasterizer.coverage(of: p, in: r).flatMap { $0.count == r.area ? $0 : nil } ?? PathCoverage.coverage(of: p, in: r)
                let a = try s.alpha(of: alphaProg, over: region, level: l, sampled: sampled)
                let mv = try maskProg.map { try s.alpha(of: $0, over: region, level: l, sampled: sampled) }
                return image(DerivedLeaves.outlineShape(alpha: a, coverage: cov, mask: mv, w: r.width, h: r.height), level: l)
            }) { s in
                let cov = s.rasterizer.coverage(of: path, in: region).flatMap { $0.count == region.area ? $0 : nil }
                    ?? PathCoverage.coverage(of: path, in: region)
                let a = try s.alpha(of: alphaProg, over: region)
                let mv = try maskProg.map { try s.alpha(of: $0, over: region) }
                return image(DerivedLeaves.outlineShape(alpha: a, coverage: cov, mask: mv, w: region.width, h: region.height))
            }
            return id
        }
        source.register(id, version: version, level: { s, l, sampled in image(try s.alpha(of: content, over: region, level: l, sampled: sampled), level: l) },
                        program: .init(ops: content, region: region)) { s in
            image(try s.alpha(of: content, over: region))
        }
        return id
    }

    /// `render_content`: pushes the layer's own pixels with its masks; false for adjustments.
    @discardableResult
    func renderContent(_ l: Layer) -> Bool {
        switch l.content {
        case .group(let g):
            ops.append(.pushGroup(.isolated))
            stack(g.children[...], scope: .isolated)
            ops.append(.popGroup(.isolated(mask: maskSpec(l))))
        case .fill(let f):
            fillContent(l, f)
        case .adjustment:
            return false
        default:
            ops.append(.drawTiles(DrawTiles(leaf: contentLeaf(l), mask: maskSpec(l))))
        }
        return true
    }

    /// A fill layer's content: Photoshop's cached pixels while they match, native CMYK fills in
    /// CMYK documents, else the fill rendered in its frame.
    func fillContent(_ l: Layer, _ f: Fill) {
        let mask = maskSpec(l)
        if let c = l.fillCache, c.fill == f {
            ops.append(.drawTiles(DrawTiles(leaf: surfaceLeaf(leafID(l, .fillCache), c.surface), mask: mask)))
            return
        }
        let frame = LayerGeometry.fillFrame(l, canvas: canvas)
        if native != .none {
            // Colours (and the ramp between them) in the document's own model.
            ops.append(.fill(FillOp(fill: NativeConvert.fill(f, native), frame: frame, mask: mask)))
            return
        }
        if mode == .cmyk, !isPattern(f) {
            let id = leafID(l, .other)
            let area = canvas.union(region)
            var fp = Fingerprint()
            fp.mix(hashable: f); fp.mix(frame); fp.mix(area); fp.mix(UInt64(depth.bytes))
            let d = depth
            source.register(id, version: fp.value, level: { _, l, _ in
                DerivedLeaves.cmykFill(f, rect: LevelOfDetail.region(area, level: l), frame: LevelOfDetail.layout(frame, level: l), depth: d)
                    ?? .image(FloatImage(rect: .empty, channels: 4), outside: .zero, version: 0)
            }) { _ in
                DerivedLeaves.cmykFill(f, rect: area, frame: frame, depth: d) ?? .image(FloatImage(rect: .empty, channels: 4), outside: .zero, version: 0)
            }
            ops.append(.drawTiles(DrawTiles(leaf: id, mask: mask)))
            return
        }
        let gray = mode == .grayscale || mode == .duotone || mode == .bitmap
        ops.append(.fill(FillOp(fill: gray ? NativeConvert.grayFill(f) : f, frame: frame, mask: mask)))
    }

    func isPattern(_ f: Fill) -> Bool { if case .pattern = f { return true } else { return false } }

    /// `advanced::composite_clipped`: clipped layers atop the base content (a floor for knockouts).
    func compositeClipped(_ clipped: ArraySlice<Layer>) {
        let vis = clipped.filter(\.visible)
        let floor = vis.contains { $0.advanced.knockout != .none }
        if floor { ops.append(.saveFloor) }
        for c in vis {
            if floor && c.advanced.knockout != .none {
                knockout(c, clipAlpha: true, target: .floor) { self.atop(c) }
            } else {
                atop(c)
            }
        }
        if floor { ops.append(.dropFloor) }
    }

    /// `composite_atop`.
    func atop(_ l: Layer) {
        let w = LayerGeometry.channelWeights(l, mode: mode)
        let bi = LayerGeometry.blendIfActive(l, mode: mode)
        let finish = w != nil || bi
        if finish { ops.append(.pick(0)) }
        atopAny(l)
        if finish { finishLayer(l, w, bi) }
    }

    /// `composite_atop_any`.
    func atopAny(_ l: Layer) {
        if case .adjustment(let adj) = l.content {
            // Clipped, a blur keeps its base's coverage (atop): it never spreads past the base's
            // outline, and its colours come from the base's own pixels.
            adjusted(adj)
            ops.append(.adjustMix(AdjustMix(mode: blendMode(l), opacity: l.opacity * l.fillOpacity, mask: maskSpec(l))))
            return
        }
        if LayerGeometry.hasEffects(l) {
            let hide = hidingMask(l)
            let src = LayerGeometry.effectsSource(l)
            if hide != nil { ops.append(.pick(0)) }
            let split = splitParts(src)
            if let split {
                ops.append(.drawTiles(DrawTiles(leaf: split.fill)))
            } else if !renderContent(src) {
                if hide != nil { ops.append(.drop) }
                return
            }
            ops.append(.effect(effectsSpec(src, split: split), atop: true))
            if let hide {
                ops.append(.pushMaskShape(hide))
                ops.append(.mixBy(1))
            }
            return
        }
        guard renderContent(l) else { return }
        ops.append(.clipped(layerBlend(l)))
    }

    /// `advanced::composite_clipped_individually`: Blend Clipped Layers as Group off.
    func clippedIndividually(_ l: Layer, _ clipped: ArraySlice<Layer>, ko: KnockoutTarget?, scope: PlanScope) {
        let vis = clipped.filter(\.visible)
        let floor = vis.contains { $0.advanced.knockout == .shallow }
        if floor { ops.append(.saveFloor) }
        compositeLayer(l, [], ko: ko, scope: scope)
        let op = min(max(l.opacity, 0), 1)
        for c in vis {
            ops.append(.pick(0))
            let t = knockoutTarget(c, floorAvailable: floor, scope: PlanScope(root: false, isolated: scope.isolated))
            compositeLayer(c, [], ko: t, scope: scope)
            if !renderContent(l) { ops.append(.pushMaskShape(maskSpec(l))) }
            ops.append(.mixBy(op))
        }
        if floor { ops.append(.dropFloor) }
    }
}
