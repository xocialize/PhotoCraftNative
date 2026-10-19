// An opt-in probe of what a single-file save holds per tile (AB-T-0328): the heap in use, sampled while the save runs,
// beyond what it was before, for documents of many small, distinct, well-compressing tiles, so the per-tile tables
// (hashes, paths, the manifest, the central directory) are what grows. Heap in use counts live blocks only, so sizes
// can share a process. `PCRAFT_SAVE_PROBE=<sides>` (comma-separated, default 32,160: 1,024 and 25,600 tiles) runs it;
// `PCRAFT_SAVE_PROBE_REPORT=<file>` appends one JSON line per size. Run it in release.

import Foundation
@testable import PCFormat
import PCDocument
import PCFoundation
import Synchronization
import Testing

/// The heap in use, sampled every half millisecond while `body` runs: its peak.
func heapPeak<T>(_ body: () throws -> T) rethrows -> (T, UInt64) {
    let stop = Atomic<Bool>(false), peak = Atomic<UInt64>(0)
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        while !stop.load(ordering: .relaxed) {
            _ = peak.max(MemorySampler.heapInUse(), ordering: .relaxed)
            usleep(500)
        }
        done.signal()
    }
    thread.qualityOfService = .userInteractive
    _ = peak.max(MemorySampler.heapInUse(), ordering: .relaxed)
    thread.start()
    defer {
        stop.store(true, ordering: .relaxed)
        done.wait()
    }
    let out = try body()
    _ = peak.max(MemorySampler.heapInUse(), ordering: .relaxed)
    return (out, peak.load(ordering: .relaxed))
}

@Suite(.serialized) struct SaveHeapProbeTests {
    static let sides = ProcessInfo.processInfo.environment["PCRAFT_SAVE_PROBE"]

    /// side × side distinct 8-bit grey tiles: an index in the first bytes, a gentle ramp after it.
    static func document(_ side: Int) -> Document {
        let format = PixelFormat(mode: .grayscale, sample: .u8, alpha: false)
        let n = Int(tileSize) * Int(tileSize)
        let tiles = Parallel.map(side * side) { i -> Tile in
            var bytes = (0 ..< n).map { UInt8(truncatingIfNeeded: $0 >> 9) }
            for k in 0 ..< 8 { bytes[k] = UInt8(truncatingIfNeeded: (i &* 2_654_435_761) >> (8 * k)) }
            return Tile(bytes: bytes)
        }
        var surface = Surface(format: format)
        surface.putTiles(tiles.enumerated().map { (TileCoord(tx: Int32($0.offset % side), ty: Int32($0.offset / side)), $0.element) })
        var doc = Document(name: "Probe", size: PixelSize(width: side * Int(tileSize), height: side * Int(tileSize)), mode: .grayscale, depth: .u8)
        doc.layers = [Layer.raster("Tiles", surface: surface)]
        return doc
    }

    /// Zip64BigTests' document: side × side tiles of RGBA 16-bit noise, 512 KiB each.
    static func noiseDocument(_ side: Int) -> Document {
        let format = PixelFormat(mode: .rgb, sample: .u16, alpha: true)
        let tileBytes = Int(tileSize) * Int(tileSize) * format.bytesPerPixel
        let tiles = Parallel.map(side * side) { i -> Tile in
            var r = Rng(UInt64(i) &* 0x9E37_79B9 &+ 1)
            var bytes = [UInt8](repeating: 0, count: tileBytes)
            bytes.withUnsafeMutableBytes { p in
                let words = p.bindMemory(to: UInt64.self)
                for k in words.indices { words[k] = r.next() }
            }
            return Tile(bytes: bytes)
        }
        var surface = Surface(format: format)
        surface.putTiles(tiles.enumerated().map { (TileCoord(tx: Int32($0.offset % side), ty: Int32($0.offset / side)), $0.element) })
        var doc = Document(name: "ZIP64", size: PixelSize(width: side * Int(tileSize), height: side * Int(tileSize)), mode: .rgb, depth: .u16)
        doc.layers = [Layer.raster("Noise", surface: surface)]
        return doc
    }

