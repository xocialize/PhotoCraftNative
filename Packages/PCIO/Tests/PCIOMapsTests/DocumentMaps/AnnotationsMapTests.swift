// Tests for AnnotationsMap. Port of photocraft-io (crates/io/src/annotations_map.rs
// `#[cfg(test)]`, and the block-level parts of crates/io/tests/annotations.rs), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
@testable import PCIOMaps
import PCPSD
import Testing

@Suite struct AnnotationsMapTests {
    static func doc() -> Document { Document(name: "n", size: PixelSize(width: 10, height: 10), mode: .rgb, depth: .u8) }

    static func annoBlocks(_ data: [UInt8]) -> [PSDGlobalBlock] { [PSDGlobalBlock(signature: "8BIM", key: "Anno", data: data)] }

    @Test func exportBlocksKeepsReplacesAndDrops() throws {
        var d = Self.doc()
        #expect(AnnotationsMap.exportBlocks(d, []).isEmpty)
        d.notes.append(Note(author: "me", text: "héllo ✓", position: SIMD2(3, 4)))
        let out = AnnotationsMap.exportBlocks(d, [])
        #expect(out.count == 1)
        #expect(try #require(AnnotationsMap.parseAnno(out[0].data))[0].text == "héllo ✓")
        // Unchanged → the very same bytes.
        d.metadata.psdGlobalBlocks = out
        #expect(AnnotationsMap.exportBlocks(d, out) == out)
        d.notes.removeAll()
        #expect(AnnotationsMap.exportBlocks(d, out).isEmpty)
        #expect(AnnotationsMap.parseAnno([0, 2, 0, 1, 0, 0, 0, 9]) == nil)
    }

    /// Issue #944: an `Anno` block that doesn't parse was taken for "no notes" and dropped on save.
    @Test func exportBlocksKeepsAnUnreadableBlock() throws {
        var d = Self.doc()
        let bad = Self.annoBlocks([0, 2, 0, 1, 0, 0, 0, 9])
        d.metadata.psdGlobalBlocks = bad
        #expect(AnnotationsMap.annoUnreadable(d) && AnnotationsMap.notesFromBlocks(d).isEmpty)
        let out = AnnotationsMap.exportBlocks(d, bad)
        #expect(out == bad)
        // A note added by the user still writes a fresh block in its place.
        d.notes.append(Note(text: "new"))
        let fresh = AnnotationsMap.exportBlocks(d, bad)
        #expect(try #require(AnnotationsMap.parseAnno(fresh[0].data))[0].text == "new")
        // A readable block is not reported.
        d.metadata.psdGlobalBlocks = fresh
        #expect(!AnnotationsMap.annoUnreadable(d))
    }

    @Test func scaleResourceRoundtripAndKeepRules() throws {
        let s = MeasurementScale(pixelLength: 150, logicalLength: 2, units: "mm")
        #expect(AnnotationsMap.scaleFromResource(AnnotationsMap.writeScaleResource(s)) == s)
        var d = Self.doc()
        #expect(AnnotationsMap.freshScaleResource(d) == nil)
        // An unparseable resource stays while the scale is untouched.
        d.metadata.psdResources.append(PSDResource(id: AnnotationsMap.measurementScale, name: "", data: [0, 0, 0, 16, 1]))
        #expect(AnnotationsMap.keepResource(d, AnnotationsMap.measurementScale) && AnnotationsMap.freshScaleResource(d) == nil)
        d.measurement.scale = s
        #expect(!AnnotationsMap.keepResource(d, AnnotationsMap.measurementScale))
        #expect(AnnotationsMap.scaleFromResource(try #require(AnnotationsMap.freshScaleResource(d))) == s)
        #expect(AnnotationsMap.keepResource(d, AnnotationsMap.countInfo))
        d.measurement.countGroups.append(CountGroup(points: [SIMD2(1, 1)]))
        #expect(!AnnotationsMap.keepResource(d, AnnotationsMap.countInfo))
        #expect(AnnotationsMap.keepResource(d, 1005))
    }

