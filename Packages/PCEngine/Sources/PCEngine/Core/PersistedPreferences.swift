// Port of photocraft-engine (crates/engine/src/prefs.rs `prefs_value` / `load_prefs_json`, presets/mod.rs `to_json` / `load_presets_json`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The one JSON document the app saves and loads: the preferences (colour settings included),
// `version`, and every preset library under `presets` — gradients, styles, shapes, pattern
// folders, tool presets, custom shapes, layer-style defaults (PresetCommands), document presets
// and recent documents (DocumentPresetCommands) and swatches (SwatchCommands).

import PCDocument

extension Session {
    /// Everything persisted, as one JSON tree (photocraft `Session::prefs_value`). Frontends
    /// write it after `.preferencesChanged`.
    public func prefsValue() -> JSONValue {
        var presets = PresetCommands.persistedJSON(self).members
        for (k, v) in DocumentPresetCommands.value(self).members { presets[k] = v }
        presets["swatches"] = SwatchCommands.libraryJSON(self)
        return preferences.values.setting("version", 1).setting("presets", .object(presets))
    }

    /// Restores what `prefsValue` saved (photocraft `load_prefs_json`). Missing keys keep their
    /// defaults, and a damaged preset set keeps its current contents, so files from older and
    /// newer versions load.
    public func loadPrefs(_ v: JSONValue) {
        guard v.objectValue != nil else { return }
        let presets = v["presets"] ?? .null
        preferences = Preferences(values: v.removing("presets").removing("version"))
        if presets.objectValue != nil {
            PresetCommands.loadPersisted(self, presets)
            DocumentPresetCommands.restore(self, from: presets)
            SwatchCommands.loadLibrary(self, presets["swatches"])
        }
        applyHistoryPreferences()
        services.renderer.textGamma = ColorCommands.settings(self).blendTextGamma
        emit(.preferencesChanged)
    }
}
