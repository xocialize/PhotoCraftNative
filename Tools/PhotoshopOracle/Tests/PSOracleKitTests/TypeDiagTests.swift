// Offline diagnosis of type layers that crash or are refused by Photoshop: compare TySh descriptors
// and EngineData key sets against type layers Photoshop itself wrote. Opt-in (PSO_TYPE_DIAG=1).

import Foundation
import Testing
import PCPSD
@testable import PSOracleKit

@Suite struct TypeDiagTests {
    static let scratch = Fixtures.path

    /// Dotted key paths of an EngineData tree (array elements collapse to `[]`).
    static func paths(_ e: PSDEngineData, _ prefix: String = "", into out: inout Set<String>) {
        switch e {
        case let .dict(items):
            for it in items {
                let p = prefix.isEmpty ? it.key : prefix + "." + it.key
                out.insert(p)
                paths(it.value, p, into: &out)
            }
        case let .array(a):
            for x in a { paths(x, prefix + "[]", into: &out) }
        default: break
        }
    }

    static func summary(_ url: URL) -> (tysh: Int, txt2: Bool, descKeys: [String], ed: Set<String>)? {
        guard let f = try? PSDFile(contentsOf: url) else { return nil }
        let txt2 = f.globalBlocks.contains { $0.key == "Txt2" }
        var keys: [String] = []
        var ed = Set<String>()
        var n = 0
        for r in f.layers {
            guard let t = r.typeTool else { continue }
            n += 1
            keys = t.text.descriptor.items.map(\.key.name)
            if let e = t.engineData { paths(e, into: &ed) }
        }
        return (n, txt2, keys, ed)
    }

