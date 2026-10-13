// Port of photocraft-paint (crates/paint/src/render.rs; docs/architecture.md §4.3 and §6), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The canvas-facing stroke: a tool feeds coalesced PointerEvents (architecture §4.3) and gets back
// the damage of each batch — the layer's live pixels are published tile by tile as they change —
// and, on pointer-up, one `StrokeTransaction` for the whole stroke (architecture §6: one
// transaction per stroke; before/after tiles share storage with the layer, so undo is a tile swap).
// The CPU reference and the Metal renderer give identical pixels; `.auto` picks Metal when there
// is a device. Symmetry passes are merged under one opacity ceiling (`compositeUnionLive` on the
// CPU, the multi-pass composite kernel on the GPU).

import Foundation
import PCFoundation

/// One pointer sample from the platform layer (photocraft-tools `PointerEvent`).
public struct PointerEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case mouse, pen, eraser, touch }

    public struct Buttons: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let primary = Buttons(rawValue: 1)
        public static let secondary = Buttons(rawValue: 2)
        public static let middle = Buttons(rawValue: 4)
        public static let barrel = Buttons(rawValue: 8)
    }

    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// Document position.
    public var position: PaintPoint
    /// 0…1 (mice report 1).
    public var pressure: Float
    /// Pen tilt in degrees, W3C `tiltX`/`tiltY` (−90…90).
    public var tilt: SIMD2<Float>
    /// Barrel rotation (twist) in degrees, 0…360.
    public var twist: Float
    /// Timestamp in microseconds (any epoch; only differences matter).
    public var timeUs: UInt64
    public var buttons: Buttons
    public var mods: Modifiers
    public var kind: Kind
    /// Airbrush wheel 0…1.
    public var wheel: Float

    public init(position: PaintPoint, pressure: Float = 1, tilt: SIMD2<Float> = .zero, twist: Float = 0, timeUs: UInt64 = 0,
                buttons: Buttons = .primary, mods: Modifiers = [], kind: Kind = .mouse, wheel: Float = 1) {
        self.position = position; self.pressure = pressure; self.tilt = tilt; self.twist = twist; self.timeUs = timeUs
        self.buttons = buttons; self.mods = mods; self.kind = kind; self.wheel = wheel
    }

    /// The brush engine's sample, with time in milliseconds since `originUs`.
    public func strokePoint(originUs: UInt64) -> StrokePoint {
        let dt = timeUs >= originUs ? Double(timeUs - originUs) : -Double(originUs - timeUs)
        let mouse = kind == .mouse
        return StrokePoint(x: position.x, y: position.y, pressure: mouse ? 1 : pressure, tiltX: mouse ? 0 : tilt.x, tiltY: mouse ? 0 : tilt.y,
                           rotation: mouse ? 0 : twist, wheel: wheel, time: dt / 1000)
    }
}

/// What one batch changed: the damaged rectangle and the 256² layer tiles to re-upload.
public struct StrokeUpdate: Sendable {
    public var damage: PixelRect
    public var tiles: [TileCoord]
    /// Primary dabs placed so far in the stroke.
    public var dabCount: Int
}

/// The whole stroke as one undoable step: every layer tile it changed, before and after.
public struct StrokeTransaction: Sendable {
    public var label: String
    public var bounds: PixelRect
    /// Tiles before the stroke (nil: the tile did not exist).
    public var before: [(TileCoord, Tile?)]
    public var after: [(TileCoord, Tile?)]

    public func undo(_ s: inout Surface) { apply(before, &s) }
    public func redo(_ s: inout Surface) { apply(after, &s) }

    func apply(_ tiles: [(TileCoord, Tile?)], _ s: inout Surface) {
        for (c, t) in tiles {
            if let t { s.putTiles([(c, t)]) } else { _ = s.takeTiles(c.rect) }
        }
    }
}

public enum PaintBackend: Sendable { case cpu, metal, auto }

/// An interactive brush stroke on one layer.
public final class PaintStroke {
    public let label: String
    public let brush: BrushSettings
    public let pre: Surface
    /// The layer as the canvas should show it now (pre-stroke pixels + the stroke so far,
    /// including the smoothing tail preview).
    public private(set) var surface: Surface
    let selection: Surface?
    let lockTransparency: Bool
    let symmetry: PresetSymmetry?
    var cpuPasses: [StrokeRenderer] = []
    var live = UnionLive()
    var passesDrawn = 0
    var gpu: MetalStrokeRenderer?
    var originUs: UInt64?
    var lastPoint: StrokePoint?
    var touched = PixelRect.empty
    public private(set) var finished = false

    /// `layer` is the target layer's pixels before the stroke; `zoom` is the view zoom (smoothing).
    public init(brush: BrushSettings, layer: Surface, selection: Surface? = nil, lockTransparency: Bool = false, zoom: Float = 1,
                symmetry: PresetSymmetry? = nil, backend: PaintBackend = .auto, label: String = "Brush Tool") throws {
        self.label = label
        self.brush = brush
        pre = layer
        surface = layer
        self.selection = selection
        self.lockTransparency = lockTransparency
        self.symmetry = symmetry
        let passes = 1 + (symmetry?.mirrorCount ?? 0)
        let wantGPU = backend == .metal || (backend == .auto && MetalContext.shared != nil)
        if wantGPU {
            gpu = try MetalStrokeRenderer(brush, format: layer.format, zoom: zoom, passes: passes)
        } else {
            cpuPasses = (0..<passes).map { _ in StrokeRenderer(brush, format: layer.format, zoom: zoom) }
        }
    }

