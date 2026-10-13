// Port of photocraft-engine (crates/engine/src/wia_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// File › Import › WIA Support. Windows Image Acquisition is a Windows-only API for scanners and
// cameras; Photoshop shows this item only on Windows. photocraft registers it cross-platform and
// reports the available acquisition devices — none off Windows, where the feature is unavailable
// (and PCEngine runs on macOS, so this is always the off-Windows answer).

import PCDocument

enum WiaCommands: CommandModule {
    static let name = "wia_cmds"

    static func wia(_ s: Session, _ p: JSONValue) -> JSONValue {
        #if os(Windows)
        // A real implementation enumerates WIA devices via COM (IWiaDevMgr) and transfers an image
        // into a new document. No COM binding is wired, so report zero devices.
        return ["available": true, "devices": .array([]), "note": "WIA device enumeration not yet wired"]
        #else
        return ["available": false, "devices": .array([]), "note": "WIA scanner/camera import is available on Windows only"]
        #endif
    }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("file.import.wiaSupport", "WIA Support…", menu: ["File", "Import"],
                          params: #"{} → {available, devices, note}: acquire from a scanner/camera (Windows only)"#,
                          module: name, journal: false) { s, p in wia(s, p) })
    }
}
