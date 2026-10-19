// AB-T-0255: the manifest's tile lists are written straight into its text, not through JSONEncoder and JSONTree. The
// text must be byte for byte what the old path wrote. MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.

import Foundation
@testable import PCFormat
import PCDocument
import PCFoundation
import Testing

@Suite struct ManifestTileListTests {
    /// The manifest text as it was written before AB-T-0255: every layer through JSONEncoder (tile lists included),
    /// parsed into a JSONTree, written pretty.
    static func legacy(_ m: Manifest) throws -> [UInt8] {
        let e = ManifestJSON.encoder()
        func tree<T: Encodable>(_ v: T) throws -> JSONTree { try JSONTree.parse([UInt8](try e.encode(v))) }
        func layer(_ l: LayerM) throws -> JSONTree {
            var shallow = l, kids: [JSONTree] = []
            if case .group(var g) = l.content {
                kids = try g.children.map(layer)
                g.children = []
                shallow.content = .group(g)
            }
            var t = try tree(shallow)
            if case .group = l.content { t["content"]["children"] = .array(kids) }
            return t
        }
        var shallow = m
        shallow.document.layers = []
        var t = try tree(shallow)
        t["document"]["layers"] = .array(try m.document.layers.map(layer))
        var out: [UInt8] = []
        t.writePretty(&out, indent: 0)
        return out
    }

    static func manifest(_ doc: Document) throws -> Manifest { try PcraftWriter().prepareWithModel(doc, SaveOptions()).model }

    @Test(arguments: allModes, allDepths) func manifestsAreTheBytesTheEncoderWrote(_ mode: ColorMode, _ depth: SampleType) throws {
        let m = try Self.manifest(richDoc(mode, depth))
        var tiles = 0
        Convert.forEachSurface(m.document) { tiles += $0.tiles.count }
        #expect(tiles > 10)
        #expect(try ManifestJSON.encode(m) == Self.legacy(m))
    }

    @Test func nestedGroupsNegativeTilesAndPlaceholderLikeNames() throws {
        var doc = RoundtripTests.nestedDoc(12, .u8)
        var odd = Layer.raster("pcraft-tiles-0\"\n\\ \u{1}", format: doc.pixelFormat)
        odd.withRaster { $0.fill(PixelRect(x0: -700, y0: -300, x1: 20, y1: 10), with: [0.5, 0.25, 1, 1]) }
        let empty = Layer.raster("\"pcraft-tiles-1\"", format: doc.pixelFormat)
        doc.layers += [odd, empty]
        doc.name = "pcraft-tiles-"
        let m = try Self.manifest(doc)
        let text = try ManifestJSON.encode(m)
        #expect(text == (try Self.legacy(m)))
        #expect(String(decoding: text, as: UTF8.self).contains("\"tx\": -3,"))
        #expect(try ManifestJSON.decode(JSONTree.parse(text)) == m)
    }

    /// No placeholder is left behind, and a manifest with no tiles at all comes out unchanged.
    @Test func everyPlaceholderIsReplaced() throws {
        let m = try Self.manifest(richDoc(.rgb, .u16))
        let text = String(decoding: try ManifestJSON.encode(m), as: UTF8.self)
        #expect(!text.contains("pcraft-tiles-"))
        let blank = try Self.manifest(Document(name: "Blank", size: PixelSize(width: 3, height: 2), mode: .rgb, depth: .u8))
        #expect(try ManifestJSON.encode(blank) == Self.legacy(blank))
    }
}
