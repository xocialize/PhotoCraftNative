// Port of photocraft-io (crates/io/tests/affinity.rs helpers, tests/support/current_affinity.rs),
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Test helpers: synthetic PNGs and preview envelopes, synthetic Affinity documents (PCAffinitySynth;
// the same pieces as PCAffinity's ModelTests), a seeded generator standing in for proptest, and a
// small CoreGraphics shape renderer standing in for photocraft_vector::render_shape.

import CoreGraphics
import Foundation
import PCAffinity
import PCAffinitySynth
@testable import PCIOAffinity
import PCDocument
import PCFoundation
import PCIOCore

typealias F = Synth.F
typealias Tag = Affinity.Tag

/// SplitMix64: deterministic cases, so a failure reproduces.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { Synth.bytesLE(v) }
func be<T: FixedWidthInteger>(_ v: T) -> [UInt8] { Synth.bytesBE(v) }
func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

/// The import through the default codec and no renderer (photocraft-io's `import`).
func importAF(_ name: String, _ bytes: [UInt8], renderer: (any LayerContentRenderer)? = nil) throws -> ImportResult {
    try AffinityImport.importDocument(name: name, bytes: bytes, renderer: renderer, codec: ImageIOCodec())
}

/// The error message of a failed import (nil when it succeeds).
func importError(_ name: String, _ bytes: [UInt8]) -> String? {
    do {
        _ = try importAF(name, bytes)
        return nil
    } catch {
        return String(describing: error)
    }
}

// MARK: - PNG and the preview envelope

/// One PNG chunk: length, type, data, CRC.
func chunk(_ kind: String, _ data: [UInt8]) -> [UInt8] {
    let tagged = ascii(kind) + data
    return be(UInt32(data.count)) + tagged + be(Synth.crc32(tagged))
}

/// A plain PNG (IHDR, one IDAT, IEND) of `rows` (unfiltered scanline bytes).
func makePNG(width: UInt32, height: UInt32, bitDepth: UInt8, colorType: UInt8, rows: [[UInt8]]) -> [UInt8] {
    var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    png += chunk("IHDR", be(width) + be(height) + [bitDepth, colorType, 0, 0, 0])
    png += chunk("IDAT", Synth.zlib(rows.flatMap { [0] + $0 }))
    png += chunk("IEND", [])
    return png
}

/// A 2×1 RGBA8 PNG: an opaque red-ish pixel and a transparent one.
func png() -> [UInt8] {
    makePNG(width: 2, height: 1, bitDepth: 8, colorType: 6, rows: [[220, 40, 60, 255, 0, 0, 0, 0]])
}

/// A synthetic record envelope, not an Affinity document writer (there is no object graph).
func file(_ png: [UInt8]) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 72)
    b.replaceSubrange(0..<4, with: Affinity.magic)
    b.replaceSubrange(4..<6, with: le(UInt16(12)))
    b.replaceSubrange(8..<12, with: ascii("nsrP"))
    b.replaceSubrange(12..<16, with: ascii("#Inf"))
    b.replaceSubrange(24..<32, with: le(UInt64(72)))
    b.replaceSubrange(64..<68, with: ascii("Prot"))
    b += [0xFF, 0xFF, 0xFF, 0xFF] + ascii("Thmb")
    b += le(UInt32(1)) + le(UInt32(png.count + 13)) + le(UInt32(29)) + le(UInt32(0)) + le(UInt32(png.count))
    b.append(1)
    b += png
    return b
}

// MARK: - Synthetic Affinity documents

func rgba(_ r: Float, _ g: Float, _ b: Float, _ a: Float) -> F {
    .structure([r, g, b, a].flatMap { le($0.bitPattern) })
}

/// A fill descriptor holding a solid RGBA colour: ids `id`, `id + 1`, `id + 2`.
func solid(_ id: UInt32, _ c: F) -> F {
    .def(id, ["FDsc"], [("FDeF", .def(id + 1, ["FilS"], [("Colr", .def(id + 2, ["RGBA"], [("_col", c)]))]))])
}

/// A stroke style of `width` px: ids `id`, `id + 1`.
func lineStyle(_ id: UInt32, width: Double) -> F {
    .def(id, ["LDsc"], [("LDeL", .def(id + 1, ["LSty"], [("Wght", .f64(width))]))])
}

/// One 18-byte curve record: an anchor at (x, y).
func anchor(_ x: Double, _ y: Double, role: UInt8 = 0) -> [UInt8] {
    le(x.bitPattern) + le(y.bitPattern) + [1, role]
}

/// A raw field: type code, tag, payload (for value kinds the synthetic builder has no case for).
func rawField(_ code: UInt8, _ tag: Tag, _ payload: [UInt8]) -> (Tag, F) {
    (tag, .raw([code] + le(tag.rawValue) + payload))
}

/// An array of f64 values (`Doub`, dash patterns).
func f64Array(_ tag: Tag, _ v: [Double]) -> (Tag, F) {
    rawField(0x80 | 0x0a, tag, le(UInt32(v.count)) + v.flatMap { le($0.bitPattern) })
}

