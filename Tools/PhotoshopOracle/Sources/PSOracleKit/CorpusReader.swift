// PCPSD over the Photoshop-authored corpus: parse, byte-identical rewrite, typed-block round trips
// (every typed parser must reproduce Photoshop's bytes), the layer tree against Photoshop's own
// report, and the decoded merged image against the composite Photoshop exported.

import Foundation
import PCPSD

public struct TypedCount: Codable, Sendable {
    public var ok = 0
    public var total = 0
}

public struct CorpusFileResult: Codable, Sendable {
    public var file: String
    public var features: [String] = []
    public var parsed = false
    public var parseError: String?
    public var mode: String?
    public var bits: Int?
    public var layerRecords: Int?
    public var hasRealMergedData: Bool?
    public var byteIdentical: Bool?
    public var modelEqualReparse: Bool?
    public var rewriteNote: String?
    public var typedFailures: [String] = []
    public var typedChecked = 0
    public var blocksUntypedKeys: [String] = []
    public var linter: [String] = []
    public var warnings: [String] = []
    public var treeMatch: Bool?
    public var mismatches: [FactMismatch] = []
    public var merged: PixelDiff?
    public var mergedAlpha: PixelDiff?
    public var mergedError: String?
}

public struct CorpusReport: Codable, Sendable {
    public var directory: String
    public var files: [CorpusFileResult]
    public var typed: [String: TypedCount]
}

public enum CorpusReader {
    /// Typed parse → serialise checks for one block; nil when the key has no typed model here.
    static func typedRoundTrip(_ b: PSDTaggedBlock) -> (name: String, result: Result<Bool, Error>)? {
        let k = b.key.string
        func check(_ body: () throws -> Data) -> Result<Bool, Error> { Result { try body() == b.data } }
        switch k {
        case "TySh": return (k, check { try PSDTypeTool(bytes: b.data).serialized() })
        case "lfx2", "lfxs", "lmfx": return (k, check { try PSDObjectEffects(bytes: b.data).serialized() })
        case "lrFX": return (k, check { try PSDLegacyEffects(bytes: b.data).serialized() })
        case "SoLd", "SoLE": return (k, check { try PSDPlacedLayerData(bytes: b.data).serialized() })
        case "PlLd": return (k, check { try PSDPlacedLayer(bytes: b.data).serialized() })
        case "vmsk", "vsms": return (k, check { try PSDVectorMask(bytes: b.data).serialized() })
        case "vogk", "vscg": return (k, check { try PSDHeaderedDescriptor(bytes: b.data).serialized() })
        case "vstk": return (k, check { try PSDVectorStroke(bytes: b.data).serialized() })
        case "SoCo", "GdFl", "PtFl": return (k, check { try PSDFillSetting(key: b.key, bytes: b.data).serialized() })
        case "shmd": return (k, check { PSDMetadataItem.serialize(try PSDMetadataItem.parse(b.data)) })
        case "Txt2": return (k, check { try PSDEngineData.parseBare(b.data).serializedCompactBare() })
        case "FEid", "FXid": return (k, check { try PSDFilterEffects(bytes: b.data).serialized() })
        case "lnk2", "lnk3", "lnkD", "lnkE": return (k, check { try PSDLinkedFiles(bytes: b.data).serialized() })
        default:
            if PSDAdjustment.keys.contains(b.key) {
                return (k, check {
                    guard let a = try PSDAdjustment.parse(key: b.key, data: b.data) else { throw PSDError.invalid("untyped") }
                    return a.serialized()
                })
            }
            return nil
        }
    }

