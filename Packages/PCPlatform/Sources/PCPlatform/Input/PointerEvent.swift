// Pointer input: the tool-facing `PointerEvent` (architecture §4.3), the pen state machine, NSEvent
// conversion, and the coalescer that hands high-rate pen samples to tools in batches.
// Replaces photocraft-tablet (crates/tablet: an AppKit local event monitor over unsafe Objective-C
// FFI, plus the pure `appkit` mapping) with AppKit's NSEvent read directly. The state machine is a
// port of crates/tablet/src/appkit.rs (`State::handle`, `Sample::sanitized`), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

import AppKit
import CoreGraphics
import Foundation

/// What is pointing (architecture §4.3 `PointerKind`).
public enum PointerKind: String, Sendable, Codable { case mouse, pen, eraser, touch }

public struct PointerButtons: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// Left button / pen tip.
    public static let primary = PointerButtons(rawValue: 1)
    /// Right button / pen's lower barrel button.
    public static let secondary = PointerButtons(rawValue: 2)
    /// Middle button / pen's upper barrel button.
    public static let middle = PointerButtons(rawValue: 4)
}

public struct PointerModifiers: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = PointerModifiers(rawValue: 1)
    public static let control = PointerModifiers(rawValue: 2)
    public static let option = PointerModifiers(rawValue: 4)
    public static let command = PointerModifiers(rawValue: 8)
    public static let capsLock = PointerModifiers(rawValue: 16)
    public static let function = PointerModifiers(rawValue: 32)

    public init(_ flags: NSEvent.ModifierFlags) {
        var m = PointerModifiers()
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.capsLock) { m.insert(.capsLock) }
        if flags.contains(.function) { m.insert(.function) }
        self = m
    }
}

/// One pointer sample in document space (architecture §4.3: `pos_doc, pressure, tilt, twist,
/// time_us, buttons, mods, kind`).
public struct PointerEvent: Sendable, Equatable, Codable {
    public enum Phase: String, Sendable, Codable { case down, drag, up, hover, enterProximity, leaveProximity }

    public var phase: Phase
    /// Document-space position (pixels, y down).
    public var posDoc: CGPoint
    /// Tip pressure 0…1 (1 for a mouse button press, 0 while hovering).
    public var pressure: Float
    /// Tilt in degrees, −90…90 per axis (W3C: +x to the right, +y towards the user).
    public var tilt: SIMD2<Float>
    /// Barrel rotation, degrees 0…360 clockwise.
    public var twist: Float
    /// Event time, microseconds since boot (NSEvent.timestamp).
    public var timeMicros: UInt64
    public var buttons: PointerButtons
    public var mods: PointerModifiers
    public var kind: PointerKind

    public init(phase: Phase, posDoc: CGPoint, pressure: Float = 1, tilt: SIMD2<Float> = .zero, twist: Float = 0, timeMicros: UInt64 = 0,
                buttons: PointerButtons = [], mods: PointerModifiers = [], kind: PointerKind = .mouse) {
        self.phase = phase; self.posDoc = posDoc; self.pressure = pressure; self.tilt = tilt; self.twist = twist
        self.timeMicros = timeMicros; self.buttons = buttons; self.mods = mods; self.kind = kind
    }
}

/// One pen reading (photocraft `tablet::Sample`).
public struct PenSample: Sendable, Equatable {
    public var pressure: Float = 1
    public var tiltX: Float = 0
    public var tiltY: Float = 0
    public var rotation: Float = 0
    public var eraser = false

    public init(pressure: Float = 1, tiltX: Float = 0, tiltY: Float = 0, rotation: Float = 0, eraser: Bool = false) {
        self.pressure = pressure; self.tiltX = tiltX; self.tiltY = tiltY; self.rotation = rotation; self.eraser = eraser
    }

    /// Clamped to the documented ranges, non-finite values replaced (photocraft `sanitized`): NaN
    /// pressure reads as full pressure, NaN tilt and rotation as 0.
    public func sanitized() -> PenSample {
        func f(_ v: Float, _ lo: Float, _ hi: Float, _ d: Float) -> Float { v.isFinite ? min(max(v, lo), hi) : d }
        var rot: Float = 0
        if rotation.isFinite {
            rot = rotation.truncatingRemainder(dividingBy: 360)
            if rot < 0 { rot += 360 }
            if rot >= 360 { rot = 0 }
        }
        return PenSample(pressure: f(pressure, 0, 1, 1), tiltX: f(tiltX, -90, 90, 0), tiltY: f(tiltY, -90, 90, 0), rotation: rot, eraser: eraser)
    }
}

