// Tests of `DocumentOp.setDocumentProperties`: guides, paths, slices, notes and the canvas size as
// reversible, rebaseable ops (architecture §6 of photocraft's design), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

import PCDocument
import PCFoundation
import Testing
@testable import PCHistory

@Suite struct DocumentPropertyOpsTests {
    func doc() -> (Document, LayerId) {
        var d = Document.withBackground(name: "props", size: PixelSize(width: 300, height: 200), mode: .rgb, depth: .u8, fill: .white)
        let a = d.insertAbove(nil, Layer.raster("A", format: d.pixelFormat))
        return (d, a)
    }

    var square: VectorPath {
        var p = VectorPath()
        p.subpaths = [.polygon([(1, 1), (9, 1), (9, 9)])]
        return p
    }

    /// Every field: applying sets it, the inverse restores it, and nothing else moves.
    @Test func eachFieldAppliesAndInverts() throws {
        let (d0, _) = doc()
        var guides = d0.guides
        guides.vertical.append(42.5)
        guides.setColor(vertical: true, position: 42.5, rgb: SIMD3(255, 0, 0))
        let paths = DocumentPaths(paths: [NamedPath(name: "Path 1", path: square)], workPath: square, clippingPath: ClippingPath(name: "Path 1"))
        var slices = d0.slices
        slices.list.append(Slice(id: 1, rect: PixelRect(x0: 10, y0: 10, x1: 60, y1: 40), name: "hero"))
        let notes = [Note(author: "me", text: "check", position: SIMD2(5, 6))]
        let cases: [(String, DocumentProperties, (Document) -> Bool)] = [
            ("guides", DocumentProperties(guides: guides), { $0.guides == guides }),
            ("paths", DocumentProperties(paths: paths), { DocumentPaths($0) == paths }),
            ("slices", DocumentProperties(slices: slices), { $0.slices == slices }),
            ("notes", DocumentProperties(notes: notes), { $0.notes == notes }),
            ("size", DocumentProperties(size: PixelSize(width: 640, height: 480)), { $0.size == PixelSize(width: 640, height: 480) }),
            ("all", DocumentProperties(size: PixelSize(width: 1, height: 2), guides: guides, paths: paths, slices: slices, notes: notes),
             { $0.size.height == 2 && $0.guides == guides && DocumentPaths($0) == paths && $0.slices == slices && $0.notes == notes }),
        ]
        for (name, props, check) in cases {
            var d = d0
            let inverse = try DocumentOp.setDocumentProperties(props).apply(to: &d)
            #expect(check(d), "\(name)")
            #expect(d.layers == d0.layers && d.selection == d0.selection && d.name == d0.name, "\(name)")
            guard case .setDocumentProperties(let back) = inverse else { Issue.record("\(name): \(inverse)"); continue }
            // The inverse carries exactly the fields the op set.
            #expect(back == props.current(in: d0), "\(name)")
            #expect((back.size == nil) == (props.size == nil) && (back.guides == nil) == (props.guides == nil), "\(name)")
            _ = try inverse.apply(to: &d)
            #expect(d == d0, "\(name)")
        }
        // Nothing set: nothing changes.
        var d = d0
        let none = try DocumentOp.setDocumentProperties(DocumentProperties()).apply(to: &d)
        #expect(d == d0)
        if case .setDocumentProperties(let p) = none { #expect(p.isEmpty) } else { Issue.record("\(none)") }
    }

    @Test func changesNameOnlyTheFieldsThatDiffer() {
        let (a, _) = doc()
        var b = a
        b.guides.horizontal = [3]
        b.workPath = square
        b.name = "renamed"
        let p = DocumentProperties.changes(from: a, to: b)
        #expect(p.guides == b.guides && p.paths == DocumentPaths(b))
        #expect(p.size == nil && p.slices == nil && p.notes == nil)
        #expect(DocumentProperties.changes(from: a, to: a).isEmpty)
        var c = a
        p.apply(to: &c)
        #expect(c.guides == b.guides && c.workPath == b.workPath && c.name == a.name)
    }

    /// A job computed from a snapshot re-applies onto the current document: only the fields it
    /// carries change, the layers, selection and other fields edited meanwhile stay, and its
    /// inverse puts back only what it replaced.
    @Test func rebasesOntoANewerDocument() throws {
        let (snapshot, a) = doc()
        // The job: a guide and a note, from the snapshot.
        var edited = snapshot
        edited.guides.vertical.append(100)
        edited.notes.append(Note(text: "from the job"))
        let job = EditTransaction("Guides and Notes", [.setDocumentProperties(DocumentProperties.changes(from: snapshot, to: edited))])
        // Meanwhile: a pixel edit, a new layer, a selection, a slice and a path.
        var current = snapshot
        current.withRaster(of: a) { $0.fill(PixelRect(x0: 0, y0: 0, x1: 8, y1: 8), with: [1, 0, 0, 1]) }
        let b = current.insertAbove(nil, Layer.raster("B", format: current.pixelFormat))
        var sel = Surface(format: .gray8)
        sel.fill(PixelRect(x0: 0, y0: 0, x1: 4, y1: 4), with: [1])
        current.selection = sel
        current.slices.list.append(Slice(id: 7, rect: PixelRect(x0: 0, y0: 0, x1: 50, y1: 50)))
        current.paths.append(NamedPath(name: "Mine", path: square))
        let meanwhile = current
        let inverse = try job.apply(to: &current)
        #expect(current.guides.vertical == [100] && current.notes.map(\.text) == ["from the job"])
        #expect(current.layer(b) != nil && current.layer(a)?.surface?.pixel(x: 3, y: 3) == [1, 0, 0, 1])
        #expect(current.selection == sel && current.slices.list.map(\.id) == [7] && current.paths.map(\.name) == ["Mine"])
        // Undoing the job keeps the other edits.
        try inverse.apply(to: &current)
        #expect(current == meanwhile)
        // Fields are replaced whole, as `setLayerProperties` replaces a layer's properties: a
        // guide added meanwhile is overwritten by the job's guides.
        var raced = meanwhile
        raced.guides.horizontal = [7]
        try job.apply(to: &raced)
        #expect(raced.guides == edited.guides)
    }

    @Test func commitsAsOneUndoableStepWithLayerOps() throws {
        var (d, a) = doc()
        var h = History()
        let original = d
        var props = try #require(d.layer(a)).properties
        props.name = "Renamed"
        let tx = EditTransaction("Canvas Size", [
            .setDocumentProperties(DocumentProperties(size: PixelSize(width: 400, height: 250))),
            .setLayerProperties(a, props),
        ])
        try h.commit(tx, to: &d, layers: .single(a))
        #expect(d.size == PixelSize(width: 400, height: 250) && d.layer(a)?.name == "Renamed")
        #expect(h.entries == ["Open", "Canvas Size"])
        #expect(try undoOrThrow(&h, d).doc == original)
        // A failing op later in the transaction leaves the properties untouched too.
        let broken = EditTransaction("Broken", [.setDocumentProperties(DocumentProperties(guides: Guides(horizontal: [1]))), .removeLayer(LayerId(.max))])
        #expect(throws: DocumentError.self) { try broken.apply(to: &d) }
        #expect(d.guides.isEmpty)
    }
}
