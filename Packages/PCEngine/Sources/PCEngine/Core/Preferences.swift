// Port of photocraft-engine (crates/engine/src/prefs.rs: `PrefsStore`, `prefs.get`/`set`/`reset`, the Edit › Preferences sections, keyboard shortcuts, menus and toolbar customisation), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Preferences are a JSON tree of Photoshop's dialog sections with photocraft's camelCase keys and
// defaults. `prefs.set` validates against the defaults' shape (a key must exist and keep its JSON
// type) and applies all or nothing. The app persists `values`; headless sessions keep them for
// the session.

import Foundation
import PCDocument

public struct Preferences: Sendable, Equatable {
    /// Every section, defaults merged with the user's values.
    public private(set) var values: JSONValue

    public init(values: JSONValue? = nil) {
        var v = Preferences.defaults
        if let values { v = Preferences.merge(v, values) }
        self.values = v
    }

    /// photocraft's defaults (prefs.rs `Default` impls).
    public static let defaults: JSONValue = [
        "general": [
            "colorPicker": "adobe", "imageInterpolation": "bicubicAutomatic", "beepWhenDone": false, "exportClipboard": true,
            "resizeImageDuringPlace": true, "alwaysCreateSmartObjectsWhenPlacing": true, "zoomWithScrollWheel": false,
            "animatedZoom": true, "zoomResizesWindows": false, "useLegacyFreeTransform": false, "autoShowHomeScreen": true,
        ],
        "interface": [
            "theme": "proMedium", "appearanceMode": "dark", "darkTheme": "proMedium", "lightTheme": "studioLight", "favoriteThemes": [],
            "canvasColor": "default", "canvasCustomColor": "#282828", "showCanvasDots": true, "canvasBorder": "dropShadow", "uiScale": "auto",
            "language": "auto", "uiFontSize": "small", "showChannelsInColor": false, "dynamicColorSliders": true, "showMenuColors": true,
            "showTooltips": true, "enableAnimations": true, "showBoundingBoxWhenDraggingLayer": false, "systemTitleBar": false,
            "notificationAutoHide": true, "notificationDurationSeconds": 6,
        ],
        "workspace": [
            "autoCollapseIconPanels": false, "autoShowHiddenPanels": true, "openDocumentsAsTabs": true,
            "enableFloatingDocumentWindowDocking": true, "largeTabs": false, "enableNarrowOptionsBar": false, "rememberWorkspaceChanges": true,
        ],
        "tools": [
            "showTooltips": true, "useShiftKeyForToolSwitch": true, "zoomClickedPointToCenter": false, "enableFlickPanning": true,
            "varyRoundBrushHardnessOnHud": true, "snapVectorToolsAndTransformsToPixelGrid": true, "showTransformationValues": true,
            "showHighlightOnRollover": true, "overscroll": true, "doubleClickLayerMaskLaunchesSelectAndMask": true,
            "rightClickWithPaintingTools": "brushPicker", "useTabletPressure": true, "pressureCurve": [[0, 0], [1, 1]],
        ],
        "historyLog": ["enabled": false, "destination": "metadata", "filePath": "", "detail": "concise"],
        "fileHandling": [
            "imagePreviews": "always", "lowercaseExtension": true, "saveInBackground": true, "autosave": true, "autosaveMinutes": 10,
            "recoverOnLaunch": true, "ignoreExifProfileTag": false, "askBeforeSavingLayeredTiff": true, "maximizePsdCompatibility": "always",
            "rasterizeSvgGroupsDeeperThan": 100, "recentFileCount": 20, "recentFiles": [],
        ],
        "export": [
            "quickExportFormat": "png", "quickExportLocation": "ask", "jpegQuality": 85, "webpLossless": true, "webpQuality": 85,
            "metadata": "copyright", "convertToSrgb": true,
        ],
        "performance": [
            "memoryUsageMb": 8192, "historyStates": 50, "cacheLevels": 4, "cacheTileSize": 8192, "useGpu": true, "renderingMode": "auto",
            "gpuBackend": "auto", "lowResolutionPreviews": true, "effectCacheMb": 768, "legacyCompositing": false,
        ],
        "scratchDisks": ["disks": []],
        "cursors": [
            "painting": "normalTip", "showCrosshairInBrushTip": false, "showOnlyCrosshairWhilePainting": false, "other": "standard",
            "brushPreviewColor": "#ff0000",
        ],
        "transparencyAndGamut": [
            "gridSize": "medium", "gridColors": "light", "customLight": "#ffffff", "customDark": "#cccccc", "gamutWarningColor": "#808080",
            "gamutWarningOpacity": 100,
        ],
        "unitsAndRulers": [
            "rulers": "pixels", "typeUnits": "points", "columnWidth": 180, "gutter": 12, "printResolution": 300, "screenResolution": 72,
            "pointSize": "postScript", "showRulers": false,
        ],
        "guidesGridAndSlices": [
            "guideColor": "#4affff", "guideStyle": "lines", "smartGuideColor": "#ff00ff", "gridColor": "#8c8c8c", "gridStyle": "lines",
            "gridlineEvery": 1, "gridUnit": "inches", "subdivisions": 4, "sliceColor": "#38b5ff", "showSliceNumbers": true,
        ],
        "plugIns": [
            "useAdditionalPluginsFolder": false, "additionalPluginsFolder": "", "showExtensionPanels": true, "allowScriptsToConnect": false,
            "generatorEnabled": false,
        ],
        "type": [
            "smartQuotes": true, "missingGlyphProtection": true, "showFontNamesInEnglish": true, "useEscToCommit": true,
            "textEngine": "worldReady", "fontPreview": "medium", "fillNewTypeLayersWithPlaceholder": true, "recentFonts": 10,
        ],
        "enhancedControls": ["scrubbySliderAcceleration": true],
        "rawDefaults": [:],
        "integrations": [:],
        "colorSettings": [
            // photocraft `ColorSettings::default()`.
            "workingRgb": "srgb", "workingCmyk": "coated-cmyk", "workingGray": "sgray",
            "policyRgb": "preserve", "policyCmyk": "preserve", "policyGray": "preserve",
            "askOnMismatch": true, "askOnPaste": true, "askOnMissing": false, "intent": "relative",
            "bpc": true, "dither": true, "blendTextGamma": 1.45, "monitorProfile": "auto",
        ],
        "shortcuts": [:],
        // File › Scripts › Script Events Manager (photocraft automate_cmds' bindings).
        "scriptEvents": ["enabled": false, "bindings": []],
        // Edit › Check Spelling's learned words (photocraft `Preferences::user_dictionary`).
        "userDictionary": [],
        "menus": ["hidden": [], "colors": [:]],
        "toolbar": ["hidden": [], "order": []],
        "dialogs": [:],
    ]

