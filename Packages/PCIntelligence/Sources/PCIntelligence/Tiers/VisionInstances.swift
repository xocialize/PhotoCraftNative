// Tier 1 (Apple Vision, on-device, no weights) for the Object Selection tool and its hover preview
// (Photoshop's Object Finder). MaskKit defines the promptable seam (`PromptMaskProvider`) but ships
// no model-free implementation of it, so this conformer picks among the foreground instances
// `VNGenerateForegroundInstanceMaskRequest` finds: the instances under the include clicks, minus
// those under exclude clicks, or those mostly inside the box. The engine tier (EdgeTAM / SAM 2.1,
// ForgeCore `EnginePromptMaskProvider`) replaces it through the registry. Command semantics after
// photocraft-engine's `select.object` (crates/engine/src/smartselect_cmds.rs), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import CoreVideo
import Foundation
import MaskKit
import Vision

/// One foreground instance Vision found: its soft coverage at the analysed image's size.
public struct VisionInstance: Sendable, Equatable {
    /// Vision's instance index.
    public let index: Int
    /// Coverage 0…1, row-major, top row first, at the image's size.
    public let coverage: [Float]
    /// Tight bounds (coverage > 0.5) in image pixels; empty when the instance is all fringe.
    public let bounds: CGRect
    /// Pixels with coverage > 0.5.
    public let area: Int
}

/// Vision's foreground instances of one image.
public struct VisionInstanceAnalysis: Sendable {
    public let width: Int
    public let height: Int
    public let instances: [VisionInstance]

    /// Runs `VNGenerateForegroundInstanceMaskRequest` on `image`. An image without a salient
    /// foreground yields no instances (not an error).
    public init(image: CGImage) throws {
        width = image.width
        height = image.height
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let obs = request.results?.first, !obs.allInstances.isEmpty else {
            instances = []
            return
        }
        var found: [VisionInstance] = []
        for index in obs.allInstances.sorted() {
            let buffer = try obs.generateScaledMaskForImage(forInstances: IndexSet(integer: index), from: handler)
            let cov = VisionInstanceAnalysis.plane(buffer, width: width, height: height)
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, area = 0
            for y in 0..<height {
                for x in 0..<width where cov[y * width + x] > 0.5 {
                    area += 1
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            let bounds = maxX >= 0 ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) : .null
            found.append(VisionInstance(index: index, coverage: cov, bounds: bounds, area: area))
        }
        instances = found
    }

    /// The instance whose mask covers image pixel (x, y) most (coverage > 0.5), if any.
    public func instance(atX x: Double, y: Double) -> VisionInstance? {
        let ix = Int(x.rounded(.down)), iy = Int(y.rounded(.down))
        guard ix >= 0, iy >= 0, ix < width, iy < height else { return nil }
        return instances
            .filter { $0.coverage[iy * width + ix] > 0.5 }
            .max { $0.coverage[iy * width + ix] < $1.coverage[iy * width + ix] }
    }

    /// The union (per-pixel max) of the coverage of `chosen`.
    public func union(_ chosen: [VisionInstance]) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        for inst in chosen { for i in out.indices where inst.coverage[i] > out[i] { out[i] = inst.coverage[i] } }
        return out
    }

    /// Reads a Vision mask buffer (one float or byte component) as a plane at `width × height`.
    static func plane(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [Float](repeating: 0, count: width * height) }
        var out = [Float](repeating: 0, count: w * h)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<h {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: Float.self)
                for x in 0..<w { out[y * w + x] = min(max(row[x], 0), 1) }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<h {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { out[y * w + x] = Float(row[x]) / 255 }
            }
        case kCVPixelFormatType_OneComponent16Half:
            for y in 0..<h {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: Float16.self)
                for x in 0..<w { out[y * w + x] = min(max(Float(row[x]), 0), 1) }
            }
        default:
            return [Float](repeating: 0, count: width * height)
        }
        if w == width && h == height { return out }
        return KitBridge.resampleBilinear(out, from: (w, h), to: (width, height))
    }
}

/// Why the Vision object picker found nothing.
public enum VisionInstanceError: Error, Equatable, CustomStringConvertible {
    /// Vision found no foreground instance in the image.
    case noForeground
    /// Instances exist, but none is under the prompt.
    case noObjectAtPrompt
    case emptyPrompt

    public var description: String {
        switch self {
        case .noForeground: "Vision found no object in the image"
        case .noObjectAtPrompt: "no object found at the click or inside the box"
        case .emptyPrompt: "the prompt has no click and no box"
        }
    }
}

/// MaskKit's promptable seam on Apple Vision's foreground instances: the Object Selection tool's
/// model-free tier.
public struct VisionInstanceMaskProvider: PromptMaskProvider {
    public static let engineName = "Apple Vision foreground instances"
    public let name = VisionInstanceMaskProvider.engineName

    /// A box selects an instance when at least this fraction of it lies inside the box.
    public var boxInclusion: Double

    public init(boxInclusion: Double = 0.5) { self.boxInclusion = boxInclusion }

    public func mask(_ image: CGImage, prompt: MaskPrompt) async throws -> CGImage {
        let analysis = try VisionInstanceAnalysis(image: image)
        let cov = try select(prompt, in: analysis)
        return try KitBridge.maskImage(cov, width: analysis.width, height: analysis.height)
    }

    /// The coverage `prompt` selects among `analysis`'s instances.
    public func select(_ prompt: MaskPrompt, in analysis: VisionInstanceAnalysis) throws -> [Float] {
        guard !prompt.isEmpty else { throw VisionInstanceError.emptyPrompt }
        guard !analysis.instances.isEmpty else { throw VisionInstanceError.noForeground }
        var chosen: [VisionInstance] = []
        if let box = prompt.box?.standardized {
            for inst in analysis.instances where inst.area > 0 {
                var inside = 0
                let x0 = max(0, Int(box.minX.rounded(.down))), x1 = min(analysis.width, Int(box.maxX.rounded(.up)))
                let y0 = max(0, Int(box.minY.rounded(.down))), y1 = min(analysis.height, Int(box.maxY.rounded(.up)))
                if x0 < x1 && y0 < y1 {
                    for y in y0..<y1 { for x in x0..<x1 where inst.coverage[y * analysis.width + x] > 0.5 { inside += 1 } }
                }
                if Double(inside) >= boxInclusion * Double(inst.area) { chosen.append(inst) }
            }
        }
        for p in prompt.points where p.include {
            if let inst = analysis.instance(atX: Double(p.x), y: Double(p.y)), !chosen.contains(inst) { chosen.append(inst) }
        }
        for p in prompt.points where !p.include {
            if let inst = analysis.instance(atX: Double(p.x), y: Double(p.y)) { chosen.removeAll { $0 == inst } }
        }
        guard !chosen.isEmpty else { throw VisionInstanceError.noObjectAtPrompt }
        return analysis.union(chosen)
    }
}
