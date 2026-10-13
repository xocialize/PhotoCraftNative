// Measurement batch M2 (PCRender phase 5): modern Brightness/Contrast and its pivot, Satin without
// anti-aliasing, Dissolve coverage (aggregate numbers only), Vibrance hold-outs, Luminosity at
// 50 %, and the 12 default contour presets rendered through Outer Glow. Same protocol and manifest
// format as M1: this side writes the PNG inputs, runs `measure-m2.jsx` job by job under the
// one-strike policy, analyses the outputs offline and writes the manifest.
//
// Contour presets: the manifest carries each preset's NAME only. No curve is read from Photoshop
// or from any file, and those jobs save no PSD.

import Foundation
import PCPSD

public enum MeasureM2 {
    public static let pivotInputs = ["flat-032", "flat-064", "flat-096", "flat-128", "flat-160", "flat-192", "flat-224", "lattice-half", "lattice-left-black"]

    /// A B/C pivot input: the identity layout with the lattice rows replaced; the grey ramp strip
    /// (rows 512–527) is kept.
    static func pivotPixels(_ name: String) -> [Int] {
        var px = MeasureM1.pixels(.identity)
        let w = MeasureM1.width
        for y in 0 ..< MeasureM1.latticeRows {
            for x in 0 ..< w {
                for c in 0 ..< 3 {
                    let o = (y * w + x) * 3 + c
                    if name.hasPrefix("flat-") { px[o] = Int(name.dropFirst(5))! }
                    else if name == "lattice-half" { px[o] = (px[o] + 1) / 2 }
                    else if name == "lattice-left-black", x < w / 2 { px[o] = 0 }
                }
            }
        }
        return px
    }

    static func means(_ px: [Int]) -> [String: Any] {
        let n = px.count / 3
        var all = [0.0, 0.0, 0.0], lat = [0.0, 0.0, 0.0]
        let latN = MeasureM1.width * MeasureM1.latticeRows
        for i in 0 ..< n { for c in 0 ..< 3 { all[c] += Double(px[i * 3 + c]); if i < latN { lat[c] += Double(px[i * 3 + c]) } } }
        return ["meanRGB": all.map { $0 / Double(n) }, "meanRGBLatticeRows": lat.map { $0 / Double(latN) }]
    }

    public static func writeInputs(_ dir: URL) throws -> [[String: Any]] {
        var out = try MeasureM1.writeInputs(dir)
        for name in pivotInputs {
            let px = pivotPixels(name)
            let url = dir.appendingPathComponent("\(name)-rgb8.png")
            try MeasureM1.writePNG(px, to: url, bits: 8)
            var rec: [String: Any] = ["file": "inputs/" + url.lastPathComponent, "kind": name, "bits": 8, "width": MeasureM1.width, "height": MeasureM1.height,
                                      "colorSpace": "sRGB IEC61966-2.1 (embedded)"]
            rec.merge(means(px)) { a, _ in a }
            out.append(rec)
        }
        return out
    }

    public static var inputLayout: [String: String] {
        var l = MeasureM1.inputLayout
        l["flat-NNN"] = "rows 0–511 flat grey NNN in all three channels; rows 512–527 the identity grey ramp"
        l["lattice-half"] = "the identity lattice with every value v replaced by (v + 1) / 2 (integer division, i.e. v × 0.5 rounded half up); identity ramp strip"
        l["lattice-left-black"] = "the identity lattice with columns 0–255 of rows 0–511 set to 0; identity ramp strip"
        return l
    }

    // MARK: offline analysis

    static func readTIFF(_ path: String) -> ReferenceImage? { try? ReferenceImageReader.read(contentsOf: URL(fileURLWithPath: path)) }

    /// Red (dissolved-in) pixels: red over white, so green < 128.
    static func redMap(_ img: ReferenceImage) -> [Bool] { img.planes[1].map { $0 < 128 } }

    /// Aggregate Dissolve coverage of one composite.
    static func coverage(_ tif: String) -> [String: Any] {
        guard let img = readTIFF(tif) else { return ["error": "cannot read \(tif)"] }
        let red = redMap(img)
        let n = red.filter { $0 }.count
        var partial = 0
        for i in 0 ..< img.width * img.height where img.planes[1][i] > 0 && img.planes[1][i] < 255 { partial += 1 }
        return ["coverage": Double(n) / Double(red.count), "pixels": red.count, "nonBinaryPixels": partial]
    }