    /// Sections that may hold anything (no fixed keys).
    static let freeform: Set<String> = ["shortcuts", "dialogs", "rawDefaults", "integrations"]

    /// Most undo states per document.
    public var historyStates: Int { max(self["performance.historyStates"]?.intValue ?? 50, 1) }
    /// Pixel memory budget of each document's history (photocraft `history_budget_bytes`).
    public var historyBudgetBytes: Int { (self["performance.memoryUsageMb"]?.intValue ?? 8192).multipliedReportingOverflow(by: 1 << 20).partialValue }

    /// The value at a dotted path (`"performance.historyStates"`).
    public subscript(path: String) -> JSONValue? {
        var v: JSONValue? = values
        for k in Preferences.keys(path) { v = v?[k] }
        return v
    }

    /// A path's keys. In a free-form section everything after the section name is one key
    /// (shortcuts are keyed by dotted command ids: `shortcuts.actions.play:Foo`).
    static func keys(_ path: String) -> [String] {
        let keys = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard keys.count > 2, freeform.contains(keys[0]) else { return keys }
        return [keys[0], keys[1...].joined(separator: ".")]
    }

    /// Sets `path` to `value`, validated against the defaults' shape.
    public mutating func set(_ path: String, _ value: JSONValue) throws(EngineError) {
        let keys = Preferences.keys(path)
        guard let section = keys.first, Preferences.defaults[section] != nil else { throw .bad("prefs.set", "unknown preference `\(path)`") }
        if keys.count == 1, let d = Preferences.defaults[section], d.objectValue == nil {
            // A top-level value that isn't a section (`userDictionary`).
            guard Preferences.sameKind(d, value) else { throw .bad("prefs.set", "`\(path)` must be \(Preferences.kindName(d)), got \(value.serialized())") }
            values = Preferences.setting(values, keys[...], value)
            return
        }
        if keys.count == 1 {
            guard value.objectValue != nil else { throw .bad("prefs.set", "`\(path)` takes an object") }
            // Free-form sections (shortcuts keyed by dotted command ids…) are replaced whole.
            if Preferences.freeform.contains(section) || ["menus", "toolbar"].contains(section) {
                var o = values.objectValue ?? [:]
                o[section] = value
                values = .object(o)
                return
            }
            for (k, v) in value.members { try set("\(section).\(k)", v) }
            return
        }
        if !Preferences.freeform.contains(section) {
            guard let d = Preferences.default(at: keys) else { throw .bad("prefs.set", "unknown preference `\(path)`") }
            guard Preferences.sameKind(d, value) else { throw .bad("prefs.set", "`\(path)` must be \(Preferences.kindName(d)), got \(value.serialized())") }
        }
        values = Preferences.setting(values, keys[...], value)
    }

