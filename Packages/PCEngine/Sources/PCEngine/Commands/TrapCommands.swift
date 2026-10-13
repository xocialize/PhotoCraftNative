// Port of photocraft-engine (crates/engine/src/trap_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Image › Trap: a CMYK prepress step. Every ink is spread by `width` px (a grayscale dilation) but
// only under already-inked pixels, so internal colour edges gain a trap band while the
// object-to-paper edge is left alone (a clean-room approximation of Photoshop's Trap). We trap the
// active pixel layer's inks over the canvas, in one history step. The dilation is PCAlgo's `Trap`
// (photocraft-algo `trap`; its Metal path is bit-exact with the CPU reference).

import Foundation
import PCAlgo
import PCDocument
import PCFoundation

public enum TrapCommands: CommandModule {
    public static let name = "trap_cmds"
    static let m = "trap_cmds"

    static let enabled: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document" }
        return d.doc.mode == .cmyk ? nil : "Trap needs a CMYK document (Image › Mode › CMYK Color)"
    }

    /// Traps an interleaved CMYK(+alpha) buffer in place (PCAlgo `Trap.trap`): inks 0…3 spread by
    /// `width` px where the pixel already has ink; alpha untouched. On the GPU when there is one
    /// (bit-exact), else — or if the GPU fails, which leaves `px` untouched — on the CPU.
    static func trapInks(_ px: inout [Float], width w: Int, height h: Int, channels ch: Int, trap width: Int) {
        do {
            try Trap.trap(&px, width: w, height: h, channels: ch, trapWidth: width, on: .auto)
        } catch {
            try? Trap.trap(&px, width: w, height: h, channels: ch, trapWidth: width, on: .cpu)
        }
    }

    static func run(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.trap"
        let wv = max((p["width"]?.doubleValue ?? 1).rounded(), 0)
        let width = wv.isFinite ? Int(min(wv, 1e9)) : 0
        guard let d = s.active else { throw EngineError.noDocument }
        if d.doc.mode != .cmyk { throw EngineError.bad(cmd, "Trap needs a CMYK document") }
        try s.edit("Trap") { doc, active in
            guard let id = active else { throw EngineError.noDocument }
            let bounds = doc.bounds
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            guard case .raster = l.content else {
                throw EngineError.bad(cmd, "Trap needs a pixel layer (active layer is \(l.content.article) \(l.content.kindName))")
            }
            if bounds.isEmpty { return }
            doc.withRaster(of: id) { surf in
                var data = surf.readRegion(bounds)
                trapInks(&data, width: bounds.width, height: bounds.height, channels: surf.channels, trap: width)
                surf.writeRegion(bounds, data)
            }
        }
        return ["trapped": true, "width": .int(width)]
    }

    public static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("image.trap", "Trap…", menu: ["Image"], params: #"{width:px>=1=1} → {trapped,width}: spread inks at colour edges (CMYK only)"#,
                          module: m, enabled: enabled, run: run))
    }
}