/// An array of i32 values (`Ints`).
func i32Array(_ tag: Tag, _ v: [Int32]) -> (Tag, F) {
    rawField(0x80 | 0x07, tag, le(UInt32(v.count)) + v.flatMap { le($0) })
}

/// Four i32 values (`BitR`).
func ints4(_ tag: Tag, _ v: [Int32]) -> (Tag, F) {
    rawField(0x17, tag, v.flatMap { le($0) })
}

/// A blob (`Data` of an embedded file).
func blob(_ tag: Tag, _ b: [UInt8]) -> (Tag, F) {
    rawField(0x2d, tag, le(UInt32(b.count)) + b)
}

/// A `doc.dat` stream: `UVCn.UPPI` = dpi, `DocR` holding `spreads`.
func stream(_ spreads: [F], dpi: Double = 144, extra: [(Tag, F)] = []) -> [UInt8] {
    Synth.stream([
        ("UVCn", .obj("UVCn", [("UPPI", .f64(dpi))])),
        ("DocR", .def(1, ["DocN"], [("Chld", .shared(spreads))])),
    ] + extra)
}

func spread(_ id: UInt32, _ children: [F], bounds: [Double] = [0, 0, 200, 100], transparent: Bool = true, fields: [(Tag, F)] = []) -> F {
    .def(id, ["Sprd"], [("SprB", .f64s(bounds)), ("SprT", .bool(transparent)), ("Chld", .shared(children))] + fields)
}

/// A stored container of one spread holding `nodes`, plus extra archive entries.
func container(_ nodes: [F], bounds: [Double] = [0, 0, 200, 100], transparent: Bool = true, entries: [(String, [UInt8])] = []) -> [UInt8] {
    Synth.container([("doc.dat", stream([spread(2, nodes, bounds: bounds, transparent: transparent)]), .stored)] + entries.map { ($0.0, $0.1, .stored) })
}

/// A parametric shape node: class `cls` in `box`.
func shapeNode(_ id: UInt32, _ cls: Tag, _ box: [Double], _ params: [(Tag, F)] = [], fields: [(Tag, F)] = []) -> F {
    .def(id, ["ShpN"], [("Shpe", .def(id + 1, [cls], params)), ("ShpB", .f64s(box))] + fields)
}

/// A 256 × 256 planar tile whose byte at (x, y) is `value(x, y)`.
func tile(_ value: (Int, Int) -> UInt8) -> [UInt8] {
    var t = [UInt8](repeating: 0, count: 65536)
    for y in 0..<256 { for x in 0..<256 { t[y * 256 + x] = value(x, y) } }
    return t
}

/// A planar bitmap (`DyBm`): per channel a tile state (0 empty, 2 full, 4 stored tile) and entry.
func bitmap(_ id: UInt32, width: UInt32, height: UInt32, format: UInt16, channels: [(state: UInt8, entry: String?)], extra: [(Tag, F)] = []) -> F {
    var fields: [(Tag, F)] = [("BmpW", .u32(width)), ("BmpH", .u32(height)), ("Frmt", .enumeration(format, 0))]
    for (i, c) in channels.enumerated() {
        fields.append((Tag("Sta\(i + 1)"), .u8s([c.state])))
        if let e = c.entry {
            fields.append((Tag("Idx\(i + 1)"), .shared([.def(id + 1 + UInt32(i), ["Blck"], [("Data", .entry(e))])])))
        }
    }
    return .def(id, ["DyBm"], fields + extra)
}

/// The ring document of photocraft-io's `mod native`: version 12 at 144 ppi, 200×100, an artboard
/// "Board" moved by (20, 10) holding a red ring (two subpaths, filled even-odd) with a 4 px blue
/// stroke; the 2×1 PNG as its preview.
func ringDocument(_ method: Synth.Method) -> [UInt8] {
    func square(_ s: Double, _ o: Double) -> [[UInt8]] {
        [anchor(o, o), anchor(o + s, o), anchor(o + s, o + s), anchor(o, o + s), anchor(o, o)]
    }
    let ring: F = .def(20, ["PCrv"], [
        ("Desc", .str("Ring")),
        ("Crvs", .obj("PCvD", [("Data", .pos([.u8(0), .u32(2), .bool(true), .records(18, square(60, 0)), .bool(true), .records(18, square(20, 20))]))])),
        ("BFFl", .shared([solid(21, rgba(1, 0, 0, 1))])),
        ("LIFl", .shared([solid(24, rgba(0, 0, 1, 1))])),
        ("LILn", .shared([lineStyle(27, width: 4)])),
    ])
    let board: F = .def(10, ["ShpN"], [
        ("Desc", .str("Board")),
        ("ABEn", .bool(true)),
        ("Shpe", .def(11, ["ShNR"], [])),
        ("ShpB", .f64s([0, 0, 120, 80])),
        ("Xfrm", .f64s([1, 0, 20, 0, 1, 10])),
        ("BFFl", .shared([solid(12, rgba(1, 1, 1, 1))])),
        ("Chld", .shared([ring])),
    ])
    return Synth.container([("doc.dat", stream([spread(2, [board])]), method)], thumbnailPNG: png())
}