    @Test func scaleIsFoundNestedAndUnderShortKeys() throws {
        let nested = PSDDescriptor(classID: "null").with("measurementScale", .descriptor(PSDDescriptor(classID: "scale")
                .with("PxlL", .integer(10)).with("LglL", .unitFloat(unit: "#Nne", value: 2.5)).with("LglU", .text("in"))))
        let s = try #require(AnnotationsMap.scaleFromResource(Blocks.versionedBytes(nested)))
        #expect(s == MeasurementScale(pixelLength: 10, logicalLength: 2.5, units: "in"))
        let noUnits = PSDDescriptor(classID: "null").with("pixelLength", .largeInteger(3)).with("logicalLength", .double(1))
        #expect(AnnotationsMap.scaleFromResource(Blocks.versionedBytes(noUnits))?.units == "pixels")
        #expect(AnnotationsMap.writeScaleResource(s).count % 2 == 0)
    }

    // MARK: Block-level parts of tests/annotations.rs

    /// An `Anno` block with one text note whose icon rectangle is `[top, left, 0, 0]` and whose popup
    /// is all zeros (issue #939's fixture).
    static func annoWithIcon(_ top: Int32, _ left: Int32) -> [UInt8] {
        func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        var entry: [UInt8] = Array("txtA".utf8)
        entry.append(1) // open
        entry.append(0x1C) // flags
        entry += [0, 1] // optional blocks
        for v in [top, left, 0, 0] { entry += be32(UInt32(bitPattern: v)) } // icon: top, left, bottom, right
        for _ in 0 ..< 4 { entry += be32(0) } // popup
        entry += [0, 0] // colour space: RGB
        entry += [UInt8](repeating: 0, count: 8)
        entry += [0, 0] // author: empty Pascal string
        entry += [0, 0] // name
        entry += [0, 0] // modification date
        let text: [UInt8] = [0xFE, 0xFF, 0x00, UInt8(ascii: "A")] // UTF-16BE "A"
        entry += be32(UInt32(text.count + 12))
        entry += Array("txtC".utf8)
        entry += be32(UInt32(text.count))
        entry += text
        return [0, 2, 0, 1] + be32(1) + be32(UInt32(entry.count + 4)) + entry
    }

    /// Icon rectangle `[top, left, bottom, right]` of the first note in the exported `Anno` block.
    static func exportedIcon(_ doc: Document) throws -> [Int32] {
        let d = try #require(AnnotationsMap.exportBlocks(doc, doc.metadata.psdGlobalBlocks).first { $0.key == "Anno" }).data
        // header (2 + 2 + 4), entry length (4), `txtA` (4), open (1), flags (1), optional (2).
        return (0 ..< 4).map { i in
            let at = 20 + i * 4
            return Int32(bitPattern: UInt32(d[at]) << 24 | UInt32(d[at + 1]) << 16 | UInt32(d[at + 2]) << 8 | UInt32(d[at + 3]))
        }
    }

