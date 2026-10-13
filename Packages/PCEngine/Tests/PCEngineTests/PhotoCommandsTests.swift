// Port of photocraft-engine (crates/engine/src/photo_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Every photocraft test is ported (they use open documents). `filesImportThroughPCIO` adds the file
// inputs: flat images (a list and a folder) and a layered PSD, all imported by PCIO.

import Foundation
import PCAlgo
import PCDocument
@testable import PCEngine
import PCFoundation
import PCPlatform
import Testing

@Suite struct PhotoCommandsTests {
    func doc(_ s: Session) -> Document { s.active!.doc }

    /// A textured RGB scene (deterministic blobs on a gradient).
    func scene(_ w: Int, _ h: Int, _ seed: UInt64) -> [SIMD4<Float>] {
        var z = seed
        func rnd() -> Double {
            z = z &* 6364136223846793005 &+ 1442695040888963407
            return Double(z >> 33) / Double(UInt64(1) << 31)
        }
        var px: [SIMD4<Float>] = (0..<(w * h)).map { i in
            let x = Float(i % w) / Float(w)
            return SIMD4(0.3 + 0.2 * x, 0.35, 0.4 - 0.1 * x, 1)
        }
        for _ in 0..<(w * h / 700) {
            let cx = rnd() * Double(w), cy = rnd() * Double(h), r = 3 + rnd() * 9
            let (c0, c1, c2) = (Float(rnd()), Float(rnd()), Float(rnd()))
            for y in stride(from: Int(max(cy - r, 0)), to: min(Int(cy + r) + 1, h), by: 1) {
                for x in stride(from: Int(max(cx - r, 0)), to: min(Int(cx + r) + 1, w), by: 1) where hypot(Double(x) - cx, Double(y) - cy) < r {
                    px[y * w + x] = SIMD4(c0, c1, c2, 1)
                }
            }
        }
        return px
    }

    func docFrom(_ name: String, _ px: [SIMD4<Float>], _ w: Int, _ h: Int, _ depth: SampleType) -> Document {
        var d = Document(name: name, size: PixelSize(width: w, height: h), mode: .rgb, depth: depth)
        var s = Surface(format: d.pixelFormat)
        s.writeRGBA(PixelRect(x: 0, y: 0, width: w, height: h), px)
        d.layers.append(Layer(name: "Background", content: .raster(s)))
        return d
    }

    func crop(_ px: [SIMD4<Float>], _ sw: Int, _ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ gain: Float) -> [SIMD4<Float>] {
        (0..<(w * h)).map { i in
            let q = px[(y0 + i / w) * sw + x0 + i % w]
            return SIMD4(q.x * gain, q.y * gain, q.z * gain, 1)
        }
    }

    @Test func photomergeOpenDocumentsRepositionAndPerspective() throws {
        for depth in [SampleType.u8, .u16, .f32] {
            let (sw, sh) = (520, 220)
            let sc = scene(sw, sh, 5)
            let s = Session()
            // Three overlapping crops, the middle one 15 % brighter (gain compensation).
            for (k, (x0, g)) in [(0, Float(1)), (130, 1.15), (260, 1)].enumerated() {
                _ = s.addDocument(docFrom("img\(k)", crop(sc, sw, x0, 10, 220, 200, g), 220, 200, depth))
            }
            let r = try s.execute("file.automate.photomerge", ["useOpenDocuments": true, "layout": "reposition"])
            #expect(r["placed"]?.arrayValue?.count == 3, "\(r.serialized())")
            let (w, h) = (r["width"]?.intValue ?? 0, r["height"]?.intValue ?? 0)
            #expect(abs(w - 480) <= 2 && abs(h - 200) <= 2, "\(depth) \(w)×\(h)")
            let d = doc(s)
            #expect(d.layers.count == 3)
            #expect(d.layers.allSatisfy { $0.mask != nil })
            // Masks partition the panorama: every covered pixel is shown by exactly one layer.
            for (x, y) in [(Int32(20), Int32(100)), (200, 50), (380, 150), (470, 120)] {
                let shown = d.layers.reduce(Float(0)) { $0 + ($1.mask?.value(x: x, y: y) ?? 0) * ($1.surface?.rgba(x: x, y: y).w ?? 0) }
                #expect(abs(shown - 1) < 0.01, "(\(x),\(y)) \(shown)")
            }
            // The composite matches the scene up to the global gain.
            let comp = try s.services.renderer.render(d, region: d.bounds).px
            let gains = try #require(r["photometric"]?["gains"]?.arrayValue)
            #expect((gains[1][0]?.doubleValue ?? 0) > (gains[0][0]?.doubleValue ?? 0) * 1.05, "\(r.serialized())")
            let probe = comp[100 * d.size.width + 160]
            let truth = sc[110 * sw + 160]
            #expect(abs(probe.y - truth.y) < 0.08, "\(probe) vs \(truth)")
        }
        // Perspective + no blending: plain layers, no masks.
        let (sw, sh) = (520, 220)
        let sc = scene(sw, sh, 8)
        let s = Session()
        for (k, x0) in [0, 180].enumerated() { _ = s.addDocument(docFrom("p\(k)", crop(sc, sw, x0, 10, 260, 200, 1), 260, 200, .u8)) }
        let r = try s.execute("file.automate.photomerge", ["useOpenDocuments": true, "layout": "perspective", "blend": false])
        #expect(r["layout"] == "perspective")
        #expect(doc(s).layers.allSatisfy { $0.mask == nil })
        #expect(abs((r["width"]?.intValue ?? 0) - 440) <= 8, "\(r.serialized())")
        #expect(throws: EngineError.self) { try s.execute("file.automate.photomerge", ["useOpenDocuments": true, "layout": "zigzag"]) }
        #expect(throws: EngineError.self) { try Session().execute("file.automate.photomerge") }
    }