    @Test(.enabled(if: Fixtures.optIn("PSO_TYPE_DIAG"), Fixtures.reason("PSO_TYPE_DIAG"))) func typeLayerSurvey() throws {
        // Every swept PCIO file with type layers, by outcome.
        let rows = try JSONDecoder().decode([SweepRow].self, from: Data(contentsOf: URL(fileURLWithPath: Self.scratch + "/ps-oracle/pcio/pcio.json")))
        let snap = URL(fileURLWithPath: Self.scratch + "/ps-oracle/pcio-snapshot")
        var byTest: [String: (ok: Int, fail: Int, crash: Int, txt2: Set<Bool>, errors: Set<String>)] = [:]
        for r in rows {
            guard let s = Self.summary(snap.appendingPathComponent(r.file)), s.tysh > 0 else { continue }
            let test = r.file.replacingOccurrences(of: #"-[0-9a-f]{10}\.ps[db]$"#, with: "", options: .regularExpression)
            var v = byTest[test] ?? (0, 0, 0, [], [])
            if r.opened { v.ok += 1 } else if (r.photoshopError ?? "").contains("crashed") { v.crash += 1 } else { v.fail += 1 }
            v.txt2.insert(s.txt2)
            if let e = r.photoshopError { v.errors.insert(String(e.prefix(50))) }
            byTest[test] = v
        }
        for (k, v) in byTest.sorted(by: { $0.key < $1.key }) {
            print("TYPE \(k): opened \(v.ok), refused \(v.fail), crashed \(v.crash), Txt2 \(v.txt2.sorted { !$0 && $1 }) \(v.errors.sorted().joined(separator: " | "))")
        }
    }

    @Test(.enabled(if: Fixtures.optIn("PSO_TYPE_DIAG"), Fixtures.reason("PSO_TYPE_DIAG"))) func typeLayerDiff() throws {
        let snap = Self.scratch + "/ps-oracle/pcio-snapshot/"
        let crash = URL(fileURLWithPath: snap + "synthetic-importedTypeLayersKeepTheirFullBounds-026de9dd90.psd")
        let okName = try FileManager.default.contentsOfDirectory(atPath: snap).sorted().first { $0.hasPrefix("synthetic-documentsWithoutStylesKeepTheirTypeData") }!
        let ok = URL(fileURLWithPath: snap + okName)
        let ps = URL(fileURLWithPath: Self.scratch + "/ps-corpus/text-point.psd")
        let a = try #require(Self.summary(crash)), b = try #require(Self.summary(ok)), c = try #require(Self.summary(ps))
        print("DIFF descriptor keys crash: \(a.descKeys)")
        print("DIFF descriptor keys opened-PCIO (\(okName)): \(b.descKeys)")
        print("DIFF descriptor keys Photoshop: \(c.descKeys)")
        print("DIFF EngineData paths: crash \(a.ed.count), opened-PCIO \(b.ed.count), Photoshop \(c.ed.count)")
        print("DIFF in opened-PCIO but not in crash, outside DocumentResources: \(b.ed.subtracting(a.ed).filter { !$0.hasPrefix("DocumentResources") }.sorted().joined(separator: " "))")
        print("DIFF DocumentResources paths in opened-PCIO: \(b.ed.filter { $0.hasPrefix("DocumentResources") }.count), in Photoshop: \(c.ed.filter { $0.hasPrefix("DocumentResources") }.count), in crash: \(a.ed.filter { $0.hasPrefix("DocumentResources") }.count)")
        print("DIFF crash EngineData paths: \(a.ed.sorted().joined(separator: " "))")
        print("DIFF in crash but not in opened-PCIO: \(a.ed.subtracting(b.ed).sorted().joined(separator: " "))")
        print("DIFF in Photoshop but not in crash (top two levels): \(c.ed.subtracting(a.ed).filter { $0.split(separator: ".").count <= 2 }.sorted().joined(separator: " "))")
        for (name, u) in [("crash", crash), ("opened", ok), ("photoshop", ps)] {
            let f = try PSDFile(contentsOf: u)
            for r in f.layers { if let t = r.typeTool { print("DIFF \(name) TySh version \(t.version) textVersion \(t.textVersion) warpVersion \(t.warpVersion) transform \(t.transform) bounds \(t.bounds ?? []) trailing \(t.trailing.count) bytes, EngineData \(t.text.descriptor["EngineData"]?.rawBytes?.count ?? -1) bytes, warp \(t.warp.map { $0.descriptor.items.map(\.key.name) } ?? [])") } }
        }
    }

    /// For every type layer Photoshop opened this session: which structural EngineData keys it had.
    @Test(.enabled(if: Fixtures.optIn("PSO_TYPE_DIAG"), Fixtures.reason("PSO_TYPE_DIAG"))) func structuralKeysOfOpenedTypeLayers() throws {
        let keys = ["DocumentResources", "EngineDict.Rendered.Version", "EngineDict.Rendered.Shapes.WritingDirection",
                    "EngineDict.Rendered.Shapes.Children[].Lines", "EngineDict.Rendered.Shapes.Children[].Procession",
                    "EngineDict.Rendered.Shapes.Children[].Cookie.Photoshop.Base", "EngineDict.AntiAlias", "EngineDict.UseFractionalGlyphWidths",
                    "EngineDict.ParagraphRun.RunArray[].ParagraphSheet.DefaultStyleSheet", "EngineDict.StyleRun.RunArray[].StyleSheet.Parent",
                    "ResourceDict.FontSet[].FontType", "DocumentResources.FontSet[].FontType"]
        var sources: [URL] = []
        let rows = try JSONDecoder().decode([SweepRow].self, from: Data(contentsOf: URL(fileURLWithPath: Self.scratch + "/ps-oracle/pcio/pcio.json")))
        sources += rows.filter(\.opened).map { URL(fileURLWithPath: Self.scratch + "/ps-oracle/pcio-snapshot/" + $0.file) }
        sources += Sweep.files(in: URL(fileURLWithPath: Self.scratch + "/ps-corpus"))
        sources += Sweep.files(in: URL(fileURLWithPath: Self.scratch + "/psd-corpus"))
        var tally: [String: (with: Int, without: Int)] = [:]
        var layers = 0
        var withoutExamples: [String: String] = [:]
        for u in sources {
            guard let f = try? PSDFile(contentsOf: u) else { continue }
            for r in f.layers {
                guard let e = r.typeTool?.engineData else { continue }
                layers += 1
                var ps = Set<String>()
                Self.paths(e, into: &ps)
                for k in keys {
                    var t = tally[k] ?? (0, 0)
                    if ps.contains(k) { t.with += 1 } else { t.without += 1; withoutExamples[k] = withoutExamples[k] ?? u.lastPathComponent }
                    tally[k] = t
                }
            }
        }
        print("OPENED type layers examined: \(layers)")
        for k in keys { let t = tally[k] ?? (0, 0); print("OPENED \(k): with \(t.with), without \(t.without)\(t.without > 0 ? " e.g. " + (withoutExamples[k] ?? "") : "")") }
    }

    static func get(_ d: PSDEngineData, _ k: String) -> PSDEngineData? {
        if case let .dict(items) = d { return items.first { $0.key == k }?.value }
        return nil
    }

    static func put(_ d: inout PSDEngineData, _ k: String, _ v: PSDEngineData) {
        guard case var .dict(items) = d else { return }
        if let i = items.firstIndex(where: { $0.key == k }) { items[i] = PSDEngineData.Entry(k, v) } else { items.append(PSDEngineData.Entry(k, v)) }
        d = .dict(items)
    }

    static func d(_ pairs: [(String, PSDEngineData)]) -> PSDEngineData { .dict(pairs.map { PSDEngineData.Entry($0.0, $0.1) }) }

    /// V1: the crasher with the TySh of a PCIO type layer Photoshop opened. V2: the crasher's own
    /// TySh with the structural EngineData PCIO's `PSDText.buildEngineData` writes (and photocraft's
    /// `build_engine_data`): AntiAlias, UseFractionalGlyphWidths, Rendered{Version, Shapes{WritingDirection,
    /// Children[{ShapeType, Procession, Lines, Cookie.Photoshop.Base}]}}, DocumentResources, DefaultStyleSheet.
    @Test(.enabled(if: Fixtures.optIn("PSO_TYPE_VARIANTS_OUT"), Fixtures.reason("PSO_TYPE_VARIANTS_OUT"))) func typeCrashVariants() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PSO_TYPE_VARIANTS_OUT"]!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let snap = Self.scratch + "/ps-oracle/pcio-snapshot/"
        let crash = try PSDFile(contentsOf: URL(fileURLWithPath: snap + "synthetic-importedTypeLayersKeepTheirFullBounds-026de9dd90.psd"))
        let okName = try FileManager.default.contentsOfDirectory(atPath: snap).sorted().first { $0.hasPrefix("synthetic-documentsWithoutStylesKeepTheirTypeData") }!
        let ok = try PSDFile(contentsOf: URL(fileURLWithPath: snap + okName))
        let goodTySh = try #require(ok.layers.compactMap { $0.block("TySh") }.first)
        // V1
        var v1 = crash
        v1.layers[0].setBlock(PSDTaggedBlock(key: "TySh", data: goodTySh.data))
        try v1.write(to: out.appendingPathComponent("type-V1-tysh-from-opened-pcio-file.psd"))
        // V2
        var t = try #require(crash.layers[0].typeTool)
        var e = try #require(t.engineData)
        var dict = try #require(Self.get(e, "EngineDict"))
        Self.put(&dict, "AntiAlias", .int(3))
        Self.put(&dict, "UseFractionalGlyphWidths", .bool(true))
        let photoshop = Self.d([("ShapeType", .int(0)), ("PointBase", .array([.real(0), .real(0)])),
                                ("Base", Self.d([("ShapeType", .int(0)), ("TransformPoint0", .array([.real(1), .real(0)])),
                                                 ("TransformPoint1", .array([.real(0), .real(1)])), ("TransformPoint2", .array([.real(0), .real(0)]))]))])
        let child = Self.d([("ShapeType", .int(0)), ("Procession", .int(0)),
                            ("Lines", Self.d([("WritingDirection", .int(0)), ("Children", .array([]))])),
                            ("Cookie", Self.d([("Photoshop", photoshop)]))])
        Self.put(&dict, "Rendered", Self.d([("Version", .int(1)), ("Shapes", Self.d([("WritingDirection", .int(0)), ("Children", .array([child]))]))]))
        if var pr = Self.get(dict, "ParagraphRun"), case let .array(runs)? = Self.get(pr, "RunArray") {
            let fixed: [PSDEngineData] = runs.map { r in
                var r = r
                if var sheet = Self.get(r, "ParagraphSheet") { Self.put(&sheet, "DefaultStyleSheet", .int(0)); Self.put(&r, "ParagraphSheet", sheet) }
                return r
            }
            Self.put(&pr, "RunArray", .array(fixed))
            Self.put(&dict, "ParagraphRun", pr)
        }
        Self.put(&e, "EngineDict", dict)
        if var rd = Self.get(e, "ResourceDict") {
            if case let .array(sets)? = Self.get(rd, "ParagraphSheetSet") {
                Self.put(&rd, "ParagraphSheetSet", .array(sets.map { s in var s = s; Self.put(&s, "DefaultStyleSheet", .int(0)); return s }))
            }
            Self.put(&e, "ResourceDict", rd)
            if Self.get(e, "DocumentResources") == nil { Self.put(&e, "DocumentResources", rd) }
        }
        t.setEngineData(e)
        var v2 = crash
        v2.layers[0].setBlock(PSDTaggedBlock(key: "TySh", data: t.serialized()))
        try v2.write(to: out.appendingPathComponent("type-V2-structural-enginedata.psd"))
        // Self-check: V2's EngineData now has every structural key the opened type layers have.
        var ps = Set<String>()
        Self.paths(try #require(PSDFile(contentsOf: out.appendingPathComponent("type-V2-structural-enginedata.psd")).layers[0].typeTool?.engineData), into: &ps)
        for k in ["DocumentResources", "EngineDict.Rendered.Version", "EngineDict.Rendered.Shapes.Children[].Lines", "EngineDict.Rendered.Shapes.Children[].Procession",
                  "EngineDict.Rendered.Shapes.Children[].Cookie.Photoshop.Base", "EngineDict.AntiAlias", "EngineDict.UseFractionalGlyphWidths",
                  "EngineDict.ParagraphRun.RunArray[].ParagraphSheet.DefaultStyleSheet"] { #expect(ps.contains(k), "\(k)") }
        print("VARIANTS written: V1 TySh \(goodTySh.data.count) bytes from \(okName); V2 EngineData paths \(ps.count)")
    }

    /// The crash signature: a type layer whose EngineData lacks a structure every type layer
    /// Photoshop opened has. Lists the snapshot files that carry it and whether they were swept.
    @Test(.enabled(if: Fixtures.optIn("PSO_TYPE_DIAG"), Fixtures.reason("PSO_TYPE_DIAG"))) func crashSignatureScan() throws {
        let required = ["DocumentResources", "EngineDict.Rendered.Version", "EngineDict.Rendered.Shapes.WritingDirection",
                        "EngineDict.Rendered.Shapes.Children[].Lines", "EngineDict.Rendered.Shapes.Children[].Procession",
                        "EngineDict.Rendered.Shapes.Children[].Cookie.Photoshop.Base", "EngineDict.AntiAlias", "EngineDict.UseFractionalGlyphWidths",
                        "EngineDict.ParagraphRun.RunArray[].ParagraphSheet.DefaultStyleSheet"]
        let rows = try JSONDecoder().decode([SweepRow].self, from: Data(contentsOf: URL(fileURLWithPath: Self.scratch + "/ps-oracle/pcio/pcio.json")))
        let swept = Dictionary(rows.map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })
        let snap = URL(fileURLWithPath: Self.scratch + "/ps-oracle/pcio-snapshot")
        var hits = 0
        for u in Sweep.files(in: snap) {
            guard let f = try? PSDFile(contentsOf: u) else { continue }
            var missing = Set<String>()
            for r in f.layers {
                guard let t = r.typeTool else { continue }
                var ps = Set<String>()
                if let e = t.engineData { Self.paths(e, into: &ps) }
                missing.formUnion(required.filter { !ps.contains($0) })
            }
            guard !missing.isEmpty else { continue }
            hits += 1
            let row = swept[u.lastPathComponent]
            let status = row.map { $0.opened ? "OPENED" : ($0.photoshopError ?? "").contains("crashed") || ($0.photoshopError ?? "").contains("CRASHED") ? "CRASHED" : ($0.photoshopError ?? "").contains("quarantined") ? "quarantined" : "refused: \(($0.photoshopError ?? "").prefix(40))" } ?? "not swept"
            print("SIG \(u.lastPathComponent) [\(status)] missing \(missing.count): \(missing.sorted().map { $0.replacingOccurrences(of: "EngineDict.", with: "") }.joined(separator: ","))")
        }
        print("SIG total \(hits)")
    }

    /// Do Photoshop's layer blocks always have 4-aligned lengths? And PCIO's accepted/refused ones?
    @Test(.enabled(if: Fixtures.optIn("PSO_TYPE_DIAG"), Fixtures.reason("PSO_TYPE_DIAG"))) func blockAlignment() throws {
        var ps: [String: (aligned: Int, odd: Int)] = [:]
        for u in Sweep.files(in: URL(fileURLWithPath: Self.scratch + "/ps-corpus")) + Sweep.files(in: URL(fileURLWithPath: Self.scratch + "/psd-corpus")) {
            guard let f = try? PSDFile(contentsOf: u) else { continue }
            for b in f.layers.flatMap(\.blocks) {
                var c = ps[b.key.string] ?? (0, 0)
                if b.data.count % 4 == 0 { c.aligned += 1 } else { c.odd += 1 }
                ps[b.key.string] = c
            }
        }
        let odd = ps.filter { $0.value.odd > 0 }.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.odd)/\($0.value.aligned + $0.value.odd)" }
        print("ALIGN Photoshop layer blocks with a length not a multiple of 4: \(odd.isEmpty ? "none" : odd.joined(separator: ", ")) (of \(ps.values.reduce(0) { $0 + $1.aligned + $1.odd }) blocks)")
    }
    // MARK: Value ranges (the type-layer rasterize modal)

