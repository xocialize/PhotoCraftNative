// Compositor `.comp` import (AB-T-0239): packages built here the way Compositor's ProjectStore writes
// them (manifest.json, 8/16-bit PNG and half-float OpenEXR layers through ImageIO, 8-bit gray mask
// PNGs), covering what the app-written fixture set (PCIOTests' CompCorpusTests) does not: every
// version gate, deep and HDR layers, transforms, unlinked and folder masks, clipping that has no
// Photoshop form, the adjustment kinds, text and shape metadata, guides and resolution.
// New; MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import Foundation
import ImageIO
import PCDocument
import PCFoundation
import PCIOCore
import Testing
import UniformTypeIdentifiers
@testable import PCIOFormats

enum CompKit {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// An 8- or 16-bit straight-alpha RGBA PNG (`px` row-major, 0–1).
    static func png(_ w: Int, _ h: Int, sixteen: Bool = false, _ px: (Int, Int) -> SIMD4<Double>) -> [UInt8] {
        let bpc = sixteen ? 16 : 8
        var data = Data(count: w * h * 4 * bpc / 8)
        data.withUnsafeMutableBytes { raw in
            for y in 0 ..< h { for x in 0 ..< w {
                let v = px(x, y)
                for k in 0 ..< 4 {
                    let i = (y * w + x) * 4 + k
                    if sixteen {
                        raw.storeBytes(of: UInt16((v[k] * 65535).rounded()).bigEndian, toByteOffset: i * 2, as: UInt16.self)
                    } else {
                        raw[i] = UInt8((v[k] * 255).rounded())
                    }
                }
            } }
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | (sixteen ? CGBitmapInfo.byteOrder16Big.rawValue : 0))
        let img = CGImage(width: w, height: h, bitsPerComponent: bpc, bitsPerPixel: bpc * 4, bytesPerRow: w * 4 * bpc / 8, space: srgb,
                          bitmapInfo: info, provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return encode(img, UTType.png.identifier)
    }

    /// An 8-bit gray PNG without alpha (a Compositor mask).
    static func maskPNG(_ w: Int, _ h: Int, _ v: (Int, Int) -> Double) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: w * h)
        for y in 0 ..< h { for x in 0 ..< w { b[y * w + x] = UInt8((v(x, y) * 255).rounded()) } }
        let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: CGDataProvider(data: Data(b) as CFData)!,
                          decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return encode(img, UTType.png.identifier)
    }

    /// An HDR layer as Compositor saves one: half floats in extended sRGB, premultiplied, through
    /// ImageIO's OpenEXR encoder.
    static func exr(_ w: Int, _ h: Int, _ px: (Int, Int) -> SIMD4<Float>) -> [UInt8] {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8, space: CGColorSpace(name: CGColorSpace.extendedSRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue | CGBitmapInfo.floatComponents.rawValue)!
        let p = ctx.data!.bindMemory(to: Float16.self, capacity: w * h * 4)
        for y in 0 ..< h { for x in 0 ..< w {
            let v = px(x, y)
            for k in 0 ..< 3 { p[(y * w + x) * 4 + k] = Float16(v[k] * v.w) }
            p[(y * w + x) * 4 + 3] = Float16(v.w)
        } }
        return encode(ctx.makeImage()!, "com.ilm.openexr-image")
    }

    static func encode(_ img: CGImage, _ type: String) -> [UInt8] {
        let out = NSMutableData()
        let dst = CGImageDestinationCreateWithData(out, type as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, img, nil)
        precondition(CGImageDestinationFinalize(dst))
        return [UInt8](out as Data)
    }

    static func id(_ n: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", n) }

    static func transform(_ x: Double = 0, _ y: Double = 0, _ w: Double, _ h: Double, rotation: Double = 0, flipX: Bool = false,
                          sampling: String = "High quality") -> [String: Any] {
        ["origin": [x, y], "size": [w, h], "rotation": rotation, "flipX": flipX, "flipY": false, "sampling": sampling]
    }

    /// A layer record; `extra` overrides or adds keys.
    static func layer(_ n: Int, _ name: String, image: Bool = true, exr: Bool = false, size: (Double, Double) = (4, 4),
                      _ extra: [String: Any] = [:]) -> [String: Any] {
        var l: [String: Any] = ["id": id(n), "name": name, "isVisible": true]
        l["transform"] = transform(0, 0, size.0, size.1)
        if image { l["imageFile"] = "\(id(n)).\(exr ? "exr" : "png")" }
        for (k, v) in extra { l[k] = v }
        return l
    }

    static func manifest(version: Int = 13, width: Int = 4, height: Int = 4, layers: [[String: Any]], _ extra: [String: Any] = [:]) -> [UInt8] {
        var m: [String: Any] = ["format": "com.compositor.project", "version": version, "colorSpace": "sRGB", "documentID": id(999),
                                "width": width, "height": height, "layers": layers]
        for (k, v) in extra { m[k] = v }
        return [UInt8](try! JSONSerialization.data(withJSONObject: m, options: [.sortedKeys]))
    }

    static func package(_ manifest: [UInt8], _ images: [String: [UInt8]]) -> CompImport.Package {
        var files = ["manifest.json": manifest]
        for (k, v) in images { files["images/\(k)"] = v }
        return .files(name: "test.comp", files)
    }

    static func load(_ manifest: [UInt8], _ images: [String: [UInt8]] = [:]) throws -> ImportResult {
        try CompImport.load(package(manifest, images), codec: ImageIOCodec(), interrupt: .none)
    }

    /// A plain 4×4 layer image.
    static func solid(_ c: SIMD4<Double>, _ w: Int = 4, _ h: Int = 4) -> [UInt8] { png(w, h) { _, _ in c } }

    static func expectRefused(_ manifest: [UInt8], _ images: [String: [UInt8]] = [:], _ expected: (CompError) -> Bool,
                              sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try load(manifest, images)
            Issue.record("accepted a package Compositor refuses", sourceLocation: sourceLocation)
        } catch let e as CompError {
            #expect(expected(e), "\(e)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
        }
    }
}

