// A bundle written the way photocraft writes it opens here, and this port names the same content
// the same way (the evidence that photocraft's files open here and ours open there).
// Test of the port of photocraft-format, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.

import Foundation
@testable import PCFormat
import PCDocument
import PCFoundation
import PCIOCore
import Testing

@Suite struct PhotocraftBundleTests {
    static func bytes() throws -> [UInt8] {
        // photocraft's ZIP writer (ported as PCIOCore's `ZipWriter`): STORE entries, manifest first.
        var z = ZipWriter()
        try z.add("manifest.json", Array(PhotocraftBundle.manifest.utf8))
        for (path, b64) in PhotocraftBundle.objects { try z.add(path, [UInt8](try #require(Data(base64Encoded: b64)))) }
        return try z.finish()
    }

    static func tileBg() -> [UInt8] {
        var b: [UInt8] = []
        for y in 0 ..< 256 { for x in 0 ..< 256 { b += [UInt8((x >> 4) * 16), UInt8((y >> 4) * 16), 200, 255] } }
        return b
    }

    static func tilePaint() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 256 * 256 * 4)
        for y in 32 ..< 96 { for x in 32 ..< 96 { b.replaceSubrange((y * 256 + x) * 4 ..< (y * 256 + x) * 4 + 4, with: [255, UInt8((x - 32) * 4), 0, 255]) } }
        return b
    }

    static func tileMask() -> [UInt8] {
        (0 ..< 256 * 256).map { i in
            let (x, y) = (i % 256, i / 256)
            return (x - 128) * (x - 128) + (y - 128) * (y - 128) <= 80 * 80 ? 255 : 0
        }
    }

    static func tileChild() -> [UInt8] {
        var b: [UInt8] = []
        for y in 0 ..< 256 {
            for x in 0 ..< 256 {
                for v in [UInt16(x * 257), 0, UInt16(y * 257), 65535] { b += [UInt8(v & 0xFF), UInt8(v >> 8)] }
            }
        }
        return b
    }

    @Test func aBundleWrittenByPhotocraftOpens() throws {
        let doc = try PcraftFormat.load(try PhotocraftBundleTests.bytes())
        #expect(doc.name == "From photocraft")
        #expect(doc.id == DocId(1))
        #expect(doc.size == PixelSize(width: 300, height: 200))
        #expect(doc.resolutionDpi == 300)
        #expect(doc.mode == .rgb && doc.depth == .u8)
        #expect(doc.iccProfile == blob(1, 500))
        #expect(doc.metadata.exif == blob(15, 64))
        #expect(doc.metadata.xmp == "<x:xmpmeta/>")
        #expect(doc.metadata.psdResources == [PSDResource(id: 1036, name: "thumb", data: blob(16, 20))])
        #expect(doc.guides.horizontal == [10])
        #expect(doc.globalLight == GlobalLight(angle: 120, altitude: 30))
        #expect(doc.layers.map(\.name) == ["Background", "Paint", "Group", "Invert", "Exposure", "Fill", "Hi", "Smart"])

        let bg = doc.layers[0]
        #expect(bg.hasBackgroundTraits && doc.background?.id == bg.id)
        let bgs = try #require(bg.rasterSurface)
        #expect(bgs.tileCoords == [TileCoord(tx: 0, ty: 0), TileCoord(tx: 1, ty: 0)])
        #expect(bgs.tile(TileCoord(tx: 0, ty: 0))?.bytes == PhotocraftBundleTests.tileBg())
        #expect(bgs.tile(TileCoord(tx: 1, ty: 0))?.generation == bgs.tile(TileCoord(tx: 0, ty: 0))?.generation, "one stored tile, shared")

        let paint = doc.layers[1]
        #expect(paint.blend == .multiply && paint.opacity == 0.75 && paint.label == .red && paint.psdId == 42)
        #expect(paint.excludedChannels == 2)
        #expect(paint.rasterSurface?.tile(TileCoord(tx: 0, ty: 0))?.bytes == PhotocraftBundleTests.tilePaint())
        #expect(paint.rasterSurface?.pixel(x: 40, y: 40) == [1, Float(32) / 255, 0, 1])
        let mask = try #require(paint.mask)
        #expect(mask.surface.format == .gray8 && mask.surface.defaultPixel == [0])
        #expect(mask.surface.tile(TileCoord(tx: 0, ty: 0))?.bytes == PhotocraftBundleTests.tileMask())
        #expect(paint.effects.psdRaw == blob(3, 64))
        #expect(paint.effects.items == [.colorOverlay(.init(common: FxCommon(.normal, 0.5), color: .rgb(1, 0, 0)))])
        #expect(paint.psdBlocks == [PSDLayerBlock(key: "lnsr", data: blob(5, 4))])

        let group = doc.layers[2]
        #expect(group.blend == .passThrough && group.group?.expanded == false)
        let deep = try #require(group.children?.first)
        #expect(deep.name == "Deep")
        let ds = try #require(deep.rasterSurface)
        #expect(ds.format == .rgba16)
        #expect(ds.tile(TileCoord(tx: -1, ty: 2))?.bytes == PhotocraftBundleTests.tileChild())
        #expect(ds.pixel(x: -256 + 10, y: 512 + 20) == [Float(10 * 257) / 65535, 0, Float(20 * 257) / 65535, 1])

        #expect(doc.layers[3].adjustment == .invert && !doc.layers[3].visible)
        #expect(doc.layers[4].adjustment == .exposure(.init(exposure: 0.5, offset: 0, gamma: 1)))
        #expect(doc.layers[5].fill == .solid(.rgb(0.25, 0.5, 0.75, 1)) && doc.layers[5].blend == .screen)
        guard case .text(let t) = doc.layers[6].content else {
            Issue.record("text layer")
            return
        }
        #expect(t.text == "Hi ✓" && t.fontFamily == "Inter" && t.sizePt == 24 && t.color == .rgb(0, 0, 1))
        #expect(t.transform == .translate(10, 20) && t.shape == .point && t.antialias == .smooth)
        guard case .smart(let s) = doc.layers[7].content else {
            Issue.record("smart object")
            return
        }
        #expect(s.contentsId == SmartContentsId(77))
        #expect(s.source == .embedded(fileName: "inner.png", bytes: blob(11, 2000)))
        #expect(s.transform == .scale(0.5))
        #expect(s.smartFilters == [SmartFilter(command: "filter.blur.gaussian", params: ["radius": 2.5])])

        #expect(doc.channels.count == 1)
        #expect(doc.channels[0].name == "Alpha 1" && doc.channels[0].indicates == .maskedAreas && doc.channels[0].opacity == 0.5)
        #expect(doc.channels[0].surface.tile(TileCoord(tx: 0, ty: 0))?.bytes == PhotocraftBundleTests.tileMask())
    }

    /// Saving what was loaded names every tile and blob exactly as photocraft did: the same
    /// content gets the same BLAKE3 address, so photocraft finds our objects and we find its.
    @Test func theSameContentGetsPhotocraftsNames() throws {
        let original = try PhotocraftBundleTests.bytes()
        let doc = try PcraftFormat.load(original)
        let ours = try PcraftFormat.save(doc)
        let theirs = Set(try ZipReader(original).entries.map(\.name).filter { $0 != "manifest.json" })
        let mine = Set(try ZipReader(ours).entries.map(\.name).filter { $0 != "manifest.json" })
        #expect(mine == theirs)
        #expect(PcraftCodec.hash(PhotocraftBundleTests.tileBg()) == PhotocraftBundle.bgTileHash)
        #expect(PcraftCodec.hash(PhotocraftBundleTests.tilePaint()) == PhotocraftBundle.paintTileHash)
        #expect(PcraftCodec.hash(PhotocraftBundleTests.tileMask()) == PhotocraftBundle.maskTileHash)
        #expect(PcraftCodec.hash(PhotocraftBundleTests.tileChild()) == PhotocraftBundle.childTileHash)
        #expect(try PcraftFormat.load(ours) == doc)
    }

    /// Our manifest says what photocraft's says, in serde's shapes: re-encoding the decoded
    /// photocraft manifest gives back the same JSON value.
    @Test func ourManifestEncodingMatchesPhotocrafts() throws {
        let theirs = try JSONTree.parse(Array(PhotocraftBundle.manifest.utf8))
        let m = try ManifestJSON.decode(theirs)
        let ours = try JSONTree.parse(try ManifestJSON.encode(m))
        #expect(PhotocraftBundleTests.canonical(ours) == PhotocraftBundleTests.canonical(theirs))
    }

    /// A JSON value with object members sorted, `null` members dropped (serde reads a missing
    /// `Option` as `None`) and numbers compared by value.
    static func canonical(_ t: JSONTree) -> JSONTree {
        switch t {
        case .object(let m):
            return .object(m.filter { $0.value != .null }.map { JSONMember(key: $0.key, value: canonical($0.value)) }.sorted { $0.key < $1.key })
        case .array(let a): return .array(a.map(canonical))
        case .number(let s): return .number(String(Double(s) ?? .nan))
        default: return t
        }
    }
}
