// Port of photocraft-engine (crates/engine/src/mode_cmds.rs: Image Rotation › Arbitrary), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Image Rotation › Arbitrary: the canvas grows to fit, every layer turns (locked ones too, inside
// groups), the Background stays a Background over the background colour, masks, channels and the
// selection turn with the pixels, type / shapes / smart objects keep vector transforms. Layers,
// masks and channels go through Free Transform's `transform_layer` / `warp_gray`
// (TransformCommands), as in photocraft.

import Foundation
import PCAlgo
import PCDocument
import PCFoundation

extension ModeCommands {
    /// Canvas size after rotating `size` by `deg` (the canvas grows to fit, as in Photoshop)
    /// (photocraft `rotated_size`).
    public static func rotatedSize(_ size: PixelSize, _ deg: Double) -> PixelSize {
        let rad = deg * (Double.pi / 180)
        let (s, c) = (sin(rad), cos(rad))
        let (w, h) = (Double(size.width), Double(size.height))
        let nw = max((w * abs(c) + h * abs(s) - 1e-6).rounded(.up), 1)
        let nh = max((w * abs(s) + h * abs(c) - 1e-6).rounded(.up), 1)
        return PixelSize(width: Int(min(nw, Double(Int32.max))), height: Int(min(nh, Double(Int32.max))))
    }

    /// The clockwise (on screen, y down) turn by `deg` about the old canvas centre, landing on the
    /// new canvas centre: x' = c·x − s·y, y' = s·x + c·y.
    static func rotation(_ old: PixelSize, _ new: PixelSize, _ deg: Double) -> PCAffine {
        let rad = deg * (Double.pi / 180)
        let (sn, cs) = (sin(rad), cos(rad))
        let (cx, cy) = (Double(old.width) / 2, Double(old.height) / 2)
        let (nx, ny) = (Double(new.width) / 2, Double(new.height) / 2)
        return PCAffine(a: cs, b: sn, c: -sn, d: cs, e: nx - (cs * cx - sn * cy), f: ny - (sn * cx + cs * cy))
    }

    /// Image › Image Rotation › Arbitrary (photocraft `rotate_arbitrary`).
    static func rotateArbitrary(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.rotation.arbitrary"
        // photocraft reads the angle as f32.
        let angle = Double(Float(p["angle"]?.doubleValue ?? 0))
        if !angle.isFinite || abs(angle) > 3600 { throw bad(cmd, "angle out of range") }
        let deg: Double
        switch p["direction"]?.stringValue ?? "cw" {
        case "cw": deg = angle
        case "ccw": deg = -angle
        case let d: throw bad(cmd, "direction `\(d)` (cw|ccw)")
        }
        var turn = deg.truncatingRemainder(dividingBy: 360)
        if turn < 0 { turn += 360 }
        if abs(turn) < 1e-9 {
            return ["width": s.active.map { .int($0.doc.size.width) } ?? .null, "height": s.active.map { .int($0.doc.size.height) } ?? .null]
        }
        let bg = s.tools.background
        // Color Sampler points turn with the canvas (the same map the edit applies to the geometry).
        guard let old = s.active?.doc.size else { throw EngineError.noDocument }
        SamplerMap.set(s, rotation(old, rotatedSize(old, deg), deg))
        let interp = Interp(parsing: p["interpolation"]?.stringValue ?? "bicubic")
        let size = try s.edit("Rotate Canvas") { doc, _ -> PixelSize in
            let old = doc.size
            let new = rotatedSize(old, deg)
            let a = rotation(old, new, deg)
            let h = Homography([a.a, a.c, a.e, a.b, a.d, a.f, 0, 0, 1])
            doc.size = new
            let canvas = doc.bounds
            let fmt = doc.pixelFormat
            let backgroundId = doc.background?.id
            for i in doc.layers.indices {
                try doc.updateLayer(at: [i]) { l in
                    if l.id == backgroundId, case .raster = l.content {
                        // The Background stays a Background: rotated pixels over the background colour.
                        l.withRaster { surf in
                            let rotated = Transform.warpSurface(surf, srcRect: surf.contentBounds, h: h, interp: interp)
                            var base = Surface(format: fmt)
                            base.fill(canvas, with: fmt.components(fromRGBA: bg))
                            FloatCommands.compositeOver(&base, rotated)
                            base.prune()
                            surf = base
                        }
                        if var m = l.mask {
                            m.surface = TransformCommands.warpGray(m.surface, h, interp)
                            l.mask = m
                        }
                    } else {
                        // Rotating the whole image moves locked layers too, including inside groups.
                        try withReleasedMovementLocks(&l) { try TransformCommands.transformLayer(nil, Locks(), &$0, h, a, interp) }
                    }
                    // What Free Transform leaves alone: unlinked vector masks, gradient angles, artboards…
                    CanvasGeometry.transformLayerGeometry(&l, a, content: false)
                }
            }
            CanvasGeometry.transformDocMarks(&doc, a)
            for i in doc.channels.indices { doc.channels[i].surface = TransformCommands.warpGray(doc.channels[i].surface, h, interp) }
            if var q = doc.quickMask {
                q.surface = TransformCommands.warpGray(q.surface, h, interp)
                doc.quickMask = q
            }
            if let sel = doc.selection {
                let w = TransformCommands.warpGray(sel, h, .bilinear)
                doc.selection = w.contentBounds.isEmpty ? nil : w
            }
            // Type, shapes and smart objects re-render from their new geometry.
            CanvasGeometry.refresh(&doc, .all)
            doc.guides = Guides()
            return new
        }
        return ["width": .int(size.width), "height": .int(size.height)]
    }

    /// Runs `f` with movement locks (`position` and `all`) temporarily released on `l` and all its
    /// descendants, so canvas-wide rotation moves every layer, then restores each lock (photocraft
    /// `with_released_movement_locks`).
    static func withReleasedMovementLocks<R>(_ l: inout Layer, _ f: (inout Layer) throws -> R) rethrows -> R {
        var saved: [Locks] = []
        func release(_ x: inout Layer) {
            saved.append(x.locks)
            x.locks.position = false
            x.locks.all = false
            x.withChildren { for i in $0.indices { release(&$0[i]) } }
        }
        var k = 0
        func restore(_ x: inout Layer) {
            if k < saved.count { x.locks = saved[k] }
            k += 1
            x.withChildren { for i in $0.indices { restore(&$0[i]) } }
        }
        release(&l)
        defer { restore(&l) }
        return try f(&l)
    }
}
