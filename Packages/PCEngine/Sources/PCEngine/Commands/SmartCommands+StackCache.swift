// Port of photocraft-engine (crates/engine/src/smart_cmds/stack_cache.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Stages of smart object renders: the placed source and the result after each visible smart
// filter, keyed by everything that produced them. A re-render starts from the deepest cached
// stage, so editing filter `i` only reruns the filters from `i` up: hiding or tweaking the top
// filter of a long stack doesn't rerun the expensive filters under it. photocraft keys by blake3;
// here SHA-256 (CryptoKit).

import CryptoKit
import Foundation
import PCDocument
import PCFoundation
import Synchronization

extension SmartCommands {
    enum StackCache {
        /// A digest of a stage's inputs: the source contents, the placement and the filters so far.
        typealias Key = [UInt8]

        struct Stage: Sendable {
            var surface: Surface
            /// Where filters repeat edge pixels: the canvas ∪ the placed content.
            var extent: PixelRect
        }

        struct Entry: Sendable {
            var key: Key
            var stage: Stage
            var bytes: Int
        }

        /// Most recently used last.
        static let stages = Mutex<[Entry]>([])
        static let entries = 64
        /// Accounted tile bytes; a stage larger than this on its own isn't kept.
        static let budget = 768 << 20

        static func update(_ h: inout SHA256, _ s: String) { h.update(data: Array(s.utf8)) }

        static func update(_ h: inout SHA256, _ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { h.update(bufferPointer: $0) } }

        /// The first stage: what placing the contents with `digest` through the smart object's
        /// transform, warp or perspective gives at pixel format `fmt` on `canvas`.
        static func placedKey(_ digest: [UInt8], _ fmt: PixelFormat, _ sm: SmartObject, _ canvas: PixelRect) -> Key {
            var h = SHA256()
            h.update(data: digest)
            for v in sm.transform.m { update(&h, v.bitPattern) }
            let warp = sm.warp.map { JSONValue.encoded($0).serialized() } ?? "none"
            let persp = sm.perspective.map { $0.map { String($0.bitPattern) }.joined(separator: ",") } ?? "none"
            update(&h, "\(fmt)|\(warp)|\(persp)|\(sm.stackMode?.id ?? "none")|\(canvas.x0),\(canvas.y0),\(canvas.x1),\(canvas.y1)")
            return Array(h.finalize())
        }

        /// The stage after applying `f` to stage `below`.
        static func filterKey(_ below: Key, _ f: SmartFilter) -> Key {
            var h = SHA256()
            h.update(data: below)
            update(&h, "\(f.command)\0\(f.params.serialized())\0\(f.blend)\0")
            update(&h, UInt64(f.opacity.bitPattern))
            return Array(h.finalize())
        }

        static func get(_ key: Key) -> Stage? {
            stages.withLock { c in
                guard let i = c.firstIndex(where: { $0.key == key }) else { return nil }
                let e = c.remove(at: i)
                c.append(e)
                return e.stage
            }
        }

        static func put(_ key: Key, _ stage: Stage) {
            _ = pressure
            let n = surfaceBytes(stage.surface)
            if n > budget { return }
            stages.withLock { c in
                c.removeAll { $0.key == key }
                c.append(Entry(key: key, stage: stage, bytes: n))
                while c.count > entries || c.reduce(0, { $0 + $1.bytes }) > budget { c.removeFirst() }
            }
        }

        /// Bytes held by cached stages.
        static func bytes() -> Int { stages.withLock { $0.reduce(0) { $0 + $1.bytes } } }

        /// Registered with `MemoryPressureRelay.shared` once a stage is first cached.
        static let pressure = MemoryPressureRelay.shared.register("smart-object stages") { trim($0) }

        /// Trims for memory pressure, least recently used first: to half the bytes on a warning,
        /// everything when critical. Returns the bytes released.
        @discardableResult
        static func trim(_ level: MemoryPressureRelay.Level) -> Int {
            stages.withLock { c in
                let held = c.reduce(0) { $0 + $1.bytes }
                let target = level == .critical ? 0 : held / 2
                var total = held
                while total > target, !c.isEmpty { total -= c.removeFirst().bytes }
                return held - total
            }
        }

        /// Drops every cached stage (Edit › Purge › All). Returns the bytes released.
        @discardableResult
        static func purge() -> Int {
            stages.withLock { c in
                let freed = c.reduce(0) { $0 + $1.bytes }
                c.removeAll()
                return freed
            }
        }

        /// Tiles shared with the document (or another stage) are charged anyway: the cache is what
        /// keeps them alive once the document moves on.
        static func surfaceBytes(_ s: Surface) -> Int {
            let tile = Int(tileSize) * Int(tileSize) * s.format.bytesPerPixel
            let (n, o) = s.tileCount.multipliedReportingOverflow(by: tile)
            return o ? Int.max : n &+ s.format.bytesPerPixel
        }
    }

    /// Bytes held by rendered smart filter stages (photocraft `stack_cache_bytes`).
    static func stackCacheBytes() -> Int { StackCache.bytes() }

    /// Drops every rendered smart filter stage (Edit › Purge › All); returns the bytes released
    /// (photocraft `purge_stack_cache`).
    @discardableResult
    static func purgeStackCache() -> Int { StackCache.purge() }
}