    /// Resets everything, a section, or one key.
    public mutating func reset(_ path: String?) throws(EngineError) {
        guard let path, !path.isEmpty else { values = Preferences.defaults; return }
        let keys = Preferences.keys(path)
        guard let d = Preferences.default(at: keys) else { throw .bad("prefs.reset", "unknown preference `\(path)`") }
        values = Preferences.setting(values, keys[...], d)
    }

    static func `default`(at keys: [String]) -> JSONValue? {
        var v: JSONValue? = defaults
        for k in keys { v = v?[k] }
        return v
    }

    static func sameKind(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.bool, .bool), (.number, .number), (.string, .string), (.array, .array), (.object, .object): true
        default: false
        }
    }

    static func kindName(_ v: JSONValue) -> String {
        switch v {
        case .bool: "a boolean"
        case .number: "a number"
        case .string: "a string"
        case .array: "an array"
        case .object: "an object"
        case .null: "null"
        }
    }

    static func setting(_ root: JSONValue, _ keys: ArraySlice<String>, _ value: JSONValue) -> JSONValue {
        guard let k = keys.first else { return value }
        var o = root.objectValue ?? [:]
        o[k] = setting(o[k] ?? .object([:]), keys.dropFirst(), value)
        return .object(o)
    }

    static func merge(_ base: JSONValue, _ over: JSONValue) -> JSONValue {
        guard case .object(var b) = base, case .object(let o) = over else { return over }
        for (k, v) in o { b[k] = b[k].map { merge($0, v) } ?? v }
        return .object(b)
    }
}

/// `prefs.*`, the Edit › Preferences sections, keyboard shortcuts, menus and toolbar.
enum PrefsCommands: CommandModule {
    static let name = "prefs"

