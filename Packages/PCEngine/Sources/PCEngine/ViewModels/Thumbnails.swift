// Port of photocraft architecture §4.5 ("Thumbnails are ThumbHandles that the UI resolves to textures through an engine thumbnail cache") and §5 ("tile generation counters feed the GPU residency cache and the thumbnail cache"), with photocraft-compose's `thumbnail` as the renderer, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// A `ThumbHandle` names what a thumbnail shows (a layer, its mask, the whole document) and a key
// that changes exactly when those pixels can have changed: the tile generations of every surface
// involved (PCFoundation renews a tile's generation on every write; copy-on-write copies keep it)
// plus the appearance-relevant model fields. A panel re-renders a row only when its handle
// changes; the cache renders on demand, through PCRender, on any thread.

import Foundation
import PCDocument
import PCFoundation
import PCRender
import Synchronization

/// What a thumbnail shows and the key of its pixels.
public struct ThumbHandle: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable { case document, layer, layerMask, channel }
    public var doc: DocId
    public var kind: Kind
    public var layer: LayerId?
    /// Alpha channel index for `.channel`.
    public var channel: Int?
    /// Changes whenever the thumbnail's pixels can have changed.
    public var key: UInt64
}

/// A rendered thumbnail: 8-bit straight RGBA, row-major.
public struct Thumbnail: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var rgba8: [UInt8]
}

public enum ThumbKeys {
    static func mix(_ h: inout UInt64, _ v: UInt64) {
        h = (h ^ v) &* 0x0100_0000_01b3
        h ^= h >> 31
    }

    static func hashOf<T: Hashable>(_ v: T) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(v)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// The pixel key of a layer's own appearance (content, cached renders, model fields).
    public static func layer(_ l: Layer, docSize: PixelSize) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        mix(&h, UInt64(docSize.width) << 32 | UInt64(docSize.height))
        if let s = l.surface { mix(&h, ContentBounds.fingerprint(s)) }
        switch l.content {
        case .adjustment(let a): mix(&h, hashOf(a))
        case .fill(let f): mix(&h, hashOf(f))
        case .text(let t): mix(&h, hashOf(t.text)); mix(&h, hashOf(t.transform))
        case .shape(let s): mix(&h, hashOf(s.path)); mix(&h, hashOf(s.fill)); mix(&h, hashOf(s.stroke))
        case .group(let g): for c in g.children { mix(&h, layer(c, docSize: docSize)); mix(&h, hashOf(c.properties.visible)) }
        default: break
        }
        return h
    }

    public static func mask(_ m: LayerMask) -> UInt64 {
        var h: UInt64 = 0x84222325
        mix(&h, ContentBounds.fingerprint(m.surface))
        mix(&h, UInt64(m.density.bitPattern) << 32 | UInt64(m.feather.bitPattern))
        mix(&h, m.enabled ? 1 : 0)
        return h
    }
}

/// Renders and caches thumbnails (LRU by insertion, bounded by count).
public final class ThumbnailCache: Sendable {
    private struct Entry: Sendable { var thumb: Thumbnail; var stamp: UInt64 }
    private let entries = Mutex<[ThumbHandle: Entry]>([:])
    private let clock = Atomic<UInt64>(0)
    public let capacity: Int
    public let renderer: EngineRenderer

    public init(capacity: Int = 512, renderer: EngineRenderer = .shared) {
        self.capacity = capacity
        self.renderer = renderer
    }

    public var count: Int { entries.withLock { $0.count } }

    /// The handle of a layer's thumbnail.
    public static func handle(doc: Document, layer l: Layer) -> ThumbHandle {
        ThumbHandle(doc: doc.id, kind: .layer, layer: l.id, channel: nil, key: ThumbKeys.layer(l, docSize: doc.size))
    }

    public static func maskHandle(doc: Document, layer l: Layer) -> ThumbHandle? {
        guard let m = l.mask else { return nil }
        return ThumbHandle(doc: doc.id, kind: .layerMask, layer: l.id, channel: nil, key: ThumbKeys.mask(m))
    }

    public static func documentHandle(_ doc: Document) -> ThumbHandle {
        var h: UInt64 = 0x1234
        for l in doc.layers {
            ThumbKeys.mix(&h, ThumbKeys.layer(l, docSize: doc.size))
            let pr = l.properties
            ThumbKeys.mix(&h, ThumbKeys.hashOf([pr.visible ? 1 : 0, Int(pr.opacity.bitPattern), Int(pr.fillOpacity.bitPattern),
                                                Int(pr.blend.rawValue), pr.clipped ? 1 : 0, Int(pr.excludedChannels)]))
            ThumbKeys.mix(&h, ThumbKeys.hashOf(pr.effects))
            ThumbKeys.mix(&h, ThumbKeys.hashOf(pr.vectorMask))
            if let m = l.mask { ThumbKeys.mix(&h, ThumbKeys.mask(m)) }
        }
        return ThumbHandle(doc: doc.id, kind: .document, layer: nil, channel: nil, key: h)
    }