@Suite struct CompImportTests {
    typealias K = CompKit

    @Test func pixelLayersOpenExactlyWithAppearanceGuidesAndResolution() throws {
        let base = K.png(4, 4) { x, y in SIMD4(Double(x) / 3, Double(y) / 3, 0.5, 1) }
        let top = K.png(2, 2) { x, _ in SIMD4(1, 0, 0, x == 0 ? 1 : 0.5) }
        let m = K.manifest(layers: [
            K.layer(1, "Base"),
            K.layer(2, "Top", ["transform": K.transform(1, 2, 2, 2), "opacity": 0.5, "blendMode": "Linear Dodge (Add)"]),
        ], ["resolution": 300, "guides": [["id": K.id(50), "axis": "horizontal", "position": 1.5], ["id": K.id(51), "axis": "vertical", "position": 3]]])
        let r = try K.load(m, ["\(K.id(1)).png": base, "\(K.id(2)).png": top])
        let d = r.document
        #expect(r.warnings.isEmpty, "\(r.warnings)")
        #expect(r.sourceReadOnly)
        #expect(d.depth == .u8 && d.mode == .rgb && d.size == PixelSize(width: 4, height: 4))
        #expect(d.resolutionDpi == 300)
        #expect(d.guides.horizontal == [1.5] && d.guides.vertical == [3])
        #expect(d.layers.map(\.name) == ["Base", "Top"])
        #expect(d.layers[1].blend == .linearDodge && d.layers[1].opacity == 0.5)
        // Exact pixels, the top layer at its whole-pixel offset.
        let b = d.layers[0].surface!.readRGBA(d.bounds)
        #expect(b[1 * 4 + 2] == SIMD4(Float(2.0 / 3).rounded8, Float(1.0 / 3).rounded8, Float(128) / 255, 1))
        let t = d.layers[1].surface!
        #expect(t.rgba(x: 1, y: 2) == SIMD4(1, 0, 0, 1))
        #expect(t.rgba(x: 2, y: 3).w == Float(128) / 255)
        #expect(t.rgba(x: 0, y: 0).w == 0)
    }

