// Port of photocraft-io (crates/io/tests/annotations.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Notes (`Anno`) and the measurement scale (resource 1074) through PSD: verbatim while
// unchanged, regenerated after edits. The block-level halves are PCIOMapsTests'
// AnnotationsMapTests; these go through whole-file export and import.
// Not ported: `corpus_notes_import_and_verbatim_export` (photocraft's external corpus file
// ag-psd/read-write/annotations/src.psd; the Photoshop corpus here has no `Anno` block).

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCIOMaps
import PCPSD
import Testing
@testable import PCIO

@Suite struct AnnotationsTests {
    init() { ExportSweep.install() }
    static func toPSD(_ doc: Document, sourceLocation: SourceLocation = #_sourceLocation) throws -> [UInt8] {
        try MapsKit.export(doc, "x.psd", sourceLocation: sourceLocation).bytes
    }

    @Test(arguments: [SampleType.u8, .u16, .f32]) func measurementScaleRoundtripsThroughPSD(_ depth: SampleType) throws {
        var doc = Document.withBackground(name: "m", size: PixelSize(width: 16, height: 8), mode: .rgb, depth: depth, fill: .rgb(1, 1, 1))
        let f = try PSDFile(bytes: Self.toPSD(doc))
        #expect(f.resource(AnnotationsMap.measurementScale) == nil)
        doc.measurement.scale = MeasurementScale(pixelLength: 120, logicalLength: 3, units: "cm")
        doc.notes.append(Note(text: "n"))
        let back = try MapsKit.importFile(Self.toPSD(doc)).document
        #expect(back.measurement.scale == doc.measurement.scale)
        #expect(back.notes.count == 1)
        #expect(back.notes.first?.text == "n" && back.notes.first?.position == SIMD2(0, 0))
        // Unchanged → the preserved resource is written byte-exact (once).
        let again = try PSDFile(bytes: Self.toPSD(back))
        #expect(again.resources.filter { $0.id == AnnotationsMap.measurementScale }.count == 1)
    }

    /// A PSD `Anno` block with one text note whose icon rectangle is `[top, left, 0, 0]` and whose
    /// popup is all zeros (issue #939's fixture).
    static func annoWithIcon(_ top: Int32, _ left: Int32) -> [UInt8] {
        var entry = Array("txtA".utf8)
        entry.append(1) // open
        entry.append(0x1C) // flags
        entry += MapsKit.beBytes(UInt16(1)) // optional blocks
        for v in [top, left, 0, 0] { entry += MapsKit.beBytes(v) } // icon: top, left, bottom, right
        for _ in 0 ..< 4 { entry += MapsKit.beBytes(Int32(0)) } // popup
        entry += MapsKit.beBytes(UInt16(0)) // colour space: RGB
        for _ in 0 ..< 4 { entry += MapsKit.beBytes(UInt16(0)) }
        entry += [0, 0] // author: empty Pascal string
        entry += [0, 0] // name
        entry += [0, 0] // modification date
        let text: [UInt8] = [0xFE, 0xFF, 0x00, UInt8(ascii: "A")] // UTF-16BE "A"
        entry += MapsKit.beBytes(UInt32(text.count + 12))
        entry += Array("txtC".utf8)
        entry += MapsKit.beBytes(UInt32(text.count))
        entry += text
        var out = MapsKit.beBytes(UInt16(2)) + MapsKit.beBytes(UInt16(1))
        out += MapsKit.beBytes(UInt32(1)) // one annotation
        out += MapsKit.beBytes(UInt32(entry.count + 4))
        out += entry
        return out
    }

    static func psdWithAnno(_ anno: [UInt8]) throws -> [UInt8] {
        var doc = Document(name: "notes", size: PixelSize(width: 16, height: 16), mode: .rgb, depth: .u8)
        doc.layers.append(Layer.raster("Background", format: doc.pixelFormat))
        var file = try PSDFile(bytes: toPSD(doc))
        file.globalBlocks.append(PSDTaggedBlock(key: "Anno", data: Data(anno), padding: [UInt8](repeating: 0, count: (4 - anno.count % 4) % 4)))
        return try MapsKit.bytes(file)
    }