    /// The 4096 × 64 canvas: coverage per 512-column block, and how often a pixel equals the one
    /// P columns to its right (1.0 would mean the pattern repeats with period P).
    static func longPeriod(_ tif: String, against square: String?) -> [String: Any] {
        guard let img = readTIFF(tif) else { return ["error": "cannot read \(tif)"] }
        let red = redMap(img), w = img.width, h = img.height
        var blocks: [Double] = []
        for b in 0 ..< w / 512 {
            var c = 0
            for y in 0 ..< h { for x in b * 512 ..< (b + 1) * 512 where red[y * w + x] { c += 1 } }
            blocks.append(Double(c) / Double(512 * h))
        }
        var periods: [String: Double] = [:]
        for p in [64, 128, 256, 512, 1024, 2048] {
            var same = 0, total = 0
            for y in 0 ..< h { for x in 0 ..< w - p { total += 1; if red[y * w + x] == red[y * w + x + p] { same += 1 } } }
            periods["\(p)"] = Double(same) / Double(total)
        }
        var out: [String: Any] = ["coveragePer512ColumnBlock": blocks, "fractionEqualToPixelPColumnsRight": periods,
                                  "note": "for an unrelated pattern at 50 % coverage this fraction is about 0.5"]
        if let s = square, let sq = readTIFF(s) {
            let sr = redMap(sq)
            var same = 0
            for y in 0 ..< h { for x in 0 ..< 512 where red[y * w + x] == sr[y * sq.width + x] { same += 1 } }
            out["fractionEqualTo512SquareAtSameCanvasPosition"] = Double(same) / Double(512 * h)
        }
        return out
    }

    /// The user mask Photoshop stored for the 50 %-grey mask job.
    static func maskValues(_ psd: String) -> [String: Any] {
        guard let f = try? PSDFile(contentsOf: URL(fileURLWithPath: psd)) else { return ["error": "cannot read \(psd)"] }
        for v in f.layerViews {
            guard case let .success(m)? = v.userMask() else { continue }
            let vals = Set(m.data)
            return ["layer": v.index, "rect": [m.left, m.top, m.width, m.height], "distinctValues": vals.sorted().prefix(8).map { Int($0) }, "default": Int(m.defaultValue)]
        }
        return ["error": "no user mask"]
    }

    /// The flat settings of the first `key` block (CgEd, vibA) in a saved job PSD, as Photoshop
    /// wrote them (CgEd also carries `means`, the image mean the contrast pivots on).
    static func fileAdjustment(_ psd: String, key: String) -> [String: Any]? {
        guard let f = try? PSDFile(contentsOf: URL(fileURLWithPath: psd)) else { return nil }
        for r in f.layers {
            guard let b = r.block(FourCC(stringLiteral: key)), let (vd, _) = try? PSDVersionedDescriptor.parsePrefix(b.data) else { continue }
            var out: [String: Any] = [:]
            for it in vd.descriptor.items {
                let v = it.value
                if let n = v.number { out[it.key.description] = n } else if let b = v.bool { out[it.key.description] = b } else if let e = v.enumValue { out[it.key.description] = e }
            }
            return out
        }
        return nil
    }

    /// Removes any contour curve from a contour-preset job record (names only, by rule).
    static func namesOnly(_ v: Any) -> Any {
        if var d = v as? [String: Any] {
            for k in ["points", "curve", "Crv ", "curvePoints"] { d.removeValue(forKey: k) }
            for (k, x) in d { d[k] = namesOnly(x) }
            return d
        }
        if let a = v as? [Any] { return a.map(namesOnly) }
        return v
    }

    // MARK: run

