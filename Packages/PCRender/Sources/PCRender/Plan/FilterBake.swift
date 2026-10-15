// Filter adjustment layers baked to pixels (AB-D-0143), for containers with no live form of them
// (PSD/PSB). New; no photocraft counterpart.
//
// A filter layer's pixels are the filter applied to its backdrop: what lies beneath it as this
// compositor evaluates the layer (its group, pass-through or isolated, and its clipping base). The
// planner runs up to the layer and keeps the ops so far, left with the backdrop alone: the program a
// blur already reads its backdrop from. The filter is applied to that.
//
// The pixels are written so that compositing them as a pixel layer, with the adjustment's own mask,
// opacity, blend mode and clipping, gives what the live layer gives (`Compose.adjustMix`):
// * a blur in Normal, unclipped, mixes premultiplied colour and coverage, so the pixels are the
//   filtered backdrop, coverage and all;
// * every other unclipped layer blends colours and keeps the backdrop's coverage, so the pixels are
//   the filtered colours with the backdrop's coverage (exact where the backdrop is opaque or clear);
// * clipped, the layer blends atop its base and keeps the base's coverage, so the pixels are the
//   filtered colours at full coverage wherever the base has any (exact).
// A pixel layer can only add coverage. Where a live blur in Normal thins it (at the canvas edge,
// past which the backdrop counts as clear, and inside the edge of translucent content), the
// pixels composite over a backdrop the live layer would have thinned.

import Foundation
import PCDocument
import PCFoundation
import simd

public enum FilterBake {
    /// What the planner found at the layer being baked.
    struct Probe {
        /// The ops so far, leaving the layer's backdrop alone on the stack.
        var backdrop: [DrawOp]
        var filter: FilterAdjustment
        /// The live layer mixes premultiplied colour and coverage (a blur in Normal, unclipped).
        var coverage: Bool
        /// The live layer blends atop its clipping base.
        var atop: Bool

        /// The baked pixels: the backdrop filtered, then mixed in at full strength in Normal, which
        /// gives the filtered colours with the coverage the live mix keeps (the filtered one when
        /// `coverage`, else the backdrop's).
        var ops: [DrawOp] {
            let spec = FilterSpec(filter)
            let mix = DrawOp.adjustMix(AdjustMix(mode: .normal, opacity: 1, coverage: coverage))
            guard filter.samplesNeighbours else { return backdrop + [.pick(0), .filter(spec), mix] }
            return [.backdropFilter(BackdropFilter(spec: spec, program: backdrop, pushesBackdrop: true)), mix]
        }
    }

    /// `doc` cut down to what the layer's backdrop needs: nothing above the layer in any stack around
    /// it. The layer, the groups around it and, when clipped, its base are shown: a hidden filter
    /// layer is baked too, for when it is turned on.
    static func probeDocument(_ doc: Document, _ id: LayerId) -> Document? {
        guard let path = doc.path(of: id), !path.isEmpty else { return nil }
        var d = doc
        func cut(_ layers: inout [Layer], _ level: Int) {
            let i = path[level]
            layers.removeSubrange((i + 1)...)
            layers[i].visible = true
            if level + 1 < path.count {
                _ = layers[i].withChildren { cut(&$0, level + 1) }
            } else if layers[i].clipped, let base = layers[..<i].lastIndex(where: { !$0.clipped }) {
                layers[base].visible = true
            }
        }
        cut(&d.layers, 0)
        return d
    }

    /// Where a filter layer can show: the canvas, within the extent of its enabled masks (their
    /// feathers included). Its pixels can't reach the composite anywhere else.
    public static func bounds(_ l: Layer, canvas: PixelRect) -> PixelRect {
        var r = canvas
        if let m = l.mask, m.enabled, m.density >= 1, (m.surface.defaultPixelValue.first ?? 1) <= 0 {
            r = r.intersect(ContentBounds.of(m.surface).inflated(featherReach(m.feather)))
        }
        if let vm = l.vectorMask, vm.enabled, vm.density >= 1, !vm.path.inverted, let b = vm.path.controlBounds {
            let pr = PixelRect(x0: Int32(clamping: Int64(b.x.rounded(.down))), y0: Int32(clamping: Int64(b.y.rounded(.down))),
                               x1: Int32(clamping: Int64(b.z.rounded(.up))), y1: Int32(clamping: Int64(b.w.rounded(.up))))
            r = r.intersect(pr.inflated(featherReach(vm.feather)))
        }
        return r
    }

    /// Every pixel with any coverage made opaque.
    static func fullCoverage(_ b: inout RGBABuffer) {
        for i in b.px.indices where b.px[i].w > 0 { b.px[i].w = 1 }
    }

