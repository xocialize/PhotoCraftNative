// The acceptance sweep: for each PSD/PSB, Photoshop opens it once (info + flattened composite +
// transparent composite + every pixel layer on its own), then PCPSD reads the same file and the two
// readings are compared — the layer tree field by field, the merged image against Photoshop's
// composite, and each pixel layer against Photoshop's export of it.

import Foundation
import PCPSD

public struct LayerCheck: Codable, Sendable {
    public var record: Int
    public var name: String
    public var color: PixelDiff?
    public var alpha: PixelDiff?
    public var maskedAlpha: PixelDiff?
    public var error: String?
}

public struct SweepRow: Codable, Sendable {
    public var file: String
    public var bytes: Int
    // PCPSD
    public var pcpsdParsed = false
    public var pcpsdError: String?
    public var pcpsdIssues: [String] = []
    // Photoshop
    public var opened = false
    public var photoshopError: String?
    public var photoshopWarnings: [String] = []
    public var photoshopDoc: DocFacts?
    public var pcpsdDoc: DocFacts?
    // Comparisons
    public var treeMatch: Bool?
    public var mismatches: [FactMismatch] = []
    public var composite: PixelDiff?
    public var compositeError: String?
    public var alpha: PixelDiff?
    public var layers: [LayerCheck] = []
    public var seconds: Double = 0

    public init(file: String, bytes: Int) {
        self.file = file
        self.bytes = bytes
    }

    public var layersWorst: Double? {
        let v = layers.flatMap { [$0.color?.max8, $0.alpha?.max8, $0.maskedAlpha?.max8].compactMap { $0 } }
        return v.max()
    }
}

/// Photoshop stopped answering (or crashed) on `row.file`: the sweep records the row and stops.
public struct SweepStop: Error, CustomStringConvertible {
    public var row: SweepRow
    public var error: OracleError
    public var description: String { "\(row.file): \(error)" }
}