    /// The thumbnail for `handle`, rendered from `doc` when not cached. `maxSide` bounds its
    /// longer side.
    public func thumbnail(_ handle: ThumbHandle, in doc: Document, maxSide: Int = 64) throws -> Thumbnail {
        let stamp = clock.add(1, ordering: .relaxed).newValue
        if let e = entries.withLock({ c -> Entry? in
            guard var e = c[handle] else { return nil }
            e.stamp = stamp
            c[handle] = e
            return e
        }) { return e.thumb }
        let t = try render(handle, doc, maxSide: maxSide)
        entries.withLock { c in
            c[handle] = Entry(thumb: t, stamp: stamp)
            if c.count > capacity, let oldest = c.min(by: { $0.value.stamp < $1.value.stamp })?.key { c[oldest] = nil }
        }
        return t
    }

    /// Drops every entry (Purge).
    public func purge() { entries.withLock { $0.removeAll() } }

    func render(_ h: ThumbHandle, _ doc: Document, maxSide: Int) throws -> Thumbnail {
        switch h.kind {
        case .document:
            return Self.pack(try renderer.thumbnail(doc, maxSide: maxSide))
        case .layer:
            guard let id = h.layer, var l = doc.layer(id) else { throw EngineError.other("no layer for thumbnail") }
            // The layer alone, as itself: shown, normal, full opacity, unclipped, unmasked.
            l.visible = true
            l.opacity = 1
            l.fillOpacity = 1
            l.clipped = false
            l.mask = nil
            if l.blend == .passThrough || !l.isGroup { l.blend = l.isGroup ? .passThrough : .normal }
            var solo = doc
            solo.layers = [l]
            return Self.pack(try renderer.thumbnail(solo, maxSide: maxSide))
        case .layerMask:
            guard let id = h.layer, let m = doc.layer(id)?.mask else { throw EngineError.other("no mask for thumbnail") }
            return Self.gray(m.surface, doc.bounds, maxSide: maxSide)
        case .channel:
            guard let i = h.channel, i < doc.channels.count else { throw EngineError.other("no channel for thumbnail") }
            return Self.gray(doc.channels[i].surface, doc.bounds, maxSide: maxSide)
        }
    }

    static func pack(_ b: RGBABuffer) -> Thumbnail {
        var out = [UInt8](repeating: 0, count: b.px.count * 4)
        func q(_ v: Float) -> UInt8 { v.isNaN ? 0 : UInt8(min(max(v, 0), 1) * 255 + 0.5) }
        for (i, p) in b.px.enumerated() {
            out[i * 4] = q(p.x); out[i * 4 + 1] = q(p.y); out[i * 4 + 2] = q(p.z); out[i * 4 + 3] = q(p.w)
        }
        return Thumbnail(width: b.rect.width, height: b.rect.height, rgba8: out)
    }

    /// A gray surface reduced by area averaging to at most `maxSide` (masks and channels).
    static func gray(_ s: Surface, _ bounds: PixelRect, maxSide: Int) -> Thumbnail {
        let w0 = max(bounds.width, 1), h0 = max(bounds.height, 1)
        let scale = min(Double(maxSide) / Double(max(w0, h0)), 1)
        let w = max(Int((Double(w0) * scale).rounded()), 1), h = max(Int((Double(h0) * scale).rounded()), 1)
        let cov = s.coverage(bounds)
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for ty in 0..<h {
            let y0 = ty * h0 / h, y1 = max((ty + 1) * h0 / h, y0 + 1)
            for tx in 0..<w {
                let x0 = tx * w0 / w, x1 = max((tx + 1) * w0 / w, x0 + 1)
                var acc: Float = 0
                for y in y0..<min(y1, h0) { for x in x0..<min(x1, w0) { acc += cov[y * w0 + x] } }
                let v = acc / Float((min(y1, h0) - y0) * (min(x1, w0) - x0))
                let b = UInt8(min(max(v, 0), 1) * 255 + 0.5)
                let o = (ty * w + tx) * 4
                out[o] = b; out[o + 1] = b; out[o + 2] = b
            }
        }
        return Thumbnail(width: w, height: h, rgba8: out)
    }
}