    @Test func versionGatesFollowProjectStore() throws {
        let img = ["\(K.id(1)).png": K.solid(SIMD4(1, 1, 1, 1))]
        func one(_ v: Int, _ extra: [String: Any], image: Bool = true) -> [UInt8] { K.manifest(version: v, layers: [K.layer(1, "L", image: image, extra)]) }
        // Outside 1–13, by number.
        K.expectRefused(one(14, [:]), img) { $0 == .version(14) }
        K.expectRefused(one(0, [:]), img) { $0 == .version(0) }
        K.expectRefused(K.manifest(layers: [K.layer(1, "L")], ["format": "com.example"]), img) { if case .invalid = $0 { true } else { false } }
        K.expectRefused(K.manifest(layers: [K.layer(1, "L")], ["colorSpace": "Display P3"]), img) { if case .invalid = $0 { true } else { false } }
        // v3: opacity and blend modes.
        K.expectRefused(one(2, ["opacity": 0.5]), img) { "\($0)".contains("version 3") }
        K.expectRefused(one(2, ["blendMode": "Multiply"]), img) { "\($0)".contains("version 3") }
        // v4: layer masks; v6: folder masks.
        K.expectRefused(one(3, ["maskFile": "\(K.id(1)).mask.png"]), img) { "\($0)".contains("version 4") }
        K.expectRefused(K.manifest(version: 5, layers: [K.layer(1, "F", image: false, ["isGroup": true, "maskFile": "\(K.id(1)).mask.png"])]), [:]) {
            "\($0)".contains("version 6")
        }
        // v5: clipping links.
        K.expectRefused(K.manifest(version: 4, layers: [K.layer(1, "A"), K.layer(2, "B", ["maskSourceID": K.id(1)])]), img) { "\($0)".contains("version 5") }
        // v2: folders.
        K.expectRefused(K.manifest(version: 1, layers: [K.layer(1, "F", image: false, ["isGroup": true])]), [:]) { "\($0)".contains("version 2") }
        // v7: adjustment layers; v9: the neighbouring-pixel kinds.
        K.expectRefused(one(6, ["adjustment": ["kind": "Invert"]], image: false)) { "\($0)".contains("version 7") }
        K.expectRefused(one(8, ["adjustment": ["kind": "Gaussian Blur", "blurRadius": 4]], image: false)) { "\($0)".contains("version 9") }
        // v8: folder opacity and guides.
        K.expectRefused(K.manifest(version: 7, layers: [K.layer(1, "F", image: false, ["isGroup": true, "opacity": 0.5])]), [:]) { "\($0)".contains("version 8") }
        K.expectRefused(K.manifest(version: 7, layers: [K.layer(1, "L")], ["guides": [["id": K.id(5), "axis": "vertical", "position": 1]]]), img) {
            "\($0)".contains("version 8")
        }
        // v10 / v11: per-letter colours and faces.
        let text: [String: Any] = ["content": "Hi", "fontName": "Helvetica", "fontSize": 12, "red": 0, "green": 0, "blue": 0, "alignment": "Left",
                                   "tracking": 0, "leading": 0]
        var colored = text; colored["colorRuns"] = [["location": 0, "length": 1, "red": 1, "green": 0, "blue": 0]]
        var faced = text; faced["fontRuns"] = [["location": 0, "length": 1, "fontName": "Courier"]]
        K.expectRefused(one(9, ["text": colored]), img) { "\($0)".contains("version 10") }
        K.expectRefused(one(10, ["text": faced]), img) { "\($0)".contains("version 11") }
        // v12: 16-bit images; v13: OpenEXR.
        K.expectRefused(one(11, [:]), ["\(K.id(1)).png": K.png(4, 4, sixteen: true) { _, _ in SIMD4(0.5, 0.5, 0.5, 1) }]) {
            if case .missingImage(let m) = $0 { m.contains("version 12") } else { false }
        }
        K.expectRefused(K.manifest(version: 12, layers: [K.layer(1, "L", exr: true)]), ["\(K.id(1)).exr": K.exr(4, 4) { _, _ in SIMD4(2, 1, 1, 1) }]) {
            if case .invalid(let m) = $0 { m.contains("image file") } else { false }
        }
        // Folders stay Normal; a folder can't hold an image or be clipped.
        K.expectRefused(K.manifest(layers: [K.layer(1, "F", image: false, ["isGroup": true, "blendMode": "Multiply"])])) { "\($0)".contains("Normal") }
        K.expectRefused(K.manifest(layers: [K.layer(1, "A"), K.layer(2, "F", image: false, ["isGroup": true, "maskSourceID": K.id(1)])]), img) {
            if case .invalid = $0 { true } else { false }
        }
        // Clipping to oneself, in a cycle or to a missing layer.
        K.expectRefused(K.manifest(layers: [K.layer(1, "A", ["maskSourceID": K.id(1)])]), img) { if case .invalid = $0 { true } else { false } }
        K.expectRefused(K.manifest(layers: [K.layer(1, "A", ["maskSourceID": K.id(9)])]), img) { if case .invalid = $0 { true } else { false } }
        // Unsafe or inconsistent names and records.
        K.expectRefused(one(13, ["imageFile": "../escape.png"]), img) { if case .invalid = $0 { true } else { false } }
        K.expectRefused(one(13, ["maskEnabled": true]), img) { if case .invalid = $0 { true } else { false } }
        K.expectRefused(one(13, ["opacity": 1.5]), img) { if case .invalid = $0 { true } else { false } }
        K.expectRefused(one(13, ["name": "  "]), img) { if case .invalid = $0 { true } else { false } }
        K.expectRefused(K.manifest(layers: [K.layer(1, "L")], ["activeLayerID": K.id(7)]), img) { if case .invalid = $0 { true } else { false } }
        K.expectRefused(K.manifest(layers: [K.layer(1, "L")], ["resolution": 0]), img) { if case .invalid = $0 { true } else { false } }
        K.expectRefused(K.manifest(width: 30_001, layers: [K.layer(1, "L")]), img) { if case .tooLarge = $0 { true } else { false } }
        // A missing or mislabelled image.
        K.expectRefused(one(13, [:]), [:]) { if case .missingImage = $0 { true } else { false } }
        K.expectRefused(one(13, [:]), ["\(K.id(1)).png": K.exr(4, 4) { _, _ in SIMD4(1, 1, 1, 1) }]) { if case .missingImage = $0 { true } else { false } }
        // A mask must be 8-bit gray without alpha.
        K.expectRefused(one(13, ["maskFile": "\(K.id(1)).mask.png"]), img.merging(["\(K.id(1)).mask.png": K.solid(SIMD4(1, 1, 1, 1))]) { a, _ in a }) {
            "\($0)".contains("8-bit gray")
        }
        // Every supported version opens (v1 without folders, opacity or the later features).
        for v in CompManifest.supported { _ = try K.load(one(v, [:]), img) }
    }

