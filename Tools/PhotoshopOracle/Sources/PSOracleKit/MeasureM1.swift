// Measurement batch M1: Photoshop as a function oracle for PCRender's remaining ps-corpus failures
// (Satin contours, modern Brightness/Contrast, Vibrance, Luminosity/Color/Hue/Saturation, Dissolve).
// This side writes the inputs (plain sRGB PNGs, ImageIO), runs `measure-m1.jsx` job by job under the
// one-strike policy, analyses the outputs offline and writes the manifest.

import CoreGraphics
import Foundation
import ImageIO
import PCPSD

public enum MeasureM1 {
    public static let width = 512
    public static let latticeRows = 512
    public static let stripRows = 16
    public static var height: Int { latticeRows + stripRows }
    public static let latticeSize = 64

    /// Lattice level `i` (0…63) at 8 bits: round(i·255/63).
    public static func level(_ i: Int) -> Int { Int((Double(i) * 255 / 63).rounded()) }

    /// Lattice entry `n` (0…262143) as (r, g, b) levels: n = r·4096 + g·64 + b.
    public static func lattice(_ n: Int) -> (Int, Int, Int) { (level(n / 4096), level((n / 64) % 64), level(n % 64)) }

    public enum Kind: String, CaseIterable, Sendable {
        /// Pixel (x, y < 512): lattice entry y·512 + x. Strip (y ≥ 512): grey step x/2 (0…255).
        case identity
        /// The lattice reversed: entry 262143 − n; strip reversed (255 − step).
        case permA = "perm-a"
        /// Channels rotated R→G→B→R (new R = old B, new G = old R, new B = old G) of entry
        /// (n + 131072) mod 262144; strip offset by half ((step + 128) mod 256).
        case permB = "perm-b"
    }

    /// Interleaved RGB samples (0…255) of an input.
    public static func pixels(_ kind: Kind) -> [Int] {
        var out = [Int](repeating: 0, count: width * height * 3)
        let n = latticeSize * latticeSize * latticeSize
        for y in 0 ..< height {
            for x in 0 ..< width {
                let o = (y * width + x) * 3
                var rgb: (Int, Int, Int)
                if y < latticeRows {
                    let i = y * width + x
                    switch kind {
                    case .identity: rgb = lattice(i)
                    case .permA: rgb = lattice(n - 1 - i)
                    case .permB:
                        let (r, g, b) = lattice((i + n / 2) % n)
                        rgb = (b, r, g)
                    }
                } else {
                    let step = x / 2
                    let v: Int
                    switch kind {
                    case .identity: v = step
                    case .permA: v = 255 - step
                    case .permB: v = (step + 128) % 256
                    }
                    rgb = (v, v, v)
                }
                out[o] = rgb.0
                out[o + 1] = rgb.1
                out[o + 2] = rgb.2
            }
        }
        return out
    }

