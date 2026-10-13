// Test fixtures for PCIntelligence: generated documents (no files, no network, no weights) and fake
// providers standing in for ForgeCore's engine adapters. MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

import ColorizeKit
import CoreGraphics
import EraseKit
import ExtractKit
import Foundation
import MaskKit
import PCDocument
import PCFoundation
import PCHistory
import RestoreTier2
import Synchronization
@testable import PCIntelligence

enum Fixture {
    /// A document whose Background shows `px(x, y)` (straight sRGB RGBA, 0…1).
    static func document(width: Int, height: Int, depth: SampleType = .u8, mode: ColorMode = .rgb,
                         _ px: (Int, Int) -> SIMD4<Float>) -> Document {
        var d = Document.withBackground(name: "fixture", size: PixelSize(width: width, height: height), mode: mode, depth: depth, fill: .white)
        let rect = d.bounds
        var rgba = [SIMD4<Float>](repeating: .zero, count: width * height)
        for y in 0..<height { for x in 0..<width { rgba[y * width + x] = px(x, y) } }
        d.updateBackground { l in l.withRaster { KitBridge.write(rgba: rgba, into: &$0, rect: rect) } }
        return d
    }

    static let blue = SIMD4<Float>(0.2, 0.4, 0.85, 1)
    static let orange = SIMD4<Float>(0.9, 0.3, 0.1, 1)

    /// An orange disc (centre (cx, cy), radius r) on a flat blue background: a subject Apple Vision
    /// finds (`VNGenerateForegroundInstanceMaskRequest` returns one instance for it).
    static func disc(width: Int = 512, height: Int = 384, cx: Double = 256, cy: Double = 192, r: Double = 100,
                     depth: SampleType = .u8) -> Document {
        document(width: width, height: height, depth: depth) { x, y in
            inside(x, y, cx, cy, r) ? orange : blue
        }
    }

    /// A red and a blue disc on light grey: two objects.
    static func twoDiscs(depth: SampleType = .u8) -> Document {
        document(width: 512, height: 384, depth: depth) { x, y in
            if inside(x, y, 120, 180, 80) { return SIMD4(0.8, 0.1, 0.1, 1) }
            if inside(x, y, 375, 195, 75) { return SIMD4(0.1, 0.2, 0.8, 1) }
            return SIMD4(0.95, 0.95, 0.95, 1)
        }
    }

    static func inside(_ x: Int, _ y: Int, _ cx: Double, _ cy: Double, _ r: Double) -> Bool {
        let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
        return dx * dx + dy * dy <= r * r
    }

    /// Intersection over union of a coverage surface (> 0.5) against a predicate on the canvas.
    static func iou(_ s: Surface?, width: Int, height: Int, _ truth: (Int, Int) -> Bool) -> Double {
        guard let s else { return 0 }
        let m = CoverageMask(surface: s, rect: PixelRect(x: 0, y: 0, width: width, height: height))
        var inter = 0, uni = 0
        for y in 0..<height {
            for x in 0..<width {
                let a = m.values[y * width + x] > 0.5, b = truth(x, y)
                if a && b { inter += 1 }
                if a || b { uni += 1 }
            }
        }
        return uni == 0 ? 0 : Double(inter) / Double(uni)
    }

    /// A rectangular selection (GRAY8, coverage 1).
    static func selection(_ r: PixelRect) -> Surface {
        CoverageMask(rect: r, fill: 1).surface()!
    }

    /// Deterministic pseudo-random numbers.
    struct RNG {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 24)
        }
        /// Approximately normal (sum of uniforms).
        mutating func normal() -> Float { (0..<4).reduce(Float(0)) { s, _ in s + next() } - 2 }
    }

    /// Applies a transaction to a copy of `doc`.
    static func applied(_ tx: EditTransaction?, to doc: Document) throws -> Document {
        var d = doc
        if let tx { try tx.apply(to: &d) }
        return d
    }

    /// Mean straight RGBA of a region of a layer.
    static func mean(_ s: Surface, _ r: PixelRect) -> SIMD4<Float> {
        let px = s.readRGBA(r)
        return px.reduce(SIMD4<Float>(), +) / Float(max(px.count, 1))
    }
}

/// Whether Apple Vision finds the disc fixture's subject in this environment (headless CI may not
/// run Vision). Tests that need Vision are disabled with this as the recorded reason when it doesn't.
enum VisionProbe {
    static let detectsDisc: Bool = {
        let d = Fixture.disc()
        guard let s = d.layers.first?.surface,
              let img = try? KitBridge.image(from: s, rect: d.bounds, colorSpace: KitBridge.colorSpace(for: d)),
              let a = try? VisionInstanceAnalysis(image: img) else { return false }
        return !a.instances.isEmpty
    }()
}

// MARK: - Fake providers (stand-ins for ForgeCore's engine adapters; no MLX, no weights)

/// Records calls; thread-safe.
final class CallLog: Sendable {
    private let calls = Mutex<[String]>([])
    func add(_ s: String) { calls.withLock { $0.append(s) } }
    var all: [String] { calls.withLock { $0 } }
}