    /// `PCRAFT_SAVE_PROBE_NOISE=<side>`: one save of Zip64BigTests' document as `Zip64BigTests` makes it (a fresh
    /// writer, the default cache), with the heap's peak and the RSS's peak beside each other, so what the allocator
    /// keeps resident shows apart from what is live. One size per process, as there.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PCRAFT_SAVE_PROBE_NOISE"] != nil, "set PCRAFT_SAVE_PROBE_NOISE"))
    func noiseHeapAndResident() throws {
        let side = Int(ProcessInfo.processInfo.environment["PCRAFT_SAVE_PROBE_NOISE"]!) ?? 32
        let doc = Self.noiseDocument(side)
        let dir = tempDir("save-probe-noise")
        defer { remove(dir) }
        let url = dir.appendingPathComponent("probe.pcraft")
        MemorySampler.releaseFreeMemory()
        let rss = MemorySampler.now().resident, heap = MemorySampler.heapInUse()
        var line: [String: Any] = ["noise_side": side, "tiles": side * side]
        if ProcessInfo.processInfo.environment["PCRAFT_SAVE_PROBE_PHASES"] == nil {
            let ((_, rssPeak), heapPeak) = try heapPeak { try MemorySampler.peak { try PcraftWriter().save(doc, to: url, as: .singleFile) } }
            line["heap_peak"] = Int64(heapPeak) - Int64(heap)
            line["rss_peak"] = Int64(rssPeak.resident) - Int64(rss)
            print("save noise probe: \(side * side) tiles; heap peak \(Self.mb(line["heap_peak"] as! Int64)), RSS peak \(Self.mb(line["rss_peak"] as! Int64))")
        } else {
            // The same save in its two phases, each phase's peaks beyond the start, and the RSS between them.
            let w = PcraftWriter()
            var p: Prepared?
            let ((_, prepRSS), prepHeap) = try heapPeak { try MemorySampler.peak { p = try w.prepare(doc, SaveOptions()) } }
            let between = MemorySampler.now().resident, heapBetween = MemorySampler.heapInUse()
            let ((_, streamRSS), streamHeap) = try heapPeak {
                try MemorySampler.peak {
                    try AtomicSave.atomicWriteStreaming(url) { fd throws(FormatError) in _ = try w.writeZip(p.take()!, into: FileZipSink(fd: fd, path: url.path)) }
                }
            }
            for (k, v) in [("prepare_heap_peak", Int64(prepHeap) - Int64(heap)), ("prepare_rss_peak", Int64(prepRSS.resident) - Int64(rss)),
                           ("between_heap", Int64(heapBetween) - Int64(heap)), ("between_rss", Int64(between) - Int64(rss)),
                           ("stream_heap_peak", Int64(streamHeap) - Int64(heap)), ("stream_rss_peak", Int64(streamRSS.resident) - Int64(rss))] {
                line[k] = v
            }
            print("save noise probe phases: \(side * side) tiles; prepare heap \(Self.mb(line["prepare_heap_peak"] as! Int64)) RSS \(Self.mb(line["prepare_rss_peak"] as! Int64)); "
                + "between heap \(Self.mb(line["between_heap"] as! Int64)) RSS \(Self.mb(line["between_rss"] as! Int64)); "
                + "stream heap \(Self.mb(line["stream_heap_peak"] as! Int64)) RSS \(Self.mb(line["stream_rss_peak"] as! Int64))")
        }
        if let report = ProcessInfo.processInfo.environment["PCRAFT_SAVE_PROBE_REPORT"] { try Zip64BigTests.report(report, line) }
    }

    static func mb(_ bytes: Int64) -> String { String(format: "%.2f MB", Double(bytes) / 1e6) }

    @Test(.enabled(if: sides != nil, "set PCRAFT_SAVE_PROBE")) func heapPerTile() throws {
        let sides = (Self.sides ?? "").split(separator: ",").compactMap { Int($0) }
        for side in sides.isEmpty ? [32, 160] : sides {
            let doc = Self.document(side)
            let dir = tempDir("save-probe")
            defer { remove(dir) }
            let url = dir.appendingPathComponent("probe.pcraft")
            var line: [String: Any] = ["tiles": side * side]
            // A fresh writer without a cache, then the default one (its cache holds every well-compressing tile here).
            for (label, budget) in [("nocache", 0), ("cache", defaultZipCacheBudget)] {
                let before = MemorySampler.heapInUse()
                let (_, peak) = try heapPeak { () throws -> SaveStats in
                    let w = PcraftWriter()
                    w.setZipCacheBudget(budget)
                    return try w.save(doc, to: url, as: .singleFile)
                }
                line["\(label)_save_peak"] = Int64(peak) - Int64(before)
            }
            // The two phases apart, without a cache: `prepare`'s peak, what it hands the archive writer, and the
            // archive's streaming (what the save holds while it writes, the writer's hash cache included).
            let w = PcraftWriter()
            w.setZipCacheBudget(0)
            let before = MemorySampler.heapInUse()
            var p: Prepared?
            let preparePeak = try heapPeak { p = try w.prepare(doc, SaveOptions()) }.1
            line["prepare_peak"] = Int64(preparePeak) - Int64(before)
            line["prepared"] = Int64(MemorySampler.heapInUse()) - Int64(before)
            let manifestBytes = p?.manifest.count ?? 0
            line["manifest_bytes"] = manifestBytes
            // Handed over, as `save` does.
            let (_, streamPeak) = try heapPeak {
                try AtomicSave.atomicWriteStreaming(url) { fd throws(FormatError) in _ = try w.writeZip(p.take()!, into: FileZipSink(fd: fd, path: url.path)) }
            }
            line["stream_peak"] = Int64(streamPeak) - Int64(before)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            line["file_bytes"] = size
            print("save heap probe: \(side * side) tiles, file \(size) bytes; heap peak beyond before: no cache \(Self.mb(line["nocache_save_peak"] as! Int64)), "
                + "64 MiB cache \(Self.mb(line["cache_save_peak"] as! Int64)); prepare peak \(Self.mb(line["prepare_peak"] as! Int64)), "
                + "prepared held \(Self.mb(line["prepared"] as! Int64)), stream peak \(Self.mb(line["stream_peak"] as! Int64)), manifest \(manifestBytes) bytes")
            if let report = ProcessInfo.processInfo.environment["PCRAFT_SAVE_PROBE_REPORT"] { try Zip64BigTests.report(report, line) }
        }
    }
}