/// The tablet fields of one NSEvent as plain values (photocraft `appkit::RawEvent`), so the state
/// machine is testable without AppKit events.
public struct RawTabletEvent: Sendable, Equatable {
    public var type: UInt        // NSEvent.EventType raw value
    public var subtype: Int16    // NSEvent.EventSubtype raw value
    public var pressure: Float
    public var tilt: CGPoint     // −1…1 per axis
    public var rotation: Float
    public var device: UInt      // NSEvent.PointingDeviceType raw value
    public var entering: Bool

    public init(type: UInt, subtype: Int16 = 0, pressure: Float = 0, tilt: CGPoint = .zero, rotation: Float = 0, device: UInt = 0, entering: Bool = false) {
        self.type = type; self.subtype = subtype; self.pressure = pressure; self.tilt = tilt; self.rotation = rotation; self.device = device; self.entering = entering
    }
}

/// Pen state across events (photocraft `appkit::State`).
public struct TabletState: Sendable, Equatable {
    /// The eraser end is in proximity.
    public var eraser = false
    /// The current sample (nil = a mouse).
    public var sample: PenSample?

    /// AppKit reports tilt as −1…1 of the device range; Wacom pens reach about ±60° (as Qt maps it).
    public static let tiltDegrees: Double = 60

    public enum Update: Sendable, Equatable { case keep, set(PenSample?) }

    public init() {}

    static let mouseTypes: Set<UInt> = [1, 2, 3, 4, 5, 6, 7, 25, 26, 27]
    static let upTypes: Set<UInt> = [2, 4, 26]

    /// Maps one event (photocraft `State::handle`).
    public mutating func handle(_ e: RawTabletEvent) -> Update {
        let mouse = Self.mouseTypes.contains(e.type)
        let u: Update
        if e.type == 24 || (mouse && e.subtype == 2) {
            u = proximity(e)
        } else if e.type == 23 || (mouse && e.subtype == 1) {
            // Lifting the tip reports pressure 0: keep the stroke's pressure for its last moves.
            u = Self.upTypes.contains(e.type) ? .keep : .set(sampleFrom(e))
        } else {
            u = mouse ? .set(nil) : .keep
        }
        if case .set(let s) = u { sample = s }
        return u
    }

    private mutating func proximity(_ e: RawTabletEvent) -> Update {
        guard e.entering, e.device != 2 else { eraser = false; return .set(nil) }   // leaving, or a puck (cursor)
        eraser = e.device == 3
        return .set(PenSample(pressure: 0, eraser: eraser))
    }

    private func sampleFrom(_ e: RawTabletEvent) -> PenSample {
        func tilt(_ v: CGFloat) -> Float { v.isFinite ? Float(min(max(v, -1), 1) * Self.tiltDegrees) : 0 }
        // AppKit's +y tilts away from the user; W3C's +y towards the user.
        return PenSample(pressure: e.pressure, tiltX: tilt(e.tilt.x), tiltY: -tilt(e.tilt.y), rotation: e.rotation, eraser: eraser).sanitized()
    }
}

/// NSEvent → PointerEvent.
public enum PointerInput {
    /// The tablet fields of an NSEvent.
    public static func raw(_ e: NSEvent) -> RawTabletEvent {
        let type = e.type
        var r = RawTabletEvent(type: type.rawValue)
        let isMouse = TabletState.mouseTypes.contains(type.rawValue)
        if isMouse || type == .tabletPoint || type == .tabletProximity {
            if isMouse { r.subtype = e.subtype.rawValue }
            if type == .tabletProximity || (isMouse && e.subtype == .tabletProximity) {
                r.device = e.pointingDeviceType.rawValue
                r.entering = e.isEnteringProximity
            }
            if type == .tabletPoint || (isMouse && e.subtype == .tabletPoint) {
                r.pressure = e.pressure
                r.tilt = e.tilt
                r.rotation = e.rotation
            }
        }
        return r
    }