    /// Numeric leaves of an EngineData tree by dotted path (array elements collapse to `[]`).
    static func numbers(_ e: PSDEngineData, _ prefix: String, into out: inout [String: [Double]]) {
        switch e {
        case let .dict(items): for it in items { numbers(it.value, prefix.isEmpty ? it.key : prefix + "." + it.key, into: &out) }
        case let .array(a): for x in a { numbers(x, prefix + "[]", into: &out) }
        case let .int(v): out[prefix, default: []].append(Double(v))
        case let .real(v): out[prefix, default: []].append(v)
        default: break
        }
    }

    static func numbers(_ v: PSDDescriptor.Value, _ p: String, into out: inout [String: [Double]]) {
        if let n = v.number { out[p, default: []].append(n) }
        else if let d = v.descriptor { for it in d.items { numbers(it.value, p + "/" + it.key.description, into: &out) } }
        else if let l = v.list { for x in l { numbers(x, p + "[]", into: &out) } }
    }

    /// Every numeric value of one type layer, plus derived ones: the transform's scale
    /// (sqrt |det|) and the effective size (FontSize x scale, in points).
    static func typeValues(_ t: PSDTypeTool) -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        for (i, v) in t.transform.enumerated() { out["TySh.transform[\(i)]", default: []].append(v) }
        let m = t.transform
        let scale = m.count >= 4 ? (abs(m[0] * m[3] - m[1] * m[2])).squareRoot() : .nan
        out["derived.scale"] = [scale]
        for (i, v) in (t.bounds ?? []).enumerated() { out["TySh.bounds[\(i)]", default: []].append(Double(v)) }
        for it in t.text.descriptor.items where it.key.description != "EngineData" { numbers(it.value, "Txt/" + it.key.description, into: &out) }
        if let e = t.engineData { numbers(e, "", into: &out) }
        let sizes = (out["EngineDict.StyleRun.RunArray[].StyleSheet.StyleSheetData.FontSize"] ?? []) + (out["DocumentResources.StyleSheetSet[].StyleSheetData.FontSize"] ?? [])
        out["derived.effectiveFontSize"] = sizes.map { $0 * scale }
        let leads = out["EngineDict.StyleRun.RunArray[].StyleSheet.StyleSheetData.Leading"] ?? []
        out["derived.effectiveLeading"] = leads.map { $0 * scale }
        return out
    }

    static func typeLayers(_ dir: String) -> [(file: String, layer: Int, values: [String: [Double]])] {
        var out: [(String, Int, [String: [Double]])] = []
        for u in Sweep.files(in: URL(fileURLWithPath: dir)) {
            guard let f = try? PSDFile(contentsOf: u) else { continue }
            for (i, r) in f.layers.enumerated() { if let t = r.typeTool { out.append((u.lastPathComponent, i, typeValues(t))) } }
        }
        return out
    }

    /// Ranges of every numeric type-layer value Photoshop itself wrote (ps-corpus and the Unity
    /// corpus), then every value of the hostile files and of the C' snapshot outside them.
    @Test(.enabled(if: Fixtures.optIn("PSO_TYPE_DIAG"), Fixtures.reason("PSO_TYPE_DIAG"))) func typeValueRanges() throws {
        let ps = Self.typeLayers(Self.scratch + "/ps-corpus") + Self.typeLayers(Self.scratch + "/psd-corpus")
        var lo: [String: Double] = [:], hi: [String: Double] = [:], nonFinite = Set<String>()
        for l in ps { for (k, vs) in l.values { for v in vs {
            if !v.isFinite { nonFinite.insert(k); continue }
            lo[k] = min(lo[k] ?? v, v); hi[k] = max(hi[k] ?? v, v)
        } } }
        print("RANGE Photoshop type layers: \(ps.count) in \(Set(ps.map(\.file)).count) files; non-finite paths \(nonFinite.sorted())")
        for k in ["derived.scale", "derived.effectiveFontSize", "derived.effectiveLeading",
                  "EngineDict.StyleRun.RunArray[].StyleSheet.StyleSheetData.FontSize",
                  "EngineDict.StyleRun.RunArray[].StyleSheet.StyleSheetData.Leading",
                  "DocumentResources.StyleSheetSet[].StyleSheetData.FontSize",
                  "DocumentResources.StyleSheetSet[].StyleSheetData.Leading",
                  "TySh.transform[0]", "TySh.transform[1]", "TySh.transform[2]", "TySh.transform[3]", "TySh.transform[4]", "TySh.transform[5]",
                  "TySh.bounds[0]", "TySh.bounds[1]", "TySh.bounds[2]", "TySh.bounds[3]",
                  "EngineDict.Rendered.Shapes.Children[].Cookie.Photoshop.BoxBounds[]",
                  "EngineDict.Rendered.Shapes.Children[].Cookie.Photoshop.Base.TransformPoint0[]",
                  "EngineDict.Rendered.Shapes.Children[].Cookie.Photoshop.Base.TransformPoint1[]",
                  "EngineDict.Rendered.Shapes.Children[].Cookie.Photoshop.Base.TransformPoint2[]"] {
            print("RANGE \(k): [\(lo[k].map { "\($0)" } ?? "-"), \(hi[k].map { "\($0)" } ?? "-")]")
        }
        func outside(_ values: [String: [Double]]) -> [String: [Double]] {
            var o: [String: [Double]] = [:]
            for (k, vs) in values {
                let bad = vs.filter { v in !v.isFinite || (lo[k].map { v < $0 } ?? false) || (hi[k].map { v > $0 } ?? false) }
                if !bad.isEmpty { o[k] = bad }
            }
            return o
        }
        let snap = Self.scratch + "/ps-oracle/pcio-snapshot-c2"
        let pc = Self.typeLayers(snap)
        for l in pc where l.file.contains("hostileTypeSizes") {
            print("HOSTILE \(l.file) #\(l.layer): " + outside(l.values).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.prefix(4).map { String(format: "%g", $0) })" }.joined(separator: "; "))
        }
        // Which out-of-range paths also occur in files Photoshop opened as type (no rasterize)?
        let rows = (try? JSONDecoder().decode([SweepRow].self, from: Data(contentsOf: URL(fileURLWithPath: Self.scratch + "/ps-oracle/pcio-c2/pcio-c2.json")))) ?? []
        let byFile = Dictionary(rows.map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })
        var pathFiles: [String: (keptType: Set<String>, rasterized: Set<String>, unswept: Set<String>)] = [:]
        for l in pc {
            let row = byFile[l.file]
            let raster = row?.mismatches.contains { $0.field == "kind" && $0.pcpsd == "text" } ?? false
            for k in outside(l.values).keys {
                var v = pathFiles[k] ?? ([], [], [])
                if row == nil || !(row!.opened) { v.unswept.insert(l.file) } else if raster { v.rasterized.insert(l.file) } else { v.keptType.insert(l.file) }
                pathFiles[k] = v
            }
        }
        for (k, v) in pathFiles.sorted(by: { $0.key < $1.key }) {
            print("OUT \(k): opened-as-type \(v.keptType.count), rasterized \(v.rasterized.count), unswept \(v.unswept.count) e.g. \((v.unswept.union(v.rasterized).union(v.keptType)).sorted().prefix(3).joined(separator: ","))")
        }
        print("SNAP type layers \(pc.count) in \(Set(pc.map(\.file)).count) files; rasterized-by-Photoshop rows in C': \(rows.filter { $0.mismatches.contains { $0.field == "kind" && $0.pcpsd == "text" } }.map(\.file))")
    }
    /// The size metrics of one type layer that a pre-screen could check.
    static func typeMetrics(_ v: [String: [Double]]) -> [String: Double] {
        func vals(_ ks: [String]) -> [Double] { ks.flatMap { v[$0] ?? [] } }
        let runSize = vals(["EngineDict.StyleRun.RunArray[].StyleSheet.StyleSheetData.FontSize"])
        let sheetSize = vals(["DocumentResources.StyleSheetSet[].StyleSheetData.FontSize", "ResourceDict.StyleSheetSet[].StyleSheetData.FontSize"])
        let lead = vals(["EngineDict.StyleRun.RunArray[].StyleSheet.StyleSheetData.Leading"])
        let scale = v["derived.scale"]?.first ?? .nan
        let eff = runSize.map { $0 * scale }
        let tf = (0 ..< 6).flatMap { v["TySh.transform[\($0)]"] ?? [] }
        let bounds = v.filter { $0.key.hasPrefix("TySh.bounds") || $0.key.hasPrefix("Txt/bounds") || $0.key.hasPrefix("Txt/boundingBox") || $0.key.hasSuffix("BoxBounds[]") }.values.flatMap { $0 }
        let all = v.values.flatMap { $0 }
        var m: [String: Double] = [:]
        m["runFontSize.max"] = runSize.max() ?? .nan
        m["runFontSize.min"] = runSize.min() ?? .nan
        m["sheetFontSize.max"] = sheetSize.max() ?? .nan
        m["runLeading.max"] = lead.max() ?? .nan
        m["scale"] = scale
        m["effectiveSize.max"] = eff.max() ?? .nan
        m["effectiveSize.min"] = eff.min() ?? .nan
        m["transform.maxAbs"] = tf.map(abs).max() ?? .nan
        m["bounds.maxAbs"] = bounds.map(abs).max() ?? .nan
        m["nonFinite"] = Double(all.filter { !$0.isFinite }.count)
        m["numbers.maxAbs"] = all.filter(\.isFinite).map(abs).max() ?? .nan
        return m
    }

    /// Type-layer size metrics: the envelope of the layers Photoshop wrote, the envelope of the
    /// layers Photoshop opened and kept as type, and every C' snapshot layer outside either.
    @Test(.enabled(if: Fixtures.optIn("PSO_TYPE_DIAG"), Fixtures.reason("PSO_TYPE_DIAG"))) func typeMetricEnvelopes() throws {
        let sc = Self.scratch
        let authored = Self.typeLayers(sc + "/ps-corpus") + Self.typeLayers(sc + "/psd-corpus")
        var kept = authored
        func rows(_ p: String) -> [SweepRow] { (try? JSONDecoder().decode([SweepRow].self, from: Data(contentsOf: URL(fileURLWithPath: sc + p)))) ?? [] }
        for (json, dir) in [("/ps-oracle/pcio/pcio.json", "/ps-oracle/pcio-snapshot"), ("/ps-oracle/pcio-c2/pcio-c2.json", "/ps-oracle/pcio-snapshot-c2")] {
            for r in rows(json) where r.opened && !r.mismatches.contains(where: { $0.field == "kind" && $0.pcpsd == "text" }) {
                guard let f = try? PSDFile(contentsOf: URL(fileURLWithPath: sc + dir + "/" + r.file)) else { continue }
                for (i, l) in f.layers.enumerated() { if let t = l.typeTool { kept.append((r.file, i, Self.typeValues(t))) } }
            }
        }
        func envelope(_ ls: [(file: String, layer: Int, values: [String: [Double]])]) -> [String: (Double, Double, String, String)] {
            var e: [String: (Double, Double, String, String)] = [:]
            for l in ls { for (k, x) in Self.typeMetrics(l.values) where x.isFinite || k == "nonFinite" {
                var c = e[k] ?? (x, x, l.file, l.file)
                if x < c.0 { c.0 = x; c.2 = l.file }
                if x > c.1 { c.1 = x; c.3 = l.file }
                e[k] = c
            } }
            return e
        }
        let ea = envelope(authored), ek = envelope(kept)
        print("ENV authored \(authored.count) layers / \(Set(authored.map(\.file)).count) files; kept-as-type \(kept.count) layers / \(Set(kept.map(\.file)).count) files")
        for k in ea.keys.sorted() {
            let a = ea[k]!, b = ek[k] ?? (.nan, .nan, "", "")
            print(String(format: "ENV %@: authored [%g, %g]  kept [%g, %g] (min %@, max %@)", k, a.0, a.1, b.0, b.1, b.2, b.3))
        }
        let snap = Self.typeLayers(sc + "/ps-oracle/pcio-snapshot-c2")
        let c2 = Dictionary(rows("/ps-oracle/pcio-c2/pcio-c2.json").map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })
        for l in snap {
            let m = Self.typeMetrics(l.values)
            let outK = m.filter { k, x in
                guard let b = ek[k] else { return false }
                return !x.isNaN && (x < b.0 || x > b.1)
            }
            guard !outK.isEmpty else { continue }
            let st = c2[l.file].map { $0.opened ? ($0.mismatches.contains { $0.field == "kind" } ? "RASTERIZED" : "kept") : "not opened" } ?? "unswept"
            print("BEYOND-KEPT \(l.file) #\(l.layer) [\(st)]: " + outK.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%g", $0.value))" }.joined(separator: " "))
        }
    }
    /// Font names of type layers (FontSet[].Name): empty or unusual ones in the C' snapshot versus
    /// the layers Photoshop wrote or kept as type.
    @Test(.enabled(if: Fixtures.optIn("PSO_TYPE_DIAG"), Fixtures.reason("PSO_TYPE_DIAG"))) func typeFontNames() throws {
        let sc = Self.scratch
        func names(_ t: PSDTypeTool) -> [String] {
            guard let e = t.engineData else { return [] }
            return ["ResourceDict", "DocumentResources"].flatMap { r in (e.path(r, "FontSet")?.array ?? []).compactMap { $0.path("Name")?.string } }
        }
        func scan(_ dir: String, only: Set<String>? = nil) -> [(String, Int, [String])] {
            var out: [(String, Int, [String])] = []
            for u in Sweep.files(in: URL(fileURLWithPath: dir)) where only?.contains(u.lastPathComponent) ?? true {
                guard let f = try? PSDFile(contentsOf: u) else { continue }
                for (i, l) in f.layers.enumerated() { if let t = l.typeTool { out.append((u.lastPathComponent, i, names(t))) } }
            }
            return out
        }
        let authored = scan(sc + "/ps-corpus") + scan(sc + "/psd-corpus")
        let rows = (try? JSONDecoder().decode([SweepRow].self, from: Data(contentsOf: URL(fileURLWithPath: sc + "/ps-oracle/pcio/pcio.json")))) ?? []
        let rows2 = (try? JSONDecoder().decode([SweepRow].self, from: Data(contentsOf: URL(fileURLWithPath: sc + "/ps-oracle/pcio-c2/pcio-c2.json")))) ?? []
        let kept = scan(sc + "/ps-oracle/pcio-snapshot", only: Set(rows.filter(\.opened).map(\.file)))
            + scan(sc + "/ps-oracle/pcio-snapshot-c2", only: Set(rows2.filter { $0.opened && !$0.mismatches.contains { $0.field == "kind" } }.map(\.file)))
        let an = Set(authored.flatMap(\.2)), kn = Set(kept.flatMap(\.2))
        print("FONTS authored: \(an.sorted())")
        print("FONTS kept-as-type (PCIO, opened): \(kn.subtracting(an).sorted())")
        print("FONTS layers with an empty name: authored \(authored.filter { $0.2.contains("") }.count), kept \(kept.filter { $0.2.contains("") }.count)")
        let snap = scan(sc + "/ps-oracle/pcio-snapshot-c2")
        let novel = snap.filter { !Set($0.2).isSubset(of: an.union(kn)) || $0.2.isEmpty }
        for (f, i, n) in novel { print("FONTS-NOVEL \(f) #\(i): \(n)") }
        for (f, i, n) in snap where f.contains("hostileTypeSizes") { print("FONTS-HOSTILE \(f) #\(i): \(n)") }
    }
    /// Pre-screen 3 calibration: no hit on any type layer Photoshop wrote or opened and kept as type.
    @Test(.enabled(if: Fixtures.optIn("PSO_TYPE_DIAG"), Fixtures.reason("PSO_TYPE_DIAG"))) func typeSizeScreenCalibration() throws {
        let sc = Self.scratch
        func rows(_ p: String) -> [SweepRow] { (try? JSONDecoder().decode([SweepRow].self, from: Data(contentsOf: URL(fileURLWithPath: sc + p)))) ?? [] }
        var files = Sweep.files(in: URL(fileURLWithPath: sc + "/ps-corpus")) + Sweep.files(in: URL(fileURLWithPath: sc + "/psd-corpus"))
        files += rows("/ps-oracle/pcio/pcio.json").filter(\.opened).map { URL(fileURLWithPath: sc + "/ps-oracle/pcio-snapshot/" + $0.file) }
        files += rows("/ps-oracle/pcio-c2/pcio-c2.json").filter { $0.opened && !$0.mismatches.contains { $0.field == "kind" } }.map { URL(fileURLWithPath: sc + "/ps-oracle/pcio-snapshot-c2/" + $0.file) }
        var layers = 0, hits: [String] = []
        for u in files {
            guard let f = try? PSDFile(contentsOf: u) else { continue }
            layers += f.layers.filter { $0.typeTool != nil }.count
            if let why = TypeSizeScreen.violation(f) { hits.append(u.lastPathComponent + ": " + why) }
        }
        print("CALIB files \(files.count), type layers \(layers), hits \(hits.count) \(hits)")
        #expect(hits.isEmpty)
    }
    /// What PCPSD's own checks say about the pre-screen-3 hits.
    @Test(.enabled(if: Fixtures.optIn("PSO_TYPE_DIAG"), Fixtures.reason("PSO_TYPE_DIAG"))) func typeSizeHitsUnderPCPSD() throws {
        for u in Sweep.files(in: URL(fileURLWithPath: Self.scratch + "/ps-oracle/pcio-snapshot-c2")) {
            guard let f = try? PSDFile(contentsOf: u), let why = TypeSizeScreen.violation(f) else { continue }
            let gaps = f.layers.compactMap(\.typeTool).flatMap { $0.photoshopStructureGaps() }.map(\.path)
            let txt2 = f.globalBlocks.contains { $0.key == "Txt2" }
            print("PCPSD \(u.lastPathComponent): structureGaps \(gaps), compatibilityIssues \(f.compatibilityIssues().map(\.description)), Txt2 \(txt2), bytes \(try Data(contentsOf: u).count); screen 3: \(why.split(separator: ":").dropFirst().joined(separator: ":"))")
        }
    }
}