    public static func run(ps: Photoshop, out: URL, only: Set<String>?, probeOnly: Bool, log: (String) -> Void) throws -> Int32 {
        let dir = URL(fileURLWithPath: try ps.config.checked(out.path))
        for sub in ["inputs", "psd", "tif"] { try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true) }
        let args: [String: Any] = ["inputs": try ps.config.checked(dir.appendingPathComponent("inputs").path), "out": dir.path]
        // The one-document Brightness/Contrast check first: nothing is saved by it.
        let probe = try ps.run("measure-m2", args.merging(["op": "probe-bc"]) { a, _ in a })
        log("probe-bc: \(probe)")
        guard probe["ok"] as? Bool == true, let stored = probe["stored"] as? [String: Any],
              let b = (stored["brightness"] ?? stored["Brgh"]) as? Double, b == 25 else {
            log("STOPPED: the modern Brightness/Contrast check did not store Brightness 25")
            return 3
        }
        if probeOnly { return 0 }
        let inputs = try writeInputs(dir.appendingPathComponent("inputs"))
        log("inputs written and read back exactly: \(inputs.count) PNGs")
        var env = try ps.run("measure-m2", args.merging(["op": "env"]) { a, _ in a })
        env.removeValue(forKey: "ok")
        let listing = try ps.run("measure-m2", args.merging(["op": "list"]) { a, _ in a })
        let jobs = ((listing["jobs"] as? [[String: Any]]) ?? []).filter { only == nil || only!.contains($0["id"] as? String ?? "") }
        let presets = Set((env["contourPresets"] as? [String]) ?? [])
        for j in jobs where j["group"] as? String == "contour-presets" {
            let name = ((j["params"] as? [String: Any])?["contour"] as? String) ?? ""
            guard presets.contains(name) else { log("STOPPED: contour preset \"\(name)\" is not in Photoshop's preset list"); return 3 }
        }
        var results: [[String: Any]] = []
        var stopped: String?
        func writeManifest() throws {
            var manifest: [String: Any] = ["batch": "M2", "created": ISO8601DateFormatter().string(from: Date()), "photoshop": env,
                                           "brightnessContrastCheck": probe, "inputs": inputs, "inputLayout": inputLayout,
                                           "jobs": results.map { $0["group"] as? String == "contour-presets" ? namesOnly($0) : $0 },
                                           "notes": [
                                               "Photoshop only created documents or opened the PNG inputs above; no PSD was opened.",
                                               "Each job: <id>.psd (Maximize Compatibility) and <id>.tif (flattened duplicate, uncompressed, document depth, ICC embedded), except dissolve-coverage and contour-presets jobs, which save the TIFF only (dissolve-mask50 also saves its PSD, to check the mask).",
                                               "Brightness/Contrast: brightnessModeModern, chosen when the layer is made. Photoshop 27 makes RGB 8/16-bit B/C layers in Light mode by default, which ignores Brightness (M1's bc-* jobs were made so: Brgh stored 0). Every adjustment job reads its settings back and fails if Photoshop stored anything else; 'stored' is that read-back.",
                                               "Dissolve: aggregate coverage only (fraction of red pixels, green < 128); no per-pixel tables are kept in this manifest.",
                                               "Contour presets: each job names a preset; the manifest records the name only. The curve Photoshop stores for a preset was not read, and no PSD was saved for these jobs.",
                                               "Satin, Outer Glow: settings read back after they were set ('stored'); contour names only.",
                                               "Inputs open untagged; each job assigns sRGB IEC61966-2.1, which does not change pixel values. 16-bit: use tif/identity-rgb16.tif as the effective input (Photoshop stores 15 bits).",
                                           ]]
            if let s = stopped { manifest["stopped"] = s }
            let d = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try d.write(to: dir.appendingPathComponent("manifest.json"))
        }
        for (i, job) in jobs.enumerated() {
            let id = job["id"] as? String ?? "?"
            var rec = job
            do {
                var r = try ps.run("measure-m2", args.merging(["op": "run", "job": id]) { a, _ in a })
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
        // Offline analysis.
        var analysis: [String: Any] = [:]
        func tif(_ id: String) -> String { dir.appendingPathComponent("tif/\(id).tif").path }
        func has(_ id: String) -> Bool { FileManager.default.fileExists(atPath: tif(id)) }
        if has("identity-rgb8") { analysis["identity-rgb8"] = MeasureM1.identityCheck(tif("identity-rgb8"), kind: .identity, bits: 8) }
        if has("identity-rgb16") { analysis["identity-rgb16"] = MeasureM1.identityCheck(tif("identity-rgb16"), kind: .identity, bits: 16) }
        if has("bcm-b0-c0-rgb8") { analysis["bcm-b0-c0-rgb8 (identity?)"] = MeasureM1.identityCheck(tif("bcm-b0-c0-rgb8"), kind: .identity, bits: 8) }
        for i in results.indices where results[i]["group"] as? String == "dissolve-coverage" {
            guard let id = results[i]["id"] as? String, has(id), var r = results[i]["result"] as? [String: Any] else { continue }
            r["coverage"] = coverage(tif(id))
            if id == "dissolve-long-4096x64-o50" { r["longCanvas"] = longPeriod(tif(id), against: has("dissolve-o50") ? tif("dissolve-o50") : nil) }
            if id == "dissolve-mask50", let psd = r["psd"] as? String { r["storedMask"] = maskValues(dir.appendingPathComponent(psd).path) }
            results[i]["result"] = r
        }
        for i in results.indices {
            guard let g = results[i]["group"] as? String, g.hasPrefix("brightness-contrast") || g == "vibrance",
                  var r = results[i]["result"] as? [String: Any], let psd = r["psd"] as? String else { continue }
            r["storedInFile"] = fileAdjustment(dir.appendingPathComponent(psd).path, key: g == "vibrance" ? "vibA" : "CgEd")
            results[i]["result"] = r
        }
        results.append(["id": "analysis", "group": "analysis", "result": analysis])
        try writeManifest()
        log("analysis: \(analysis)")
        return 0
    }
}