/// Takes `InpaintOptions` (as PCEngine's PatchMatch does): records what it was given and fills
/// the hole with the colour the options select (green for a mirrored fill, magenta otherwise).
final class OptionsRecordingInpaint: OptionsInpaintProvider {
    let name = "FakePatchMatch"
    private let log = Mutex<[InpaintOptions]>([])
    var seen: [InpaintOptions] { log.withLock { $0 } }
    func inpaint(_ image: CGImage, mask: CGImage, quality: InpaintQuality, options: InpaintOptions) async throws -> CGImage {
        log.withLock { $0.append(options) }
        let w = image.width, h = image.height
        let m = try KitBridge.coverage(from: mask, width: w, height: h)
        var px = try KitBridge.rgba(from: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, sample: .u8)
        for i in px.indices where m[i] > 0.5 { px[i] = options.mirror ? SIMD4(0, 1, 0, 1) : SIMD4(1, 0, 1, 1) }
        return try KitBridge.image(fromRGBA: px, width: w, height: h, sample: .u8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}

/// Fills the hole with solid magenta.
struct MagentaInpaint: InpaintProvider {
    let name = "FakeLaMa"
    let log: CallLog
    func inpaint(_ image: CGImage, mask: CGImage, quality: InpaintQuality) async throws -> CGImage {
        log.add("inpaint \(quality.rawValue)")
        let w = image.width, h = image.height
        let m = try KitBridge.coverage(from: mask, width: w, height: h)
        var px = try KitBridge.rgba(from: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, sample: .u8)
        for i in px.indices where m[i] > 0.5 { px[i] = SIMD4(1, 0, 1, 1) }
        return try KitBridge.image(fromRGBA: px, width: w, height: h, sample: .u8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}

/// A matte whose top half is white.
struct HalfMatte: MatteProvider {
    let name = "FakeBiRefNet"
    func matte(_ image: CGImage, quality: ExtractQuality) async throws -> CGImage {
        let w = image.width, h = image.height
        var v = [Float](repeating: 0, count: w * h)
        for y in 0..<(h / 2) { for x in 0..<w { v[y * w + x] = 1 } }
        return try KitBridge.maskImage(v, width: w, height: h)
    }
}

/// Selects a 20×20 square centred on the first include click (records the prompt it got).
final class SquarePromptMask: PromptMaskProvider, @unchecked Sendable {
    let name = "FakeEdgeTAM"
    private let lock = NSLock()
    private var _last: MaskPrompt?
    var last: MaskPrompt? { lock.withLock { _last } }
    func mask(_ image: CGImage, prompt: MaskPrompt) async throws -> CGImage {
        lock.withLock { _last = prompt }
        let w = image.width, h = image.height
        var v = [Float](repeating: 0, count: w * h)
        if let p = prompt.points.first(where: { $0.include }) {
            for y in max(0, Int(p.y) - 10)..<min(h, Int(p.y) + 10) { for x in max(0, Int(p.x) - 10)..<min(w, Int(p.x) + 10) { v[y * w + x] = 1 } }
        }
        return try KitBridge.maskImage(v, width: w, height: h)
    }
}

/// Colours every pixel with a sepia version of its luminance.
struct SepiaColorize: ColorizeProvider {
    let name = "FakeDDColor"
    func colorize(_ image: CGImage, variant: ColorizeVariant) async throws -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var px = try KitBridge.rgba(from: image, colorSpace: cs, sample: .u8)
        for i in px.indices {
            let l = 0.299 * px[i].x + 0.587 * px[i].y + 0.114 * px[i].z
            px[i] = SIMD4(min(l * 1.1, 1), l * 0.9, l * 0.6, 1)
        }
        return try KitBridge.image(fromRGBA: px, width: image.width, height: image.height, sample: .u8, colorSpace: cs)
    }
}

/// Nearest-neighbour ×factor.
struct NearestUpscale: UpscaleProvider {
    let name = "FakeRealPLKSR"
    func upscale(_ image: CGImage, factor: Int) async throws -> CGImage {
        let w = image.width * factor, h = image.height * factor
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }
}

/// A restore provider with a denoise backer only; deblur jobs are unregistered (as ForgeCore's
/// adapter reports them when their backer fails registration). Denoising here inverts the image so
/// the test can tell it ran.
struct InvertingRestore: FrameRestoreProvider {
    func engineName(for job: RestoreJob) -> String { job == .denoise ? "FakeNAFNet" : "unavailable" }
    func restore(imageData: Data, job: RestoreJob, strength: Float?) async throws -> FrameRestoreResult {
        let img = try KitBridge.decodeImage(imageData)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var px = try KitBridge.rgba(from: img, colorSpace: cs, sample: .u8)
        for i in px.indices { px[i] = SIMD4(1 - px[i].x, 1 - px[i].y, 1 - px[i].z, 1) }
        let out = try KitBridge.image(fromRGBA: px, width: img.width, height: img.height, sample: .u8, colorSpace: cs)
        return FrameRestoreResult(imageData: try KitBridge.pngData(out), appliedStrength: nil, engineName: "FakeNAFNet")
    }
}

/// Blocks until cancelled.
struct SlowInpaint: InpaintProvider {
    let name = "Slow"
    func inpaint(_ image: CGImage, mask: CGImage, quality: InpaintQuality) async throws -> CGImage {
        try await Task.sleep(for: .seconds(30))
        return image
    }
}
