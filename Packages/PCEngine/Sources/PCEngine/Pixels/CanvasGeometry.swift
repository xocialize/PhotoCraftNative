// Port of photocraft-engine (crates/engine/src/canvas_geom.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Canvas-wide geometry: Image Rotation (90°, 180°, flips), Canvas Size, Crop and Trim move
// everything in the document, not only pixels. Pixels are remapped by the callers; this moves the
// rest: type, shape and smart-object transforms, vector masks, gradient fill angles, effect
// reference points, artboards, and document-level paths, guides, slices, notes and measurement
// marks. Layer effect angles are left alone (Photoshop keeps the Global Light when the canvas
// rotates).

import Foundation
import PCDocument
import PCFoundation
import PCPlatform

public enum CanvasGeometry {
    static let eps = 1e-9

    static func mapPoint(_ a: PCAffine, _ p: SIMD2<Double>) -> SIMD2<Double> { a.apply(p) }

    /// Bounding box `[x0, y0, x1, y1]` of the mapped corners.
    static func mapBox(_ a: PCAffine, _ b: SIMD4<Double>) -> SIMD4<Double> {
        let c = [SIMD2(b.x, b.y), SIMD2(b.z, b.y), SIMD2(b.z, b.w), SIMD2(b.x, b.w)].map { a.apply($0) }
        return SIMD4(c.map(\.x).min()!, c.map(\.y).min()!, c.map(\.x).max()!, c.map(\.y).max()!)
    }

    public static func mapRect(_ a: PCAffine, _ r: PixelRect) -> PixelRect {
        if r.isEmpty { return r }
        let b = mapBox(a, SIMD4(Double(r.x0), Double(r.y0), Double(r.x1), Double(r.y1)))
        func i(_ v: Double) -> Int32 { Int32(min(max(v.rounded(), Double(Int32.min / 2)), Double(Int32.max / 2))) }
        return PixelRect(x0: i(b.x), y0: i(b.y), x1: i(b.z), y1: i(b.w))
    }

    /// A gradient angle (degrees, counter-clockwise on screen) carried through `a`'s linear part.
    static func mapAngle(_ a: PCAffine, _ deg: Float) -> Float {
        let r = Double(deg) * .pi / 180
        let (dx, dy) = (cos(r), -sin(r))
        let (nx, ny) = (a.a * dx + a.c * dy, a.b * dx + a.d * dy)
        if abs(nx) < eps && abs(ny) < eps { return deg }
        var out = atan2(-ny, nx) * 180 / .pi
        if abs(out - out.rounded()) < 1e-6 { out = out.rounded() }
        return Float(out <= -180 ? out + 360 : out)
    }

    static func mapFill(_ a: PCAffine, _ f: inout Fill) {
        guard case .gradient(var g) = f else { return }
        g.angle = mapAngle(a, g.angle)
        let (ox, oy) = (Double(g.offset.x), Double(g.offset.y))
        g.offset = SIMD2(Float(a.a * ox + a.c * oy), Float(a.b * ox + a.d * oy))
        f = .gradient(g)
    }

    /// Applies `a` to one layer's (and its children's) non-pixel geometry. With `content` false only
    /// the parts Free Transform doesn't move are touched: unlinked vector masks, gradient angles,
    /// effect reference points and artboards.
    public static func transformLayerGeometry(_ l: inout Layer, _ a: PCAffine, content: Bool) {
        if var vm = l.vectorMask, content || !vm.linked {
            vm.path = vm.path.transform(a)
            l.vectorMask = vm
        }
        if let r = l.effects.reference { l.effects.reference = a.apply(r) }
        if !content {
            l.fillCache = nil
        } else if var fc = l.fillCache {
            mapFill(a, &fc.fill)
            l.fillCache = fc
        }
        switch l.content {
        case .fill(var f):
            mapFill(a, &f)
            l.content = .fill(f)
        case .shape:
            l.withShape { sh in
                if var f = sh.fill { mapFill(a, &f); sh.fill = f }
                if content { transformShape(&sh, a) }
            }
        case .text where content:
            l.withText { t in
                t.transform = a.mul(t.transform)
                // photocraft rebuilds the PSD TySh block here; PCIO regenerates it from the model.
                t.psdRaw = nil
            }
        case .smart where content:
            l.withSmartObject { sm in transformPlacement(&sm, a) }
        case .group:
            l.withGroup { g in
                if var ab = g.artboard { ab.rect = mapRect(a, ab.rect); g.artboard = ab }
                for i in g.children.indices { transformLayerGeometry(&g.children[i], a, content: content) }
            }
        default:
            break
        }
    }

