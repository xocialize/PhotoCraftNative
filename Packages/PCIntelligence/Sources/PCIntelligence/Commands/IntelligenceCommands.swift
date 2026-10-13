// The AI operations described as photocraft-engine commands: id, label, menu path, shortcut, params
// schema and an enabled predicate, as plain data (Codable), so the future engine (PCEngine) registers
// them without rework. Shape after photocraft-engine's `CommandSpec` (crates/engine/src/commands.rs);
// ids reuse photocraft's where the feature exists (`select.subject`, `select.object`,
// `layer.removeBackground`, `paint.remove`, `edit.contentAwareFill`), and new ids follow its menu
// naming. MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import PCDocument
import PCFoundation
import RestoreTier2

/// A condition a command needs before it can run. photocraft's `enabled` is a function returning
/// the reason it can't run; here the conditions are data and `IntelligenceCommands.disabledReason`
/// evaluates them in order, so the first failing one gives the message.
public enum CommandPrecondition: Hashable, Sendable, Codable {
    /// A document is open.
    case document
    /// The target layer exists.
    case layer
    /// The target layer is a pixel layer whose pixels are not locked.
    case editablePixelLayer
    /// A selection with pixels on the canvas.
    case selection
    /// The document is in a colour mode (not Grayscale, Bitmap or Duotone).
    case colorDocument
    /// The capability can run (a model-free tier or a registered provider).
    case capability(Capability)
    /// The restore job can run.
    case restoreJob(String)
}

/// One command as data.
public struct CommandDescriptor: Hashable, Sendable, Codable, Identifiable {
    /// Photoshop-structured id (`select.subject`).
    public var id: String
    public var label: String
    /// Menu placement (`["Select"]`); empty = a tool or Quick Action, not in menus.
    public var menu: [String]
    /// Default shortcut in photocraft's notation (`Cmd+Shift+N`).
    public var shortcut: String?
    /// photocraft's human/agent-readable params schema (JSON-ish) and result.
    public var params: String
    /// All must hold for the command to be enabled.
    public var enabled: [CommandPrecondition]
    /// The registry slot it runs on.
    public var capability: Capability
    /// Recorded in the session journal (false for queries such as the hover preview).
    public var journal: Bool
    /// Runs as a background job (progress, cancellable, applies in one undo step).
    public var job: Bool
    /// The photocraft source that already defines this id (nil for a new id).
    public var photocraftSource: String?
}

/// What a command's enabled predicate looks at.
public struct CommandContext: Sendable {
    public var document: Document?
    public var activeLayer: LayerId?
    public var registry: ProviderRegistry

    public init(document: Document?, activeLayer: LayerId?, registry: ProviderRegistry) {
        self.document = document; self.activeLayer = activeLayer; self.registry = registry
    }
}

/// The AI tier's commands.
public enum IntelligenceCommands {

