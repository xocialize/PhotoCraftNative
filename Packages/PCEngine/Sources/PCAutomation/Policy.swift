// Port of photocraft-automation (crates/automation/src/workspace.rs: `authorize_engine_command`, `authorize_desktop_engine_command`, `authorize_engine_step`, `authorize_desktop_engine_step` and the per-command path and preference classification), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Engine commands that still read or write ambient filesystem paths are refused in untrusted
// automation; automation reaches files through the capability-scoped document methods
// (`doc.open`, `doc.save`, `doc.render`, `doc.place`, the exports and the data-set import). The
// step variants are what `Session.authorize` stores, so a command can't reach a refused one by
// running it on its own behalf (`actions.play`, Apply Data Set, Conditional Mode Change…).

import PCDocument
import PCEngine

public enum AutomationPolicy {
    static let safeFileCommands: Set<String> = [
        "file.new", "file.newFromClipboard", "file.close", "file.closeAll", "file.closeOthers", "file.fileInfo",
        "file.automate.fitImage", "file.automate.conditionalModeChange", "file.scripts.flattenAllLayerEffects",
        "file.scripts.flattenAllMasks", "file.scripts.deleteAllEmptyLayers", "file.export.exportPreferences",
    ]

    /// Contents commands re-check the resolved source in the engine before any disk read;
    /// Photoshop's embedded linked-layer blocks count as in-memory sources too.
    static let inMemorySmartCommands: Set<String> = [
        "layer.smartObjects.convertToSmartObject", "layer.smartObjects.editContents", "layer.smartObjects.convertToLayers",
        "layer.smartObjects.saveContents",
    ]

    static let ambientCommands: Set<String> = [
        "pattern.import", "pattern.export", "edit.presets.migratePresets", "measurementLog.export",
        "layer.videoLayers.newVideoLayerFromFile", "layer.videoLayers.replaceFootage", "layer.videoLayers.reloadFrame",
    ]

    /// Refuses commands that read or write ambient filesystem paths (photocraft
    /// `authorize_engine_command`).
    public static func authorizeEngineCommand(_ id: String, _ params: JSONValue) throws {
        if id.hasPrefix("file.") && !safeFileCommands.contains(id) { throw commandError(id) }
        if (id.hasPrefix("layer.smartObjects.") && !inMemorySmartCommands.contains(id))
            || ambientCommands.contains(id)
            || commandUsesAmbientPath(id, params)
            || profileCommandMayReadAmbient(id, params)
            || preferencesMayGrantAmbientPaths(id, params)
            || paramsContainAmbientPath(id, params) {
            throw commandError(id)
        }
    }

    /// Desktop sessions may already hold user-configured ambient colour-profile paths: commands
    /// that implicitly resolve those settings are refused even without a path in their params
    /// (photocraft `authorize_desktop_engine_command`). Fresh headless sessions can't acquire
    /// such settings through automation.
    public static func authorizeDesktopEngineCommand(_ id: String, _ params: JSONValue) throws {
        try authorizeEngineCommand(id, params)
        if id.hasPrefix("image.mode.") { throw commandError(id) }
    }

    /// `authorizeEngineCommand` as the hook `Session.authorize` stores (photocraft
    /// `authorize_engine_step`); `actions.play` calls it for every nested step.
    @Sendable public static func authorizeEngineStep(_ id: String, _ params: JSONValue) throws {
        try authorizeEngineCommand(id, params)
    }

    /// `authorizeDesktopEngineCommand` as a `Session.authorize` hook.
    @Sendable public static func authorizeDesktopEngineStep(_ id: String, _ params: JSONValue) throws {
        try authorizeDesktopEngineCommand(id, params)
    }

    static func commandError(_ id: String) -> EngineError {
        AutomationError.badRequest("automation command `\(id)` uses ambient filesystem paths and is disabled; use capability-scoped document methods")
    }

    static func paramsContainAmbientPath(_ id: String, _ params: JSONValue) -> Bool {
        let keys: [String]
        switch id {
        case "image.adjustments.colorLookup", "layer.newAdjustmentLayer.colorLookup", "layer.setAdjustment": keys = ["file"]
        case "filter.distort.displace": keys = ["mapPath"]
        case "layer.quickExportAsPng", "layer.exportAs", "image.applyDataSet", "layer.smartObjects.editContents", "layer.smartObjects.convertToLayers":
            keys = ["path"]
        case "image.mode.rgb", "image.mode.grayscale", "image.mode.cmyk", "image.mode.lab": keys = ["profile"]
        case "edit.assignProfile", "edit.convertToProfile", "edit.profileInfo", "view.proofSetup", "view.gamutWarning": keys = ["profile"]
        case "edit.colorSettings": keys = ["workingRgb", "workingCmyk", "workingGray"]
        default: keys = []
        }
        return keys.contains { key in
            guard let value = params[key]?.stringValue else { return false }
            return ["file", "mapPath", "path"].contains(key) ? !value.isEmpty : looksLikePath(value)
        }
    }

    static func profileCommandMayReadAmbient(_ id: String, _ params: JSONValue) -> Bool {
        // Installed profiles scan OS and user directories even without a request path.
        if ["color.profileMismatch", "edit.colorSettings", "edit.installedProfiles", "view.proofSetup"].contains(id) { return true }
        guard ["edit.assignProfile", "edit.convertToProfile", "edit.profileInfo"].contains(id), let profile = params["profile"]?.stringValue else { return false }
        return ["working", "default", "working-cmyk", "workingCmyk", "working-rgb", "workingRgb", "working-gray", "workingGray"].contains(profile)
    }

    static func preferencesMayGrantAmbientPaths(_ id: String, _ params: JSONValue) -> Bool {
        guard id == "prefs.set" else { return false }
        let direct = params["path"]?.stringValue.map(preferenceUsesAmbientFilesystem) ?? false
        let batch = params["values"]?.objectValue?.keys.contains(where: preferenceUsesAmbientFilesystem) ?? false
        return direct || batch
    }

    /// The engine skips empty segments (`.scriptEvents.enabled` sets `scriptEvents.enabled`), so
    /// the first non-empty one is judged; no segment at all is the whole-preferences update.
    static func preferenceUsesAmbientFilesystem(_ path: String) -> Bool {
        guard let section = path.split(separator: ".", omittingEmptySubsequences: true).first else { return true }
        return ["colorSettings", "scriptEvents", "historyLog", "plugIns", "scratchDisks"].contains(String(section))
    }

    static func commandUsesAmbientPath(_ id: String, _ params: JSONValue) -> Bool {
        switch id {
        // `data` wins over `path` in these commands; any `path` without it reads the filesystem.
        case "brush.presets.importAbr", "gradient.presets.importGrd", "plugin.install", "swatches.import":
            return params["data"] == nil && params["path"] != nil
        // With a `path` the file is written there; without one the bytes come back as `data`.
        case "swatches.export": return params["path"] != nil
        case "plugin.reload": return true
        default: return false
        }
    }

    static func looksLikePath(_ value: String) -> Bool {
        let lower = value.lowercased()
        return value.contains("/") || value.contains("\\") || value.contains(":") || lower.hasSuffix(".icc") || lower.hasSuffix(".icm")
    }
}

extension AuthorizedWorkspace {
    /// `AutomationPolicy.authorizeEngineCommand` (kept where the first port exposed it).
    public static func authorizeEngineCommand(_ id: String, _ params: JSONValue) throws {
        try AutomationPolicy.authorizeEngineCommand(id, params)
    }
}
