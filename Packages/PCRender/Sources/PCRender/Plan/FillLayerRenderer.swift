// Port of photocraft-compose (crates/compose/src/lib.rs `render_fill_content`, gradient_fill.rs `render_cmyk_fill`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// A fill layer's pixels as a PSD stores them: the fill laid out in the frame its masks give it,
// as the compositor lays it out, but without applying the masks, rounded to the format's depth.
// CMYK and Lab formats get the colours, the ramp between them and patterns in their own model
// (the planes of `NativeSpace`), so the pixels match what the compositor draws in those documents;
// grey modes get each colour's grey; every other mode goes through display RGB and
// `Surface.writeRGBA`. PCIO writes fill layers
// with it when the file carries no cached rendering.

import Foundation
import PCDocument
import PCFoundation

public enum FillLayerRenderer {
    /// `fill` (normally the layer's own) over `canvas` in `format` for `layer`'s frame, with the
    /// document's `patterns`. Pattern fills whose pattern is missing come out transparent.
    public static func render(_ layer: Layer, fill: Fill, canvas: PixelRect, patterns: [Pattern], format: PixelFormat) -> Surface {
        var out = Surface(format: format)
        if canvas.isEmpty { return out }
        let frame = LayerGeometry.fillFrame(layer, canvas: canvas)
        let store: Float? = format.sample == .f32 ? nil : (format.sample == .u8 ? 255 : 65535)
        let quantum = adjustmentQuantum(format.sample)
        let cache = DocumentLeafCache()
        func source(_ space: NativeSpace) -> LeafTable {
            LeafTable(patterns: patterns.compactMap { cache.pattern($0, mode: format.mode, native: space) })
        }
        func plane(_ space: NativeSpace) -> RGBABuffer {
            FillRender.render(NativeConvert.fill(fill, space), rect: canvas, frame: frame, quantum: quantum, store: store, source: source(space))
        }
        let n = canvas.area
        let ch = format.channels
        switch format.mode {
        case .cmyk:
            let ink = plane(.cmykInk), black = plane(.cmykBlack)
            var data = [Float](repeating: 0, count: n * ch)
            for i in 0..<n {
                let a = ink.px[i], k = black.px[i]
                let v: [Float] = [1 - a.x, 1 - a.y, 1 - a.z, 1 - k.x]
                for c in 0..<min(4, ch) { data[i * ch + c] = v[c] }
                if format.alpha { data[i * ch + ch - 1] = a.w }
            }
            out.writeRegion(canvas, data)
        case .lab:
            let lab = plane(.lab)
            var data = [Float](repeating: 0, count: n * ch)
            for i in 0..<n {
                let p = lab.px[i]
                for c in 0..<min(3, ch) { data[i * ch + c] = p[c] }
                if format.alpha { data[i * ch + ch - 1] = p.w }
            }
            out.writeRegion(canvas, data)
        case .grayscale, .duotone, .bitmap:
            // The grey the compositor draws (`NativeConvert.grayFill`), stored as is.
            let g = FillRender.render(NativeConvert.grayFill(fill), rect: canvas, frame: frame, quantum: quantum, store: store, source: source(.none))
            out.writeRGBA(canvas, g.px)
        default:
            out.writeRGBA(canvas, plane(.none).px)
        }
        return out
    }
}