    /// Every command, in menu order.
    public static let all: [CommandDescriptor] = [
        CommandDescriptor(
            id: "select.subject", label: "Subject", menu: ["Select"], shortcut: nil,
            params: #"{"sampleAllLayers":bool=true,"mode":"replace|add|subtract|intersect"="replace","quality":"fast|best"="fast"} → {selected,changed,bounds,tier,engine} (finding nothing leaves the selection alone: changed=false)"#,
            enabled: [.document, .capability(.subjectMatte)], capability: .subjectMatte, journal: true, job: true,
            photocraftSource: "crates/engine/src/smartselect_cmds.rs"),
        CommandDescriptor(
            id: "select.object", label: "Object Selection", menu: [], shortcut: nil,
            params: #"{"rect":[x,y,w,h]?,"points":[[x,y,include?=true],…]?,"mode":"replace|add|subtract|intersect"="replace","sampleAllLayers":bool=false} → {selected,changed,bounds,tier,engine} (a click, clicks with exclusions, a box, or both; negative sizes are normalised)"#,
            enabled: [.document, .capability(.promptMask)], capability: .promptMask, journal: true, job: true,
            photocraftSource: "crates/engine/src/smartselect_cmds.rs"),
        CommandDescriptor(
            id: "select.objectFinder", label: "Object Finder", menu: [], shortcut: nil,
            params: #"{"x":px,"y":px,"sampleAllLayers":bool=false} → {object:{index,bounds:[x,y,w,h]}|null,objects:n,tier:"vision"} (the Object Selection tool's hover preview; objects are detected once per document state, then looked up per pointer move; a click selects through select.object)"#,
            enabled: [.document], capability: .promptMask, journal: false, job: false, photocraftSource: nil),
        CommandDescriptor(
            id: "layer.removeBackground", label: "Remove Background", menu: [], shortcut: nil,
            params: #"{"layer":id?,"sampleAllLayers":bool=false,"refine":bool=true} → {layer,bounds,tier,engine} (adds a layer mask from the subject; the Background becomes a normal layer; refine is PCAlgo's matting refine, applied by the engine when present)"#,
            enabled: [.document, .layer, .editablePixelLayer, .capability(.subjectMatte)], capability: .subjectMatte, journal: true, job: true,
            photocraftSource: "crates/engine/src/cutout_cmds.rs"),
        CommandDescriptor(
            id: "paint.remove", label: "Remove", menu: [], shortcut: nil,
            params: #"{"points":[[x,y,pressure?],…],"size":1..5000 px=tool size,"hardness":0..100=tool hardness,"strokes":[[[x,y,pressure?],…],…]?,"closeLoops":bool=true,"sampleAllLayers":bool=false,"newLayer":bool=false,"layer":id?=active} → {damage,layer?,tier,engine} (the engine renders the strokes to a hole mask, closing loops, and passes it to PCIntelligence.remove; the hole grows 2 px; the selection limits what changes)"#,
            enabled: [.document, .layer, .editablePixelLayer, .capability(.inpaint)], capability: .inpaint, journal: true, job: true,
            photocraftSource: "crates/engine/src/retouch_cmds.rs"),
        CommandDescriptor(
            id: "edit.contentAwareFill", label: "Content-Aware Fill…", menu: ["Edit"], shortcut: nil,
            params: #"{"sampling":"auto|rectangular|custom"="auto","margin":px?,"area":[x,y,w,h]?,"output":"current|new|duplicate"="current","quality":"fast|best"="best"} → {layer,filled,window:[x,y,w,h],tier,engine} (colorAdaptation, rotationAdaptation, scale, mirror and seed steer PatchMatch: registered as a classical inpaint provider by PCAlgo)"#,
            enabled: [.document, .layer, .editablePixelLayer, .selection, .capability(.inpaint)], capability: .inpaint, journal: true, job: true,
            photocraftSource: "crates/engine/src/edit_menu_cmds.rs"),
        CommandDescriptor(
            id: "edit.generativeFill", label: "Generative Fill…", menu: ["Edit"], shortcut: nil,
            params: #"{"prompt":string="","sampleAllLayers":bool=true} → {layer,bounds,tier,engine,notes} (a new Generative Layer above the active layer, masked by the selection)"#,
            enabled: [.document, .selection, .capability(.generativeFill)], capability: .generativeFill, journal: true, job: true,
            photocraftSource: nil),
        CommandDescriptor(
            id: "filter.neuralFilters.colorize", label: "Colorize", menu: ["Filter", "Neural Filters"], shortcut: nil,
            params: #"{"variant":"fast|best|artistic"="best","output":"currentLayer|newLayer|newLayerMasked"="currentLayer"} → {layer,tier,engine}"#,
            enabled: [.document, .layer, .editablePixelLayer, .colorDocument, .capability(.colorize)], capability: .colorize, journal: true, job: true,
            photocraftSource: nil),
        CommandDescriptor(
            id: "filter.neuralFilters.photoRestoration", label: "Photo Restoration", menu: ["Filter", "Neural Filters"], shortcut: nil,
            params: #"{"scratchReduction":0..1=0.5,"noiseReduction":0..1=0.5,"enhanceFace":0..1=0.5,"output":"currentLayer|newLayer|newLayerMasked"="currentLayer"} → {layer,stages:[{capability,tier,engine,notes}]} (a stage whose model is missing is skipped and named)"#,
            enabled: [.document, .layer, .editablePixelLayer], capability: .restore, journal: true, job: true,
            photocraftSource: nil),
        CommandDescriptor(
            id: "filter.neuralFilters.jpegArtifactsRemoval", label: "JPEG Artifacts Removal", menu: ["Filter", "Neural Filters"], shortcut: nil,
            params: #"{"strength":"low|medium|high"="medium","output":"currentLayer|newLayer|newLayerMasked"="currentLayer"} → {layer,tier,engine,noiseSigma?}"#,
            enabled: [.document, .layer, .editablePixelLayer, .restoreJob(RestoreJob.denoise.rawValue)], capability: .restore, journal: true, job: true,
            photocraftSource: nil),
        CommandDescriptor(
            id: "filter.neuralFilters.smartPortrait", label: "Smart Portrait", menu: ["Filter", "Neural Filters"], shortcut: nil,
            params: #"{"faceRestore":0..1=1,"output":"currentLayer|newLayer|newLayerMasked"="currentLayer"} → {layer,tier,engine} (face restoration only)"#,
            enabled: [.document, .layer, .editablePixelLayer, .capability(.faceRestore)], capability: .faceRestore, journal: true, job: true,
            photocraftSource: nil),
        CommandDescriptor(
            id: "image.superResolution", label: "Super Resolution…", menu: ["Image"], shortcut: nil,
            params: #"{"factor":2..8=2,"sampleAllLayers":bool=true} → {document,width,height,appliedFactor,tier,engine} (a new document; Image Size's "resample":"preserveDetails2" runs the same upscale per surface)"#,
            enabled: [.document, .capability(.upscale)], capability: .upscale, journal: true, job: true,
            photocraftSource: nil),
        CommandDescriptor(
            id: "image.autoWhiteBalance", label: "Auto White Balance", menu: ["Image"], shortcut: nil,
            params: #"{"layer":id?=active,"output":"currentLayer|newLayer|newLayerMasked"="currentLayer"} → {layer,kelvin,tint,tier,engine}"#,
            enabled: [.document, .layer, .editablePixelLayer, .colorDocument, .capability(.whiteBalance)], capability: .whiteBalance, journal: true, job: true,
            photocraftSource: nil),
        CommandDescriptor(
            id: "image.sdrToHdr", label: "SDR to HDR…", menu: ["Image", "Mode"], shortcut: nil,
            params: #"{"diffuseWhite":80..10000 cd/m²=203,"deband":bool=true,"dither":bool=true,"sampleAllLayers":bool=true} → {document,peakNits,tier,engine} (a new 32-bit linear-sRGB document; 1.0 = 203 cd/m²)"#,
            enabled: [.document, .colorDocument, .capability(.hdrExpansion)], capability: .hdrExpansion, journal: true, job: true,
            photocraftSource: nil),
    ]

