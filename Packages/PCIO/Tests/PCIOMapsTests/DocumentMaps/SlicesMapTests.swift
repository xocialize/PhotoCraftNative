// Tests for SlicesMap. Port of photocraft-io (crates/io/src/slices_map.rs `#[cfg(test)]`), MIT OR
// Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
@testable import PCIOMaps
import PCPSD
import Testing

@Suite struct SlicesMapTests {
    @Test func slicesSurviveAPSDRoundTrip() throws {
        var d = Document(name: "site.psd", size: PixelSize(width: 120, height: 90), mode: .rgb, depth: .u8)
        var l = Layer.raster("Logo", format: d.pixelFormat)
        l.psdId = 5
        let lid = l.id
        d.layers.append(l)
        var hero = Slice(id: 1, rect: PixelRect(x0: 10, y0: 10, x1: 60, y1: 40), name: "hero")
        hero.url = "https://example.org"
        hero.alt = "Hero"
        d.slices.list.append(hero)
        var layerSlice = Slice(id: 2, origin: .layer, rect: PixelRect(x0: 70, y0: 50, x1: 100, y1: 80))
        layerSlice.layer = lid
        layerSlice.kind = .noImage
        layerSlice.outsets = SIMD4(1, 1, 1, 1)
        d.slices.list.append(layerSlice)
        let ids: [LayerId: UInt32] = [lid: 5]
        let (data, warning) = SlicesMap.exportResource(d, ids)
        #expect(warning == nil)
        let bytes = try #require(data.flatMap { $0 })
        // Read back into a copy of the document without slices.
        var back = d
        back.slices = Slices()
        back.metadata.psdResources.append(PSDResource(id: SlicesMap.slices, name: "", data: bytes))
        SlicesMap.importSlices(&back)
        #expect(back.slices.list == d.slices.list)
        #expect(back.slices.groupName == "site")
        #expect(SlicesMap.unchanged(back))
        let again = SlicesMap.exportResource(back, ids)
        #expect(again.resource == nil && again.warning == nil, "unchanged → keep the raw resource")
    }

    @Test func autoSliceIdsDoNotCollideWithMaximalStoredId() throws {
        var d = Document(name: "site.psd", size: PixelSize(width: 120, height: 90), mode: .rgb, depth: .u8)
        d.slices.list.append(Slice(id: .max, rect: PixelRect(x0: 10, y0: 10, x1: 20, y1: 20)))
        let (resource, warning) = SlicesMap.exportResource(d, [:])
        #expect(warning == nil)
        let data = try #require(resource.flatMap { $0 }, "a changed document writes a resource")
        let decoded = try PSDSlices(bytes: Data(data))
        let ids = decoded.slices.map(\.id)
        #expect(ids.contains(.max))
        #expect(ids.contains(1))
        #expect(Set(ids).count == ids.count)
    }

    @Test func layerSlicesWithoutTheirLayerBecomeUserSlices() throws {
        var d = Document(name: "x.psd", size: PixelSize(width: 40, height: 40), mode: .rgb, depth: .u8)
        var s = Slice(id: 3, origin: .layer, rect: PixelRect(x0: 0, y0: 0, x1: 10, y1: 10))
        s.layer = LayerId.fresh()
        s.background = SIMD4(255, 1, 2, 3)
        d.slices.list = [s]
        let bytes = try #require(SlicesMap.exportResource(d, [:]).resource.flatMap { $0 })
        let back = SlicesMap.slicesFromPSD(bytes, d)
        #expect(back.list.count == 1)
        #expect(back.list[0].origin == .user && back.list[0].layer == nil)
        #expect(back.list[0].background == SIMD4(255, 1, 2, 3))
        // Deleting every slice drops the resource; unreadable data reads as no slices.
        var none = d
        none.metadata.psdResources = [PSDResource(id: SlicesMap.slices, name: "", data: bytes)]
        none.slices = Slices()
        let dropped = SlicesMap.exportResource(none, [:])
        #expect(dropped.resource == .some(nil))
        #expect(SlicesMap.slicesFromPSD([0, 0, 0, 9], d) == Slices())
        #expect(SlicesMap.slicesFromPSD(nil, d) == Slices())
    }
}
