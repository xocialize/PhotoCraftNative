// Port of photocraft-engine (crates/engine/src/brush_key_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Photoshop's brush keys (#626): `[` / `]` step the brush size and ⇧[ / ⇧] the hardness. Photoshop
// has no menu item for them but lists them in Edit › Keyboard Shortcuts › Tools; here they are
// ordinary commands with default shortcuts, so they can be rebound, recorded and driven by
// agents. Each one is a `tools.setBrush` on the session brush. `tools.rotateBrush` turns the tip:
// Photoshop's ← / → while painting (1°, ⇧ 15°).

import PCDocument

enum BrushKeyCommands: CommandModule {
    static let name = "brush_key_cmds"
    static let m = "brush_key_cmds"

    /// Photoshop's largest brush diameter, in pixels.
    static let maxSize: Float = 5000

    /// `[` / `]`: 25 % smaller or larger, and at least a pixel either way so small brushes still
    /// grow and shrink (2 / 1.25 rounds back to 2, which kept `[` from reaching 1 px, #3229).
    static func sizeStep(_ size: Float, _ up: Bool) -> Float {
        let next = up ? max((size * 1.25).rounded(), size + 1) : min((size / 1.25).rounded(), size - 1)
        return min(max(next, 1), maxSize)
    }

    /// ⇧[ / ⇧]: to the previous or next quarter (0, 25, 50, 75, 100 %).
    static func hardnessStep(_ hardness: Float, _ up: Bool) -> Float {
        let quarter = (hardness * 4).rounded()
        let next = up ? quarter + 1 : quarter - 1
        return min(max(next, 0), 4) / 4
    }

    static func size(_ s: Session, _ up: Bool) throws -> JSONValue {
        let size = sizeStep(s.tools.brush.size, up)
        return try BrushCommands.setBrush(s, ["brush": ["size": .float(size)]])
    }

    static func hardness(_ s: Session, _ up: Bool) throws -> JSONValue {
        let hardness = hardnessStep(s.tools.brush.hardness, up)
        return try BrushCommands.setBrush(s, ["brush": ["hardness": .float(hardness)]])
    }

    /// The brush angle turned by `degrees` (positive is anticlockwise, as the angle field counts),
    /// wrapped into Photoshop's -180..=180.
    static func turned(_ angle: Float, _ degrees: Float) -> Float {
        var a = (angle + degrees).truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return a > 180 ? a - 360 : a
    }

    static func rotate(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let by = p["degrees"]?.doubleValue, by.isFinite, abs(by) <= 360 else {
            throw EngineError.bad("tools.rotateBrush", "`degrees` must be a number from -360 to 360")
        }
        let angle = turned(s.tools.brush.angle, Float(by))
        return try BrushCommands.setBrush(s, ["brush": ["angle": .float(angle)]])
    }

    static func register(into r: inout CommandRegistry) {
        r.add([
            CommandSpec("tools.decreaseBrushSize", "Decrease Brush Size", shortcut: "[", params: "{}", module: m) { s, _ in try size(s, false) },
            CommandSpec("tools.increaseBrushSize", "Increase Brush Size", shortcut: "]", params: "{}", module: m) { s, _ in try size(s, true) },
            CommandSpec("tools.decreaseBrushHardness", "Decrease Brush Hardness", shortcut: "Shift+[", params: "{}", module: m) { s, _ in
                try hardness(s, false)
            },
            CommandSpec("tools.increaseBrushHardness", "Increase Brush Hardness", shortcut: "Shift+]", params: "{}", module: m) { s, _ in
                try hardness(s, true)
            },
            CommandSpec("tools.rotateBrush", "Rotate Brush Tip",
                        params: #"{"degrees":-360..360 (positive anticlockwise; ← / → while painting send 1, ⇧ 15)}"#, module: m, run: rotate),
        ])
    }
}