    /// Writes an sRGB PNG (8 or 16 bits; 16-bit samples are 8-bit × 257) and reads it back with
    /// ImageIO to confirm the samples are exact.
    public static func writePNG(_ samples: [Int], to url: URL, bits: Int) throws {
        let bpc = bits, bpp = bits * 3, bpr = width * bpp / 8
        var bytes = [UInt8]()
        bytes.reserveCapacity(bpr * height)
        for v in samples {
            if bits == 8 { bytes.append(UInt8(v)) } else {
                let w = v * 257
                bytes.append(UInt8(w >> 8)); bytes.append(UInt8(w & 0xFF))
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: bpc, bitsPerPixel: bpp, bytesPerRow: bpr, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | (bits == 16 ? CGBitmapInfo.byteOrder16Big.rawValue : 0)),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw OracleError.badOutput("cannot create PNG \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw OracleError.badOutput("cannot write \(url.path)") }
        // Read back: exact samples.
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let back = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let data = back.dataProvider?.data as Data?, back.bitsPerComponent == bits else {
            throw OracleError.badOutput("cannot read back \(url.lastPathComponent)")
        }
        let b = [UInt8](data)
        let spp = back.bitsPerPixel / back.bitsPerComponent
        let little = back.bitmapInfo.contains(.byteOrder16Little)
        for y in 0 ..< height {
            for x in 0 ..< width {
                for c in 0 ..< 3 {
                    let o = y * back.bytesPerRow + (x * spp + c) * bits / 8
                    let v = bits == 8 ? Int(b[o]) : (little ? Int(b[o]) | Int(b[o + 1]) << 8 : Int(b[o]) << 8 | Int(b[o + 1]))
                    let want = samples[(y * width + x) * 3 + c] * (bits == 8 ? 1 : 257)
                    guard v == want else { throw OracleError.badOutput("\(url.lastPathComponent) reads back \(v) at (\(x),\(y),\(c)), wrote \(want)") }
                }
            }
        }
    }

    public static func writeInputs(_ dir: URL) throws -> [[String: Any]] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [[String: Any]] = []
        for kind in Kind.allCases {
            let px = pixels(kind)
            for bits in [8, 16] {
                let url = dir.appendingPathComponent("\(kind.rawValue)-rgb\(bits).png")
                try writePNG(px, to: url, bits: bits)
                out.append(["file": "inputs/" + url.lastPathComponent, "kind": kind.rawValue, "bits": bits, "width": width, "height": height,
                            "colorSpace": "sRGB IEC61966-2.1 (embedded)"])
            }
        }
        return out
    }

    public static let inputLayout: [String: String] = [
        "size": "512 × 528: rows 0–511 the 64³ lattice, rows 512–527 a 256-step grey ramp (2 px per step)",
        "lattice": "pixel (x, y < 512) holds entry n = y·512 + x, with r = n / 4096, g = (n / 64) mod 64, b = n mod 64; channel value = round(i·255/63)",
        "identity": "entry n; strip value = x / 2",
        "perm-a": "the lattice reversed: entry 262143 − n; strip value = 255 − x / 2",
        "perm-b": "channels rotated R→G→B→R (new R = old B, new G = old R, new B = old G) of entry (n + 131072) mod 262144; strip value = (x / 2 + 128) mod 256",
        "16-bit": "the 8-bit values × 257",
    ]

    // MARK: offline analysis

    static func readTIFF(_ path: String) -> ReferenceImage? { try? ReferenceImageReader.read(contentsOf: URL(fileURLWithPath: path)) }

    /// Photoshop's composite of an unadjusted input against the input itself.
    static func identityCheck(_ tif: String, kind: Kind, bits: Int) -> [String: Any] {
        guard let img = readTIFF(tif) else { return ["error": "cannot read \(tif)"] }
        let px = pixels(kind)
        var worst = 0.0, differing = 0
        for i in 0 ..< width * height {
            for c in 0 ..< 3 {
                let want = Double(px[i * 3 + c] * (bits == 8 ? 1 : 257))
                let d = abs(img.planes[c][i] - want)
                if d > 0 { differing += 1 }
                worst = max(worst, d)
            }
        }
        return ["maxDifference": worst, "differingSamples": differing, "unit": bits == 8 ? "8-bit levels" : "16-bit units"]
    }

    /// Dissolve determinism: are the two identical builds equal, and is the offset build the same
    /// pattern shifted with the layer, anchored to the canvas, or new?
    static func dissolveCheck(_ a: String, _ b: String, _ off: String, offset: (Int, Int)) -> [String: Any] {
        guard let A = readTIFF(a), let B = readTIFF(b), let O = readTIFF(off) else { return ["error": "cannot read the dissolve TIFFs"] }
        func red(_ img: ReferenceImage, _ x: Int, _ y: Int) -> Bool { img.planes[1][y * img.width + x] < 128 }
        var sameAB = 0, total = 0
        for y in 0 ..< 256 { for x in 0 ..< 256 { total += 1; if red(A, x, y) == red(B, x, y) { sameAB += 1 } } }
        var shifted = 0, anchored = 0
        for y in 0 ..< 256 {
            for x in 0 ..< 256 {
                if red(O, x + offset.0, y + offset.1) == red(A, x, y) { shifted += 1 }
                let cx = x + offset.0, cy = y + offset.1
                if cx < 256, cy < 256, red(O, cx, cy) == red(A, cx, cy) { anchored += 1 }
            }
        }
        var redA = 0
        for y in 0 ..< 256 { for x in 0 ..< 256 where red(A, x, y) { redA += 1 } }
        let anchoredTotal = (256 - offset.0) * (256 - offset.1)
        let verdict: String
        if sameAB == total, shifted == total { verdict = "deterministic, and the pattern moves with the layer (identical when shifted by the layer offset)" } else if sameAB == total, anchored == anchoredTotal { verdict = "deterministic, anchored to the canvas (identical at the same canvas coordinates)" } else if sameAB == total { verdict = "deterministic for identical documents, but reseeded when the layer is offset" } else { verdict = "reseeded: two identical builds differ" }
        return ["redFractionA": Double(redA) / Double(total), "identicalAB": Double(sameAB) / Double(total),
                "offsetMatchesShifted": Double(shifted) / Double(total), "offsetMatchesSameCanvasPosition": Double(anchored) / Double(max(anchoredTotal, 1)),
                "verdict": verdict]
    }

    /// The Satin contour Photoshop stored (name and curve points) in a saved job PSD.
    static func storedContour(_ psd: String) -> [String: Any]? {
        guard let f = try? PSDFile(contentsOf: URL(fileURLWithPath: psd)) else { return nil }
        for r in f.layers {
            guard let fx = r.objectEffects else { continue }
            for e in fx.effects where e.key == "ChFX" {
                guard let c = e.descriptor.descriptor("MpgS") else { continue }
                let pts: [[Double]] = (c.list("Crv ") ?? []).compactMap { v in
                    guard let d = v.descriptor, let h = d.number("Hrzn"), let vv = d.number("Vrtc") else { return nil }
                    return [h, vv]
                }
                var out: [String: Any] = ["name": c.text("Nm  ") ?? "?", "points": pts, "invert": e.descriptor.bool("Invr") as Any,
                                          "antialias": e.descriptor.bool("AntA") as Any]
                out["angle"] = e.descriptor.number("lagl")
                out["distance"] = e.descriptor.number("Dstn")
                out["size"] = e.descriptor.number("blur")
                return out
            }
        }
        return nil
    }

    // MARK: run

    public static func run(ps: Photoshop, out: URL, only: Set<String>?, log: (String) -> Void) throws -> Int32 {
        let dir = URL(fileURLWithPath: try ps.config.checked(out.path))
        for sub in ["inputs", "psd", "tif"] { try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true) }
        let inputs = try writeInputs(dir.appendingPathComponent("inputs"))
        log("inputs written and read back exactly: \(inputs.count) PNGs")
        let args: [String: Any] = ["inputs": try ps.config.checked(dir.appendingPathComponent("inputs").path), "out": dir.path]
        var env = try ps.run("measure-m1", args.merging(["op": "env"]) { a, _ in a })
        env.removeValue(forKey: "ok")
        let listing = try ps.run("measure-m1", args.merging(["op": "list"]) { a, _ in a })
        let jobs = ((listing["jobs"] as? [[String: Any]]) ?? []).filter { only == nil || only!.contains($0["id"] as? String ?? "") }
        var results: [[String: Any]] = []
        var stopped: String?
        func writeManifest() throws {
            var manifest: [String: Any] = ["batch": "M1", "created": ISO8601DateFormatter().string(from: Date()), "photoshop": env,
                                           "inputs": inputs, "inputLayout": inputLayout, "jobs": results,
                                           "notes": ["Photoshop only created documents or opened the PNG inputs above; no PSD was opened.",
                                                     "Each job: <id>.psd (Maximize Compatibility) and <id>.tif (flattened duplicate, uncompressed, document depth, ICC embedded).",
                                                     "Satin raw jobs: the same shapes with Fill 0 % over black, Satin white Normal 100 %, so the composite is the Satin map.",
                                                     "Shapes (Satin): one pixel layer 'Shapes' with white anti-aliased selections filled; geometry in each job's 'shapes' (pixels; rotation counter-clockwise on screen, Photoshop's angle convention). The 19° rectangle's edges are parallel/perpendicular to the 19° Satin offset.",
                                                     "Inputs open untagged in Photoshop; each job assigns sRGB IEC61966-2.1 (the corpus profile), which does not change pixel values.",
                                                     "16-bit: Photoshop stores 16-bit data with 15 bits, so the 16-bit identity round trip differs by up to 2/65535; use tif/identity-rgb16.tif as the effective 16-bit input."]]
            if let s = stopped { manifest["stopped"] = s }
            let d = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try d.write(to: dir.appendingPathComponent("manifest.json"))
        }
        for (i, job) in jobs.enumerated() {
            let id = job["id"] as? String ?? "?"
            var rec = job
            do {
                var r = try ps.run("measure-m1", args.merging(["op": "run", "job": id]) { a, _ in a })
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
        if FileManager.default.fileExists(atPath: tif("identity-rgb8")) { analysis["identity-rgb8"] = identityCheck(tif("identity-rgb8"), kind: .identity, bits: 8) }
        if FileManager.default.fileExists(atPath: tif("identity-rgb16")) { analysis["identity-rgb16"] = identityCheck(tif("identity-rgb16"), kind: .identity, bits: 16) }
        if FileManager.default.fileExists(atPath: tif("bc-b0-c0-rgb8")) { analysis["bc-b0-c0-rgb8 (identity?)"] = identityCheck(tif("bc-b0-c0-rgb8"), kind: .identity, bits: 8) }
        if ["dissolve-a", "dissolve-b", "dissolve-offset"].allSatisfy({ FileManager.default.fileExists(atPath: tif($0)) }) {
            analysis["dissolve"] = dissolveCheck(tif("dissolve-a"), tif("dissolve-b"), tif("dissolve-offset"), offset: (37, 53))
        }
        for i in results.indices {
            guard results[i]["group"] as? String == "satin" || results[i]["group"] as? String == "satin-raw",
                  let r = results[i]["result"] as? [String: Any], let psd = r["psd"] as? String,
                  let c = storedContour(dir.appendingPathComponent(psd).path) else { continue }
            var rr = r
            rr["storedSatin"] = c
            results[i]["result"] = rr
        }
        results.append(["id": "analysis", "group": "analysis", "result": analysis])
        try writeManifest()
        log("analysis: \(analysis)")
        return 0
    }
}