    public var usesMetal: Bool { gpu != nil }
    public var dabCount: Int { gpu?.dabCount ?? cpuPasses.first?.dabCount ?? 0 }
    /// Keep calling `tick` while the pointer is held still (airbrush, smoothing catch-up).
    public var wantsTime: Bool { gpu?.wantsTime ?? cpuPasses.first?.wantsTime ?? false }
    /// The string from the lagging brush to the pointer, for the canvas to draw.
    public var smoothingString: (brush: SIMD2<Double>, pointer: SIMD2<Double>)? { gpu?.smoothingString ?? cpuPasses.first?.smoothingString }

    /// Feed a coalesced batch of pointer samples; returns what changed.
    @discardableResult
    public func feed(_ events: [PointerEvent]) throws -> StrokeUpdate {
        precondition(!finished, "stroke already ended")
        if events.isEmpty { return StrokeUpdate(damage: .empty, tiles: [], dabCount: dabCount) }
        if originUs == nil { originUs = events[0].timeUs }
        let pts = events.map { $0.strokePoint(originUs: originUs!) }
        lastPoint = pts.last
        return try push(pts)
    }

    /// The pointer is held still at time `timeUs`: re-feed the last sample so time-driven effects
    /// (Build-up, smoothing catch-up) advance. Nil when the stroke doesn't want time.
    public func tick(timeUs: UInt64) throws -> StrokeUpdate? {
        guard wantsTime, var p = lastPoint, let o = originUs else { return nil }
        p.time = timeUs >= o ? Double(timeUs - o) / 1000 : p.time
        lastPoint = p
        return try push([p])
    }

    func push(_ pts: [StrokePoint]) throws -> StrokeUpdate {
        let dmg: PixelRect
        let mirrored = symmetry?.reflectedPasses(pts) ?? []
        if let g = gpu {
            try g.push(passes: [pts] + mirrored)
            dmg = try g.compositeLive(pre: pre, target: &surface, selection: selection, lockTransparency: lockTransparency)
        } else {
            cpuPasses[0].push(pts)
            for (i, m) in mirrored.enumerated() { cpuPasses[i + 1].push(m) }
            let full = passesDrawn != cpuPasses.count
            passesDrawn = cpuPasses.count
            dmg = StrokeRenderer.compositeUnionLive(&cpuPasses, live: &live, full: full, pre: pre, target: &surface, selection: selection,
                                                    lockTransparency: lockTransparency)
        }
        touched = touched.union(dmg)
        return StrokeUpdate(damage: dmg, tiles: dmg.tiles, dabCount: dabCount)
    }

    /// Pointer up: finish the stroke and return it as one transaction (the final damage is in
    /// `transaction.bounds`; `surface` holds the committed pixels).
    public func end() throws -> StrokeTransaction {
        precondition(!finished, "stroke already ended")
        finished = true
        var bounds: PixelRect
        if let g = gpu {
            try g.finish()
            // Composite the finished stroke from the pre-stroke pixels; tiles only the live tail
            // preview drew go back to their pre-stroke state.
            var finishedLayer = pre
            let b = try g.composite(pre: pre, target: &finishedLayer, selection: selection, lockTransparency: lockTransparency, all: true)
            surface = mergeTiles(base: surface, finished: finishedLayer, over: touched.union(b))
            bounds = b
        } else {
            for i in cpuPasses.indices { cpuPasses[i].finish() }
            var target = pre
            bounds = cpuPasses[0].compositeUnionMany(Array(cpuPasses.dropFirst()), pre: pre, target: &target, selection: selection,
                                                     lockTransparency: lockTransparency)
            surface = mergeTiles(base: surface, finished: target, over: touched.union(bounds))
        }
        bounds = bounds.union(touched)
        var before: [(TileCoord, Tile?)] = [], after: [(TileCoord, Tile?)] = []
        for c in bounds.tiles {
            let b = pre.tile(c), a = surface.tile(c)
            if b?.generation == a?.generation { continue }
            before.append((c, b))
            after.append((c, a))
        }
        return StrokeTransaction(label: label, bounds: bounds, before: before, after: after)
    }

    /// Abandon the stroke; `surface` returns to the pre-stroke pixels.
    public func cancel() {
        finished = true
        surface = pre
    }

    /// `base` with the tiles over `rect` taken from `finished` (the committed stroke), so tiles the
    /// live preview drew but the finished stroke doesn't touch return to the pre-stroke pixels.
    func mergeTiles(base: Surface, finished: Surface, over rect: PixelRect) -> Surface {
        var out = base
        for c in rect.tiles {
            if let t = finished.tile(c) { out.putTiles([(c, t)]) } else { _ = out.takeTiles(c.rect) }
        }
        return out
    }
}
