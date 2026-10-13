// Native bundles preserve smart-object sharing without inferring it from equal source bytes;
// Image › Analysis data, notes and layer labels survive a round trip.
// Port of photocraft-format (crates/format/tests/smart_contents.rs, analysis.rs,
// layer_labels.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
@testable import PCFormat
import PCDocument
import PCFoundation
import Testing

@Suite struct SmartContentsTests {
    static func embedded(_ bytes: [UInt8]) -> Layer {
        Layer(name: "embedded", content: .smart(SmartObject(source: .embedded(fileName: "source.png", bytes: bytes), transform: .identity, cache: nil)))
    }

    static func linked(_ path: String) -> Layer {
        Layer(name: "linked", content: .smart(SmartObject(source: .linked(path: path), transform: .identity, cache: nil)))
    }

    static func sample() -> Document {
        var doc = Document(name: "contents identities", size: PixelSize(width: 1, height: 1), mode: .rgb, depth: .u8)
        let bytes: [UInt8] = [1, 2, 3]
        let first = embedded(bytes)
        let duplicate = first.duplicate()
        doc.layers.append(Layer.group("instances", [first, duplicate]))
        doc.layers.append(embedded(bytes))
        return doc
    }

    static func contentsIds(_ doc: Document) -> [SmartContentsId] {
        doc.walk().compactMap { e in
            if case .smart(let s) = e.layer.content { return s.contentsId }
            return nil
        }
    }

    static func removeContentsIds(_ layers: [Any]) -> [Any] {
        layers.map { l in
            guard var l = l as? [String: Any], var content = l["content"] as? [String: Any] else { return l }
            content["contents_id"] = nil
            if let children = content["children"] as? [Any] { content["children"] = removeContentsIds(children) }
            l["content"] = content
            return l
        }
    }

    static func layers(_ m: [String: Any]) -> [Any] { (m["document"] as? [String: Any])?["layers"] as? [Any] ?? [] }

    static func setLayers(_ m: inout [String: Any], _ layers: [Any]) {
        var d = m["document"] as? [String: Any] ?? [:]
        d["layers"] = layers
        m["document"] = d
    }

    @Test func smartContentsRoundtripPreservesSharedInstancesAndIndependentEqualBlobs() throws {
        let doc = SmartContentsTests.sample()
        let ids = SmartContentsTests.contentsIds(doc)
        #expect(ids[0] == ids[1], "ordinary layer duplicates share their contents")
        #expect(ids[0] != ids[2], "equal bytes do not imply shared contents")
        #expect(try load(try save(doc)) == doc)
    }

    @Test func smartContentsRemappingPreservesGroups() throws {
        let doc = SmartContentsTests.sample()
        let original = SmartContentsTests.contentsIds(doc)
        let back = try load(try save(doc), LoadOptions(preserveIds: false))
        let ids = SmartContentsTests.contentsIds(back)
        #expect(ids[0] == ids[1])
        #expect(ids[0] != ids[2])
        #expect(ids.allSatisfy { !original.contains($0) })
        #expect(back.id != doc.id)
        #expect(back.layers[0].id != doc.layers[0].id)
    }

    @Test func legacySmartContentsAreIndependentExceptForNonemptyLinkedPaths() throws {
        var doc = SmartContentsTests.sample()
        doc.layers += [SmartContentsTests.linked("/tmp/shared.psd"), SmartContentsTests.linked("/tmp/shared.psd"),
                       SmartContentsTests.linked("/tmp/other.psd"), SmartContentsTests.linked(""), SmartContentsTests.linked("")]
        let bytes = try save(doc)
        let legacy = try withManifest(bytes) { m in
            SmartContentsTests.setLayers(&m, SmartContentsTests.removeContentsIds(SmartContentsTests.layers(m)))
        }
        let back = try load(legacy)
        let ids = SmartContentsTests.contentsIds(back)
        #expect(ids[0] != ids[1], "legacy embedded duplicates have no recorded shared identity")
        #expect(ids[0] != ids[2])
        #expect(ids[1] != ids[2])
        #expect(ids[3] == ids[4])
        #expect(ids[3] != ids[5])
        #expect(ids[6] != ids[7], "an empty path identifies no shared source")
        // Allocated legacy identities become explicit on the next save.
        #expect(try load(try save(back)) == back)
    }