    static let sections: [(String, String, String?)] = [
        ("general", "General…", "Cmd+K"), ("interface", "Interface…", nil), ("workspace", "Workspace…", nil), ("tools", "Tools…", nil),
        ("historyLog", "History Log…", nil), ("fileHandling", "File Handling…", nil), ("export", "Export…", nil),
        ("performance", "Performance…", nil), ("scratchDisks", "Scratch Disks…", nil), ("cursors", "Cursors…", nil),
        ("transparencyAndGamut", "Transparency & Gamut…", nil), ("unitsAndRulers", "Units & Rulers…", nil),
        ("guidesGridAndSlices", "Guides, Grid & Slices…", nil), ("plugIns", "Plug-ins…", nil), ("type", "Type…", nil),
        ("enhancedControls", "Enhanced Controls…", nil), ("rawDefaults", "Camera Raw…", nil), ("integrations", "Integrations…", nil),
    ]

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("prefs.get", "Get Preferences", params: #"{"path":"section.key"?=everything (e.g. "performance.historyStates", "colorSettings.workingRgb")}"#,
                          module: "prefs", journal: false) { s, p in
            guard let path = p["path"]?.stringValue else { return s.preferences.values }
            guard let v = s.preferences[path] else { throw EngineError.bad("prefs.get", "unknown preference `\(path)`") }
            return v
        })
        r.add(CommandSpec("prefs.set", "Set Preferences",
                          params: #"{"path":"section.key","value":json} or {"values":{"section.key":json,…}} (validated; all or nothing)"#,
                          module: "prefs", journal: false) { s, p in
            var next = s.preferences
            if let path = p["path"]?.stringValue {
                guard let v = p["value"] else { throw EngineError.bad("prefs.set", "missing `value`") }
                try next.set(path, v)
            } else if let vs = p["values"]?.objectValue {
                for (k, v) in vs.sorted(by: { $0.key < $1.key }) { try next.set(k, v) }
            } else {
                throw EngineError.bad("prefs.set", "pass `path` and `value`, or `values`")
            }
            s.preferences = next
            s.applyHistoryPreferences()
            s.emit(.preferencesChanged)
            return .null
        })
        r.add(CommandSpec("prefs.reset", "Reset Preferences", params: #"{"path":"section|section.key"?=everything}"#, module: "prefs", journal: false) { s, p in
            try s.preferences.reset(p["path"]?.stringValue)
            s.applyHistoryPreferences()
            s.emit(.preferencesChanged)
            return .null
        })
        for (key, label, sc) in sections {
            r.add(CommandSpec("edit.preferences.\(key)", label, menu: ["Edit", "Preferences"], shortcut: sc, module: "prefs", journal: false) { s, _ in
                ["section": .string(key), "values": s.preferences.values[key] ?? .object([:])]
            })
        }
        r.add(CommandSpec("edit.keyboardShortcuts", "Keyboard Shortcuts…", menu: ["Edit"], shortcut: "Cmd+Alt+Shift+K",
                          params: #"{"set":{"<command id>|tools.temporary.hand|zoomIn|zoomOut":"Cmd+Shift+X"|""(remove)|null(default)}?,"reset":true|["<id>",…]?,"removeConflicts":bool=true,"filter":str?,"list":bool=false,"importKys":"<.kys XML>"?}"#,
                          module: "prefs", run: keyboardShortcuts))
        r.add(CommandSpec("edit.menus", "Menus…", menu: ["Edit"], shortcut: "Cmd+Alt+Shift+M",
                          params: #"{"hide":["<id>",…]?,"show":["<id>",…]?,"color":{"<id>":"red|orange|yellow|green|blue|violet|gray|none"}?,"reset":bool=false}"#,
                          module: "prefs", run: menus))
        r.add(CommandSpec("edit.toolbar", "Toolbar…", menu: ["Edit"], params: #"{"hidden":["<tool>",…]?,"order":["<tool>",…]?,"reset":bool=false}"#,
                          module: "prefs") { s, p in
            var tb = s.preferences["toolbar"]?.members ?? [:]
            if p["reset"]?.boolValue == true { tb = ["hidden": [], "order": []] }
            if let h = p["hidden"]?.arrayValue { tb["hidden"] = .array(h.filter { $0.stringValue != nil }) }
            if let o = p["order"]?.arrayValue { tb["order"] = .array(o.filter { $0.stringValue != nil }) }
            try s.preferences.set("toolbar", .object(tb))
            s.emit(.preferencesChanged)
            return .object(tb)
        })
    }

    /// The effective shortcut of every command: user overrides over the registry's defaults.
    static func effectiveShortcuts(_ s: Session) -> [String: String] {
        var out: [String: String] = [:]
        for spec in s.registry.specs { if let sc = spec.shortcut { out[spec.id] = sc } }
        for (id, v) in s.preferences["shortcuts"]?.members ?? [:] {
            switch v {
            case .string(let sc) where sc.isEmpty: out[id] = nil
            case .string(let sc): out[id] = sc
            default: break
            }
        }
        return out
    }

    static func keyboardShortcuts(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        if p.has("importKys") { throw EngineError.unavailable("edit.keyboardShortcuts", "Photoshop .kys import is not ported yet (photocraft kys.rs)") }
        var overrides = s.preferences["shortcuts"]?.members ?? [:]
        if let reset = p["reset"] {
            if reset.boolValue == true { overrides = [:] } else if let ids = reset.arrayValue { for id in ids.compactMap(\.stringValue) { overrides[id] = nil } }
        }
        let removeConflicts = p["removeConflicts"]?.boolValue ?? true
        var conflicts: [JSONValue] = []
        for (id, v) in (p["set"]?.members ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard s.registry.contains(id) || id.hasPrefix("tools.temporary.") || ["zoomIn", "zoomOut"].contains(id) || id.hasPrefix("actions.play:")
                    || p["allowUnknown"]?.boolValue == true else {
                throw EngineError.bad("edit.keyboardShortcuts", "unknown command `\(id)`")
            }
            switch v {
            case .null: overrides[id] = nil
            case .string(let sc):
                if !sc.isEmpty {
                    let current = effectiveShortcuts(s).merging(overrides.compactMapValues(\.stringValue)) { _, b in b }
                    for (other, osc) in current where other != id && osc.caseInsensitiveCompare(sc) == .orderedSame {
                        conflicts.append(["id": .string(other), "shortcut": .string(osc)])
                        if removeConflicts { overrides[other] = "" }
                    }
                }
                overrides[id] = .string(sc)
            default:
                throw EngineError.bad("edit.keyboardShortcuts", "`set.\(id)` must be a shortcut string, \"\" or null")
            }
        }
        try s.preferences.set("shortcuts", .object(overrides))
        s.emit(.preferencesChanged)
        let eff = effectiveShortcuts(s)
        let filter = p["filter"]?.stringValue?.lowercased()
        let list: [JSONValue] = (p["list"]?.boolValue ?? false) || filter != nil
            ? eff.sorted { $0.key < $1.key }.filter { filter == nil || $0.key.lowercased().contains(filter!) || $0.value.lowercased().contains(filter!) }
                .map { ["id": .string($0.key), "shortcut": .string($0.value)] }
            : []
        return ["overrides": .object(overrides), "conflicts": .array(conflicts), "shortcuts": .array(list)]
    }

    static func menus(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        var m = s.preferences["menus"]?.members ?? [:]
        if p["reset"]?.boolValue == true { m = ["hidden": [], "colors": [:]] }
        var hidden = Set((m["hidden"]?.arrayValue ?? []).compactMap(\.stringValue))
        for id in (p["hide"]?.arrayValue ?? []).compactMap(\.stringValue) { hidden.insert(id) }
        for id in (p["show"]?.arrayValue ?? []).compactMap(\.stringValue) { hidden.remove(id) }
        var colors = m["colors"]?.members ?? [:]
        let allowed: Set<String> = ["red", "orange", "yellow", "green", "blue", "violet", "gray", "none"]
        for (id, c) in p["color"]?.members ?? [:] {
            guard let c = c.stringValue, allowed.contains(c) else { throw EngineError.bad("edit.menus", "`color.\(id)` must be one of \(allowed.sorted().joined(separator: "|"))") }
            colors[id] = c == "none" ? nil : .string(c)
        }
        m["hidden"] = .strings(hidden.sorted())
        m["colors"] = .object(colors)
        try s.preferences.set("menus", .object(m))
        s.emit(.preferencesChanged)
        return .object(m)
    }
}

extension Session {
    /// New history limits apply to every open document.
    func applyHistoryPreferences() {
        let n = preferences.historyStates, b = preferences.historyBudgetBytes
        for i in documents.indices {
            documents[i].history.maxStates = n
            documents[i].history.maxBytes = b
            documents[i].history.trim(documents[i].doc)
        }
    }
}