    /// A shape's outline through `a` (photocraft `vector_cmds::transform_shape`): live shapes
    /// follow axis-aligned maps and are dropped otherwise.
    public static func transformShape(_ sh: inout ShapeLayer, _ a: PCAffine) { VectorCommands.transformShape(&sh, a) }

    /// A smart object's placement through `a` (photocraft `smart_cmds::transform_placement`).
    public static func transformPlacement(_ sm: inout SmartObject, _ a: PCAffine) {
        sm.transform = a.mul(sm.transform)
        if let m = sm.perspective, m.count == 9 {
            // Prepend the affine to the projective map: P' = A · P.
            let am = [a.a, a.c, a.e, a.b, a.d, a.f, 0, 0, 1]
            var out = [Double](repeating: 0, count: 9)
            for r in 0..<3 { for c in 0..<3 { out[r * 3 + c] = (0..<3).reduce(0) { $0 + am[r * 3 + $1] * m[$1 * 3 + c] } } }
            sm.perspective = out
        }
        sm.psdRaw = nil
    }

    /// Document-level geometry: paths, notes, Count/Ruler marks, slices and guides. Guides survive
    /// axis-aligned maps (and swap orientation under 90° turns); any other map clears them.
    public static func transformDocMarks(_ doc: inout Document, _ a: PCAffine) {
        for i in doc.paths.indices { doc.paths[i].path = doc.paths[i].path.transform(a) }
        if let wp = doc.workPath { doc.workPath = wp.transform(a) }
        for i in doc.notes.indices {
            doc.notes[i].position = a.apply(doc.notes[i].position)
            doc.notes[i].popup = mapBox(a, doc.notes[i].popup)
        }
        for g in doc.measurement.countGroups.indices {
            for p in doc.measurement.countGroups[g].points.indices {
                doc.measurement.countGroups[g].points[p] = a.apply(doc.measurement.countGroups[g].points[p])
            }
        }
        if var r = doc.measurement.ruler {
            r.start = a.apply(r.start)
            r.end = a.apply(r.end)
            if let p = r.protractor { r.protractor = a.apply(p) }
            doc.measurement.ruler = r
        }
        for i in doc.slices.list.indices { doc.slices.list[i].rect = mapRect(a, doc.slices.list[i].rect) }
        var g = doc.guides
        if abs(a.b) < eps && abs(a.c) < eps {
            g.horizontal = g.horizontal.map { a.d * $0 + a.f }
            g.vertical = g.vertical.map { a.a * $0 + a.e }
        } else if abs(a.a) < eps && abs(a.d) < eps {
            let v = g.horizontal.map { a.c * $0 + a.e }
            let h = g.vertical.map { a.b * $0 + a.f }
            g.horizontal = h
            g.vertical = v
        } else {
            g.horizontal.removeAll()
            g.vertical.removeAll()
        }
        g.pruneColors()
        doc.guides = g
    }

    /// Applies `a` to all non-pixel geometry of the document (layers and document marks).
    public static func transformGeometry(_ doc: inout Document, _ a: PCAffine) {
        for i in doc.layers.indices {
            var l = doc.layers[i]
            transformLayerGeometry(&l, a, content: true)
            doc.updateLayer(at: [i]) { $0 = l }
        }
        transformDocMarks(&doc, a)
    }

    /// What to re-render after the geometry moved.
    public enum Refresh { case shapes, all }