public enum Sweep {
    /// PSD/PSB files under `dir` (recursively), skipping directories named in `skip`.
    public static func files(in dir: URL, skip: Set<String> = []) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skip.contains(url.lastPathComponent) { e.skipDescendants() }
                continue
            }
            if ["psd", "psb"].contains(url.pathExtension.lowercased()) { out.append(url) }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Photoshop's composite of `file` (TIFF or Raw) read back.
    public static func readComposite(_ info: [String: Any], key: String) throws -> ReferenceImage? {
        guard let c = info[key] as? [String: Any], let path = c["path"] as? String else { return nil }
        if c["format"] as? String == "raw" {
            return try ReferenceImageReader.readRaw(contentsOf: URL(fileURLWithPath: path), width: c["width"] as? Int ?? Int(c["width"] as? Double ?? 0),
                                                    height: c["height"] as? Int ?? Int(c["height"] as? Double ?? 0),
                                                    channels: c["channels"] as? Int ?? 1, bits: c["bits"] as? Int ?? 8)
        }
        return try ReferenceImageReader.read(contentsOf: URL(fileURLWithPath: path))
    }

    /// Runs one file. `outDir` receives Photoshop's report and exports.
    public static func run(_ url: URL, ps: Photoshop, outDir: URL, layerExports: Bool, log: (String) -> Void) throws -> SweepRow {
        let started = Date()
        let path = try ps.config.checked(url.path)
        var row = SweepRow(file: url.lastPathComponent, bytes: (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
        let stem = outDir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-" + url.pathExtension.lowercased()).path
        // PCPSD first (a parse failure is a finding, not a reason to skip Photoshop).
        var file: PSDFile?
        do {
            let f = try PSDFile(contentsOf: url)
            file = f
            row.pcpsdParsed = true
            row.pcpsdDoc = PCPSDFacts.doc(f)
            row.pcpsdIssues = f.compatibilityIssues().map(\.description) + f.warnings.map { "warning: \($0)" }
        } catch {
            row.pcpsdError = "\(error)"
        }
        var args: [String: Any] = ["path": path, "out": try ps.config.checked(stem + "-composite.tif"), "alphaOut": try ps.config.checked(stem + "-alpha.tif")]
        if file?.header.colorMode == .multichannel || file?.header.colorMode == .duotone { args["out"] = try ps.config.checked(stem + "-composite.raw") }
        if layerExports, let f = file, !f.layers.isEmpty { args["layerPrefix"] = try ps.config.checked(stem + "-L") }
        let info: [String: Any]
        do {
            try ps.admit(URL(fileURLWithPath: path))
            info = try ps.run("probe", args)
        } catch let e as OracleError {
            switch e {
            case let .crashed(why): ps.quarantine(URL(fileURLWithPath: path), reason: "crashed Photoshop on open: \(why)")
            case let .timedOut(_, t): ps.quarantine(URL(fileURLWithPath: path), reason: "Photoshop did not finish within \(Int(t)) s")
            case let .unresponsive(why): ps.quarantine(URL(fileURLWithPath: path), reason: "Photoshop stopped answering: \(why)")
            case let .modal(why): ps.quarantine(URL(fileURLWithPath: path), reason: "raised a modal dialog on open: \(why)")
            default: break
            }
            if e.isFatal {
                var r = row
                r.photoshopError = "\(e)"
                throw SweepStop(row: r, error: e)
            }
            row.photoshopError = "\(e)"
            row.seconds = Date().timeIntervalSince(started)
            return row
        }
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: stem + ".photoshop.json"))
        }
        row.opened = info["opened"] as? Bool ?? false
        if !(info["ok"] as? Bool ?? false) {
            row.photoshopError = info["error"] as? String ?? "unknown"
            row.seconds = Date().timeIntervalSince(started)
            return row
        }
        row.photoshopWarnings = (info["warnings"] as? [String] ?? []) + ((info["steps"] as? [String: String]) ?? [:]).map { "\($0.key): \($0.value)" }
        let psDoc = PhotoshopFacts.doc(info)
        row.photoshopDoc = psDoc
        guard let f = file, let ourDoc = row.pcpsdDoc else {
            row.seconds = Date().timeIntervalSince(started)
            return row
        }
        row.mismatches = FactComparison.compare(docPS: psDoc, docOurs: ourDoc, layersPS: PhotoshopFacts.layers(info), layersOurs: PCPSDFacts.layers(f))
        row.treeMatch = row.mismatches.isEmpty
        do {
            if let ref = try readComposite(info, key: "composite") { row.composite = try PixelCompare.merged(f, against: ref) }
        } catch { row.compositeError = "\(error)" }
        do {
            if let ref = try readComposite(info, key: "alphaComposite") { row.alpha = try PixelCompare.mergedAlpha(f, against: ref) }
        } catch { row.compositeError = (row.compositeError.map { $0 + "; " } ?? "") + "alpha: \(error)" }
        for e in (info["layerExports"] as? [[String: Any]]) ?? [] {
            let index = e["index"] as? Int ?? -1
            // Photoshop's index counts from 1 without a background, from 0 with one; records from 0.
            let record = (info["hasBackground"] as? Bool ?? false) ? index : index - 1
            var check = LayerCheck(record: record, name: e["name"] as? String ?? "")
            if let err = e["error"] as? String { check.error = err; row.layers.append(check); continue }
            guard record >= 0, record < f.layers.count else { check.error = "no matching record"; row.layers.append(check); continue }
            if f.layers[record].displayName != check.name { check.error = "record \(record) is named \(f.layers[record].displayName)" }
            let files = e["files"] as? [String: String] ?? [:]
            do {
                if let p = files["pixels"] {
                    let r = try PixelCompare.layer(f, record: record, masked: false, against: try ReferenceImageReader.read(contentsOf: URL(fileURLWithPath: p)))
                    check.color = r.color
                    check.alpha = r.alpha
                }
                if let p = files["masked"] {
                    check.maskedAlpha = try PixelCompare.layer(f, record: record, masked: true, against: try ReferenceImageReader.read(contentsOf: URL(fileURLWithPath: p))).alpha
                }
            } catch { check.error = "\(error)" }
            row.layers.append(check)
        }
        row.seconds = Date().timeIntervalSince(started)
        return row
    }

    // MARK: report

    public static func markdownTable(_ rows: [SweepRow]) -> String {
        var s = "| File | PCPSD | Opens in Photoshop | Tree match | Composite vs merged (max / mean, 8-bit levels) | Alpha | Layers worst | Notes |\n|---|---|---|---|---|---|---|---|\n"
        for r in rows {
            let opens = r.opened ? "yes" : "**no**: \(r.photoshopError ?? "")"
            let tree = r.treeMatch.map { $0 ? "yes" : "**no** (\(r.mismatches.count))" } ?? "–"
            let comp = r.composite.map { "\(fmt($0.max8)) / \(fmt($0.mean8, 3))" } ?? (r.compositeError ?? "–")
            let alpha = r.alpha.map { "\(fmt($0.max8)) / \(fmt($0.mean8, 3))" } ?? "–"
            let layers = r.layersWorst.map { fmt($0) } ?? "–"
            var notes = r.mismatches.prefix(3).map(\.description)
            notes += r.layers.compactMap { $0.error.map { "layer \($0)" } }
            if !r.pcpsdIssues.isEmpty { notes.append("PCPSD linter: \(r.pcpsdIssues.count)") }
            s += "| \(r.file) | \(r.pcpsdParsed ? "ok" : "**fail**") | \(opens.replacingOccurrences(of: "\n", with: " ")) | \(tree) | \(comp) | \(alpha) | \(layers) | \(notes.joined(separator: "; ").replacingOccurrences(of: "|", with: "\\|")) |\n"
        }
        return s
    }
}
