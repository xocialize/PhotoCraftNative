// Every type layer of the Photoshop corpus (`PCPSD_CORPUS`, skipped when absent): the model
// parses, and writing an unchanged imported layer re-imports to an equal model. The model part of
// photocraft-io's tests/text_corpus.rs (`corpus_text_layers`), MIT OR Apache-2.0, © ArtCraft Team
// and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCPSD
import Testing
@testable import PCIOText

@Suite(.enabled(if: Corpus.directory != nil, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)"))
struct CorpusTextTests {
    @Test func everyTyShImportsAndRoundTrips() throws {
        var blocks = 0, imported = 0, equal = 0, txt2Files = 0, txt2Layout = 0, styleSheets = 0
        var photoshopLayout = 0, photocraftLayout = 0, emptyText = 0, freshEqual = 0
        var failures: [String] = []
        for url in Corpus.files {
            let file = try PSDFile(contentsOf: url)
            let dpi = Float(file.resolution.map { $0.hRes } ?? 72)
            let txt2 = file.globalBlock("Txt2").flatMap { PSDText.parseTxt2([UInt8]($0.data)) }
            if let b = file.globalBlock("Txt2"), let parsed = txt2 {
                txt2Files += 1
                // Photoshop's `Txt2` layout, byte for byte.
                if PSDText.engineDataBareBytes(parsed.entries ?? []) == [UInt8](b.data) { txt2Layout += 1 }
            }
            for (i, record) in file.layers.enumerated() {
                guard let block = record.block("TySh") else { continue }
                blocks += 1
                let raw = [UInt8](block.data)
                let name = "\(url.lastPathComponent)#\(i)"
                guard var t = PSDText.textLayer(fromTySh: raw, dpi: dpi) else {
                    failures.append("\(name): does not import")
                    continue
                }
                imported += 1
                if let txt2 {
                    PSDText.applyTxt2(&t, tysh: raw, txt2: txt2)
                    PSDText.applyTxt2Frame(&t, tysh: raw, txt2: txt2)
                }
                // An empty type layer (blank engine text) whose `Txt2` object matches ends up with
                // no runs, as in photocraft (`apply_txt2` splits nothing); `charRuns()` covers it.
                if !t.text.isEmpty {
                    #expect(!t.runs.isEmpty, "\(name): no style runs")
                    #expect(t.runs.map(\.len).reduce(0, +) >= t.text.utf8.count, "\(name): runs cover the text")
                    #expect(t.runs.first.map { $0.style.sizePt > 0 && $0.style.postscriptName != nil } ?? false, "\(name)")
                } else {
                    emptyText += 1
                }
                if PSDStyles.readStyleSheets(raw, dpi: dpi) != nil { styleSheets += 1 }
                // The default EngineData writer reproduces Photoshop's bytes (photocraft's doesn't).
                if let pt = PSDText.parseTySh(raw), case let .rawData(ed)? = pt.text["EngineData"], let e = PSDText.engineData(pt.text) {
                    if PSDText.engineDataBytes(e) == [UInt8](ed) { photoshopLayout += 1 }
                    if PSDText.engineDataBytes(e, layout: .photocraft) == [UInt8](ed) { photocraftLayout += 1 }
                }
                // A fresh block (no `psdRaw`, no `Txt2`) for the layer as EngineData alone gives it.
                if let t0 = PSDText.textLayer(fromTySh: raw, dpi: dpi),
                   PSDText.textLayer(fromTySh: PSDText.buildTySh(t0, dpi: dpi, ink: nil), dpi: dpi) == t0 {
                    freshEqual += 1
                }
                // Write the unchanged imported layer (as the text engine does, from its `psdRaw`)
                // and read it back the way the importer does.
                var source = t
                source.psdRaw = raw
                let rebuilt = PSDText.buildTySh(source, dpi: dpi, ink: nil)
                guard var back = PSDText.textLayer(fromTySh: rebuilt, dpi: dpi) else {
                    failures.append("\(name): rebuilt block does not import")
                    continue
                }
                if let txt2 {
                    PSDText.applyTxt2(&back, tysh: rebuilt, txt2: txt2)
                    PSDText.applyTxt2Frame(&back, tysh: rebuilt, txt2: txt2)
                }
                if back == t {
                    equal += 1
                } else {
                    var diff: [String] = []
                    if back.text != t.text { diff.append("text") }
                    if back.charRuns() != t.charRuns() { diff.append("runs") }
                    if back.paragraphRuns() != t.paragraphRuns() { diff.append("paragraphs") }
                    if back.shape != t.shape { diff.append("shape") }
                    if back.transform != t.transform { diff.append("transform \(t.transform) → \(back.transform)") }
                    if back.orientation != t.orientation || back.antialias != t.antialias || back.warp != t.warp { diff.append("settings") }
                    if back.runs != t.runs || back.paragraphs != t.paragraphs { diff.append("raw runs") }
                    failures.append("\(name): re-import differs: \(diff.joined(separator: ", "))")
                }
            }
        }
        print("PCIOText corpus: \(Corpus.files.count) files, \(txt2Files) with Txt2 (\(txt2Layout) rewritten byte-exact); \(blocks) TySh blocks, \(imported) import, \(equal) re-import equal (\(emptyText) with empty text), \(freshEqual) equal from a fresh block; \(styleSheets) with style sheets; EngineData rewritten byte-exact: Photoshop layout \(photoshopLayout), photocraft layout \(photocraftLayout)")
        for f in failures { print("  \(f)") }
        #expect(imported == blocks)
        #expect(photoshopLayout == blocks, "the default writer reproduces Photoshop's EngineData")
        #expect(txt2Layout == txt2Files, "the default writer reproduces Photoshop's Txt2")
        #expect(equal == imported, "\(failures)")
    }

    /// The document resolution as photocraft's importer reads it (1005, per cm → per inch).
    static func dpi(_ file: PSDFile) -> Float {
        Float(file.resolution.map { $0.hRes } ?? 72)
    }

    /// #2374: an unedited save hands Photoshop back its own `Txt2`, byte for byte. The type layers
    /// are built as the importer builds them (`textLayer(fromTySh:)`, `applyTxt2`,
    /// `applyTxt2Frame`), numbered by their `TextIndex` (a duplicate or missing one takes the next
    /// free number), and `buildTxt2` with the file's block as `previous` must return it.
    @Test func unchangedTxt2IsWrittenBackByteForByte() throws {
        var files = 0, identical = 0
        var failures: [String] = []
        for url in Corpus.files {
            let file = try PSDFile(contentsOf: url)
            guard let block = file.globalBlock("Txt2") else { continue }
            files += 1
            let previous = [UInt8](block.data)
            let txt2 = try #require(PSDText.parseTxt2(previous), "\(url.lastPathComponent)")
            var objects: [(index: Int32, layer: TextLayer)] = []
            var pending: [TextLayer] = []
            var used = Set<Int32>()
            for record in file.layers {
                guard let b = record.block("TySh") else { continue }
                let tysh = [UInt8](b.data)
                guard var t = PSDText.textLayer(fromTySh: tysh, dpi: Self.dpi(file)) else { continue }
                PSDText.applyTxt2(&t, tysh: tysh, txt2: txt2)
                PSDText.applyTxt2Frame(&t, tysh: tysh, txt2: txt2)
                if let i = PSDText.textIndex(tysh), used.insert(i).inserted { objects.append((i, t)) } else { pending.append(t) }
            }
            var next: Int32 = 0
            for t in pending {
                while used.contains(next) { next += 1 }
                used.insert(next)
                objects.append((next, t))
            }
            let out = PSDText.buildTxt2(objects, previous: previous)
            if out == previous { identical += 1 } else { failures.append("\(url.lastPathComponent): \(previous.count) → \(out.count) bytes") }
        }
        print("PCIOText corpus Txt2: \(identical)/\(files) written back byte for byte")
        #expect(files > 0)
        #expect(identical == files, "\(failures)")
    }

    /// Unedited type layers are not rewritten: no style sheets to regenerate (`exportTySh` nil,
    /// after the importer's style pass), and `setTextIndex` changes nothing for the layer's own
    /// number and only the number otherwise.
    @Test func uneditedTyShIsNotRewritten() throws {
        var blocks = 0, exportNil = 0, sameIndex = 0, otherIndex = 0
        for url in Corpus.files {
            let file = try PSDFile(contentsOf: url)
            let dpi = Self.dpi(file)
            var doc = Document(name: "t", size: PixelSize(width: 16, height: 16), mode: .rgb, depth: .u8)
            doc.resolutionDpi = dpi
            var raws: [[UInt8]] = []
            for record in file.layers {
                guard let b = record.block("TySh"), var t = PSDText.textLayer(fromTySh: [UInt8](b.data), dpi: dpi) else { continue }
                t.psdRaw = [UInt8](b.data)
                raws.append([UInt8](b.data))
                doc.layers.append(Layer(name: "t\(raws.count)", content: .text(t)))
            }
            _ = TextStylesMap.importStyles(&doc)
            for (raw, layer) in zip(raws, doc.layers) {
                guard case let .text(t) = layer.content else { continue }
                blocks += 1
                if TextStylesMap.exportTySh(raw, t, doc.textStyles, dpi: dpi) == nil { exportNil += 1 }
                let own = try #require(PSDText.textIndex(raw))
                if PSDText.setTextIndex(raw, own) == raw { sameIndex += 1 }
                // Another number: the block differs from the file's in that item only.
                let moved = try #require(PSDText.setTextIndex(raw, own &+ 1))
                var expected = try PSDTypeTool(bytes: Data(raw))
                expected.text.descriptor.set("TextIndex", .integer(own &+ 1))
                if moved == [UInt8](expected.serialized()), moved.count == raw.count, PSDText.textIndex(moved) == own &+ 1 { otherIndex += 1 }
            }
        }
        print("PCIOText corpus TySh: \(blocks) blocks, exportTySh nil \(exportNil), setTextIndex same index unchanged \(sameIndex), other index only the index \(otherIndex)")
        #expect(blocks > 0)
        #expect(exportNil == blocks)
        #expect(sameIndex == blocks)
        #expect(otherIndex == blocks)
    }
}
