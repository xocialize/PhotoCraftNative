// Port of photocraft-compose (crates/compose/src/lib.rs `render_content`, shape_split.rs) and photocraft-vector (`path_coverage`, `CompiledVectorMask`) entry points, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// What the planner needs from the vector and type engines, which live in PCPlatform: pixels of
// type / shape / smart-object layers that carry no cached raster, the coverage of a path (vector
// masks, a filled shape's effect outline) and a shape rendered without its stroke or fill (shapes
// whose vector stroke sits above their clipped layers). `PlaceholderRasterizer` renders nothing
// and records every miss, so a document still composites (those layers draw as empty, vector
// masks and effect outlines use PCRender's own exact path coverage, `PathCoverage`) and callers
// can tell what was left out.

import Foundation
import PCDocument
import PCFoundation

/// Rasterises what the compositor can't draw from stored pixels (implemented by PCPlatform).
public protocol LayerRasterizer: Sendable {
    /// The pixels of a type, shape or smart-object layer that has no cached raster (`layer.surface`
    /// is nil), in any pixel format (read as straight RGBA); nil when it can't be rendered.
    func rasterize(_ layer: Layer, in document: Document) -> Surface?
    /// Fill coverage (0…1, row-major over `rect`) of `path`: its fill rule and path operations,
    /// inverted when `path.inverted`. nil when it can't be computed.
    func coverage(of path: VectorPath, in rect: PixelRect) -> [Float]?
    /// `shape` (its fill and/or stroke, ignoring `cache`) rendered as RGBA over `clip` in `format`;
    /// nil when it can't be rendered.
    func renderShape(_ shape: ShapeLayer, format: PixelFormat, clip: PixelRect) -> Surface?
}

/// Something the rasterizer could not provide.
public struct RasterMiss: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Hashable, Sendable {
        /// A type / shape / smart-object layer without a cached raster (drawn as empty).
        case layerPixels
        /// A vector mask's coverage (no longer reported: PCRender falls back to `PathCoverage`).
        case vectorMask
        /// A filled shape's effect outline (no longer reported: `PathCoverage` fallback).
        case effectOutline
        /// A stroked shape's fill / stroke split (the shape draws as one raster).
        case shapeSplit
    }
    public var layer: LayerId
    public var kind: Kind
    public init(layer: LayerId, kind: Kind) { self.layer = layer; self.kind = kind }
    public var description: String { "\(kind.rawValue) of \(layer)" }
}

/// A `LayerRasterizer` that renders nothing and records each miss (until PCPlatform supplies the
/// real one). Misses are also reported per plan in `DocumentPlan.misses`.
public final class PlaceholderRasterizer: LayerRasterizer, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RasterMiss] = []
    private var requests = 0

    public init() {}

    /// Every request this rasterizer turned down, in order (duplicates kept).
    public var misses: [RasterMiss] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Requests seen (all of them misses).
    public var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    public func reset() {
        lock.lock(); recorded.removeAll(); requests = 0; lock.unlock()
    }

    /// Records a miss the planner attributes to a layer (the protocol calls carry no layer id).
    func record(_ m: RasterMiss) {
        lock.lock(); recorded.append(m); lock.unlock()
    }

    public func rasterize(_ layer: Layer, in document: Document) -> Surface? {
        lock.lock(); requests += 1; lock.unlock()
        return nil
    }

    public func coverage(of path: VectorPath, in rect: PixelRect) -> [Float]? {
        lock.lock(); requests += 1; lock.unlock()
        return nil
    }

    public func renderShape(_ shape: ShapeLayer, format: PixelFormat, clip: PixelRect) -> Surface? {
        lock.lock(); requests += 1; lock.unlock()
        return nil
    }
}
