// Tests ported from photocraft-io (crates/io/src/displace_map.rs `#[cfg(test)]`), MIT OR
// Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
@testable import PCIOSmart
import PCPSD
import Testing

@Suite struct DisplaceMapTests {
    /// A `tdta` blob: `w`×`h`, horizontal plane `hOf(i)`, vertical `vOf(i)`, then `pad` zeros.
    static func tdta(_ w: UInt32, _ h: UInt32, _ hOf: (Int) -> UInt8, _ vOf: (Int) -> UInt8, _ pad: Int) -> [UInt8] {
        let n = Int(w * h)
        var b: [UInt8] = []
        b += withUnsafeBytes(of: h.littleEndian, Array.init)
        b += withUnsafeBytes(of: w.littleEndian, Array.init)
        b += withUnsafeBytes(of: DisplaceMap.modeTwoPlanes.littleEndian, Array.init)
        b += (0 ..< n).map(hOf)
        b += (0 ..< n).map(vOf)
        b += [UInt8](repeating: 0, count: pad)
        return b
    }

    /// A `filterFXList` item as Photoshop writes a Displace smart filter.
    static func item(_ map: [UInt8]) -> PSDDescriptor {
        PSDDescriptor(classID: "filterFX")
            .with("Nm  ", .text(.nulTerminated("Displace...")))
            .with("blendOptions", SmartMap.blendOptions(SmartMap.neutralFilter))
            .with("enab", .boolean(true))
            .with("hasoptions", .boolean(true))
            .with("Fltr", .descriptor(PSDDescriptor(classID: DID(DisplaceMap.className))
                    .with("HrzS", .integer(10))
                    .with("VrtS", .integer(10))
                    .with("DspM", SmartMap.enumv("DspM", "StrF"))
                    .with("UndA", SmartMap.enumv("UndA", "RptE"))
                    .with("DspF", .alias(Data("Macintosh HD:maps:displace.psd".utf8)))
                    .with("EmbF", .boolean(true))
                    .with(DisplaceMap.mapKey, .rawData(Data(map)))))
            .with("filterID", .integer(DisplaceMap.filterID))
    }

    static func withFltr(_ item: PSDDescriptor, _ edit: (inout PSDDescriptor) -> Void) -> PSDDescriptor {
        var i = item
        var f = SmartMap.getDesc(i, "Fltr") ?? PSDDescriptor()
        edit(&f)
        SmartMap.set(&i, "Fltr", .descriptor(f))
        return i
    }

    @Test func filterIDIsDspl() {
        #expect(DisplaceMap.filterID == 1_148_416_108)
    }

    @Test func parsesTheObservedLayout() throws {
        let b = Self.tdta(3, 2, { UInt8($0) }, { 100 + UInt8($0) }, 3)
        let m = try #require(DisplaceMap.parseMap(b))
        #expect(m.width == 3 && m.height == 2)
        #expect(Array(m.horizontal) == [0, 1, 2, 3, 4, 5])
        #expect(Array(m.vertical) == [100, 101, 102, 103, 104, 105])
    }

    @Test func hostileMapsAreRejectedWithoutTrapping() {
        let good = Self.tdta(4, 4, { UInt8($0) }, { UInt8($0) }, 0)
        for len in 0 ..< good.count {
            #expect(DisplaceMap.parseMap(Array(good[..<len])) == nil, "truncated to \(len)")
        }
        func header(_ h: UInt32, _ w: UInt32, _ mode: UInt16) -> [UInt8] {
            withUnsafeBytes(of: h.littleEndian, Array.init) + withUnsafeBytes(of: w.littleEndian, Array.init)
                + withUnsafeBytes(of: mode.littleEndian, Array.init) + [UInt8](repeating: 0, count: 64)
        }
        #expect(DisplaceMap.parseMap(header(.max, .max, 3)) == nil)
        #expect(DisplaceMap.parseMap(header(1 << 16, 1 << 16, 3)) == nil)
        #expect(DisplaceMap.parseMap(header(0, 4, 3)) == nil)
        #expect(DisplaceMap.parseMap(header(2, 2, 2)) == nil)
        #expect(DisplaceMap.parseMap(header(2, 2, 4)) == nil)
        #expect(DisplaceMap.parseMap(header(2, 2, 3)) != nil)
        // Corrupted bytes of a good blob.
        for seed in 0 ..< 512 {
            var b = good
            let i = (seed * 7) % b.count
            b[i] = b[i] &+ (UInt8(truncatingIfNeeded: seed) | 1)
            _ = DisplaceMap.parseMap(b)
            _ = DisplaceMap.embeddedMap([DisplaceMap.templateKey: .string(SmartMap.toHex(Self.item(b).serializedBytes()))])
        }
    }

