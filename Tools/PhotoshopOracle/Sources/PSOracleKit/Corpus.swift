// The Photoshop-authored oracle corpus: `corpus.jsx` holds the catalogue (one builder per file);
// this side asks Photoshop for the catalogue, has it build and save each file (Maximize
// Compatibility on), exports Photoshop's own flattened composite, records Photoshop's reading of the
// saved file, and writes `manifest.json`.

import Foundation
import PCPSD

public struct CorpusComposite: Codable, Sendable {
    public var path: String
    public var format: String
    public var width: Int?
    public var height: Int?
    public var channels: Int?
    public var bits: Int?
}

public struct CorpusEntry: Codable, Sendable {
    public var file: String
    public var description: String
    public var features: [String]
    public var mode: String?
    public var bits: Int?
    public var layerRecords: Int?
    public var maximizeCompatibility: Bool
    public var composite: CorpusComposite?
    public var alphaComposite: CorpusComposite?
    /// Photoshop's reading of the saved file (`info` JSON), relative to the corpus directory.
    public var photoshop: String?
    public var buildNotes: [String]?
    /// Feature tags Photoshop's reading of the saved file confirms / does not show / cannot show.
    public var featuresConfirmed: [String]?
    public var featuresNotSeen: [String]?
    public var featuresNotCheckable: [String]?
    /// Tags Photoshop's report cannot show, confirmed in the Photoshop-written blocks instead.
    public var featuresConfirmedInFile: [String]?

    public mutating func checkFeatures(_ dir: URL) {
        guard let info = photoshopInfo(dir) else { return }
        let r = FeatureCheck.verify(features, info: info, fileExtension: (file as NSString).pathExtension)
        let unknown = features.filter { r[$0] == .some(nil) || r[$0] == nil }
        let inFile = (try? PSDFile(contentsOf: dir.appendingPathComponent(file))).map { FeatureCheck.verifyInFile(unknown, file: $0) } ?? [:]
        featuresConfirmed = features.filter { r[$0] == .some(true) }
        featuresConfirmedInFile = unknown.filter { inFile[$0] == true }
        featuresNotSeen = features.filter { r[$0] == .some(false) } + unknown.filter { inFile[$0] == false }
        featuresNotCheckable = unknown.filter { inFile[$0] == nil }
    }

    public func photoshopInfo(_ dir: URL) -> [String: Any]? {
        guard let p = photoshop, let d = try? Data(contentsOf: dir.appendingPathComponent(p)) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    public func readComposite(_ dir: URL, _ c: CorpusComposite) throws -> ReferenceImage {
        let url = dir.appendingPathComponent(c.path)
        if c.format == "raw" {
            return try ReferenceImageReader.readRaw(contentsOf: url, width: c.width ?? 0, height: c.height ?? 0, channels: c.channels ?? 1, bits: c.bits ?? 8)
        }
        return try ReferenceImageReader.read(contentsOf: url)
    }
}

public struct CorpusSkip: Codable, Sendable {
    public var name: String
    public var features: [String]
    public var reason: String
}

public struct CorpusManifest: Codable, Sendable {
    public var generator: String
    public var photoshopVersion: String
    public var created: String
    public var notes: [String]
    public var files: [CorpusEntry]
    public var skipped: [CorpusSkip]

    /// Re-checks every entry's features against Photoshop's stored reading and rewrites the manifest.
    public static func annotate(_ dir: URL) throws {
        guard var m = load(dir) else { return }
        for i in m.files.indices { m.files[i].checkFeatures(dir) }
        try CorpusBuilder.write(m, to: dir)
    }

    public static func load(_ dir: URL) -> CorpusManifest? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONDecoder().decode(CorpusManifest.self, from: d)
    }
}

public enum CorpusBuilder {
    static func int(_ v: Any?) -> Int? { (v as? Int) ?? (v as? Double).map { Int($0) } }

    static func composite(_ v: Any?, relativeTo dir: URL) -> CorpusComposite? {
        guard let c = v as? [String: Any], let p = c["path"] as? String else { return nil }
        let rel = p.hasPrefix(dir.path + "/") ? String(p.dropFirst(dir.path.count + 1)) : p
        return CorpusComposite(path: rel, format: c["format"] as? String ?? "tiff", width: int(c["width"]), height: int(c["height"]),
                               channels: int(c["channels"]), bits: int(c["bits"]))
    }