    /// Converts an AppKit event, updating the pen state. `location` maps the event's window
    /// location to document space (e.g. view conversion + viewport inverse). Returns nil for events
    /// that are not pointer events.
    public static func event(from e: NSEvent, state: inout TabletState, location: (CGPoint) -> CGPoint = { $0 }) -> PointerEvent? {
        let update = state.handle(raw(e))
        let t = e.type
        let phase: PointerEvent.Phase
        switch t {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: phase = .down
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: phase = .drag
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: phase = .up
        case .mouseMoved: phase = .hover
        case .tabletPoint: phase = NSEvent.pressedMouseButtons != 0 ? .drag : .hover
        case .tabletProximity: phase = e.isEnteringProximity ? .enterProximity : .leaveProximity
        default: return nil
        }
        var buttons = PointerButtons()
        switch t {
        case .leftMouseDown, .leftMouseDragged: buttons.insert(.primary)
        case .rightMouseDown, .rightMouseDragged: buttons.insert(.secondary)
        case .otherMouseDown, .otherMouseDragged: buttons.insert(.middle)
        default: break
        }
        let pos = t == .tabletProximity ? .zero : location(e.locationInWindow)
        var ev = PointerEvent(phase: phase, posDoc: pos, timeMicros: UInt64(max(e.timestamp, 0) * 1_000_000),
                              buttons: buttons, mods: PointerModifiers(e.modifierFlags), kind: .mouse)
        let sample: PenSample?
        if case .set(let s) = update { sample = s } else { sample = state.sample }
        if let s = sample {
            ev.kind = s.eraser ? .eraser : .pen
            ev.pressure = s.pressure
            ev.tilt = SIMD2(s.tiltX, s.tiltY)
            ev.twist = s.rotation
        } else {
            ev.pressure = (phase == .down || phase == .drag) ? 1 : 0
            if TabletState.mouseTypes.contains(t.rawValue), e.subtype == .touch { ev.kind = .touch }
        }
        return ev
    }

    /// AppKit coalesces mouse-drag events to one per display frame; painting wants every tablet
    /// sample, so a canvas turns coalescing off while it has focus (photocraft reads the same
    /// stream through its event monitor).
    @MainActor public static func setAppKitCoalescing(_ enabled: Bool) {
        NSEvent.isMouseCoalescingEnabled = enabled
    }
}

/// Collects pointer events between frames and hands them to a tool as one batch (architecture §4.3:
/// "coalesced high-rate pen samples … handed to tools as a batch, so the brush sees every sample").
/// Within a batch: repeated positions at the same pressure are merged, consecutive hovers collapse to
/// the latest, and a lift's pressure-0 report keeps the stroke's last pressure (photocraft's
/// `lifting_the_pen_keeps_the_strokes_pressure`).
public struct PointerCoalescer: Sendable {
    public private(set) var pending: [PointerEvent] = []
    private var lastDownPressure: Float?
    /// Samples closer than this (px) at the same pressure are merged.
    public var minDistance: CGFloat

    public init(minDistance: CGFloat = 0.01) { self.minDistance = minDistance }

    public mutating func push(_ e: PointerEvent) {
        var e = e
        switch e.phase {
        case .down, .drag:
            lastDownPressure = e.pressure
            if e.phase == .drag, let last = pending.last, last.phase == .drag || last.phase == .down,
               hypot(last.posDoc.x - e.posDoc.x, last.posDoc.y - e.posDoc.y) < minDistance, last.pressure == e.pressure, last.buttons == e.buttons {
                pending[pending.count - 1].timeMicros = e.timeMicros
                return
            }
        case .up:
            if e.kind != .mouse, e.pressure == 0, let p = lastDownPressure { e.pressure = p }
            lastDownPressure = nil
        case .hover:
            if let last = pending.last, last.phase == .hover { pending[pending.count - 1] = e; return }
        default: break
        }
        pending.append(e)
    }

    /// The batch since the last drain.
    public mutating func drain() -> [PointerEvent] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }

    /// Samples spaced at most `spacing` px apart along a stroke batch (linear interpolation of
    /// position, pressure, tilt, twist and time), for brushes that need even dab spacing.
    public static func resample(_ events: [PointerEvent], spacing: CGFloat) -> [PointerEvent] {
        guard spacing > 0, events.count > 1 else { return events }
        var out: [PointerEvent] = [events[0]]
        for (a, b) in zip(events, events.dropFirst()) {
            let d = hypot(b.posDoc.x - a.posDoc.x, b.posDoc.y - a.posDoc.y)
            if b.phase == .drag || b.phase == .up, d > spacing {
                let n = Int((d / spacing).rounded(.up))
                for k in 1..<n {
                    let t = CGFloat(k) / CGFloat(n), tf = Float(t)
                    var m = b
                    m.posDoc = CGPoint(x: a.posDoc.x + (b.posDoc.x - a.posDoc.x) * t, y: a.posDoc.y + (b.posDoc.y - a.posDoc.y) * t)
                    m.pressure = a.pressure + (b.pressure - a.pressure) * tf
                    m.tilt = a.tilt + (b.tilt - a.tilt) * tf
                    m.twist = a.twist + (b.twist - a.twist) * tf
                    m.timeMicros = a.timeMicros + UInt64(Double(b.timeMicros > a.timeMicros ? b.timeMicros - a.timeMicros : 0) * Double(t))
                    m.phase = .drag
                    out.append(m)
                }
            }
            out.append(b)
        }
        return out
    }
}