    /// Issue #939: a note whose stored icon top sits near Int32.max overflowed `y + 20` on every
    /// save. The far edge saturates instead, so the note survives a round trip with representable
    /// geometry.
    @Test func aNoteIconNearInt32MaxSavesWithRepresentableGeometry() throws {
        for (top, left) in [(Int32.max - 5, Int32(0)), (0, .max - 3), (.min, .min)] {
            let notes = try #require(AnnotationsMap.parseAnno(Self.annoWithIcon(top, left)))
            #expect(notes[0].position == SIMD2(Double(left), Double(top)))
            var d = Self.doc()
            d.notes = notes
            let icon = try Self.exportedIcon(d)
            #expect(icon == [top, left, top.addingReportingOverflow(20).overflow ? .max : top + 20,
                             left.addingReportingOverflow(16).overflow ? .max : left + 16], "\(top),\(left)")
            let back = try #require(AnnotationsMap.parseAnno(AnnotationsMap.writeAnno(notes, [])))
            #expect(back[0].text == "A" && back[0].position == SIMD2(Double(left), Double(top)))
        }
        // The same through the model: a position a command could set beyond Int32 saturates, NaN is 0.
        var d = Self.doc()
        d.notes.append(Note(text: "far", position: SIMD2(1e300, .infinity)))
        #expect(try Self.exportedIcon(d) == [.max, .max, .max, .max])
        d.notes[0].position = SIMD2(.nan, -1e300)
        #expect(try Self.exportedIcon(d) == [.min, 0, .min + 20, 16])
        // Control: an ordinary note is unchanged.
        d.notes[0].position = SIMD2(42, 28)
        #expect(try Self.exportedIcon(d) == [28, 42, 48, 58])
        let back = try #require(AnnotationsMap.parseAnno(AnnotationsMap.writeAnno(d.notes, [])))
        #expect(back[0].position == SIMD2(42, 28))
    }

    /// Issue #944: a block declaring two annotations but holding one reads as unreadable, and is
    /// written back byte for byte.
    @Test func anUnreadableAnnoBlockSurvivesASave() throws {
        var broken = Self.annoWithIcon(28, 42)
        broken.replaceSubrange(4 ..< 8, with: [0, 0, 0, 2])
        var d = Self.doc()
        d.metadata.psdGlobalBlocks = Self.annoBlocks(broken)
        d.notes = AnnotationsMap.notesFromBlocks(d)
        #expect(d.notes.isEmpty && AnnotationsMap.annoUnreadable(d))
        #expect(AnnotationsMap.exportBlocks(d, d.metadata.psdGlobalBlocks).first?.data == broken)
        // Control: the intact block reads.
        var ok = Self.doc()
        ok.metadata.psdGlobalBlocks = Self.annoBlocks(Self.annoWithIcon(28, 42))
        #expect(AnnotationsMap.notesFromBlocks(ok).count == 1 && !AnnotationsMap.annoUnreadable(ok))
    }

    /// Text, line ends, colours (RGB, HSB, CMYK, gray), sound entries and padding.
    @Test func notesRoundtripAndSoundEntriesAreCarriedOver() throws {
        let n = Note(author: "Ann", color: .rgb(0.25, 0.5, 1), text: "line 1\nline 2\r\nline 3", position: SIMD2(5, 6),
                     popup: SIMD4(1, 2, 3, 4), open: true, modified: "D:20260101")
        let sound: [UInt8] = [0, 0, 0, 12] + Array("sndA".utf8) + [9, 9, 9, 9]
        let block = AnnotationsMap.writeAnno([n], [sound])
        let entries = try #require(AnnotationsMap.parseEntries(block))
        #expect(entries.count == 2)
        guard case let .raw(r) = entries[1] else {
            Issue.record("sound entry not kept raw")
            return
        }
        #expect(r == sound)
        let back = try #require(AnnotationsMap.parseAnno(block))
        #expect(back.count == 1)
        #expect(back[0].text == "line 1\nline 2\nline 3")
        #expect(back[0].author == "Ann" && back[0].modified == "D:20260101" && back[0].open)
        #expect(back[0].popup == n.popup && back[0].position == n.position)
        #expect(abs(back[0].color.rgb.y - 0.5) < 1e-4)
        // Editing a note keeps the sound entry.
        var d = Self.doc()
        d.metadata.psdGlobalBlocks = Self.annoBlocks(block)
        d.notes = back
        d.notes[0].text = "changed"
        let out = AnnotationsMap.exportBlocks(d, d.metadata.psdGlobalBlocks)
        #expect(try #require(AnnotationsMap.parseEntries(out[0].data)).count == 2)
        // Deleting the note keeps a block for the sound entry.
        d.notes = []
        let soundOnly = AnnotationsMap.exportBlocks(d, d.metadata.psdGlobalBlocks)
        #expect(soundOnly.count == 1 && AnnotationsMap.parseAnno(soundOnly[0].data) == [])
        // Colour spaces of the note colour struct.
        #expect(AnnotationsMap.colorFrom(8, [10000, 0, 0, 0]) == .rgb(0, 0, 0))
        #expect(AnnotationsMap.colorFrom(2, [65535, 0, 65535, 65535]) == .rgb(1, 0, 1))
        let pink = AnnotationsMap.colorFrom(1, [62441, 32112, 65535, 0]).rgb
        #expect(pink.x > 0.99 && pink.y < pink.z && pink.z < 0.7, "\(pink)")
        // Latin-1 author names; characters beyond Latin-1 become `?`.
        var named = n
        named.author = "Zoë ✓"
        #expect(try #require(AnnotationsMap.parseAnno(AnnotationsMap.writeAnno([named], [])))[0].author == "Zoë ?")
        // A zero-length entry cannot make progress: the block is unreadable (photocraft would loop).
        #expect(AnnotationsMap.parseAnno([0, 2, 0, 1, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0, 0x73, 0x6E, 0x64, 0x41]) == nil)
    }
}
