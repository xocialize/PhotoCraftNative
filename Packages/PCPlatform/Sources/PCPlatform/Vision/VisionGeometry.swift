// On-device Vision helpers for geometry and text: horizon (Straighten), rectangle / document
// detection (Perspective Crop), text recognition, saliency (crop suggestions).
// Fills part of photocraft gap G15 (no ML runtime) with Apple's Vision framework. Subject and person
// segmentation are deliberately not here: the fleet's ExtractKit / MaskKit own them (see
// PORT-NOTES). Ports photocraft's geometry result shapes (crates/algo straighten / perspective crop
// inputs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Vision reports normalised coordinates with the origin bottom-left; everything here is converted to
// image pixels with the origin top-left (PCFoundation's convention).

import CoreGraphics
import CoreImage
import Foundation
import PCFoundation
import Vision

/// A quadrilateral in image pixels (y down).
public struct DetectedQuad: Sendable, Equatable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint
    public var confidence: Float

    public var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }
}

public struct HorizonResult: Sendable, Equatable {
    /// The horizon's angle in degrees, counter-clockwise positive as seen on screen (a horizon
    /// rising to the right is positive).
    public var angleDegrees: Double
    /// Rotate the image by this many degrees counter-clockwise to level it (Image ▸ Straighten).
    public var correctionDegrees: Double { -angleDegrees }
}

public struct RecognizedText: Sendable, Equatable {
    public var string: String
    public var confidence: Float
    public var quad: DetectedQuad
}

public struct SaliencyResult: Sendable {
    /// Saliency heat map resampled to the image size (0…1, row-major).
    public var heatMap: FloatImage
    /// Salient regions in image pixels, most salient first.
    public var regions: [CGRect]
}

public enum SaliencyKind: Sendable { case attention, objectness }

public enum VisionGeometry {
    static func cgImage(_ r: RasterBuffer) throws -> CGImage {
        try SurfaceBridge.cgImage(r.format.sample == .f32 ? r.converted(to: .u16) : r)
    }