    @Test func displaceItemsMapToTheCommandAndRoundTrip() throws {
        let src = Self.item(Self.tdta(4, 3, { UInt8($0 * 20) }, { UInt8($0 * 20) }, 4))
        let f = SmartMap.filterFromItem(src)
        #expect(f.command == DisplaceMap.command)
        #expect(f.params["horizontal"]?.doubleValue == 10 && f.params["fit"]?.stringValue == "stretch"
            && f.params["undefinedAreas"]?.stringValue == "repeat")
        #expect(try SmartMap.itemForFilter(f) == src, "unchanged settings write the original item back")
        let map = try #require(SmartMap.displaceEmbeddedMap(f.params))
        #expect(map.rect == PixelRect(x0: 0, y0: 0, x1: 4, y1: 3) && map.channels == 1)
        #expect(map.data[1] == Float(20) / 255)

        var edited = f
        var p = try #require(f.params.objectValue)
        p["horizontal"] = -25.4
        p["fit"] = "tile"
        p["undefinedAreas"] = "wrap"
        edited.params = .object(p)
        edited.opacity = 0.5
        let back = SmartMap.filterFromItem(try SmartMap.itemForFilter(edited))
        #expect(back.command == DisplaceMap.command)
        #expect(back.params["horizontal"]?.doubleValue == -25 && back.params["fit"]?.stringValue == "tile"
            && back.params["undefinedAreas"]?.stringValue == "wrap")
        #expect(back.opacity == 0.5)
        #expect(SmartMap.displaceEmbeddedMap(back.params) != nil, "the map survives")
    }

    @Test func differentPlanesDriveEachDirection() throws {
        let f = SmartMap.filterFromItem(Self.item(Self.tdta(2, 1, { _ in 255 }, { _ in 0 }, 0)))
        let map = try #require(SmartMap.displaceEmbeddedMap(f.params))
        #expect(map.channels == 3)
        #expect(Array(map.data[..<3]) == [1, 0, 0.5])
    }

    @Test func unreadableDisplaceFiltersStayOpaque() throws {
        let onlyAlias = Self.withFltr(Self.item([])) { $0.items.removeAll { $0.key.is(DisplaceMap.mapKey) } }
        let badEnum = Self.withFltr(Self.item(Self.tdta(2, 2, { _ in 0 }, { _ in 0 }, 0))) {
            SmartMap.set(&$0, "DspM", SmartMap.enumv("DspM", "Huh?"))
        }
        let wrongMode = Self.item(Array(Self.tdta(2, 2, { _ in 0 }, { _ in 0 }, 0)[..<8]) + [1, 0] + [UInt8](repeating: 0, count: 8))
        for src in [onlyAlias, badEnum, wrongMode, Self.item([1, 2, 3])] {
            let f = SmartMap.filterFromItem(src)
            #expect(f.command == SmartMap.unsupportedFilter)
            #expect(try SmartMap.itemForFilter(f) == src)
        }
    }

    @Test func badExportsReportErrors() throws {
        let ok = try #require(SmartMap.filterFromItem(Self.item(Self.tdta(2, 2, { _ in 0 }, { _ in 0 }, 0))).params.objectValue)
        func with(_ k: String, _ v: JSONValue) -> JSONValue {
            var p = ok
            p[k] = v
            return .object(p)
        }
        let notDisplace = PSDDescriptor(classID: "filterFX").with("filterID", .integer(DisplaceMap.filterID))
        for p: JSONValue in [
            .null,
            ["horizontal": 10],
            [DisplaceMap.templateKey: "zz"],
            [DisplaceMap.templateKey: 12],
            [DisplaceMap.templateKey: .string(SmartMap.toHex(notDisplace.serializedBytes()))],
            with("horizontal", "big"),
            with("fit", "squash"),
            with("mapPath", "/tmp/map.psd"),
        ] {
            #expect(throws: PCIOError.self, "\(p)") { try DisplaceMap.exportItem(p) }
        }
        let huge = String(repeating: "0", count: DisplaceMap.maxTemplateBytes * 2 + 2)
        #expect(DisplaceMap.embeddedMap([DisplaceMap.templateKey: .string(huge)]) == nil)
    }
}
