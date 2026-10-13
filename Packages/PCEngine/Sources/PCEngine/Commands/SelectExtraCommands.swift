// Port of photocraft-engine (crates/engine/src/select_extra_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Select › Sky, Select › Isolate Layers and Select › Transform Selection. Isolate Layers toggles
// the Layers panel's isolation filter (per-document view state: only the layers selected when it
// was turned on are listed). Sky (PCAlgo's classical sky segmentation, `SelectSky`) and Transform
// Selection (the selection mask through a homography or a warp, PCAlgo's resamplers) are in
// SelectExtraCommands+Algo.swift.

import PCDocument
import PCFoundation

public enum SelectExtraCommands: CommandModule {
    public static let name = "select_extra_cmds"
    static let m = "select_extra_cmds"

    public static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("select.sky", "Sky", menu: ["Select"],
                          params: #"{"mode":"replace|add|subtract|intersect"="replace","sampleAllLayers":bool=true,"threshold":0..100=50 (higher = stricter),"softness":0..100=50 (edge softness)} → {selected, changed, coverage (0–1 of the canvas), bounds [x,y,w,h]}"#,
                          module: m, enabled: hasDoc, run: selectSky))
        r.add(CommandSpec("select.isolateLayers", "Isolate Layers", menu: ["Select"],
                          params: #"{"on":bool? (default: toggle)} — Layers panel lists only the selected layers → {isolated, layers}"#,
                          module: m, journal: false, enabled: hasLayer, run: isolateLayers))
        r.add(CommandSpec("select.transformSelection", "Transform Selection", menu: ["Select"],
                          params: #"{"rect":[x0,y0,x1,y1]? (frame; default = selection bounds),"quad"|"corners":[[x,y]×4]? (where the frame's corners go: distort/perspective),"matrix":[a,b,c,d,e,f]?,"scaleX":%=100,"scaleY":%=100,"rotate":deg=0,"skewX":deg=0,"skewY":deg=0,"dx":px=0,"dy":px=0,"reference":"center|topLeft|top|topRight|left|right|bottomLeft|bottom|bottomRight"|[x,y]="center","style"|"mesh"|"grid"|"warp":… (warp, as edit.transform.warp),"interpolation":"bilinear|bicubic|nearest"="bilinear"}"#,
                          module: m, enabled: hasSelection, run: transformSelection))
        r.hooks.documentInspectors.append { st, o in o["isolatedLayers"] = .ids(st.view[IsolatedLayersKey.self]) }
    }

    /// The layers the Layers panel is isolated to (photocraft `DocState::isolated_layers`); empty
    /// = not isolated. View state, not history.
    public enum IsolatedLayersKey: StateKey { public static let defaultValue: [LayerId] = [] }

    static let hasLayer: CommandEnabled = { s, _ in s.active?.activeLayer == nil ? "no active layer" : nil }
    static let hasDoc: CommandEnabled = { s, _ in s.active == nil ? "no document open" : nil }
    static let hasSelection: CommandEnabled = { s, _ in s.active?.doc.selection == nil ? "no selection" : nil }

    static func isolateLayers(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        try s.updateActive { st -> JSONValue in
            let on = p["on"]?.boolValue ?? st.view[IsolatedLayersKey.self].isEmpty
            st.view[IsolatedLayersKey.self] = on ? st.selectedLayers : []
            st.revision += 1
            let layers = st.view[IsolatedLayersKey.self]
            return ["isolated": .bool(!layers.isEmpty), "layers": .ids(layers)]
        }
    }

    /// Whether a Layers panel row for `id` is listed under isolation (ancestors of an isolated
    /// layer stay visible so it can be shown in place).
    public static func isolationShows(_ doc: Document, _ isolated: [LayerId], _ id: LayerId) -> Bool {
        if isolated.isEmpty || isolated.contains(id) { return true }
        func contains(_ l: Layer) -> Bool {
            guard case .group(let g) = l.content else { return false }
            return g.children.contains { isolated.contains($0.id) || contains($0) }
        }
        return doc.layer(id).map(contains) ?? false
    }
}