    static func typedRoundTrip(_ r: PSDImageResource) -> (name: String, result: Result<Bool, Error>)? {
        func check(_ body: () throws -> Data) -> Result<Bool, Error> { Result { try body() == r.data } }
        switch r.id {
        case 1050: return ("res1050 slices", check { try PSDSlices(bytes: r.data).serialized() })
        case 1032: return ("res1032 guides", check { try PSDGridAndGuides(bytes: r.data).serialized() })
        case 1005: return ("res1005 resolution", check { try PSDResolutionInfo(bytes: r.data).serialized() })
        case 1057: return ("res1057 version", check { try PSDVersionInfo(bytes: r.data).serialized() })
        case 1065, 1082, 1083, 1088: return ("res\(r.id) descriptor", check { try PSDVersionedDescriptor(bytes: r.data).serialized() })
        case 1025, 2000 ... 2997: return ("res\(r.id < 2000 ? 1025 : 2000) path", check { try PSDPathData(bytes: r.data).serialized() })
        default: return nil
        }
    }

    public static func read(_ dir: URL, log: (String) -> Void) throws -> CorpusReport {
        try CorpusManifest.annotate(dir)
        let manifest = CorpusManifest.load(dir)
        let files: [URL] = manifest.map { $0.files.map { dir.appendingPathComponent($0.file) } } ?? Sweep.files(in: dir)
        var typed: [String: TypedCount] = [:]
        var results: [CorpusFileResult] = []
        for url in files {
            let entry = manifest?.files.first { $0.file == url.lastPathComponent }
            var r = CorpusFileResult(file: url.lastPathComponent, features: entry?.features ?? [])
            defer { results.append(r) }
            let data: Data
            let f: PSDFile
            do {
                data = try Data(contentsOf: url)
                f = try PSDFile(data: data)
            } catch {
                r.parseError = "\(error)"
                log("\(url.lastPathComponent): PCPSD cannot parse: \(error)")
                continue
            }
            r.parsed = true
            r.mode = PCPSDFacts.modeName(f.header.colorMode)
            r.bits = Int(f.header.depth)
            r.layerRecords = f.layers.count
            r.hasRealMergedData = f.hasRealMergedData
            r.warnings = f.warnings
            r.linter = f.compatibilityIssues().map(\.description)
            do {
                let out = try f.serialized()
                r.byteIdentical = out == data
                if out != data {
                    let n = min(out.count, data.count)
                    let first = (0 ..< n).first { out[out.startIndex + $0] != data[data.startIndex + $0] } ?? n
                    r.rewriteNote = "\(out.count) vs \(data.count) bytes, first difference at offset \(first)"
                }
                r.modelEqualReparse = try PSDFile(data: out) == f
            } catch { r.rewriteNote = "rewrite failed: \(error)" }
            var untyped = Set<String>()
            for b in f.layers.flatMap(\.blocks) + f.globalBlocks {
                do {
                    _ = try b.parsed()
                    try b.checkStructure()
                } catch { r.typedFailures.append("\(b.key.string) structure: \(error)") }
                guard let (name, res) = typedRoundTrip(b) else {
                    if (try? b.parsed()) == nil { untyped.insert(b.key.string) }
                    continue
                }
                r.typedChecked += 1
                var c = typed[name] ?? TypedCount()
                c.total += 1
                switch res {
                case let .success(same): if same { c.ok += 1 } else { r.typedFailures.append("\(name): re-serialised bytes differ (\(b.data.count) bytes)") }
                case let .failure(e): r.typedFailures.append("\(name): \(e)")
                }
                typed[name] = c
                if name == "TySh", let t = try? PSDTypeTool(bytes: b.data), let raw = t.text.descriptor["EngineData"]?.rawBytes {
                    var e = typed["EngineData"] ?? TypedCount()
                    e.total += 1
                    if let parsed = try? PSDEngineData.parse(raw), parsed.serialized() == raw { e.ok += 1 } else { r.typedFailures.append("EngineData: not byte-identical") }
                    typed["EngineData"] = e
                }
            }
            r.blocksUntypedKeys = untyped.sorted()
            for res in f.resources {
                do { _ = try res.parsed() } catch { r.typedFailures.append("resource \(res.id): \(error)") }
                guard let (name, result) = typedRoundTrip(res) else { continue }
                r.typedChecked += 1
                var c = typed[name] ?? TypedCount()
                c.total += 1
                switch result {
                case let .success(same): if same { c.ok += 1 } else { r.typedFailures.append("\(name): re-serialised bytes differ") }
                case let .failure(e): r.typedFailures.append("\(name): \(e)")
                }
                typed[name] = c
            }
            if let entry, let psInfo = entry.photoshopInfo(dir) {
                r.mismatches = FactComparison.compare(docPS: PhotoshopFacts.doc(psInfo), docOurs: PCPSDFacts.doc(f),
                                                      layersPS: PhotoshopFacts.layers(psInfo), layersOurs: PCPSDFacts.layers(f))
                r.treeMatch = r.mismatches.isEmpty
            }
            if let entry, let comp = entry.composite {
                do {
                    let ref = try entry.readComposite(dir, comp)
                    r.merged = try PixelCompare.merged(f, against: ref)
                } catch { r.mergedError = "\(error)" }
            }
            if let entry, let a = entry.alphaComposite {
                do { r.mergedAlpha = try PixelCompare.mergedAlpha(f, against: try entry.readComposite(dir, a)) } catch {
                    r.mergedError = (r.mergedError.map { $0 + "; " } ?? "") + "alpha: \(error)"
                }
            }
        }
        return CorpusReport(directory: dir.path, files: results, typed: typed)
    }