    /// Re-renders shape (and with `.all`, type) caches from their models.
    public static func refresh(_ doc: inout Document, _ what: Refresh) {
        let fmt = doc.pixelFormat, clip = doc.bounds, dpi = Double(doc.resolutionDpi)
        doc.forEachLayerMut { l in
            switch l.content {
            case .shape:
                l.withShape { sh in if sh.cache != nil { VectorRasterizer.renderCache(&sh, format: fmt, clip: clip) } }
            case .text where what == .all:
                l.withText { t in if t.cache != nil { TextEngine.renderLayer(&t, dpi: dpi, format: fmt) } }
            default:
                break
            }
        }
    }

    /// Image › Image Rotation by a right angle or a flip.
    public enum Turn: Sendable {
        case flipHorizontal, flipVertical, rotate180, cw90, ccw90

        /// Pixel map for a `w × h` canvas.
        public func pixelMap(_ w: Int32, _ h: Int32) -> (Int32, Int32) -> (Int32, Int32) {
            switch self {
            case .flipHorizontal: { x, y in (w - 1 - x, y) }
            case .flipVertical: { x, y in (x, h - 1 - y) }
            case .rotate180: { x, y in (w - 1 - x, h - 1 - y) }
            case .cw90: { x, y in (h - 1 - y, x) }
            case .ccw90: { x, y in (y, w - 1 - x) }
            }
        }

        /// The same map in continuous (pixel-edge) coordinates.
        public func affine(_ w: Double, _ h: Double) -> PCAffine {
            switch self {
            case .flipHorizontal: PCAffine(a: -1, b: 0, c: 0, d: 1, e: w, f: 0)
            case .flipVertical: PCAffine(a: 1, b: 0, c: 0, d: -1, e: 0, f: h)
            case .rotate180: PCAffine(a: -1, b: 0, c: 0, d: -1, e: w, f: h)
            case .cw90: PCAffine(a: 0, b: 1, c: -1, d: 0, e: h, f: 0)
            case .ccw90: PCAffine(a: 0, b: -1, c: 1, d: 0, e: 0, f: w)
            }
        }

        var swaps: Bool { self == .cw90 || self == .ccw90 }
    }

    /// Every pixel surface a canvas turn moves: content, rendered caches, masks, channels, Quick
    /// Mask and the selection.
    public static func remapPixels(_ doc: inout Document, _ map: (Int32, Int32) -> (Int32, Int32)) {
        func re(_ s: inout Surface) { s = Pixels.remapSurface(s, map) }
        func rec(_ l: inout Layer) {
            if var m = l.mask { re(&m.surface); l.mask = m }
            if var fc = l.fillCache { re(&fc.surface); l.fillCache = fc }
            switch l.content {
            case .raster: l.withRaster { re(&$0) }
            case .text: l.withText { t in if var c = t.cache { re(&c); t.cache = c } }
            case .shape: l.withShape { sh in if var c = sh.cache { re(&c); sh.cache = c } }
            case .smart:
                l.withSmartObject { sm in
                    if var c = sm.cache { re(&c); sm.cache = c }
                    if var m = sm.filterMask { re(&m.surface); sm.filterMask = m }
                }
            case .group: l.withChildren { for i in $0.indices { rec(&$0[i]) } }
            default: break
            }
        }
        for i in doc.layers.indices { doc.updateLayer(at: [i]) { rec(&$0) } }
        for i in doc.channels.indices { re(&doc.channels[i].surface) }
        if var q = doc.quickMask { re(&q.surface); doc.quickMask = q }
        if var s = doc.selection { re(&s); doc.selection = s }
    }

    /// Turns or flips the whole canvas: pixels remapped exactly, vectors through the affine map.
    public static func turnCanvas(_ doc: inout Document, _ turn: Turn) {
        let (w, h) = (Int32(clamping: doc.size.width), Int32(clamping: doc.size.height))
        remapPixels(&doc, turn.pixelMap(w, h))
        let a = turn.affine(Double(doc.size.width), Double(doc.size.height))
        if turn.swaps { doc.size = PixelSize(width: doc.size.height, height: doc.size.width) }
        transformGeometry(&doc, a)
    }
}
