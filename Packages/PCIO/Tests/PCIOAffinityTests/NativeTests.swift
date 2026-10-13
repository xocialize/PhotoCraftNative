// Port of photocraft-io (crates/io/tests/affinity.rs `mod native`, tests/affinity_artboards.rs with
// tests/support/current_affinity.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.
// Native import: artboards, shapes, paints. photocraft also saves the result (.pcraft, PSD, PNG)
// and compares composites; that needs the PCIO dispatch and a compositor, so these tests assert on
// the PhotoCraft layers (and on a shape cache drawn by a test renderer).

import Foundation
import PCAffinity
import PCAffinitySynth
@testable import PCIOAffinity
import PCDocument
import PCFoundation
import PCIOCore
import Testing

@Suite struct NativeTests {
    @Test func artboardsShapesAndPaintsImportAsEditableLayers() throws {
        for method in Synth.Method.allCases {
            let r = try importAF("native.af", ringDocument(method), renderer: CGShapeRenderer())
            #expect(r.sourceReadOnly && !r.previewOnly, "\(r.warnings)")
            #expect(r.warnings == [])
            let d = r.document
            #expect(d.size == PixelSize(width: 200, height: 100) && d.resolutionDpi == 144)
            #expect(d.mode == .rgb && d.depth == .u8)
            let board = d.layers[0]
            #expect(d.layers.count == 1, "a transparent spread has no Background")
            #expect(board.name == "Board")
            let ab = try #require(board.group?.artboard)
            #expect(ab.rect == PixelRect(x0: 20, y0: 10, x1: 140, y1: 90))
            #expect(ab.background == .custom(.white) && ab.preset == "")
            #expect(board.group?.expanded == false)
            let ring = try #require(board.children?.first)
            #expect(ring.name == "Ring")
            let sh = try #require(ring.shapeContent)
            #expect(sh.path.subpaths.count == 2)
            #expect(sh.path.subpaths[0].knots.count == 4, "the closing duplicate knot is merged")
            #expect(sh.path.subpaths[0].knots[0].anchor == PCPoint(20, 10))
            #expect(sh.path.subpaths.allSatisfy { $0.closed })
            #expect(sh.path.fillRule == .evenOdd && sh.path.subpaths[1].op == .join && sh.path.subpaths[0].op == .combine)
            #expect(sh.fill == .solid(.rgb(1, 0, 0, 1)))
            let stroke = try #require(sh.stroke)
            #expect(stroke.width == 4 && stroke.paint == .solid(.rgb(0, 0, 1, 1)) && stroke.align == .center && stroke.miterLimit == 4)
            #expect(stroke.dashes == [] && stroke.dashOffset == 0 && stroke.opacity == 1)
            // The cache shows the ring: red on it, empty in its hole.
            let cache = try #require(sh.cache)
            func px(_ x: Int32, _ y: Int32) -> [UInt8] { cache.readInterleaved(PixelRect(x0: x, y0: y, x1: x + 1, y1: y + 1)) }
            #expect(px(30, 20) == [255, 0, 0, 255])
            #expect(px(50, 40)[3] == 0, "even-odd hole")
        }
    }

    @Test func withoutARendererShapeCachesStayEmpty() throws {
        let r = try importAF("native.af", ringDocument(.stored))
        let ring = try #require(r.document.layers[0].children?.first?.shapeContent)
        #expect(ring.cache == nil)
    }

    @Test func aDamagedNativeDocumentFallsBackToItsPreviewWithTheReason() throws {
        var bytes = ringDocument(.zlib)
        bytes[80] ^= 0xFF
        let r = try importAF("broken.af", bytes)
        #expect(r.previewOnly && r.sourceReadOnly)
        #expect(r.warnings[0].contains("could not be read (damaged Affinity file"), "\(r.warnings[0])")
        #expect(r.document.size == PixelSize(width: 2, height: 1))
    }

    /// photocraft's proptest (256 cases): mutated stored and zstd documents never trap.
    @Test func mutatedNativeDocumentsNeverTrap() {
        var rng = SeededRNG(seed: 8)
        let stored = ringDocument(.stored), zstd = ringDocument(.zstd)
        for _ in 0..<256 {
            var b = Bool.random(using: &rng) ? stored : zstd
            for _ in 0..<Int.random(in: 1..<16, using: &rng) {
                b[Int.random(in: 0..<2048, using: &rng) % b.count] = UInt8.random(in: 0...255, using: &rng)
            }
            _ = try? AffinityImport.importDocument(name: "mutated.af", bytes: b, renderer: CGShapeRenderer(), codec: ImageIOCodec())
        }
    }

    // MARK: affinity_artboards.rs

    static func boards(_ d: Document) -> [String] {
        d.artboards.map { "\($0.name) \($0.artboard.rect)" }
    }

    @Test func currentPropertyArtboardsKeepBoundsClippingAndRoundtrips() throws {
        for marker in [Marker.legacy, .current] {
            for method in Synth.Method.allCases {
                let loaded = try importAF("synthetic.af", boardsDocument(marker, curve: false, method), renderer: CGShapeRenderer())
                #expect(!loaded.previewOnly && loaded.sourceReadOnly)
                let d = loaded.document
                #expect(d.size == PixelSize(width: 40, height: 16))
                #expect(Self.boards(d) == ["Board 100 \(PixelRect(x0: 0, y0: 0, x1: 16, y1: 16))", "Board 200 \(PixelRect(x0: 24, y0: 0, x1: 40, y1: 16))"])
                #expect(d.layers.allSatisfy { $0.artboard?.background == .transparent })
                // The overflowing child keeps its full outline: the artboard clips it (photocraft
                // checks the flattened PNG: red inside both boards, transparent between them).
                for (layer, x) in zip(d.layers, [0.0, 24.0]) {
                    let child = try #require(layer.children?.first)
                    #expect(child.name == "Overflow")
                    let sh = try #require(child.shapeContent)
                    #expect(sh.path.controlBounds == SIMD4(x - 4, -4, x + 20, 20))
                    #expect(sh.fill == .solid(.rgb(1, 0, 0, 1)))
                    // The cache is the whole outline, overflow into the gap between the boards included.
                    let gap: Int32 = x == 0 ? 18 : 22
                    #expect(bytes(sh.cache, PixelRect(x0: gap, y0: 0, x1: gap + 1, y1: 1)) == [255, 0, 0, 255])
                }
                #expect(loaded.warnings == [])
            }
        }
    }

    @Test func currentPropertiesMarkConvertedCurveArtboardsToo() throws {
        let loaded = try importAF("curves.af", boardsDocument(.current, curve: true, .stored))
        #expect(loaded.document.artboards.count == 2)
        #expect(loaded.warnings.contains { $0.contains("converted artboard outline") }, "\(loaded.warnings)")
        #expect(loaded.warnings == ["Affinity: not imported or approximated: a converted artboard outline (imported at its bounding box) (2×)."])
    }

    @Test func otherPropertiesDoNotTurnOrdinaryShapesIntoArtboards() throws {
        let d = try importAF("shapes.af", boardsDocument(.otherProperties, curve: false, .stored)).document
        #expect(!d.hasArtboards)
        // Each board is a shape clipping its child: a group masked by the outline.
        for l in d.layers {
            #expect(l.vectorMask != nil && l.children?.count == 2)
            #expect(l.children?.first?.shapeContent != nil && l.children?.first?.name == l.name)
        }
    }
}