    @Test func refusalsReachDocumentIOAsFormatErrors() throws {
        do {
            _ = try CompImport.importDocument(K.package(K.manifest(version: 14, layers: []), [:]), codec: ImageIOCodec())
            Issue.record("accepted version 14")
        } catch let e as PCIOError {
            #expect(e == .format("Compositor", CompError.version(14).description))
            #expect("\(e)".contains("versions 1–13"))
        }
    }

    @Test func sixteenBitLayersMakeASixteenBitDocument() throws {
        let deep = K.png(4, 4, sixteen: true) { x, _ in SIMD4(Double(0x1234 + x) / 65535, 0.25, 0.75, 1) }
        let m = K.manifest(version: 12, layers: [K.layer(1, "Deep"), K.layer(2, "Eight")])
        let r = try K.load(m, ["\(K.id(1)).png": deep, "\(K.id(2)).png": K.solid(SIMD4(0, 0.5, 1, 1))])
        let d = r.document
        #expect(d.depth == .u16)
        #expect(d.layers[0].surface!.format == .rgba16)
        // 16-bit samples kept exactly; the 8-bit layer widened without changing its levels.
        #expect(d.layers[0].surface!.rgba(x: 2, y: 0).x == Float(0x1236) / 65535)
        #expect(d.layers[1].surface!.rgba(x: 0, y: 0) == SIMD4(0, Float(128) / 255, 1, 1))
    }