    public static func summary(_ r: CorpusReport) -> String {
        let n = r.files.count
        let parsed = r.files.filter(\.parsed).count
        let ident = r.files.filter { $0.byteIdentical == true }.count
        let typedOK = r.files.filter { $0.parsed && $0.typedFailures.isEmpty }.count
        let tree = r.files.filter { $0.treeMatch == true }.count
        let exact = r.files.filter { $0.merged?.exact == true }.count
        let worst = r.files.compactMap { $0.merged?.max8 }.max() ?? 0
        return "corpus read: \(parsed)/\(n) parse, \(ident)/\(n) byte-identical rewrites, \(typedOK)/\(n) typed-block clean, tree match \(tree)/\(n), merged == Photoshop composite exactly \(exact)/\(n) (worst \(fmt(worst)) levels)"
    }

    public static func markdown(_ r: CorpusReport) -> String {
        var s = "| File | Features | Parse | Rewrite identical | Typed blocks | Tree vs Photoshop | Merged vs PS composite (max / mean levels) | Alpha | Notes |\n|---|---|---|---|---|---|---|---|---|\n"
        for f in r.files {
            let typed = f.parsed ? (f.typedFailures.isEmpty ? "ok (\(f.typedChecked))" : "**\(f.typedFailures.count) fail**") : "–"
            let tree = f.treeMatch.map { $0 ? "match" : "**\(f.mismatches.count) diff**" } ?? "–"
            let merged = f.merged.map { "\(fmt($0.max8)) / \(fmt($0.mean8, 3))" } ?? (f.mergedError ?? "–")
            let alpha = f.mergedAlpha.map { "\(fmt($0.max8)) / \(fmt($0.mean8, 3))" } ?? "–"
            var notes: [String] = []
            notes += f.typedFailures.prefix(3)
            notes += f.mismatches.prefix(3).map(\.description)
            if let n = f.rewriteNote { notes.append(n) }
            if !f.linter.isEmpty { notes.append("linter: " + f.linter.prefix(2).joined(separator: "; ")) }
            if let e = f.parseError { notes.append(e) }
            s += "| \(f.file) | \(f.features.joined(separator: ", ")) | \(f.parsed ? "ok" : "**fail**") | \(f.byteIdentical.map { $0 ? "yes" : "**no**" } ?? "–") | \(typed) | \(tree) | \(merged) | \(alpha) | \(notes.joined(separator: "; ").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")) |\n"
        }
        s += "\nTyped round trips: " + r.typed.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.ok)/\($0.value.total)" }.joined(separator: ", ") + "\n"
        return s
    }
}