    @Test func photomergeCylindricalWithFill() throws {
        let (sw, sh) = (900, 260)
        let sc = scene(sw, sh, 21)
        let f = 260.0
        let s = Session()
        let (tw, th) = (260, 200)
        for (k, pan) in [-0.45, 0, 0.45].enumerated() {
            let px: [SIMD4<Float>] = (0..<(tw * th)).map { i in
                let (dx, dy) = (Double(i % tw) - Double(tw) / 2, Double(i / tw) - Double(th) / 2)
                let (u, v) = (Double(sw) / 2 + f * (atan2(dx, f) + pan), Double(sh) / 2 + f * dy / hypot(dx, f))
                return sc[Int(min(max(v.rounded(), 0), Double(sh) - 1)) * sw + Int(min(max(u.rounded(), 0), Double(sw) - 1))]
            }
            _ = s.addDocument(docFrom("c\(k)", px, tw, th, .u8))
        }
        let r = try s.execute("file.automate.photomerge", ["useOpenDocuments": true, "layout": "cylindrical", "contentAwareFill": true])
        #expect(r["layout"] == "cylindrical")
        #expect(r["placed"]?.arrayValue?.count == 3, "\(r.serialized())")
        let d = doc(s)
        let top = try #require(d.layers.last)
        #expect(top.name == "Content-Aware Fill")
        // The fill layer is opaque everywhere (the bow-tie corners are filled).
        let b = d.bounds
        let surf = try #require(top.surface)
        #expect(surf.rgba(x: 1, y: 1).w > 0.99 && surf.rgba(x: b.x1 - 2, y: b.y1 - 2).w > 0.99)
    }