    public static func build(ps: Photoshop, out: URL, only: Set<String>?, listOnly: Bool, log: (String) -> Void, emit: (String) -> Void) throws {
        let dir = URL(fileURLWithPath: try ps.config.checked(out.path))
        let catalogue = try ps.run("corpus", ["op": "list"])
        guard let items = catalogue["items"] as? [[String: Any]] else { throw OracleError.badOutput("corpus list: \(catalogue)") }
        if listOnly {
            for i in items { emit("\(i["name"] ?? "?").\(i["ext"] ?? "psd")\t\((i["features"] as? [String] ?? []).joined(separator: ", "))") }
            emit("\(items.count) corpus files")
            return
        }
        for sub in ["", "composites", "info"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        var manifest = CorpusManifest.load(dir) ?? CorpusManifest(generator: "ps-oracle corpus build", photoshopVersion: "", created: "", notes: [], files: [], skipped: [])
        manifest.photoshopVersion = (try? ps.ping())?["version"] as? String ?? "?"
        manifest.created = ISO8601DateFormatter().string(from: Date())
        manifest.notes = [
            "Every file was built by ExtendScript (DOM + Action Manager) in Photoshop and saved with Maximize Compatibility on.",
            "composites/<name>.tif is Photoshop's flattened composite of the saved file, reopened (uncompressed TIFF, document mode and depth, ICC embedded; Photoshop Raw for Duotone/Multichannel).",
            "composites/<name>-alpha.tif is the composite with transparency, for documents without a background layer.",
            "info/<name>.json is Photoshop's own reading of the saved file (ps-oracle info).",
        ]
        let selected = items.filter { only == nil || only!.contains($0["name"] as? String ?? "") }
        for (n, item) in selected.enumerated() {
            let name = item["name"] as? String ?? "?"
            let ext = item["ext"] as? String ?? "psd"
            let features = item["features"] as? [String] ?? []
            let fileURL = dir.appendingPathComponent("\(name).\(ext)")
            manifest.files.removeAll { $0.file == fileURL.lastPathComponent }
            manifest.skipped.removeAll { $0.name == name }
            let started = Date()
            let built: [String: Any]
            do {
                built = try ps.run("corpus", ["op": "build", "name": name, "out": try ps.config.checked(fileURL.path)], timeout: max(ps.config.timeout, 300))
            } catch let e as OracleError {
                if e.isFatal { throw e }
                built = ["ok": false, "error": "\(e)"]
            }
            guard built["ok"] as? Bool == true else {
                let reason = built["error"] as? String ?? "unknown"
                manifest.skipped.append(CorpusSkip(name: name, features: features, reason: reason))
                log("[\(n + 1)/\(selected.count)] \(name): NOT BUILT — \(reason)")
                try write(manifest, to: dir)
                continue
            }
            // Photoshop's reading of the saved file and its composite (a fresh open of the file).
            let comp = try ps.config.checked(dir.appendingPathComponent("composites/\(name).\(built["compositeFormat"] as? String == "raw" ? "raw" : "tif")").path)
            let alpha = try ps.config.checked(dir.appendingPathComponent("composites/\(name)-alpha.tif").path)
            var probe: [String: Any] = [:]
            do { probe = try ps.run("probe", ["path": fileURL.path, "out": comp, "alphaOut": alpha]) } catch let e as OracleError {
                if e.isFatal { throw e }
                probe = ["ok": false, "error": "\(e)"]
            }
            let infoRel = "info/\(name).json"
            if let d = try? JSONSerialization.data(withJSONObject: probe, options: [.prettyPrinted, .sortedKeys]) {
                try d.write(to: dir.appendingPathComponent(infoRel))
            }
            var notes = built["notes"] as? [String] ?? []
            if probe["ok"] as? Bool != true { notes.append("reopen failed: \(probe["error"] ?? "?")") }
            // What the file really holds, from PCPSD (merged data flag = Maximize Compatibility).
            var real: Bool?
            if let f = try? PSDFile(contentsOf: fileURL) { real = f.hasRealMergedData }
            if real == false { notes.append("PCPSD: version info says the merged image is not real") }
            manifest.files.append(CorpusEntry(file: fileURL.lastPathComponent, description: item["description"] as? String ?? "", features: features,
                                              mode: probe["mode"] as? String, bits: int(probe["bits"]), layerRecords: (probe["layers"] as? [Any])?.count,
                                              maximizeCompatibility: real ?? (built["maximizeCompatibility"] as? Bool ?? true),
                                              composite: composite(probe["composite"], relativeTo: dir), alphaComposite: composite(probe["alphaComposite"], relativeTo: dir),
                                              photoshop: infoRel, buildNotes: notes.isEmpty ? nil : notes))
            manifest.files[manifest.files.count - 1].checkFeatures(dir)
            manifest.files.sort { $0.file < $1.file }
            try write(manifest, to: dir)
            log("[\(n + 1)/\(selected.count)] \(name).\(ext): \(probe["mode"] ?? "?") \(probe["bits"] ?? "?")-bit, \((probe["layers"] as? [Any])?.count ?? 0) records (\(String(format: "%.1f", Date().timeIntervalSince(started)))s)\(notes.isEmpty ? "" : " — " + notes.joined(separator: "; "))")
        }
        emit("corpus: \(manifest.files.count) files, \(manifest.skipped.count) not buildable; manifest \(dir.appendingPathComponent("manifest.json").path)")
    }

    static func write(_ m: CorpusManifest, to dir: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(m).write(to: dir.appendingPathComponent("manifest.json"))
    }
}