    /// How far a mask feather spreads a mask's edge (a Gaussian of sigma = feather, or three box
    /// passes approximating it), with room to spare.
    static func featherReach(_ feather: Float) -> Int32 {
        let s = MaskSpec.featherSigma(feather)
        return s > 0 ? Int32((4 * s).rounded(.up)) + 2 : 0
    }
}

extension DocumentPlanner {
    /// The plan of the baked pixels of filter layer `layer` over `region` (clear where the planner
    /// doesn't reach it: its masks hide it there), in the space `document` composites in, and
    /// whether the layer blends atop a clipping base.
    static func buildFilterBake(document: Document, layer: LayerId, region: PixelRect, rasterizer: any LayerRasterizer,
                                cache: DocumentLeafCache, subRenderer: CPUCompositor, options: PlanOptions) -> (plan: DocumentPlan, atop: Bool)? {
        var doc = document
        if let comp = options.comp { doc = applying(comp, to: doc) }
        guard let cut = FilterBake.probeDocument(doc, layer) else { return nil }
        // The live document's space: what lies above the layer can decide it (CMYK planes).
        let r = build(cut, region: region, space: nativeSpace(doc, options), bake: layer, rasterizer: rasterizer, cache: cache,
                      subRenderer: subRenderer, options: options)
        return (r.plan, r.probe?.atop ?? false)
    }
}

extension DocumentCompositor {
    /// A filter adjustment layer baked to pixels (AB-D-0143, `FilterBake`): the pixel layer a
    /// container with no live filter layers (PSD/PSB) stores in its place, in `doc.pixelFormat`,
    /// rendered band by band over the canvas within the layer's masks and clear elsewhere. nil when
    /// `layer` isn't a filter adjustment layer of `doc`.
    public func bakeFilterLayer(_ doc: Document, layer id: LayerId) throws -> Surface? {
        guard let l = doc.layer(id), case .adjustment(let a) = l.content, a.asFilter != nil else { return nil }
        let format = doc.pixelFormat
        var s = Surface(format: format)
        let area = FilterBake.bounds(l, canvas: doc.bounds)
        if area.isEmpty { return s }
        let empty = s.defaultPixelValue
        let n = format.channels
        // A Lab or CMYK result is written in its own model, as `compositeToSurface` writes one.
        let native = DocumentPlanner.nativeSpace(doc, options).mode == format.mode
        let rows = DocumentCompositor.bandRows(width: area.width, requested: 0)
        var y = area.y0
        while y < area.y1 {
            let band = PixelRect(x0: area.x0, y0: y, x1: area.x1, y1: Int32(clamping: min(Int64(y) + Int64(rows), Int64(area.y1))))
            guard let (p, atop) = DocumentPlanner.buildFilterBake(document: doc, layer: id, region: band, rasterizer: rasterizer, cache: cache,
                                                                   subRenderer: cpu, options: options) else { return nil }
            var res = try runNative(p, backend: backend)
            if atop {
                // Atop its base the layer keeps the base's coverage: full wherever the base has any.
                FilterBake.fullCoverage(&res.buffer)
                if var k = res.black {
                    FilterBake.fullCoverage(&k)
                    res.black = k
                }
            }
            var data = [Float](repeating: 0, count: band.area * n)
            if native {
                let inks = res.native == .lab ? [] : NativeConvert.inks(res.buffer, res.black ?? res.buffer, paper: false)
                for i in 0..<band.area {
                    let q = res.buffer.px[i]
                    let v: [Float]
                    if format.alpha && (q.w <= 0 || q.w.isNaN) && empty.count == n {
                        v = empty
                    } else if res.native == .lab {
                        v = [q.x, q.y, q.z] + (format.alpha ? [q.w] : [])
                    } else {
                        let c = simd_clamp(inks[i], .zero, SIMD4(repeating: 1))
                        v = [c.x, c.y, c.z, c.w] + (format.alpha ? [q.w] : [])
                    }
                    for k in 0..<n { data[i * n + k] = v[k] }
                }
            } else if format.mode == .rgb && n == 4 && empty.count == 4 {
                // Straight RGBA as it is: no per-pixel conversion.
                let px = try display(res, p).px
                let e = SIMD4(empty[0], empty[1], empty[2], empty[3])
                data.withUnsafeMutableBufferPointer { out in
                    out.baseAddress!.withMemoryRebound(to: SIMD4<Float>.self, capacity: px.count) { o in
                        for i in px.indices { o[i] = px[i].w > 0 ? px[i] : e }
                    }
                }
            } else {
                for (i, q) in try display(res, p).px.enumerated() {
                    let v = format.alpha && (q.w <= 0 || q.w.isNaN) && empty.count == n ? empty : format.components(fromRGBA: q)
                    for k in 0..<n { data[i * n + k] = v[k] }
                }
            }
            s.writeRegion(band, data)
            y = band.y1
        }
        s.prune()
        return s
    }
}