    @Test func hdrLayersMakeALinearFloatDocument() throws {
        // 2.0 in extended sRGB is ≈ 4.95 in linear light; OpenEXR stores linear values.
        let hdr = K.exr(4, 4) { _, _ in SIMD4(2, 0.5, 0, 1) }
        // A 2×2 HDR layer drawn 4×4 goes through the half-float resampling path, highlights kept.
        let small = K.exr(2, 2) { x, _ in SIMD4(x == 0 ? 3 : 0.25, 0, 0, 1) }
        let m = K.manifest(layers: [K.layer(1, "HDR", exr: true), K.layer(2, "Eight"),
                                    K.layer(3, "Scaled HDR", exr: true, ["transform": K.transform(0, 0, 4, 4, sampling: "Nearest")])])
        let r = try K.load(m, ["\(K.id(1)).exr": hdr, "\(K.id(2)).png": K.solid(SIMD4(0.5, 0.5, 0.5, 1)), "\(K.id(3)).exr": small])
        let s = r.document.layers[2].surface!
        #expect(abs(s.rgba(x: 1, y: 3).x - CompPixels.srgbToLinear(3)) < 0.05 && abs(s.rgba(x: 3, y: 0).x - CompPixels.srgbToLinear(0.25)) < 0.002,
                "\(s.rgba(x: 1, y: 3)) \(s.rgba(x: 3, y: 0))")
        let d = r.document
        #expect(d.depth == .f32)
        let lin = CGColorSpace(name: CGColorSpace.linearSRGB)!.copyICCData().map { [UInt8]($0 as Data) }
        #expect(d.iccProfile == lin)
        let p = d.layers[0].surface!.rgba(x: 1, y: 1)
        #expect(abs(p.x - CompPixels.srgbToLinear(2)) < 0.02 && abs(p.y - CompPixels.srgbToLinear(0.5)) < 0.002, "\(p)")
        // The 8-bit layer is decoded to linear light (sRGB 128 → 0.2158).
        #expect(abs(d.layers[1].surface!.rgba(x: 0, y: 0).x - 0.2158605) < 1e-4)
        #expect(r.warnings.contains { $0.contains("32-bit linear") })
    }

    @Test func anExrWithinWhiteOpensAsSixteenBits() throws {
        // Compositor loads an OpenEXR that never passes white as a 16-bit layer.
        let m = K.manifest(layers: [K.layer(1, "SDR", exr: true)])
        let r = try K.load(m, ["\(K.id(1)).exr": K.exr(4, 4) { _, _ in SIMD4(0.5, 0.25, 1, 1) }])
        #expect(r.document.depth == .u16)
        let p = r.document.layers[0].surface!.rgba(x: 0, y: 0)
        #expect(abs(p.x - 0.5) < 0.002 && abs(p.y - 0.25) < 0.002 && abs(p.z - 1) < 0.002, "\(p)")
    }

    @Test func transformsAreAppliedToThePixels() throws {
        // A 2×2 image scaled to 4×4 with Nearest, and the same one flipped horizontally in place.
        let img = K.png(2, 2) { x, y in SIMD4(x == 0 ? 1 : 0, y == 0 ? 1 : 0, 0, 1) }
        let m = K.manifest(layers: [
            K.layer(1, "Scaled", ["transform": K.transform(0, 0, 4, 4, sampling: "Nearest")]),
            K.layer(2, "Flipped", ["transform": K.transform(1, 1, 2, 2, flipX: true, sampling: "Nearest")]),
            K.layer(3, "Turned", ["transform": K.transform(0, 0, 2, 2, rotation: 90, sampling: "Nearest")]),
        ])
        let r = try K.load(m, ["\(K.id(1)).png": img, "\(K.id(2)).png": img, "\(K.id(3)).png": img])
        let s = r.document.layers[0].surface!
        #expect(s.rgba(x: 1, y: 1) == SIMD4(1, 1, 0, 1) && s.rgba(x: 2, y: 1) == SIMD4(0, 1, 0, 1) && s.rgba(x: 3, y: 3) == SIMD4(0, 0, 0, 1), "\((0..<4).map { y in (0..<4).map { x in s.rgba(x: Int32(x), y: Int32(y)) } })")
        let f = r.document.layers[1].surface!
        #expect(f.rgba(x: 1, y: 1) == SIMD4(0, 1, 0, 1) && f.rgba(x: 2, y: 1) == SIMD4(1, 1, 0, 1))
        // Clockwise 90°: the top-left pixel goes to the top right.
        let t = r.document.layers[2].surface!
        #expect(t.rgba(x: 1, y: 0) == SIMD4(1, 1, 0, 1) && t.rgba(x: 0, y: 0) == SIMD4(1, 0, 0, 1), "\(t.rgba(x: 0, y: 0)) \(t.rgba(x: 1, y: 0))")
        #expect(r.warnings.contains { $0.contains("\"Scaled\": its transform") })
    }

    @Test func masksKeepTheirPlacementAndWhatLiesBeyond() throws {
        let img = K.solid(SIMD4(1, 1, 1, 1))
        let m = K.manifest(layers: [
            // A 1×1 hide-all mask covers the layer.
            K.layer(1, "Hidden", ["maskFile": "\(K.id(1)).mask.png"]),
            // An unlinked 2×2 mask placed in the bottom-right quarter; its edge is mostly white,
            // so it reveals beyond its own box.
            K.layer(2, "Unlinked", ["maskFile": "\(K.id(2)).mask.png", "maskLinked": false, "maskEnabled": false,
                                   "maskPlacement": K.transform(2, 2, 2, 2)]),
            // A folder's mask hides everything beyond its own box.
            K.layer(3, "Folder", image: false, ["isGroup": true, "maskFile": "\(K.id(3)).mask.png", "transform": K.transform(0, 0, 2, 2)]),
            K.layer(4, "Inside", ["parentID": K.id(3)]),
            // A 2×2 mask stretched over a 4×4 layer is resampled.
            K.layer(5, "Stretched", ["maskFile": "\(K.id(5)).mask.png"]),
        ])
        let r = try K.load(m, [
            "\(K.id(1)).png": img, "\(K.id(1)).mask.png": K.maskPNG(1, 1) { _, _ in 0 },
            "\(K.id(2)).png": img, "\(K.id(2)).mask.png": K.maskPNG(2, 2) { x, y in x == 0 && y == 0 ? 0 : 1 },
            "\(K.id(4)).png": img, "\(K.id(3)).mask.png": K.maskPNG(2, 2) { _, _ in 1 },
            "\(K.id(5)).png": img, "\(K.id(5)).mask.png": K.maskPNG(2, 2) { x, y in x == 0 && y == 0 ? 0 : 1 },
        ])
        let d = r.document
        let hide = d.layers[0].mask!
        #expect(hide.enabled && hide.surface.tileCount == 0 && hide.value(x: 2, y: 2) == 0)
        let un = d.layers[1].mask!
        #expect(!un.enabled && !un.linked)
        #expect(un.surface.pixel(x: 2, y: 2) == [0] && un.surface.pixel(x: 3, y: 3) == [1] && un.surface.pixel(x: 0, y: 0) == [1])
        let folder = d.layers[2]
        #expect(folder.isGroup && folder.blend == .passThrough)
        #expect(folder.mask!.surface.pixel(x: 1, y: 1) == [1] && folder.mask!.surface.pixel(x: 3, y: 3) == [0])
        let stretched = d.layers[3].mask!
        #expect(stretched.value(x: 0, y: 0) < 0.5 && stretched.value(x: 3, y: 3) == 1 && stretched.value(x: 3, y: 0) == 1)
    }

    @Test func clippingRunsBecomeClippingGroupsAndTheRestIsBaked() throws {
        let disc = K.png(4, 4) { x, _ in SIMD4(1, 0, 0, x < 2 ? 1 : 0) }
        let full = K.solid(SIMD4(0, 0, 1, 1))
        let m = K.manifest(layers: [
            K.layer(1, "Base"),
            K.layer(2, "Clip 1", ["maskSourceID": K.id(1), "blendMode": "Multiply"]),
            K.layer(3, "Hidden clip", ["maskSourceID": K.id(1), "isVisible": false]),
            K.layer(4, "Clip 2", ["maskSourceID": K.id(1)]),
            K.layer(5, "Plain"),
            // Clipped to Base across "Plain": no Photoshop form, baked.
            K.layer(6, "Far", ["maskSourceID": K.id(1), "opacity": 0.5]),
            // An adjustment clipped across "Plain" never draws in Compositor.
            K.layer(7, "Far adjustment", image: false, ["maskSourceID": K.id(1), "adjustment": ["kind": "Invert"]]),
        ])
        let r = try K.load(m, ["\(K.id(1)).png": disc, "\(K.id(2)).png": full, "\(K.id(3)).png": full, "\(K.id(4)).png": full,
                               "\(K.id(5)).png": full, "\(K.id(6)).png": full])
        let d = r.document
        #expect(d.layers.map(\.clipped) == [false, true, true, true, false, false, false])
        // The baked mask is the base's coverage over the canvas (its opacity is the layer's own).
        let far = d.layers[5]
        #expect(far.opacity == 0.5)
        #expect(far.mask!.value(x: 0, y: 0) == 1 && far.mask!.value(x: 3, y: 0) == 0 && far.mask!.value(x: -1, y: 0) == 0)
        #expect(!d.layers[6].visible)
        #expect(r.warnings.contains { $0.contains("\"Far\" is clipped to \"Base\"") })
        #expect(r.warnings.contains { $0.contains("\"Far adjustment\"") && $0.contains("never applies") })
    }

    @Test func aHiddenBaseBakesItsCoverage() throws {
        let half = K.png(4, 4) { _, y in SIMD4(1, 1, 1, y < 2 ? 1 : 0) }
        let m = K.manifest(layers: [K.layer(1, "Base", ["isVisible": false]), K.layer(2, "Clipped", ["maskSourceID": K.id(1)])])
        let r = try K.load(m, ["\(K.id(1)).png": half, "\(K.id(2)).png": K.solid(SIMD4(0, 1, 0, 1))])
        let c = r.document.layers[1]
        #expect(!c.clipped && c.mask!.value(x: 0, y: 0) == 1 && c.mask!.value(x: 0, y: 3) == 0)
    }

    @Test func adjustmentKindsMapOrSayWhyNot() throws {
        func adj(_ n: Int, _ a: [String: Any]) -> [String: Any] { K.layer(n, a["kind"] as! String, image: false, ["adjustment": a]) }
        let curves: [String: Any] = ["channel": "RGB", "channels": [
            [["x": 0, "y": 0], ["x": 96, "y": 60], ["x": 160, "y": 200], ["x": 255, "y": 255]],
            [["x": 0, "y": 0], ["x": 255, "y": 255]], [["x": 0, "y": 0], ["x": 255, "y": 255]], [["x": 0, "y": 0], ["x": 255, "y": 200]]]]
        let levels: [String: Any] = ["channel": "RGB", "ranges": [
            ["black": 30, "gamma": 1.4, "white": 220, "outputBlack": 0, "outputWhite": 255],
            ["black": 0, "gamma": 1, "white": 255, "outputBlack": 10, "outputWhite": 255],
            ["black": 0, "gamma": 1, "white": 255, "outputBlack": 0, "outputWhite": 255],
            ["black": 0, "gamma": 1, "white": 255, "outputBlack": 0, "outputWhite": 255]]]
        // Range-aware Hue/Saturation, its enum-keyed dictionaries in JSONEncoder's flat array form.
        let hsv: [String: Any] = ["range": "Reds", "colorize": false, "invertRange": false,
                                  "adjustments": ["Master", ["hue": 20, "saturation": 10, "lightness": 0], "Reds", ["hue": -30, "saturation": 0, "lightness": 5]],
                                  "bands": ["Reds", ["falloffStart": 300, "rangeStart": 330, "rangeEnd": 20, "falloffEnd": 50]]]
        let m = K.manifest(layers: [
            adj(1, ["kind": "Hue/Saturation", "hsvSettings": hsv]),
            adj(2, ["kind": "Levels", "levels": levels]),
            adj(3, ["kind": "Curves", "curves": curves]),
            adj(4, ["kind": "Exposure", "exposureSettings": ["exposure": 0.8, "offset": -0.1, "gamma": 1.2]]),
            adj(5, ["kind": "Gradient Map", "gradientMapSettings": ["shadows": ["red": 0.2, "green": 0, "blue": 0], "highlights": ["red": 1, "green": 1, "blue": 0.5], "reversed": true]]),
            adj(6, ["kind": "Invert"]),
            adj(7, ["kind": "Black & White", "blackWhiteSettings": ["reds": 40, "yellows": 60, "greens": 40, "cyans": 60, "blues": 20, "magentas": 80, "tint": true, "tintHue": 40, "tintSaturation": 20]]),
            adj(8, ["kind": "Color Balance", "colorBalanceSettings": ["midCyanRed": 40, "midYellowBlue": -35, "preserveLuminosity": false]]),
            adj(9, ["kind": "Grain", "grainSettings": ["amount": 25, "size": 1.5, "roughness": 50, "seed": 7]]),
            adj(10, ["kind": "Add Noise", "noiseAmount": 12, "noiseSeed": 3]),
            adj(11, ["kind": "Gaussian Blur", "blurRadius": 4]),
            adj(12, ["kind": "Motion Blur", "motionAngle": 30, "motionDistance": 12]),
        ])
        let r = try K.load(m)
        let a = r.document.layers.compactMap { l -> Adjustment? in if case .adjustment(let x) = l.content { x } else { nil } }
        #expect(a.count == 8)
        guard a.count == 8 else { return }
        if case .hueSaturation(let h) = a[0] {
            #expect(h.hue == 20 && h.saturation == 10 && h.ranges[0].hue == -30 && h.ranges[0].lightness == 5)
            #expect(h.ranges[0].bounds == HueRange.canonicalBounds(SIMD4(300, 330, 20, 50)))
        } else { Issue.record("Hue/Saturation") }
        if case .levels(let l) = a[1] {
            #expect(l.master.inBlack == Float(30) / 255 && l.master.inWhite == Float(220) / 255 && l.master.gamma == 1.4)
            #expect(l.perChannel[0].outBlack == Float(10) / 255)
        } else { Issue.record("Levels") }
        if case .curves(let c) = a[2] {
            #expect(c.pencil && c.master.count == 256 && c.perChannel[2].count == 256)
            // The map holds Compositor's curve at every level: 96 → 60, and blue's 255 → 200.
            #expect(abs(c.master[96].output * 255 - 60) < 1e-3 && abs(c.perChannel[2][255].output * 255 - 200) < 1e-3)
            #expect(c.perChannel[0].allSatisfy { abs($0.output - $0.input) < 1e-6 })
        } else { Issue.record("Curves") }
        if case .exposure(let e) = a[3] { #expect(e.exposure == 0.8 && e.offset == -0.1 && e.gamma == 1.2) } else { Issue.record("Exposure") }
        if case .gradientMap(let g) = a[4] {
            #expect(g.reverse && g.stops.count == 2 && g.stops[0].rgb == SIMD3(0.2, 0, 0) && g.stops[1].rgb == SIMD3(1, 1, 0.5))
        } else { Issue.record("Gradient Map") }
        #expect(a[5] == .invert)
        if case .blackWhite(let b) = a[6] { #expect(b.weights == [40, 60, 40, 60, 20, 80] && b.tint != nil) } else { Issue.record("B&W") }
        if case .colorBalance(let c) = a[7] { #expect(c.midtones == SIMD3(40, 0, -35) && !c.preserveLuminosity) } else { Issue.record("Color Balance") }
        for kind in ["Grain", "Add Noise", "Gaussian Blur (radius 4 px)", "Motion Blur (30°, 12 px)"] {
            #expect(r.warnings.contains { $0.hasPrefix(kind) && $0.contains("left out") }, "\(kind): \(r.warnings)")
        }
        #expect(r.warnings.contains { $0.contains("pencil") })
    }

    @Test func textAndShapeMetadataBecomeTypeAndShapeLayers() throws {
        // "a😀b": UTF-16 offsets 0, 1–2, 3; UTF-8 lengths 1, 4, 1.
        let text: [String: Any] = ["content": "a😀b", "fontName": "Helvetica-Bold", "fontSize": 36, "red": 0, "green": 0, "blue": 1,
                                   "alignment": "Center", "tracking": 18, "leading": 48, "boxSize": [120, 60],
                                   "colorRuns": [["location": 1, "length": 2, "red": 1, "green": 0, "blue": 0]]]
        let shape: [String: Any] = ["kind": "Rectangle", "red": 0, "green": 1, "blue": 0, "cornerRadius": 2]
        let line: [String: Any] = ["kind": "Line", "red": 1, "green": 0, "blue": 0, "cornerRadius": 0, "lineWidth": 2, "start": [0, 0], "end": [1, 1]]
        let m = K.manifest(width: 8, height: 8, layers: [
            K.layer(1, "Type", ["text": text]), K.layer(2, "Box", ["shape": shape, "transform": K.transform(2, 2, 4, 4)]),
            K.layer(3, "Line", ["shape": line]),
        ], ["resolution": 144])
        let img = K.solid(SIMD4(0, 0, 1, 1))
        let r = try K.load(m, ["\(K.id(1)).png": img, "\(K.id(2)).png": img, "\(K.id(3)).png": img])
        let d = r.document
        guard case .text(let t) = d.layers[0].content else { Issue.record("not a type layer"); return }
        #expect(t.text == "a😀b" && t.cache != nil)
        #expect(t.runs.map(\.len) == [1, 4, 1])
        #expect(t.runs[1].style.color == .rgb(1, 0, 0) && t.runs[0].style.color == .rgb(0, 0, 1))
        #expect(t.runs[0].style.postscriptName == "Helvetica-Bold" && t.sizePt == 18)
        #expect(t.runs[0].style.tracking == 500 && t.runs[0].style.leadingPt == 24)
        #expect(t.paragraphs.first?.style.align == .center)
        if case .box(let b) = t.shape { #expect(b.width == 96 && b.height == 36) } else { Issue.record("not box text") }
        guard case .shape(let s) = d.layers[1].content else { Issue.record("not a shape layer"); return }
        #expect(s.cache != nil && s.fill == .solid(.rgb(0, 1, 0)))
        #expect(s.live == .rect(rect: SIMD4(2, 2, 4, 4), radii: SIMD4(repeating: 2)))
        #expect(!s.path.isEmpty)
        guard case .shape(let l) = d.layers[2].content else { Issue.record("not a line"); return }
        #expect(l.fill == nil && l.stroke?.width == 2 && l.live == .line(from: SIMD2(0, 0), to: SIMD2(4, 4), weight: 2))
    }

    @Test func blankLayersEffectsAndUnknownModes() throws {
        let fx: [String: Any] = ["stroke": ["size": 3, "red": 0, "green": 0, "blue": 1, "opacity": 1, "inside": true],
                                 "shadow": ["angle": 120, "distance": 5, "blur": 4, "red": 0, "green": 0, "blue": 0, "opacity": 0.5, "enabled": false],
                                 "outerGlow": ["size": 6, "red": 1, "green": 1, "blue": 0, "opacity": 0.75],
                                 "innerShadow": ["angle": 90, "distance": 2, "blur": 2, "red": 0, "green": 0, "blue": 0, "opacity": 0.5],
                                 "innerGlow": ["size": 3, "red": 1, "green": 1, "blue": 1, "opacity": 0.5],
                                 "colorOverlay": ["red": 1, "green": 0, "blue": 0, "opacity": 0.25]]
        let m = K.manifest(layers: [K.layer(1, "Blank", image: false), K.layer(2, "Styled", size: (8, 8), ["effects": fx, "blendMode": "Darker Gleam"])])
        // The 4×4 image drawn 8×8: effect sizes double with it.
        let r = try K.load(m, ["\(K.id(2)).png": K.solid(SIMD4(1, 1, 1, 1))])
        let d = r.document
        #expect(d.layers[0].surface?.tileCount == 0)
        let e = d.layers[1].effects
        #expect(e.enabled && e.items.count == 6)
        for item in e.items {
            switch item {
            case .stroke(let s): #expect(s.size == 6 && s.position == .inside)
            case .dropShadow(let s): #expect(!s.common.enabled && s.distance == 10 && s.size == 8 && s.angle == 120 && !s.useGlobalLight)
            case .outerGlow(let g): #expect(g.size == 12 && g.common.opacity == 0.75)
            case .innerShadow(let s): #expect(s.distance == 4)
            case .innerGlow(let g): #expect(g.size == 6)
            case .colorOverlay(let o): #expect(o.common.opacity == 0.25)
            default: Issue.record("unexpected effect \(item)")
            }
        }
        #expect(d.layers[1].blend == .normal && r.warnings.contains { $0.contains("Darker Gleam") })
    }

    @Test func packagesOnDiskAreCheckedLikeProjectStoreChecksThem() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("comp-\(UUID().uuidString)")
        let pkg = root.appendingPathComponent("Doc.comp")
        try fm.createDirectory(at: pkg.appendingPathComponent("images"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data(K.manifest(layers: [K.layer(1, "L")])).write(to: pkg.appendingPathComponent("manifest.json"))
        let outside = root.appendingPathComponent("outside.png")
        try Data(K.solid(SIMD4(1, 0, 0, 1))).write(to: outside)
        // A symbolic link pointing out of the package is refused.
        try fm.createSymbolicLink(at: pkg.appendingPathComponent("images/\(K.id(1)).png"), withDestinationURL: outside)
        #expect(CompImport.isPackage(pkg))
        #expect(throws: PCIOError.self) { try CompImport.importDocument(contentsOf: pkg, codec: ImageIOCodec()) }
        try fm.removeItem(at: pkg.appendingPathComponent("images/\(K.id(1)).png"))
        try fm.copyItem(at: outside, to: pkg.appendingPathComponent("images/\(K.id(1)).png"))
        let r = try CompImport.importDocument(contentsOf: pkg, codec: ImageIOCodec())
        #expect(r.document.name == "Doc.comp" && r.document.layers.count == 1)
        #expect(!CompImport.isPackage(outside))
    }
}

extension Float {
    /// The nearest 8-bit level, as a stored 8-bit sample reads back.
    var rounded8: Float { (self * 255).rounded() / 255 }
}
