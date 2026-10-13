// Port of photocraft-engine (crates/engine/src/file_cmds/tests.rs `guide_layouts`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The shape layer comes from a direct edit instead of `shape.create` (shape_cmds); guide_layout.rs
// has no tests of its own, so a few of its refusals and the artboard target are checked too.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct GuideLayoutTests {
    func session(_ w: Int, _ h: Int) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": .int(w), "height": .int(h)])
        return s
    }

    @Test func guideLayouts() throws {
        let s = try session(100, 50)
        let r = try s.execute("view.newGuideLayout", ["columns": 2, "gutter": 10, "margin": [5, 10, 5, 10]])
        #expect(r["vertical"] == 4)
        var g = s.active!.doc.guides
        #expect(g.vertical == [10, 90, 45, 55])
        #expect(g.horizontal == [5, 45])
        try s.execute("view.newGuideLayout", ["rows": 2, "clearExisting": true])
        g = s.active!.doc.guides
        #expect(g.vertical.isEmpty)
        #expect(g.horizontal == [0, 25, 50])
        // Fixed-width centred columns.
        try s.execute("view.newGuideLayout", ["columns": 2, "width": 20, "gutter": 10, "centerColumns": true, "clearExisting": true])
        #expect(s.active!.doc.guides.vertical == [25, 45, 55, 75])
        #expect(throws: EngineError.self) { try s.execute("view.newGuideLayout", .object([:])) }
        #expect(try s.execute("view.clearCanvasGuides", .object([:]))["cleared"] == 4)
        #expect(s.active!.doc.guides.vertical.isEmpty)
        #expect(!s.isEnabled("view.newGuidesFromShape"))
        try s.edit("shape") { doc, active in
            let path = VectorPath([.polygon([(10, 10), (50, 10), (50, 30), (10, 30)])])
            let id = doc.insertAbove(nil, Layer(name: "Rectangle 1", content: .shape(ShapeLayer(path: path))))
            active = id
        }
        try s.execute("view.newGuidesFromShape", .object([:]))
        g = s.active!.doc.guides
        #expect(g.vertical == [10, 30, 50])
        #expect(g.horizontal == [10, 20, 30])
    }

    @Test func refusalsAndPreviewDoNotEdit() throws {
        let s = try session(100, 50)
        let past = s.active!.history.pastCount
        // The preview calculation never edits.
        let layout = try GuideLayoutCommands.calculate(s, ["columns": 4])
        #expect(layout.added.vertical.count == 5)
        #expect(s.active!.doc.guides.isEmpty)
        for p: JSONValue in [["columns": 1001], ["columns": 2.5], ["margin": [1, 2, 3]], ["margin": 60], ["columns": 2, "width": 80],
                             ["columns": 1, "clearExisting": "yes"], ["columns": 1, "target": "selectedArtboards"], ["columns": 1, "target": 3]] {
            #expect(throws: EngineError.self, "\(p.serialized())") { try s.execute("view.newGuideLayout", p) }
        }
        #expect(s.active!.history.pastCount == past)
    }

    @Test func selectedArtboardTarget() throws {
        let s = try session(100, 50)
        try s.execute("layer.new.artboard", ["rect": [200, 0, 40, 20]])
        try s.execute("view.newGuideLayout", ["columns": 2, "target": "selectedArtboards"])
        #expect(s.active!.doc.guides.vertical == [200, 220, 240])
        // Clear Canvas Guides leaves the guides inside the artboard (its edges are canvas guides).
        #expect(try s.execute("view.clearCanvasGuides", .object([:]))["cleared"] == 2)
        #expect(s.active!.doc.guides.vertical == [220])
    }
}
