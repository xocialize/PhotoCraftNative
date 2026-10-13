// Port of photocraft-io (crates/io/tests/smart_contents_identity.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Shared contents and independent placed layers through PSD/PSB persistence. The parts that need
// only the smart-object mapping are PCIOSmartTests' SmartMapTests and LinkedTests.
//
// The regenerated filter cache (`FEid`) needs the source placed on the canvas: PCAlgo's placement
// in the engine, whole-pixel translations here (MapsKit.placeTranslated).

import Foundation
import PCDocument
import PCFormat
import PCFoundation
import PCIOCore
import PCIOSmart
import PCPSD
import Testing
@testable import PCIO

@Suite struct SmartContentsIdentityTests {
    init() { ExportSweep.install() }
    static func fixture() throws -> Document {
        var source = Document(name: "contents", size: PixelSize(width: 2, height: 2), mode: .rgb, depth: .u8)
        var pixels = Surface(format: source.pixelFormat)
        pixels.fill(source.bounds, with: [1, 0, 0, 1])
        source.layers.append(Layer(name: "red", content: .raster(pixels)))
        let bytes = try PcraftFormat.save(source)
        var doc = Document(name: "instances", size: PixelSize(width: 12, height: 4), mode: .rgb, depth: .u8)
        let smart = SmartObject(source: .embedded(fileName: "contents.pcraft", bytes: bytes), transform: .identity, cache: pixels)
        doc.layers.append(Layer(name: "original", content: .smart(smart)))
        return doc
    }

    static func smart(_ doc: Document, _ name: String) throws -> SmartObject {
        let layer = try #require(doc.layers.first { $0.name == name }, "\(name) missing")
        guard case let .smart(sm) = layer.content else { throw PCIOError.unsupported("\(name) is no longer a smart object") }
        return sm
    }

    static func options() -> IOOptions {
        var o = MapsKit.options()
        o.placeSource = MapsKit.placeTranslated
        return o
    }

    /// A `liFE` (external file) item, version 7, whose file is missing, as Photoshop lays it out:
    /// the item header with no data, no open descriptor, the linked-file descriptor, the
    /// timestamp, a zero file size, then the child document id, modification time and lock flag.
    static func externalItem(uniqueID: String, fileName: String) -> PSDLinkedFile {
        var w = BEWriter()
        w.fourCC("liFE")
        w.u32(7)
        let id = Array(uniqueID.utf8.prefix(255))
        w.u8(UInt8(id.count))
        w.put(id)
        w.unicodeUnits(Array(fileName.utf16) + [0])
        w.fourCC("8BPB")
        w.fourCC("8BIM")
        w.u64(0)
        w.u8(0)
        let link = PSDDescriptor(classID: "ExternalFileLink")
            .with("descVersion", .integer(2))
            .with("Nm  ", Blocks.text(fileName))
            .with("fullPath", Blocks.text("/missing/\(fileName)"))
            .with("originalPath", Blocks.text("/missing/\(fileName)"))
            .with("relPath", Blocks.text(fileName))
        w.put(Blocks.versionedBytes(link))
        w.u32(2026)
        for v: UInt8 in [1, 1, 0, 0] { w.u8(v) }
        w.f64(0)
        w.u64(0)
        w.unicodeUnits([])
        w.f64(0)
        w.u8(0)
        return PSDLinkedFile(raw: Data(w.bytes))
    }