    @Test func storedSmartContentsIdsAreReservedBeforeAllocatingLegacyIds() throws {
        var doc = SmartContentsTests.sample()
        doc.layers.append(SmartContentsTests.linked("/tmp/source.psd"))
        let bytes = try save(doc)
        let stored = LayerId.fresh().rawValue + 5000
        let mixed = try withManifest(bytes) { m in
            var layers = SmartContentsTests.removeContentsIds(SmartContentsTests.layers(m))
            // This later, nested entry must be reserved before the first missing identity is minted.
            if var group = layers[0] as? [String: Any], var content = group["content"] as? [String: Any],
               var children = content["children"] as? [[String: Any]], var cc = children[1]["content"] as? [String: Any] {
                cc["contents_id"] = stored
                children[1]["content"] = cc
                content["children"] = children
                group["content"] = content
                layers[0] = group
            }
            SmartContentsTests.setLayers(&m, layers)
        }
        let back = try load(mixed)
        let ids = SmartContentsTests.contentsIds(back)
        #expect(ids[1] == SmartContentsId(stored))
        #expect(ids[0].rawValue > stored)
        #expect(ids[2].rawValue > stored)
        #expect(ids[3].rawValue > stored)
        #expect(LayerId.fresh().rawValue > stored)
    }

    @Test func extremeSmartContentsIdsRemapWithoutPoisoningAllocator() throws {
        let doc = SmartContentsTests.sample()
        let bytes = try save(doc)
        // UInt64.max is out of JSONSerialization's integer range: edit the text.
        let damaged = try rebuild(bytes) { name, data in
            guard name == "manifest.json" else { return data }
            var tree = try JSONTree.parse(data)
            var layers = tree["document"]["layers"]
            if case .array(var top) = layers, case .array(var children) = top[0]["content"]["children"] {
                for i in children.indices { children[i]["content"]["contents_id"] = .number(String(UInt64.max)) }
                top[0]["content"]["children"] = .array(children)
                layers = .array(top)
            }
            tree["document"]["layers"] = layers
            return tree.bytes
        }
        let back = try load(damaged)
        let ids = SmartContentsTests.contentsIds(back)
        #expect(ids[0] == ids[1])
        #expect(ids[0] != ids[2])
        #expect(back.id != doc.id)
        #expect(back.layers[0].id != doc.layers[0].id)
        #expect(ids.allSatisfy { $0.rawValue < UInt64.max / 2 })
        #expect(SmartContentsId.fresh().rawValue < UInt64.max / 2)
        #expect(LayerId.fresh().rawValue < UInt64.max / 2)
    }

    @Test func measurementAndNotesRoundtripAndDefaultWhenAbsent() throws {
        var doc = Document(name: "a", size: PixelSize(width: 40, height: 30), mode: .rgb, depth: .u16)
        doc.measurement.scale = MeasurementScale(pixelLength: 72, logicalLength: 1, units: "inches")
        doc.measurement.countGroups = [CountGroup(name: "Cells", color: .rgb(0, 0.5, 1), markerSize: 3, labelSize: 12, visible: true,
                                                  points: [SIMD2(1, 2), SIMD2(5.5, 6.5)])]
        doc.measurement.ruler = Ruler(start: SIMD2(1, 1), end: SIMD2(30, 20), protractor: SIMD2(1, 25))
        doc.notes = [Note(author: "A", text: "Fix the sky\nplease", position: SIMD2(10, 12), popup: SIMD4(10, 30, 200, 150), open: true)]
        let bytes = try save(doc)
        let back = try load(bytes)
        #expect(back.measurement == doc.measurement)
        #expect(back.notes == doc.notes)

        var v = try RoundtripTests.docJSON(try PcraftFormat.readManifest(bytes))
        v["measurement"] = nil
        v["notes"] = nil
        let old = try RoundtripTests.docM(v)
        #expect(old.measurement.isEmpty && old.notes.isEmpty)
    }

    @Test(arguments: allDepths)
    func layerLabelsPcraftRoundtripAllColorsAndDepths(depth: SampleType) throws {
        var doc = Document(name: "Labels", size: PixelSize(width: 2, height: 2), mode: .rgb, depth: depth)
        for color in LabelColor.all {
            var child = Layer.raster("Child", format: doc.pixelFormat)
            child.label = color
            var group = Layer.group(color.label, [child])
            group.label = color
            doc.layers.append(group)
        }
        let bytes = try save(doc)
        #expect(try load(bytes) == doc, "\(depth)")
        #expect(throws: (any Error).self) { try load(Array(bytes[..<(bytes.count / 2)])) }
    }
}
