// AB-T-0285: Layer › Layer Mask and clipping, where PixelAgencyEditor worked around PCEngine — Reveal Selection,
// Release Clipping Mask on a run, Ungroup of a folder something is clipped to, and the mask toggles' preconditions.
// Each is Photoshop's behaviour, measured in Photoshop 27 through scripting (PCEngine PORT-NOTES, AB-T-0285).

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct MaskAndClipTests {
    func doc(_ s: Session) throws -> Document { try #require(s.active?.doc) }

    @Test func revealSelectionUsesTheSelectionUp() throws {
        for command in ["layer.layerMask.revealSelection", "layer.layerMask.hideSelection"] {
            let s = try sessionWithDoc()
            let a = try newLayer(s, "A")
            try s.execute("select.rect", ["x": 4, "y": 4, "width": 20, "height": 20])
            let steps = pastCount(s)
            try s.execute(command, ["layer": .id(a)])
            #expect(try doc(s).selection == nil, "\(command)")
            #expect(try doc(s).layer(a)?.mask != nil, "\(command)")
            #expect(pastCount(s) == steps + 1 && s.active?.history.undoLabel == "Add Layer Mask", "\(command)")
            #expect(s.undo())
            #expect(try doc(s).selection != nil && doc(s).layer(a)?.mask == nil, "\(command): one step")
        }
    }

    /// Layers A–D above the Background, B, C and D clipped to A.
    func run() throws -> (Session, [LayerId]) {
        let s = try sessionWithDoc()
        let ids = try ["A", "B", "C", "D"].map { try newLayer(s, $0) }
        for id in ids.dropFirst() { try s.execute("layer.createClippingMask", ["layer": .id(id)]) }
        return (s, ids)
    }

    func clipped(_ s: Session, _ ids: [LayerId]) -> [Bool] { ids.map { s.active?.doc.layer($0)?.clipped ?? false } }

    @Test func releaseClippingMaskTakesTheLayersAboveOutToo() throws {
        let (s, ids) = try run()
        #expect(clipped(s, ids) == [false, true, true, true])
        let steps = pastCount(s)
        let r = try s.execute("layer.releaseClippingMask", ["layer": .id(ids[2])])
        #expect(clipped(s, ids) == [false, true, false, false], "C and D leave; B stays clipped to A")
        #expect(r["layers"] == .ids([ids[2], ids[3]]))
        #expect(pastCount(s) == steps + 1 && s.active?.history.undoLabel == "Release Clipping Mask")
        #expect(s.undo())
        #expect(clipped(s, ids) == [false, true, true, true])
        // The top of the run releases alone.
        try s.execute("layer.releaseClippingMask", ["layer": .id(ids[3])])
        #expect(clipped(s, ids) == [false, true, true, false])
        #expect(s.undo())
        // A base isn't clipped, and its group stays (Photoshop greys the item out for it).
        try s.execute("layer.releaseClippingMask", ["layer": .id(ids[0])])
        #expect(clipped(s, ids) == [false, true, true, true])
        // No `layer`: each selected layer, with the run above it.
        try s.execute("layer.select", ["layer": .id(ids[1])])
        let all = try s.execute("layer.releaseClippingMask")
        #expect(clipped(s, ids) == [false, false, false, false])
        #expect(all["layers"] == .ids([ids[1], ids[2], ids[3]]))
    }

    @Test func ungroupReleasesWhatWasClippedToTheFolder() throws {
        let s = try sessionWithDoc()
        let inside = try newLayer(s, "Inside")
        try s.execute("layer.groupLayers")
        let folder = try #require(s.active?.activeLayer)
        let top = try newLayer(s, "Top")
        #expect(try doc(s).path(of: top)?.count == 1, "Top is beside the folder")
        try s.execute("layer.createClippingMask", ["layer": .id(top)])
        #expect(ClipGroup.clippedTo(try doc(s), folder) == [top])
        let steps = pastCount(s)
        try s.execute("layer.ungroupLayers", ["layer": .id(folder)])
        #expect(try doc(s).layer(folder) == nil)
        #expect(try doc(s).layer(top)?.clipped == false, "its base went: released, not clipped to Inside")
        #expect(try doc(s).layer(inside)?.clipped == false)
        #expect(pastCount(s) == steps + 1 && s.active?.history.undoLabel == "Ungroup Layers")
        #expect(s.undo())
        #expect(try doc(s).layer(top)?.clipped == true)
    }

    @Test func maskTogglesAskTheLayerTheyAreGiven() throws {
        let s = try sessionWithDoc()
        let masked = try newLayer(s, "Masked")
        try s.execute("layer.layerMask.revealAll", ["layer": .id(masked)])
        let plain = try newLayer(s, "Plain")
        #expect(s.active?.activeLayer == plain)
        for (command, key) in [("layer.layerMask.enabled", "enabled"), ("layer.layerMask.linked", "linked")] {
            // The active layer has no mask: no param is refused, a named masked layer isn't.
            #expect(!s.isEnabled(command), "\(command)")
            #expect(throws: EngineError.self) { try s.execute(command) }
            #expect(s.isEnabled(command, ["layer": .id(masked)]), "\(command)")
            #expect(try s.execute(command, ["layer": .id(masked)])[key] == false, "\(command)")
            #expect(!s.isEnabled(command, ["layer": .id(plain)]), "\(command)")
            #expect(!s.isEnabled(command, ["layer": 999_999]), "\(command)")
        }
        let mask = try #require(try doc(s).layer(masked)?.mask)
        #expect(!mask.enabled && !mask.linked)
        // With the masked layer active, no param still works.
        try s.execute("layer.select", ["layer": .id(masked)])
        #expect(try s.execute("layer.layerMask.enabled")["enabled"] == true)
    }
}
