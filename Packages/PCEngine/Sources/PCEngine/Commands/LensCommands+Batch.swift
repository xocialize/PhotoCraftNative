// Port of photocraft-engine (crates/engine/src/lens_cmds.rs `lens_batch`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// File › Automate › Lens Correction: opens each input in a scratch session, flattens it, runs
// Filter › Lens Correction (the EXIF-driven profile by default) and saves it into the output
// folder, through FileCommands' batch helpers (photocraft `file_cmds::batch_inputs` /
// `process_files`): every format PCIO imports (flat images, PSD/PSB, .pcraft, OpenRaster,
// Paint.NET, Affinity, SVG, layered TIFF…) opens as photocraft opens it, and results are saved by
// PCIO's exporters, layered formats included. Errors per file are collected, not fatal.

import Foundation
import PCDocument

extension LensCommands {
    /// `file.automate.lensCorrection` (photocraft `lens_batch` over `process_files`).
    static func lensBatch(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = lensBatchId
        let inputs = try FileCommands.batchInputs(s, p, cmd)
        let output = try FileCommands.strParam(p, "output", cmd)
        let format = p["format"]?.stringValue ?? "same"
        var m = p.objectValue ?? [:]
        for k in ["input", "files", "output", "format", "quality"] { m[k] = nil }
        // Batch default: the EXIF-driven profile, as Photoshop's dialog suggests.
        if m["profile"] == nil { m["profile"] = .string("auto") }
        let params = JSONValue.object(m)
        let save = try FileCommands.SaveOpts.from(s, p, cmd)
        return FileCommands.processFiles(s, inputs, output: output, format: format, save: save, suffix: "") { scratch in
            if (scratch.active?.doc.layers.count ?? 0) > 1 { try scratch.execute("layer.flattenImage", [:]) }
            try scratch.execute(lens, params)
        }
    }
}
