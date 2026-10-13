// Port of photocraft-io (crates/io/tests/smart_corpus.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Smart objects and smart filters through PSD export, over every file of the Photoshop corpus
// (PCPSD_CORPUS; skipped when absent) that has them. The block-level half (every `SoLd`/`lnk2`
// parses and writes back) is PCIOSmartTests' SmartCorpusTests.
//
// For each file: import → export → import must give back, layer for layer, a live smart object
// (not pixels) with the same embedded file (byte-identical), transform, filter list, filter
// switches and filter mask; every exported block re-parses strictly (`strictBlockErrors`). Then
// two edits must survive the same way: the first filter hidden at 40 % opacity in Multiply, and
// every source re-embedded from its bytes (new `lnk2` items, the old ones dropped).
// Deviation: photocraft requires at least 30 corpus files with smart objects (its corpus); the
// Photoshop corpus here has fewer, so at least one is required.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCIOSmart
import PCPSD
import Testing
@testable import PCIO

@Suite(.enabled(if: Corpus.available, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)")) struct SmartCorpusTests {
    init() { ExportSweep.install() }
    static func smarts(_ doc: Document) -> [(String, SmartObject)] {
        var out: [(String, SmartObject)] = []
        doc.forEachLayer { _, _, l in if case let .smart(sm) = l.content { out.append((l.name, sm)) } }
        return out
    }

    static func sourceFile(_ doc: Document, _ sm: SmartObject) -> [UInt8]? {
        switch sm.source {
        case let .embedded(_, bytes): bytes
        case let .linked(path): Linked.findLinkedFile(doc.metadata, path)?.bytes
        }
    }

    /// Mask coverage over `area` (nil = no mask: all ones).
    static func maskValues(_ sm: SmartObject, _ area: PixelRect) -> [Float] {
        guard let m = sm.filterMask else { return [Float](repeating: 1, count: area.area) }
        var v: [Float] = []
        m.values(area, into: &v)
        return v
    }

    /// Compares the smart objects of `a` and `b`; returns problems.
    static func compare(_ a: Document, _ b: Document, sameFiles: Bool) -> [String] {
        let (sa, sb) = (smarts(a), smarts(b))
        if sa.count != sb.count { return ["\(sa.count) smart objects became \(sb.count)"] }
        var errs: [String] = []
        for ((name, x), (_, y)) in zip(sa, sb) {
            switch (sourceFile(a, x), sourceFile(b, y)) {
            case let (p?, q?) where sameFiles && p != q: errs.append("\(name): embedded file changed")
            case (.some, nil): errs.append("\(name): embedded file lost")
            default: break
            }
            if x.smartFilters != y.smartFilters { errs.append("\(name): filters \(x.smartFilters) became \(y.smartFilters)") }
            if x.filtersEnabled != y.filtersEnabled { errs.append("\(name): filters enabled changed") }
            if zip(x.transform.m, y.transform.m).contains(where: { abs($0 - $1) > 1e-6 }) { errs.append("\(name): transform \(x.transform) became \(y.transform)") }
            if x.warp != y.warp { errs.append("\(name): warp changed") }
            let area = a.bounds
            if !x.smartFilters.isEmpty, maskValues(x, area) != maskValues(y, area) { errs.append("\(name): filter mask changed") }
            if x.filterMask.map({ "\($0.enabled) \($0.linked)" }) != y.filterMask.map({ "\($0.enabled) \($0.linked)" }) {
                errs.append("\(name): filter mask switches changed")
            }
        }
        return errs
    }

    static func options() -> IOOptions {
        // PCRender for the merged image (MapsKit's): these exports reach the Photoshop oracle.
        var o = MapsKit.options()
        o.placeSource = MapsKit.placeTranslated
        return o
    }

    static func roundTrip(_ doc: Document) -> Result<(Document, [UInt8]), PCIOError> {
        do {
            let out = try DocumentIO.export(doc, as: "psd", options: options())
            if let w = out.warnings.first(where: { $0.contains("smart object written as pixels") }) { return .failure(.unsupported(w)) }
            let errs = MapsKit.strictBlockErrors(out.bytes)
            if !errs.isEmpty { return .failure(.unsupported("strict structure: \(errs)")) }
            let back = try DocumentIO.importFile(name: "x.psd", bytes: out.bytes, options: options()).document
            return .success((back, out.bytes))
        } catch {
            return .failure(.unsupported("\(error)"))
        }
    }

    static func editFilters(_ doc: inout Document) -> Bool {
        var any = false
        doc.forEachLayerMut { l in
            l.withSmartObject { sm in
                guard !sm.smartFilters.isEmpty else { return }
                sm.smartFilters[0].visible.toggle()
                sm.smartFilters[0].opacity = 0.4
                sm.smartFilters[0].blend = .multiply
                any = true
            }
        }
        return any
    }

    static func reEmbed(_ doc: inout Document) -> Bool {
        let meta = doc.metadata
        var any = false
        doc.forEachLayerMut { l in
            guard case let .smart(sm) = l.content, case let .linked(path) = sm.source, let f = Linked.findLinkedFile(meta, path) else { return }
            l.withSmartObject {
                $0.source = .embedded(fileName: f.fileName, bytes: f.bytes)
                $0.psdRaw = nil
            }
            l.psdBlocks.removeAll { ["SoLd", "PlLd", "SoLE"].contains($0.key) }
            any = true
        }
        return any
    }

    @Test func smartObjectsRoundTripThroughPSD() throws {
        var (checked, objects, withFilters, edited, embedded) = (0, 0, 0, 0, 0)
        var failures: [String] = []
        for url in Corpus.files {
            let name = url.lastPathComponent
            let bytes = [UInt8](try Data(contentsOf: url))
            guard let imp = try? DocumentIO.importFile(name: name, bytes: bytes, options: Self.options()) else { continue }
            let doc = imp.document
            let n = Self.smarts(doc).count
            if n == 0 { continue }
            checked += 1
            objects += n
            withFilters += Self.smarts(doc).filter { !$0.1.smartFilters.isEmpty }.count
            func fail(_ what: String, _ e: String) { failures.append("\(name) (\(what)): \(e)") }
            switch Self.roundTrip(doc) {
            case let .success((back, _)): Self.compare(doc, back, sameFiles: true).forEach { fail("as imported", $0) }
            case let .failure(e): fail("as imported", "\(e)")
            }
            var ed = doc
            if Self.editFilters(&ed) {
                edited += 1
                switch Self.roundTrip(ed) {
                case let .success((back, _)): Self.compare(ed, back, sameFiles: true).forEach { fail("filters edited", $0) }
                case let .failure(e): fail("filters edited", "\(e)")
                }
            }
            var em = doc
            if Self.reEmbed(&em) {
                embedded += 1
                switch Self.roundTrip(em) {
                case let .success((back, out)):
                    Self.compare(em, back, sameFiles: true).forEach { fail("re-embedded", $0) }
                    // The old files are gone: one lnk2 item per distinct source.
                    let f = try PSDFile(bytes: out)
                    let items = f.globalBlocks.filter { ["lnk2", "lnk3", "lnkD", "lnkE"].contains($0.key) }.flatMap { Linked.blockUuids([UInt8]($0.data)) }
                    let used = Set(Self.smarts(back).compactMap { s -> String? in if case let .linked(p) = s.1.source { p } else { nil } })
                    if !used.allSatisfy({ items.contains($0) }) || items.count > used.count {
                        fail("re-embedded", "lnk2 items \(items) for sources \(used.sorted())")
                    }
                case let .failure(e): fail("re-embedded", "\(e)")
                }
            }
            print("\(name): \(n) smart objects")
        }
        print("smart objects through PSD: \(checked) files, \(objects) smart objects (\(withFilters) with filters); \(edited) filter edits, \(embedded) re-embeds; \(failures.count) failures")
        for f in failures { print("  FAIL \(f)") }
        #expect(checked >= 1, "no corpus files with smart objects")
        #expect(failures.isEmpty, "\(failures.prefix(6))")
    }
}