    static func perform(_ requests: [VNRequest], on image: CGImage) throws {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform(requests) } catch { throw PlatformError.frameworkFailure("Vision: \(error.localizedDescription)") }
    }

    static func toPixels(_ p: CGPoint, _ w: Int, _ h: Int) -> CGPoint {
        CGPoint(x: p.x * CGFloat(w), y: (1 - p.y) * CGFloat(h))
    }

    static func quad(_ o: VNRectangleObservation, _ w: Int, _ h: Int) -> DetectedQuad {
        DetectedQuad(topLeft: toPixels(o.topLeft, w, h), topRight: toPixels(o.topRight, w, h), bottomRight: toPixels(o.bottomRight, w, h),
                     bottomLeft: toPixels(o.bottomLeft, w, h), confidence: o.confidence)
    }

    /// The horizon (VNDetectHorizonRequest), nil when none is found.
    public static func horizon(_ r: RasterBuffer) throws -> HorizonResult? {
        let req = VNDetectHorizonRequest()
        try perform([req], on: try cgImage(r))
        guard let o = req.results?.first else { return nil }
        // Measured: Vision reports a horizon rising to the right (on screen) as a negative angle.
        return HorizonResult(angleDegrees: -Double(o.angle) * 180 / .pi)
    }

    /// Rectangles (VNDetectRectanglesRequest), most confident first.
    public static func rectangles(_ r: RasterBuffer, maxCount: Int = 4, minimumConfidence: Float = 0.5, minimumSize: Float = 0.1,
                                  quadratureTolerance: Float = 20) throws -> [DetectedQuad] {
        let req = VNDetectRectanglesRequest()
        req.maximumObservations = maxCount
        req.minimumConfidence = minimumConfidence
        req.minimumSize = minimumSize
        req.quadratureTolerance = quadratureTolerance
        try perform([req], on: try cgImage(r))
        return (req.results ?? []).map { quad($0, r.width, r.height) }.sorted { $0.confidence > $1.confidence }
    }

    /// A document's outline (VNDetectDocumentSegmentationRequest).
    public static func document(_ r: RasterBuffer) throws -> DetectedQuad? {
        let req = VNDetectDocumentSegmentationRequest()
        try perform([req], on: try cgImage(r))
        return req.results?.first.map { quad($0, r.width, r.height) }
    }

    /// Text lines (VNRecognizeTextRequest).
    public static func recognizeText(_ r: RasterBuffer, accurate: Bool = true, languages: [String]? = nil) throws -> [RecognizedText] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = accurate ? .accurate : .fast
        req.usesLanguageCorrection = accurate
        if let languages { req.recognitionLanguages = languages }
        try perform([req], on: try cgImage(r))
        return (req.results ?? []).compactMap { o in
            guard let top = o.topCandidates(1).first else { return nil }
            return RecognizedText(string: top.string, confidence: top.confidence, quad: quad(o, r.width, r.height))
        }
    }

    /// Saliency heat map and regions (attention- or objectness-based).
    public static func saliency(_ r: RasterBuffer, kind: SaliencyKind = .attention) throws -> SaliencyResult {
        let req: VNImageBasedRequest = kind == .attention ? VNGenerateAttentionBasedSaliencyImageRequest() : VNGenerateObjectnessBasedSaliencyImageRequest()
        try perform([req], on: try cgImage(r))
        guard let o = (req.results as? [VNSaliencyImageObservation])?.first else { throw PlatformError.frameworkFailure("no saliency result") }
        // The map is a small one-channel float pixel buffer; scale it to the image.
        let ci = CIImage(cvPixelBuffer: o.pixelBuffer)
        let sx = CGFloat(r.width) / ci.extent.width, sy = CGFloat(r.height) / ci.extent.height
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        var buf = [Float](repeating: 0, count: r.width * r.height)
        RawDeveloper.context.render(scaled, toBitmap: &buf, rowBytes: r.width * 4, bounds: CGRect(x: 0, y: 0, width: r.width, height: r.height),
                                    format: .Rf, colorSpace: nil)
        // `render(toBitmap:)` writes the top row first (measured), matching the image's convention.
        let flipped = buf.map { min(max($0, 0), 1) }
        let regions = (o.salientObjects ?? []).sorted { $0.confidence > $1.confidence }.map { b -> CGRect in
            let bb = b.boundingBox
            return CGRect(x: bb.minX * CGFloat(r.width), y: (1 - bb.maxY) * CGFloat(r.height), width: bb.width * CGFloat(r.width), height: bb.height * CGFloat(r.height))
        }
        return SaliencyResult(heatMap: FloatImage(rect: PixelRect(x: 0, y: 0, width: r.width, height: r.height), channels: 1, data: flipped), regions: regions)
    }

    /// A crop of `aspect` (width/height; nil keeps the image's) that holds the salient regions,
    /// as large as fits — Photoshop's content-aware crop suggestion.
    public static func cropSuggestion(_ r: RasterBuffer, aspect: Double? = nil) throws -> CGRect {
        let s = try saliency(r, kind: .attention)
        let focus = s.regions.reduce(CGRect.null) { $0.union($1) }
        let a = aspect ?? Double(r.width) / Double(r.height)
        var w = Double(r.width), h = w / a
        if h > Double(r.height) { h = Double(r.height); w = h * a }
        let c = focus.isNull ? CGPoint(x: r.width / 2, y: r.height / 2) : CGPoint(x: focus.midX, y: focus.midY)
        let x = min(max(Double(c.x) - w / 2, 0), Double(r.width) - w), y = min(max(Double(c.y) - h / 2, 0), Double(r.height) - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The quad mapped onto an upright rectangle (Perspective Crop), via Core Image's
    /// CIPerspectiveCorrection. Output keeps the raster's format.
    public static func perspectiveCorrect(_ r: RasterBuffer, quad q: DetectedQuad) throws -> RasterBuffer {
        let img = CIImage(cgImage: try cgImage(r))
        func ci(_ p: CGPoint) -> CIVector { CIVector(x: p.x, y: CGFloat(r.height) - p.y) }
        guard let f = CIFilter(name: "CIPerspectiveCorrection") else { throw PlatformError.unsupported("CIPerspectiveCorrection") }
        f.setValue(img, forKey: kCIInputImageKey)
        f.setValue(ci(q.topLeft), forKey: "inputTopLeft"); f.setValue(ci(q.topRight), forKey: "inputTopRight")
        f.setValue(ci(q.bottomRight), forKey: "inputBottomRight"); f.setValue(ci(q.bottomLeft), forKey: "inputBottomLeft")
        guard let out = f.outputImage else { throw PlatformError.frameworkFailure("perspective correction") }
        let ext = out.extent.integral
        guard let cg = RawDeveloper.context.createCGImage(out, from: ext, format: r.format.sample == .u8 ? .RGBA8 : .RGBA16,
                                                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw PlatformError.frameworkFailure("render perspective correction")
        }
        let rgba = try SurfaceBridge.raster(from: cg)
        return r.format.alpha ? rgba : ImageCodecs.stripAlpha(rgba)
    }

    /// The image rotated by `degrees` counter-clockwise about its centre and cropped to the largest
    /// upright rectangle without empty corners (Straighten), via Core Image.
    public static func straighten(_ r: RasterBuffer, degrees: Double) throws -> RasterBuffer {
        let img = CIImage(cgImage: try cgImage(r))
        let rad = degrees * .pi / 180
        let rotated = img.transformed(by: CGAffineTransform(translationX: CGFloat(r.width) / 2, y: CGFloat(r.height) / 2)
            .rotated(by: rad).translatedBy(x: -CGFloat(r.width) / 2, y: -CGFloat(r.height) / 2))
        // Largest axis-aligned rectangle of the image's aspect inside the rotated image.
        let w = Double(r.width), h = Double(r.height), c = abs(cos(rad)), s = abs(sin(rad))
        let k = min(w / (w * c + h * s), h / (w * s + h * c))
        let cw = (w * k).rounded(.down), ch = (h * k).rounded(.down)
        let crop = CGRect(x: (w - cw) / 2, y: (h - ch) / 2, width: cw, height: ch)
        guard let cg = RawDeveloper.context.createCGImage(rotated, from: crop, format: r.format.sample == .u8 ? .RGBA8 : .RGBA16,
                                                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw PlatformError.frameworkFailure("straighten")
        }
        let rgba = try SurfaceBridge.raster(from: cg)
        return r.format.alpha ? rgba : ImageCodecs.stripAlpha(rgba)
    }
}