/// photocraft-io tests/support/current_affinity.rs: how a board says it is one.
enum Marker { case legacy, current, otherProperties }

/// Two 16 px boards at x = 0 and 24 on a 40×16 spread, each holding a red square that overflows
/// it by 4 px on every side.
func boardsDocument(_ marker: Marker, curve: Bool, _ method: Synth.Method) -> [UInt8] {
    func board(_ id: UInt32, _ x: Double) -> F {
        let child: F = .def(id + 10, ["ShpN"], [
            ("Desc", .str("Overflow")),
            ("Shpe", .def(id + 11, ["ShNR"], [])),
            ("ShpB", .f64s([-4, -4, 20, 20])),
            ("BFFl", .shared([solid(id + 12, rgba(1, 0, 0, 1))])),
        ])
        var fields: [(Tag, F)] = [
            ("Desc", .str("Board \(id)")),
            ("Shpe", .def(id + 1, ["ShNR"], [])),
            ("ShpB", .f64s([0, 0, 16, 16])),
            ("Xfrm", .f64s([1, 0, x, 0, 1, 0])),
            ("Chld", .shared([child])),
        ]
        switch marker {
        case .legacy:
            fields.append(("ABEn", .bool(true)))
        case .current, .otherProperties:
            fields.append(("ABEn", .bool(false)))
            fields.append(("phrp", .def(id + 2, [marker == .current ? "aprp" : "prps"], [])))
        }
        return .def(id, [curve ? "PCrv" : "ShpN"], fields)
    }
    let s = stream([spread(2, [board(100, 0), board(200, 24)], bounds: [0, 0, 40, 16])])
    return Synth.container([("doc.dat", s, method)])
}

// MARK: - Renderers

/// Fills a shape's outline with its solid fill through CoreGraphics (no antialiasing, no stroke):
/// enough to check what photocraft's `render_shape` cache shows.
struct CGShapeRenderer: LayerContentRenderer {
    func renderShape(_ shape: ShapeLayer, format: PixelFormat, canvas: PixelRect) -> Surface? {
        guard format == .rgba8, case .solid(let c)? = shape.fill, canvas.width > 0, canvas.height > 0 else { return Surface(format: format) }
        let (w, h) = (canvas.width, canvas.height)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setShouldAntialias(false)
            // Top-left origin, canvas coordinates.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: -CGFloat(canvas.x0), y: -CGFloat(canvas.y0))
            let path = CGMutablePath()
            for s in shape.path.subpaths { path.addPath(s.cgPath) }
            ctx.addPath(path)
            ctx.setFillColor(CGColor(srgbRed: CGFloat(c.rgb.x), green: CGFloat(c.rgb.y), blue: CGFloat(c.rgb.z), alpha: CGFloat(c.alpha)))
            ctx.fillPath(using: shape.path.fillRule.cgFillRule)
            return true
        }
        guard ok else { return nil }
        return Surface(format: .rgba8, rect: canvas, interleaved: buf)
    }
}

/// A renderer whose fonts resolve one PostScript name and whose type layers render as one marker
/// pixel at (0, 0).
struct FontRenderer: LayerContentRenderer {
    func hasFontFamily(_ family: String) -> Bool { family == "Helvetica Neue" }
    func resolvePostScript(_ name: String) -> ResolvedFont? {
        name == "Helvetica-Bold" ? ResolvedFont(family: "Helvetica Neue", weight: 700, italic: false, exact: true) : nil
    }
    func renderText(_ text: TextLayer, format: PixelFormat, dpi: Float, maxPixels: UInt64) -> Surface? {
        var s = Surface(format: format)
        s.setPixel(x: 0, y: 0, [0, 0, 0, 1])
        return s
    }
}

/// A codec returning one fixed picture.
struct StubCodec: FlatImageCodec {
    let image: DecodedImage
    func decode(_ data: [UInt8]) throws -> DecodedImage { image }
    func encode(_ surface: Surface, rect: PixelRect, as type: FlatImageType, quality: Double?, iccProfile: [UInt8]?) throws -> [UInt8] {
        throw PCIOError.codec("stub")
    }
}

// MARK: - Layer access

extension Layer {
    var shapeContent: ShapeLayer? { if case .shape(let s) = content { s } else { nil } }
    var textContent: TextLayer? { if case .text(let t) = content { t } else { nil } }
    var smartContent: SmartObject? { if case .smart(let s) = content { s } else { nil } }
}

/// Interleaved bytes of `s` at `r`.
func bytes(_ s: Surface?, _ r: PixelRect) -> [UInt8] {
    s?.readInterleaved(r) ?? []
}

final class Box<T>: @unchecked Sendable {
    var value: T?
}

/// Run `body` on a thread with a `stack`-byte stack and wait for its result.
func onThread<T>(stack: Int, _ body: @escaping @Sendable () -> T) -> T {
    let box = Box<T>()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        box.value = body()
        done.signal()
    }
    thread.stackSize = stack
    thread.start()
    done.wait()
    return box.value!
}