    /// Icon rectangle `[top, left, bottom, right]` of the first note in the exported `Anno` block.
    static func exportedIcon(_ doc: Document) throws -> [Int32] {
        let f = try PSDFile(bytes: toPSD(doc))
        let d = [UInt8](try #require(f.globalBlock("Anno")).data)
        // header (2 + 2 + 4), entry length (4), `txtA` (4), open (1), flags (1), optional (2).
        return (0 ..< 4).map { Int32(bitPattern: MapsKit.be32(d, 20 + $0 * 4)) }
    }

    /// Issue #939: a note whose stored icon top sits near Int32.max imported fine and then
    /// overflowed `y + 20` on every PSD save. The far edge saturates instead, so the note survives
    /// a round trip with representable geometry.
    @Test func aNoteIconNearInt32MaxSavesWithRepresentableGeometry() throws {
        func sat(_ a: Int32, _ b: Int32) -> Int32 { a.addingReportingOverflow(b).overflow ? (b > 0 ? .max : .min) : a + b }
        for (top, left) in [(Int32.max - 5, Int32(0)), (0, .max - 3), (.min, .min)] {
            let imp = try MapsKit.importFile(Self.psdWithAnno(Self.annoWithIcon(top, left)), "notes.psd")
            #expect(imp.document.notes.first?.position == SIMD2(Double(left), Double(top)))
            let icon = try Self.exportedIcon(imp.document)
            #expect(icon == [top, left, sat(top, 20), sat(left, 16)], "\(top),\(left)")
            let back = try MapsKit.importFile(Self.toPSD(imp.document), "notes.psd").document
            #expect(back.notes.first?.text == "A" && back.notes.first?.position == SIMD2(Double(left), Double(top)))
        }
        // The same through the model: a position a command could set beyond Int32 saturates, NaN is 0.
        var doc = Document(name: "notes", size: PixelSize(width: 16, height: 16), mode: .rgb, depth: .u8)
        doc.notes.append(Note(text: "far", position: SIMD2(1e300, .infinity)))
        #expect(try Self.exportedIcon(doc) == [.max, .max, .max, .max])
        doc.notes[0].position = SIMD2(.nan, -1e300)
        #expect(try Self.exportedIcon(doc) == [.min, 0, .min + 20, 16])
        // Control: an ordinary note is unchanged.
        doc.notes[0].position = SIMD2(42, 28)
        #expect(try Self.exportedIcon(doc) == [28, 42, 48, 58])
        let back = try MapsKit.importFile(Self.toPSD(doc)).document
        #expect(back.notes.first?.position == SIMD2(42, 28))
    }

    /// Issue #944: an `Anno` block the reader rejects opened as "no notes" without a word, and the
    /// next save deleted it. It now opens with a warning and is written back byte for byte.
    @Test func anUnreadableAnnoBlockWarnsAndSurvivesASave() throws {
        // The block declares two annotations but holds one.
        var broken = Self.annoWithIcon(28, 42)
        broken.replaceSubrange(4 ..< 8, with: MapsKit.beBytes(UInt32(2)))
        let imp = try MapsKit.importFile(Self.psdWithAnno(broken), "notes.psd")
        #expect(imp.document.notes.isEmpty)
        #expect(imp.warnings.contains { $0.contains("Anno") }, "\(imp.warnings)")
        // Damaged on purpose (Photoshop refuses it): not swept.
        let f = try PSDFile(bytes: ExportSweep.excluded { try Self.toPSD(imp.document) })
        #expect(f.globalBlock("Anno").map { [UInt8]($0.data) } == broken, "Anno block kept")
        // Control: the intact block reads with no warning.
        let ok = try MapsKit.importFile(Self.psdWithAnno(Self.annoWithIcon(28, 42)), "notes.psd")
        #expect(ok.document.notes.count == 1)
        #expect(!ok.warnings.contains { $0.contains("Anno") })
    }
}