    func srgb(_ v: Float) -> Float { v <= 0.003_130_8 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    @Test func hdrMergeFromSyntheticExposures() throws {
        let (w, h) = (96, 64)
        let radiance: [SIMD3<Float>] = (0..<(w * h)).map { i in
            let x = Float(i % w) / Float(w)
            let b = 0.003 * pow(2, x * 11) * (1 + 0.2 * sin(Float(i / w) * 0.3))
            return SIMD3(b, b * 0.9, b * 0.7)
        }
        func shoot(_ dt: Float) -> [SIMD4<Float>] {
            radiance.map { r in SIMD4(srgb(min(r.x * dt, 1)), srgb(min(r.y * dt, 1)), srgb(min(r.z * dt, 1)), 1) }
        }
        let s = Session()
        for (k, dt) in [Float(0.25), 1, 4].enumerated() {
            var d = docFrom("e\(k)", shoot(dt), w, h, .u8)
            d.metadata.exif = Exif.build(Exif.CameraInfo(exposureTime: Double(dt) / 100, fNumber: 8, iso: 100))
            _ = s.addDocument(d)
        }
        let r = try s.execute("file.automate.mergeToHdrPro", ["useOpenDocuments": true])
        #expect(r["exposureSource"] == "exif")
        let ev = try #require(r["ev"]?.arrayValue).map { $0.doubleValue ?? .nan }
        #expect(abs(ev[1] - 2) < 1e-6 && abs(ev[2] - 4) < 1e-6, "\(ev)")
        let d = doc(s)
        #expect(d.depth == .f32)
        let l = try #require(d.layers[0].surface)
        // Linear output: ratios across the ramp follow the radiance.
        let (a, b) = (Double(l.rgba(x: 20, y: 30).y), Double(l.rgba(x: 80, y: 30).y))
        let expect = Double(radiance[30 * w + 80].y) / Double(radiance[30 * w + 20].y)
        #expect(abs(log((b / a) / expect)) < 0.3, "\(b / a) vs \(expect)")
        #expect((r["stops"]?.doubleValue ?? 0) > 7, "\(r.serialized())")
        _ = s.close(try #require(r["document"]?.intValue))
        // 8-bit tone-mapped output with explicit EVs.
        for method in ["localAdaptation", "exposureGamma", "highlightCompression", "equalizeHistogram"] {
            let r = try s.execute("file.automate.mergeToHdrPro", ["paths": [], "useOpenDocuments": true, "exposures": [0, 2, 4], "mode": "8", "method": .string(method)])
            #expect(r["exposureSource"] == "params")
            #expect(doc(s).depth == .u8, "\(method)")
            _ = s.close(try #require(r["document"]?.intValue))
        }
        #expect(throws: EngineError.self) { try s.execute("file.automate.mergeToHdrPro", ["useOpenDocuments": true, "exposures": [0, 1]]) }
    }

    @Test func cropAndStraightenMakesDocuments() throws {
        let (w, h) = (500, 360)
        var px = [SIMD4<Float>](repeating: SIMD4(0.98, 0.98, 0.98, 1), count: w * h)
        let photos: [(SIMD2<Double>, Double, Double, Double)] = [(SIMD2(140, 120), 160, 110, 6), (SIMD2(360, 240), 150, 120, -9)]
        for (c, pw, ph, ang) in photos {
            let rad = ang * Double.pi / 180
            let (sn, co) = (sin(rad), cos(rad))
            for y in 0..<h {
                for x in 0..<w {
                    let (dx, dy) = (Double(x) + 0.5 - c.x, Double(y) + 0.5 - c.y)
                    let (u, v) = (co * dx + sn * dy, -sn * dx + co * dy)
                    if abs(u) < pw / 2 && abs(v) < ph / 2 { px[y * w + x] = SIMD4(0.2 + Float(u / pw) * 0.3, 0.3, 0.6, 1) }
                }
            }
        }
        let s = Session()
        _ = s.addDocument(docFrom("scan", px, w, h, .u16))
        #expect(s.isEnabled("file.automate.cropAndStraightenPhotos"))
        let r = try s.execute("file.automate.cropAndStraightenPhotos")
        let found = try #require(r["photos"]?.arrayValue)
        #expect(found.count == 2, "\(r.serialized())")
        #expect(s.documents.count == 3)
        #expect(abs((found[0]["angle"]?.doubleValue ?? 0) - 6) < 1)
        let d = s.documents[1].doc
        #expect(abs(d.size.width - 158) <= 4 && abs(d.size.height - 108) <= 4, "\(d.size)")
        #expect(d.depth == .u16)
        // Upright: the photo's horizontal gradient runs along x.
        let l = try #require(d.layers[0].surface)
        let (hw, hh) = (Int32(d.size.width), Int32(d.size.height))
        let (a, b) = (l.rgba(x: 10, y: hh / 2).x, l.rgba(x: hw - 10, y: hh / 2).x)
        #expect(b > a + 0.15, "\(a) \(b)")
        let (c, e) = (l.rgba(x: hw / 2, y: 6).x, l.rgba(x: hw / 2, y: hh - 6).x)
        #expect(abs(c - e) < 0.05)
    }

    /// Files: flat images and layered documents import through PCIO, named one by one or as a
    /// folder; an unreadable file is an error.
    @Test func filesImportThroughPCIO() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pcengine-photo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (w, h) = (48, 32)
        let sc = scene(w, h, 3)
        var paths: [String] = []
        for (k, gain) in [Float(0.5), 1].enumerated() {
            let d = docFrom("f\(k)", crop(sc, w, 0, 0, w, h, gain), w, h, .u8)
            let data = try ImageCodecs.encode(d.layers[0].surface!, rect: d.bounds, as: .png)
            let url = dir.appendingPathComponent("exposure\(k).png")
            try data.write(to: url)
            paths.append(url.path)
        }
        let s = Session()
        let r = try s.execute("file.automate.mergeToHdrPro", ["paths": .strings(paths), "exposures": [0, 1], "mode": "8", "align": false])
        #expect(r["exposureSource"] == "params")
        #expect(doc(s).size == PixelSize(width: w, height: h) && doc(s).depth == .u8)
        // A folder: its images, sorted by name.
        let r2 = try s.execute("file.automate.mergeToHdrPro", ["paths": .string(dir.path), "exposures": [0, 1], "mode": "16", "align": false])
        #expect(r2["document"] == 1 && doc(s).depth == .u16)
        // A layered PSD is flattened like any other source.
        let layered = Session()
        _ = layered.addDocument(docFrom("layered", crop(sc, w, 0, 0, w, h, 0.75), w, h, .u8))
        let psd = dir.appendingPathComponent("layers.psd")
        try layered.saveDocument(to: psd.path)
        dropForOracle(psd, as: "photo-hdr-source.psd")
        let r3 = try s.execute("file.automate.mergeToHdrPro", ["paths": .strings([paths[0], psd.path]), "exposures": [0, 1], "mode": "8", "align": false])
        #expect(r3["exposureSource"] == "params")
        #expect(doc(s).size == PixelSize(width: w, height: h))
        // An unreadable file is an error.
        let broken = dir.appendingPathComponent("broken.psd")
        try Data("8BPS".utf8).write(to: broken)
        #expect(throws: (any Error).self) { try s.execute("file.automate.mergeToHdrPro", ["paths": .strings([paths[0], broken.path])]) }
        #expect(throws: EngineError.self) { try s.execute("file.automate.photomerge", ["paths": .strings([dir.appendingPathComponent("missing.png").path])]) }
    }
}