    /// The command with `id`.
    public static func command(_ id: String) -> CommandDescriptor? { all.first { $0.id == id } }

    /// Why `command` can't run in `context` (nil = it can): the first failing precondition's message,
    /// as photocraft's `enabled` returns it.
    public static func disabledReason(_ command: CommandDescriptor, in context: CommandContext) -> String? {
        for p in command.enabled {
            if let reason = check(p, context) { return reason }
        }
        return nil
    }

    /// Whether `command` can run in `context`.
    public static func isEnabled(_ command: CommandDescriptor, in context: CommandContext) -> Bool {
        disabledReason(command, in: context) == nil
    }

    static func check(_ p: CommandPrecondition, _ c: CommandContext) -> String? {
        switch p {
        case .document:
            return c.document == nil ? "no document open" : nil
        case .layer:
            guard let d = c.document else { return "no document open" }
            guard let id = c.activeLayer, d.layer(id) != nil else { return "no active layer" }
            return nil
        case .editablePixelLayer:
            guard let d = c.document, let id = c.activeLayer, let l = d.layer(id) else { return "no active layer" }
            guard case .raster = l.content else { return "the layer is \(l.content.article) \(l.content.kindName) layer, not a pixel layer" }
            let locks = d.effectiveLocks(id)
            if locks.pixels || locks.all { return "Could not complete your request because the layer \"\(l.name)\" is locked" }
            return nil
        case .selection:
            guard let d = c.document else { return "no document open" }
            guard let s = d.selection, !s.contentBounds.intersect(d.bounds).isEmpty else { return "make a selection first" }
            return nil
        case .colorDocument:
            guard let d = c.document else { return "no document open" }
            return d.mode.isGrayLike ? "needs an RGB, CMYK or Lab document" : nil
        case .capability(let cap):
            return c.registry.status(of: cap).reason
        case .restoreJob(let name):
            guard let job = RestoreJob(rawValue: name) else { return "unknown restore job \(name)" }
            return c.registry.status(of: job).reason
        }
    }
}