    static func roundTrip(_ doc: Document, _ ext: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> (PSDFile, Document) {
        let out = try MapsKit.export(doc, ext, options: options(), sourceLocation: sourceLocation)
        #expect(!out.warnings.contains { $0.contains("smart object written as pixels") }, "\(out.warnings)", sourceLocation: sourceLocation)
        let file = try PSDFile(bytes: out.bytes)
        let back = try MapsKit.importFile(out.bytes, ext, options: options()).document
        return (file, back)
    }

    static func sold(_ file: PSDFile, _ name: String) throws -> SmartMap.Placed {
        let data = try #require(MapsKit.layerBlock(file, name, "SoLd"), "\(name): SoLd")
        return try #require(SmartMap.parseSold(data), "\(name): SoLd parses")
    }

    static func gaussian(_ radius: Double) -> SmartFilter {
        SmartFilter(command: "filter.blur.gaussianBlur", params: .object(["radius": .number(radius)]), blend: .normal, opacity: 1, visible: true)
    }

    static func radius(_ f: SmartFilter?) -> Double? {
        if case let .object(o)? = f?.params, case let .number(r)? = o["radius"] { r } else { nil }
    }

    static func lnk2(_ f: PSDFile) -> [UInt8]? { f.globalBlocks.first { $0.key == "lnk2" }.map { [UInt8]($0.data) } }

    @Test func psdAndPSBKeepSharedContentsAndIdenticalIndependentCopiesDistinct() throws {
        var doc = try Self.fixture()
        var shared = doc.layers[0].duplicate()
        shared.name = "shared"
        shared.withSmartObject { sm in
            sm.transform = .translate(4, 0)
            sm.cache = sm.cache.map { $0.translated(dx: 4, dy: 0, content: $0.contentBounds) }
            sm.smartFilters.append(Self.gaussian(2))
        }
        var independent = doc.layers[0].duplicate()
        independent.name = "independent"
        independent.withSmartObject { $0.contentsId = .fresh() }
        doc.layers += [shared, independent]

        for ext in ["psd", "psb"] {
            let (file, back) = try Self.roundTrip(doc, ext)
            let a = try Self.sold(file, "original")
            let b = try Self.sold(file, "shared")
            let c = try Self.sold(file, "independent")
            #expect(a.idnt == b.idnt, "\(ext)")
            #expect(a.idnt != c.idnt, "\(ext)")
            #expect(Set([a.placed, b.placed, c.placed]).count == 3, "\(ext)")
            let payloads = file.globalBlocks.filter { $0.key == "lnk2" }.flatMap { Linked.parseLinkedFiles([UInt8]($0.data)) }
            #expect(payloads.count == 2, "\(ext)")
            #expect(payloads.first?.bytes == payloads.last?.bytes, "independent identical contents still have separate payload identities")
            #expect(try Self.smart(back, "original").contentsId == Self.smart(back, "shared").contentsId)
            #expect(try Self.smart(back, "original").contentsId != Self.smart(back, "independent").contentsId)
            #expect(try Self.smart(back, "shared").transform == .translate(4, 0))
            #expect(Self.radius(try Self.smart(back, "shared").smartFilters.first) == 2)
            #expect(try Self.smart(back, "original").smartFilters.isEmpty)
            #expect(try Self.smart(back, "independent").smartFilters.isEmpty)
        }
    }

    @Test func duplicatedImportedLayerKeepsSourceButGetsItsOwnPlacement() throws {
        let (before, imported) = try Self.roundTrip(try Self.fixture(), "psd")
        var doc = imported
        let originalFiles = try #require(Self.lnk2(before))
        var duplicate = doc.layers[0].duplicate()
        duplicate.name = "duplicate"
        duplicate.withSmartObject { $0.smartFilters.append(Self.gaussian(3)) }
        // An imported UUID may have been generated under a different allocator lifetime and equal
        // the duplicate's first candidate. Preserve it for the original even when emitted second.
        let old = try Self.sold(before, "original")
        let colliding = SmartMap.uuidFrom(Array("\(old.idnt):\(duplicate.id.rawValue)".utf8))
        let spec = SmartMap.PlacedSpec(idnt: old.idnt, placed: colliding, transform: .identity, perspective: nil, size: SIMD2(2, 2), dpi: 72, warp: nil, filterFX: nil)
        var w: [String] = []
        let originalRaw = SmartMap.soldBytes(old.descriptor, spec, &w)
        func pin(_ l: inout Layer) {
            l.withSmartObject { $0.psdRaw = originalRaw }
            for i in l.psdBlocks.indices where l.psdBlocks[i].key == "SoLd" { l.psdBlocks[i].data = originalRaw }
        }
        pin(&doc.layers[0])
        pin(&duplicate)
        doc.layers.append(duplicate)

        for reversed in [false, true] {
            var ordered = doc
            if reversed { ordered.layers.reverse() }
            let (after, back) = try Self.roundTrip(ordered, "psd")
            let original = try Self.sold(after, "original")
            let dup = try Self.sold(after, "duplicate")
            #expect(original.idnt == dup.idnt, "reversed \(reversed)")
            #expect(original.placed == colliding, "reversed \(reversed)")
            #expect(original.placed != dup.placed, "reversed \(reversed)")
            let feid = try #require(after.globalBlocks.first { $0.key == "FEid" }, "FEid (reversed \(reversed))")
            let cache = try PSDFilterEffects(bytes: feid.data)
            #expect(cache.items.count == 1)
            #expect(cache.items.first?.id == dup.placed)
            #expect(MapsKit.layerBlock(after, "original", "SoLd") == originalRaw)
            #expect(Self.lnk2(after) == originalFiles)
            #expect(try Self.smart(back, "original").contentsId == Self.smart(back, "duplicate").contentsId)
            #expect(Self.radius(try Self.smart(back, "duplicate").smartFilters.first) == 3)
            #expect(try Self.smart(back, "original").smartFilters.isEmpty)
        }
    }

    @Test func missingSourceIdentifiersDoNotJoinImportedContents() throws {
        var (file, _) = try Self.roundTrip(try Self.fixture(), "psd")
        let spec = SmartMap.PlacedSpec(idnt: "", placed: "placement", transform: .identity, perspective: nil, size: SIMD2(2, 2), dpi: 72, warp: nil, filterFX: nil)
        var w: [String] = []
        let data = SmartMap.soldBytes(nil, spec, &w)
        var record = try #require(file.layers.first)
        record.blocks.removeAll { ["SoLd", "SoLE", "PlLd"].contains($0.key) }
        record.blocks.append(PSDTaggedBlock(key: "SoLd", bytes: data))
        file.layers = [record, record]
        let doc = try MapsKit.psdToDocument(file)
        guard case let .smart(a) = doc.layers[0].content, case let .smart(b) = doc.layers[1].content else {
            Issue.record("smart objects missing")
            return
        }
        #expect(a.contentsId != b.contentsId)
        let (_, back) = try Self.roundTrip(doc, "psd")
        guard case let .smart(x) = back.layers[0].content, case let .smart(y) = back.layers[1].content else {
            Issue.record("smart objects lost on save")
            return
        }
        #expect(x.contentsId != y.contentsId)
    }

    /// An embedded item relabelled `liFE` (Photoshop refuses the whole file: PCPSD
    /// `linkedFileKindMismatch`) is written with the kind its layout reads as, with a warning.
    @Test func mislabelledLinkedItemsGetTheirOwnKind() throws {
        var (file, _) = try Self.roundTrip(try Self.fixture(), "psd")
        let i = try #require(file.globalBlocks.firstIndex { $0.key == "lnk2" })
        var data = [UInt8](file.globalBlocks[i].data)
        data.replaceSubrange(8 ..< 12, with: Array("liFE".utf8))
        file.globalBlocks[i].data = Data(data)
        let doc = try MapsKit.psdToDocument(file)
        let out = try ExportSweep.excluded { try DocumentIO.export(doc, as: "s.psd", options: Self.options()) }
        #expect(out.warnings.contains { $0.contains("labelled liFE but stored as liFD") }, "\(out.warnings)")
        let back = try PSDFile(bytes: out.bytes)
        let items = try PSDLinkedFiles(bytes: try #require(back.globalBlock("lnk2")).data).items
        #expect(items.allSatisfy { $0.strictInfo?.kind == "liFD" })
        #expect(!back.compatibilityIssues().contains { $0.rule == .linkedFileKindMismatch })
    }

    @Test func independentUnavailableLinkRetainsSeparatePreservedRecord() throws {
        var (file, _) = try Self.roundTrip(try Self.fixture(), "psd")
        let i = try #require(file.globalBlocks.firstIndex { $0.key == "lnk2" })
        // An external item whose file is missing: the source UUID is known, but no embedded bytes
        // can be loaded. Built in Photoshop's `liFE` layout (relabelling the embedded item in place,
        // as this fixture first did, is a mislabelled item Photoshop refuses the file for).
        let embedded = try #require(PSDLinkedFiles(bytes: file.globalBlocks[i].data).items.first?.strictInfo)
        file.globalBlocks[i].data = PSDLinkedFiles(items: [Self.externalItem(uniqueID: embedded.uniqueID, fileName: embedded.fileName)]).serialized()
        let data = [UInt8](file.globalBlocks[i].data)
        let originalRecord = data
        var doc = try MapsKit.psdToDocument(file)
        var independent = doc.layers[0].duplicate()
        independent.name = "independent"
        independent.withSmartObject {
            $0.contentsId = .fresh()
            $0.psdRaw = nil
        }
        independent.psdBlocks.removeAll { ["SoLd", "SoLE", "PlLd"].contains($0.key) }
        // Encounter the independent copy first: the original imported identity must keep its UUID.
        doc.layers.insert(independent, at: 0)

        let (after, back) = try Self.roundTrip(doc, "psd")
        #expect(try Self.sold(file, "original").idnt == Self.sold(after, "original").idnt)
        #expect(try Self.sold(after, "original").idnt != Self.sold(after, "independent").idnt)
        let links = try #require(Self.lnk2(after))
        #expect(links.starts(with: originalRecord))
        #expect(Linked.blockUuids(links).count == 2)
        #expect(try Self.smart(back, "original").contentsId != Self.smart(back, "independent").contentsId)
        let (again, _) = try Self.roundTrip(doc, "psd")
        #expect(try MapsKit.bytes(after) == MapsKit.bytes(again))
    }
}
