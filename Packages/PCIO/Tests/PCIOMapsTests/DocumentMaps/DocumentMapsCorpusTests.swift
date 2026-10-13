// The DocumentMaps mappings over the Photoshop corpus (read from PCPSD_CORPUS, default the scratch
// corpus; skipped when absent). Map-level counterpart of photocraft-io's corpus checks in
// crates/io/tests/vector.rs (`corpus_vector_blocks_survive_roundtrip`) and the comps/slices corpus
// tests (MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors).

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
@testable import PCIOMaps
import PCPSD
import Testing

/// Where the corpus lives (a separate type: the suite's trait cannot refer to the suite itself).
private enum DocMapsCorpus {
    /// `PCPSD_CORPUS`, default `<fixtures>/psd-corpus` (`Fixtures`); nil when absent.
    static var directory: URL? { Fixtures.psdCorpus }

    static var files: [URL] {
        guard let dir = directory, let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { ["psd", "psb"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

@Suite(.enabled(if: DocMapsCorpus.directory != nil, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)"))
struct DocumentMapsCorpusTests {
    struct Opened {
        var name: String
        var file: PSDFile
        var w: UInt32
        var h: UInt32
        var dpi: Float
    }

    static func open() throws -> [Opened] {
        try DocMapsCorpus.files.map { url in
            let f = try PSDFile(contentsOf: url)
            return Opened(name: url.lastPathComponent, file: f, w: f.header.width, h: f.header.height, dpi: Float(f.resolution?.hRes ?? 72))
        }
    }

    /// A document standing in for the import: one empty pixel layer per record (with its `lyid` and
    /// preserved blocks), plus the preserved resources and global blocks.
    static func document(_ o: Opened) -> Document {
        var d = Document(name: o.name, size: PixelSize(width: Int(o.w), height: Int(o.h)), mode: .rgb, depth: .u8)
        for r in o.file.layers where r.kind != .groupEnd {
            var l = Layer.raster(r.displayName, format: .rgba8)
            if let b = r.block("lyid"), b.data.count >= 4 {
                let v = [UInt8](b.data)
                l.psdId = UInt32(v[0]) << 24 | UInt32(v[1]) << 16 | UInt32(v[2]) << 8 | UInt32(v[3])
            }
            l.psdBlocks = r.blocks.map { PSDLayerBlock(key: $0.key.psdKey, data: [UInt8]($0.data)) }
            d.layers.append(l)
        }
        d.metadata.psdResources = o.file.resources.map { PSDResource(id: $0.id, name: "", data: [UInt8]($0.data)) }
        d.metadata.psdGlobalBlocks = o.file.globalBlocks.map {
            PSDGlobalBlock(signature: $0.signature.psdKey, key: $0.key.psdKey, data: [UInt8]($0.data))
        }
        return d
    }

    /// Every `vmsk`/`vsms`/`vscg`/`vstk`/`vogk` block decodes, re-encodes to bytes that decode to
    /// the same model, and an unedited shape layer keeps every vector block byte-identical.
    @Test func vectorBlocksRoundTrip() throws {
        var counts: [String: (total: Int, decoded: Int, identical: Int)] = [:]
        func count(_ k: String, decoded: Bool, identical: Bool = false) {
            var c = counts[k] ?? (0, 0, 0)
            c.total += 1
            if decoded { c.decoded += 1 }
            if identical { c.identical += 1 }
            counts[k] = c
        }
        var shapes = 0, shapeBlocksKept = 0, gradientsApprox = 0
        for o in try Self.open() {
            for r in o.file.layers {
                for b in r.blocks {
                    let data = [UInt8](b.data)
                    let at = "\(o.name)/\(r.displayName)/\(b.key)"
                    switch b.key {
                    case "vmsk", "vsms":
                        let m = VectorMap.vectorMaskFromBlock(data, o.w, o.h)
                        let shape = VectorMap.pathFromVmsk(data, o.w, o.h)
                        #expect(m != nil && shape != nil, "\(at): does not parse")
                        guard let m, let shape else { continue }
                        #expect(VectorMap.vectorMaskBlockMatches(data, m, o.w, o.h), "\(at)")
                        let again = VectorMap.vectorMaskBytes(m, o.w, o.h)
                        #expect(VectorMap.vectorMaskBlockMatches(again, m, o.w, o.h), "\(at): vector mask re-encode")
                        let shapeAgain = VectorMap.vmskBytes(shape.path, shape.flags, o.w, o.h)
                        #expect(VectorMap.pathFromVmsk(shapeAgain, o.w, o.h)?.path == shape.path, "\(at): shape path re-encode")
                        count(b.key.description, decoded: true, identical: again == data)
                    case "vscg":
                        let f = VectorMap.fillFromVscg(data)
                        count("vscg", decoded: f != nil, identical: f.map { VectorMap.vscgBytes($0) == data } ?? false)
                        #expect(f != nil, "\(at): does not parse")
                        if let f {
                            // Solid and pattern fills re-encode exactly; a gradient's stops are baked
                            // (Photoshop's smoothness) and stored at 1/4096 locations, so they come
                            // back equivalent rather than bit-equal.
                            let back = VectorMap.fillFromVscg(VectorMap.vscgBytes(f))
                            #expect(back.map { Self.equivalent($0, f) } ?? false, "\(at): re-encode")
                            if back != f { gradientsApprox += 1 }
                        }
                    case "vstk":
                        let v = VectorMap.parseVstk(data, o.dpi)
                        count("vstk", decoded: v != nil, identical: v.map { VectorMap.vstkBytes($0.stroke, $0.fillEnabled, o.dpi) == data } ?? false)
                        #expect(v != nil, "\(at): does not parse")
                        if let v { #expect(VectorMap.parseVstk(VectorMap.vstkBytes(v.stroke, v.fillEnabled, o.dpi), o.dpi) == v, "\(at): re-encode") }
                    case "vogk":
                        // Only a single, untransformed rectangle / ellipse / line maps to a live shape.
                        let s = VectorMap.liveFromVogk(data)
                        count("vogk", decoded: s != nil, identical: s.flatMap { VectorMap.vogkBytes($0, o.dpi) } == data)
                        #expect(Blocks.parsePrefixVersioned(Array(data.dropFirst(4))) != nil, "\(at): descriptor does not parse")
                        if let s {
                            let again = try #require(VectorMap.vogkBytes(s, o.dpi))
                            #expect(VectorMap.liveFromVogk(again) == s, "\(at): re-encode")
                        }
                    default:
                        break
                    }
                }
                // An unedited shape layer exports its vector blocks verbatim.
                guard r.kind == .shape else { continue }
                shapes += 1
                let raw: RawBlocks = r.blocks.map { ($0.key, [UInt8]($0.data)) }
                // As the importer builds it: the plain fill block first, then the vector blocks.
                var sh = ShapeLayer()
                if let k = (["SoCo", "GdFl", "PtFl"] as [FourCC]).first(where: { k in raw.contains { $0.key == k } }) {
                    sh.fill = raw.first { $0.key == k }.flatMap { Blocks.parseFill(k, $0.data) }
                }
                VectorMap.shapeFromBlocks(&sh, { k in raw.first { $0.key == k }?.data }, o.w, o.h, o.dpi)
                sh.psdRaw = raw.first { $0.key == "vsms" }?.data ?? raw.first { $0.key == "vmsk" }?.data
                var out = raw
                VectorMap.shapeBlocks(sh, &out, o.w, o.h, o.dpi)
                let same = out.map(\.key) == raw.map(\.key) && out.map(\.data) == raw.map(\.data)
                #expect(same, "\(o.name)/\(r.displayName): shape blocks changed: \(raw.map(\.key)) → \(out.map(\.key))")
                if same { shapeBlocksKept += 1 }
            }
        }
        let summary = counts.keys.sorted().map { k in
            let c = counts[k] ?? (0, 0, 0)
            return "\(k) \(c.decoded)/\(c.total) decoded (\(c.identical) regenerate byte-identical)"
        }
        print("DOCMAPS CORPUS vectors: " + summary.joined(separator: ", ") + "; \(gradientsApprox) baked gradients re-encode within tolerance; shape layers kept verbatim \(shapeBlocksKept)/\(shapes)")
    }

    /// Fills equal up to descriptor precision: gradient stop locations within 1/4096, colours and
    /// opacities within 1e-3 (everything else exact).
    static func equivalent(_ a: Fill, _ b: Fill) -> Bool {
        guard case let .gradient(x) = a, case let .gradient(y) = b else { return a == b }
        func close(_ p: Float, _ q: Float, _ tol: Float) -> Bool { abs(p - q) <= tol }
        var xs = x, ys = y
        (xs.stops, xs.opacityStops, ys.stops, ys.opacityStops) = ([], [], [], [])
        return xs == ys && x.stops.count == y.stops.count && x.opacityStops.count == y.opacityStops.count
            && zip(x.stops, y.stops).allSatisfy { s, t in
                close(s.location, t.location, 1.0 / 4096) && s.color.mode == t.color.mode && close(s.color.alpha, t.color.alpha, 1e-3)
                    && (0 ..< 4).allSatisfy { close(s.color.c[$0], t.color.c[$0], 1e-3) }
            }
            && zip(x.opacityStops, y.opacityStops).allSatisfy { close($0.location, $1.location, 1.0 / 4096) && close($0.opacity, $1.opacity, 1e-3) }
    }

    /// Saved paths (2000–2997) and the work path (1025) decode and re-encode to the same model.
    @Test func pathResourcesRoundTrip() throws {
        var n = 0, identical = 0, subpaths = 0
        for o in try Self.open() {
            for r in o.file.resources where VectorMap.savedPaths.contains(r.id) || r.id == VectorMap.workPath {
                let data = [UInt8](r.data)
                let p = VectorMap.pathFromResource(data, o.w, o.h)
                #expect(p != nil, "\(o.name): path resource \(r.id) does not parse")
                guard let p else { continue }
                let again = [UInt8](VectorMap.pathToRecords(p, o.w, o.h).serialized())
                #expect(VectorMap.pathFromResource(again, o.w, o.h) == p, "\(o.name): path resource \(r.id)")
                n += 1
                subpaths += p.subpaths.count
                if again == data { identical += 1 }
            }
        }
        print("DOCMAPS CORPUS path resources: \(n) round-trip (\(subpaths) subpaths; \(identical) regenerate byte-identical)")
    }

    /// Slices (1050) decode, count as unchanged, and a regenerated resource reads back the same.
    /// Layer comps (1065) decode with the layers' `cmls`, count as unchanged and survive
    /// regeneration of the resource and of every layer's `cmls`.
    @Test func slicesAndCompsDecode() throws {
        var sliceFiles = 0, slices = 0, layerSlices = 0, compFiles = 0, comps = 0, states = 0, warnings = 0
        for o in try Self.open() {
            var d = Self.document(o)
            let ids = Dictionary(d.layers.compactMap { l in l.psdId.map { (l.id, $0) } }, uniquingKeysWith: { _, b in b })
            if let raw = o.file.resource(SlicesMap.slices) {
                #expect((try? PSDSlices(bytes: raw.data)) != nil, "\(o.name): 1050 does not parse")
                SlicesMap.importSlices(&d)
                sliceFiles += 1
                slices += d.slices.list.count
                layerSlices += d.slices.list.filter { $0.origin == .layer }.count
                #expect(SlicesMap.unchanged(d), "\(o.name)")
                #expect(SlicesMap.exportResource(d, ids).resource == nil, "\(o.name): unchanged slices keep the raw resource")
                if !d.slices.isEmpty {
                    var edited = d
                    edited.metadata.psdResources.removeAll { $0.id == SlicesMap.slices }
                    let fresh = try #require(SlicesMap.exportResource(edited, ids).resource.flatMap { $0 })
                    #expect(SlicesMap.slicesFromPSD(fresh, d).list == d.slices.list, "\(o.name): regenerated 1050")
                }
            }
            if let raw = o.file.resource(CompsMap.layerComps) {
                let data = [UInt8](raw.data)
                let r = CompsMap.decodeComps(data, d)
                #expect(Blocks.parsePrefixVersioned(data) != nil, "\(o.name): 1065 does not parse")
                compFiles += 1
                comps += r.comps.count
                states += r.comps.reduce(0) { $0 + $1.states.count } + (r.lastDocumentState?.states.count ?? 0)
                warnings += r.warnings.count
                (d.layerComps, d.lastAppliedComp, d.lastDocumentState) = (r.comps, r.lastApplied, r.lastDocumentState)
                #expect(CompsMap.compsUnchanged(d), "\(o.name)")
                // Regenerated resource and cmls items decode to the same comps.
                var regen = d
                regen.metadata.psdResources.removeAll { $0.id == CompsMap.layerComps }
                for i in regen.layers.indices {
                    var raw = RawBlockList.from(regen.layers[i].psdBlocks)
                    CompsMap.setCmls(&raw, CompsMap.writeCmls(d.layerComps, d.lastDocumentState, regen.layers[i], regen.layers[i].psdId ?? 0))
                    regen.layers[i].psdBlocks = RawBlockList.toDocument(raw)
                }
                let back = CompsMap.compsFromPSD(CompsMap.writeCompsResource(regen), regen)
                #expect(back.comps == d.layerComps, "\(o.name): regenerated comps")
                #expect(back.lastApplied == d.lastAppliedComp && back.lastDocumentState == d.lastDocumentState, "\(o.name)")
            }
        }
        print("DOCMAPS CORPUS slices: \(sliceFiles) files, \(slices) user/layer slices (\(layerSlices) layer-based); "
            + "comps: \(compFiles) files, \(comps) comps, \(states) layer states, \(warnings) warnings")
    }

    /// Artboards, patterns, notes, the measurement scale and channel display info, where present.
    @Test func otherDocumentDataDecodes() throws {
        var boards = 0, patternBlocks = 0, patterns = 0, notes = 0, scales = 0, displayInfos = 0
        for o in try Self.open() {
            let d = Self.document(o)
            for r in o.file.layers {
                for b in r.blocks where CompsMap.artboardKeys.contains(b.key) {
                    let a = CompsMap.parseArtboard([UInt8](b.data))
                    #expect(a != nil, "\(o.name)/\(r.displayName): \(b.key) does not parse")
                    if let a {
                        boards += 1
                        #expect(CompsMap.parseArtboard(CompsMap.writeArtboard(a, [])) == a, "\(o.name)/\(r.displayName)")
                    }
                }
            }
            for b in o.file.globalBlocks where PatternMap.patternKeys.contains(b.key) {
                patternBlocks += 1
                let ps = try PSDPattern.parseBlock(b.data)
                for p in ps {
                    let m = try #require(PatternMap.fromPSD(p), "\(o.name): pattern \(p.name)")
                    patterns += 1
                    #expect(PatternMap.fromPSD(PatternMap.toPSD(m)) == m, "\(o.name): pattern \(p.name)")
                }
                #expect(PatternMap.exportGlobalBlocks({ var x = d; x.patterns = PatternMap.fromGlobalBlocks(d); return x }()) == d.metadata.psdGlobalBlocks)
            }
            if let b = o.file.globalBlock("Anno") {
                let n = try #require(AnnotationsMap.parseAnno([UInt8](b.data)), "\(o.name): Anno")
                notes += n.count
            }
            if let r = o.file.resource(AnnotationsMap.measurementScale) {
                scales += 1
                #expect(AnnotationsMap.scaleFromResource([UInt8](r.data)) != nil, "\(o.name): 1074")
            }
            if let r = o.file.resource(ChannelMap.displayInfo) {
                displayInfos += 1
                let extra = Int(o.file.header.channels) - 3
                var chans = (0 ..< max(extra, 0)).map { AlphaChannel(name: "\($0)", surface: Surface(format: .gray8)) }
                ChannelMap.applyDisplayInfo([UInt8](r.data), true, 0, &chans)
                #expect(chans.allSatisfy { $0.opacity >= 0 && $0.opacity <= 1 })
            }
        }
        print("DOCMAPS CORPUS other: \(boards) artboards, \(patterns) patterns in \(patternBlocks) blocks, \(notes) notes, "
            + "\(scales) measurement scales, \(displayInfos) display-info resources")
    }
}
