// Measurement batch M3: Photoshop 27's Light-mode Brightness/Contrast on the M1 identity lattice.
// First the default Light descriptor and each control's accepted range (one document, nothing
// saved), then the sweeps, each job read back (mode Light, every control as asked). Same protocol
// and manifest format as M1/M2.

import Foundation

public enum MeasureM3 {
    /// Exposure steps spanning the accepted range: its ends, halves and quarters.
    static func exposureSteps(_ probes: [[String: Any]]) -> [Double]? {
        let ok = probes.compactMap { p -> Double? in
            guard p["error"] == nil, let a = p["asked"] as? Double, let s = p["stored"] as? Double, abs(a - s) < 1e-6 else { return nil }
            return a
        }
        guard let lo = ok.min(), let hi = ok.max(), lo < 0, hi > 0 else { return nil }
        return [lo, lo / 2, lo / 4, hi / 4, hi / 2, hi]
    }

    /// Each control's accepted interval from the probes: the extreme values stored as asked, and
    /// what happened beyond them.
    static func ranges(_ probes: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in probes {
            guard let list = v as? [[String: Any]] else { continue }
            let ok = list.compactMap { p -> Double? in
                guard p["error"] == nil, let a = p["asked"] as? Double, let s = p["stored"] as? Double, abs(a - s) < 1e-6 else { return nil }
                return a
            }
            let beyond = list.filter { p in
                guard let a = p["asked"] as? Double else { return false }
                return a < (ok.min() ?? 0) || a > (ok.max() ?? 0)
            }.map { p -> String in
                let a = p["asked"] as? Double ?? .nan
                if let e = p["error"] as? String { return "\(a): refused (\(e.prefix(80)))" }
                return "\(a): stored \(p["stored"] ?? "?")"
            }
            out[k] = ["acceptedMin": ok.min() as Any, "acceptedMax": ok.max() as Any, "beyond": beyond]
        }
        return out
    }

    public static func run(ps: Photoshop, out: URL, only: Set<String>?, log: (String) -> Void) throws -> Int32 {
        let dir = URL(fileURLWithPath: try ps.config.checked(out.path))
        for sub in ["inputs", "psd", "tif"] { try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true) }
        var args: [String: Any] = ["inputs": try ps.config.checked(dir.appendingPathComponent("inputs").path), "out": dir.path]
        var defaults = try ps.run("measure-m3", args.merging(["op": "light-defaults"]) { a, _ in a })
        guard defaults["ok"] as? Bool == true else { log("STOPPED: light-defaults failed: \(defaults["error"] ?? "?")"); return 3 }
        defaults.removeValue(forKey: "ok")
        let probes = defaults["probes"] as? [String: Any] ?? [:]
        let lightRanges = ranges(probes)
        log("Light controls: \(lightRanges)")
        guard let steps = exposureSteps(probes["brightnessExposure"] as? [[String: Any]] ?? []) else { log("STOPPED: no Exposure range found"); return 3 }
        args["exposureSteps"] = steps
        log("Exposure steps: \(steps)")
        let inputs = try MeasureM1.writeInputs(dir.appendingPathComponent("inputs"))
        var env = try ps.run("measure-m3", args.merging(["op": "env"]) { a, _ in a })
        env.removeValue(forKey: "ok")
        env.removeValue(forKey: "contourPresets")
        let listing = try ps.run("measure-m3", args.merging(["op": "list"]) { a, _ in a })
        let jobs = ((listing["jobs"] as? [[String: Any]]) ?? []).filter { only == nil || only!.contains($0["id"] as? String ?? "") }
        var results: [[String: Any]] = []
        var stopped: String?
        func writeManifest() throws {
            var manifest: [String: Any] = ["batch": "M3", "created": ISO8601DateFormatter().string(from: Date()), "photoshop": env,
                                           "lightModeDescriptor": ["default": defaults["defaultDescriptor"] as Any, "acceptedRanges": lightRanges,
                                                                   "probes": probes, "afterReset": defaults["afterReset"] as Any],
                                           "exposureSteps": steps, "inputs": inputs, "inputLayout": MeasureM1.inputLayout, "jobs": results,
                                           "notes": [
                                               "Photoshop only created documents or opened the PNG inputs above; no PSD was opened.",
                                               "Each job: <id>.psd (Maximize Compatibility) and <id>.tif (flattened duplicate, uncompressed, document depth, ICC embedded).",
                                               "Brightness/Contrast in Light mode (brightnessMode = brightnessModeLight), set when the layer is made; every job reads the layer back and fails unless the mode is Light and every control is stored as asked ('stored', 'descriptor').",
                                               "lightModeDescriptor: the default B/C layer of a new RGB 8-bit document (no mode asked for), and each control probed from inside to beyond plausible limits in that one document (nothing saved): accepted = stored as asked.",
                                               "Controls not swept in a job are at their default (0). Contrast jobs are at Exposure 0, to tie to M1's bc-* jobs (Light mode, Brgh ignored).",
                                               "Inputs open untagged; each job assigns sRGB IEC61966-2.1, which does not change pixel values. 16-bit: use tif/identity-rgb16.tif as the effective input.",
                                           ]]
            if let s = stopped { manifest["stopped"] = s }
            let d = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try d.write(to: dir.appendingPathComponent("manifest.json"))
        }
        for (i, job) in jobs.enumerated() {
            let id = job["id"] as? String ?? "?"
            var rec = job
            do {
                var r = try ps.run("measure-m3", args.merging(["op": "run", "job": id]) { a, _ in a })
                if r["ok"] as? Bool != true {
                    rec["error"] = r["error"] ?? "unknown"
                    log("[\(i + 1)/\(jobs.count)] \(id): FAILED \(r["error"] ?? "")")
                } else {
                    for k in ["psd", "tif"] { if let p = r[k] as? String { r[k] = String(p.dropFirst(dir.path.count + 1)) } }
                    r.removeValue(forKey: "ok")
                    rec["result"] = r
                    log("[\(i + 1)/\(jobs.count)] \(id): ok (\(r["mode"] ?? "?") \(r["bits"] ?? "?")-bit, \(r["profile"] ?? "untagged"))")
                }
            } catch let e as OracleError where e.isFatal {
                rec["error"] = "\(e)"
                results.append(rec)
                stopped = "one strike at job \(id): \(e)"
                try writeManifest()
                log("STOPPED at \(id): \(e)")
                return 3
            }
            results.append(rec)
            try writeManifest()
        }
        var analysis: [String: Any] = [:]
        func tif(_ id: String) -> String { dir.appendingPathComponent("tif/\(id).tif").path }
        for (id, bits) in [("identity-rgb8", 8), ("identity-rgb16", 16), ("light-default-rgb8", 8)] where FileManager.default.fileExists(atPath: tif(id)) {
            analysis[id + (id.hasPrefix("light") ? " (identity?)" : "")] = MeasureM1.identityCheck(tif(id), kind: .identity, bits: bits)
        }
        for i in results.indices {
            guard let g = results[i]["group"] as? String, g.hasPrefix("light"), var r = results[i]["result"] as? [String: Any], let psd = r["psd"] as? String else { continue }
            r["storedInFile"] = MeasureM2.fileAdjustment(dir.appendingPathComponent(psd).path, key: "CgEd")
            results[i]["result"] = r
        }
        results.append(["id": "analysis", "group": "analysis", "result": analysis])
        try writeManifest()
        log("analysis: \(analysis)")
        return 0
    }
}
