// The large single-file receipts: AB-T-0240's (a `.pcraft` over 4 GiB saves, reopens equal and
// passes Info-ZIP's `unzip -t`) and AB-T-0249's (save and load hold a bounded amount of memory
// beyond the document, whatever its size). Opt-in, like `PCIO_BIG_PSB`: the default size writes a
// 4.5 GiB file to the temp directory (deleted afterwards) and holds two copies of a 4.5 GiB
// document (the one saved and the one loaded) in memory. Run it in release:
//
//     PCRAFT_ZIP64_BIG=1 swift test -c release --filter PCFormatTests.Zip64BigTests
//
// `PCRAFT_ZIP64_BIG_SIDE=<n>` saves n × n tiles of 512 KiB instead of 96 × 96 (32: 0.5 GiB,
// 160: 12.5 GiB); run each size in its own process, so one size's freed memory can't flatter the
// next. `PCRAFT_ZIP64_BIG_REPORT=<file>` appends the measurements to that file as one JSON line.
//
// The allocator keeps freed blocks of a tile's size resident for reuse, so a load measured after
// the save in the same process could hide its own allocations in what the save left. For the load
// figure, `PCRAFT_ZIP64_BIG_KEEP=<file>` keeps the saved file there, and
// `PCRAFT_ZIP64_BIG_LOAD=<file>` (without `PCRAFT_ZIP64_BIG`) loads it in a fresh process and
// reports the peak beyond the loaded document.

import Foundation
@testable import PCFormat
import PCDocument
import PCFoundation
import Synchronization
import Testing

/// The process's resident memory, sampled every half millisecond while a phase runs: its peak.
final class MemorySampler: Sendable {
    /// Resident set and physical footprint (what Activity Monitor calls Memory), in bytes.
    struct Sample: Sendable {
        var resident: UInt64
        var footprint: UInt64
    }

    static func now() -> Sample {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return r == 0 ? Sample(resident: info.ri_resident_size, footprint: info.ri_phys_footprint) : Sample(resident: 0, footprint: 0)
    }

    /// Returns memory the allocator holds for reuse to the system (what it will give back).
    static func releaseFreeMemory() { _ = malloc_zone_pressure_relief(nil, 0) }

    /// Bytes the allocator has handed out and not had back: live heap memory, whatever stays
    /// resident for reuse.
    static func heapInUse() -> UInt64 {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return UInt64(stats.size_in_use)
    }

    private let stop = Atomic<Bool>(false)
    private let peakResident = Atomic<UInt64>(0)
    private let peakFootprint = Atomic<UInt64>(0)

    /// `body`'s result and the peak while it ran.
    static func peak<T>(_ body: () throws -> T) rethrows -> (T, Sample) {
        let s = MemorySampler()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            while !s.stop.load(ordering: .relaxed) {
                s.record()
                usleep(500)
            }
            s.record()
            done.signal()
        }
        thread.qualityOfService = .userInteractive
        s.record()
        thread.start()
        defer {
            s.stop.store(true, ordering: .relaxed)
            done.wait()
        }
        let out = try body()
        s.record()
        return (out, Sample(resident: s.peakResident.load(ordering: .relaxed), footprint: s.peakFootprint.load(ordering: .relaxed)))
    }

    private func record() {
        let n = MemorySampler.now()
        _ = peakResident.max(n.resident, ordering: .relaxed)
        _ = peakFootprint.max(n.footprint, ordering: .relaxed)
    }
}

@Suite struct Zip64BigTests {
    static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "?" }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func gb(_ bytes: UInt64) -> String { String(format: "%.3f GB", Double(bytes) / 1e9) }
    static func mb(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / 1e6) }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PCRAFT_ZIP64_BIG"] != nil, "writes a 4.5 GiB file; set PCRAFT_ZIP64_BIG"))
    func singleFileOver4GiBRoundTrips() throws {
        // n × n tiles of RGBA 16-bit noise: incompressible 512 KiB tiles (96 × 96: 4.5 GiB stored).
        let env = ProcessInfo.processInfo.environment
        let tilesPerSide = env["PCRAFT_ZIP64_BIG_SIDE"].flatMap { Int($0) } ?? 96
        let format = PixelFormat(mode: .rgb, sample: .u16, alpha: true)
        let tileBytes = Int(tileSize) * Int(tileSize) * format.bytesPerPixel
        let tiles = Parallel.map(tilesPerSide * tilesPerSide) { i -> Tile in
            var r = Rng(UInt64(i) &* 0x9E37_79B9 &+ 1)
            var bytes = [UInt8](repeating: 0, count: tileBytes)
            bytes.withUnsafeMutableBytes { p in
                let words = p.bindMemory(to: UInt64.self)
                for k in words.indices { words[k] = r.next() }
            }
            return Tile(bytes: bytes)
        }
        var surface = Surface(format: format)
        surface.putTiles(tiles.enumerated().map { (TileCoord(tx: Int32($0.offset % tilesPerSide), ty: Int32($0.offset / tilesPerSide)), $0.element) })
        let side = tilesPerSide * Int(tileSize)
        var doc = Document(name: "ZIP64", size: PixelSize(width: side, height: side), mode: .rgb, depth: .u16)
        doc.layers = [Layer.raster("Noise", surface: surface)]

        // A crashed earlier run (a trap skips `defer`) may have left its file behind.
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        for name in (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [] where name.hasPrefix("pcformat-zip64-big-") {
            remove(temp.appendingPathComponent(name))
        }
        let dir = tempDir("zip64-big")
        let url = dir.appendingPathComponent("big.pcraft")
        defer {
            if let keep = env["PCRAFT_ZIP64_BIG_KEEP"] {
                remove(URL(fileURLWithPath: keep))
                try? FileManager.default.moveItem(at: url, to: URL(fileURLWithPath: keep))
            }
            remove(dir)
        }
        let clock = ContinuousClock()

        // Save: the peak beyond the memory held with the document loaded. Memory the allocator
        // keeps after a free is returned first (here and below), so a phase can't hide its own
        // allocations in what an earlier one left behind.
        MemorySampler.releaseFreeMemory()
        let beforeSave = MemorySampler.now()
        let heapBeforeSave = MemorySampler.heapInUse()
        var start = clock.now
        let (stats, savePeak) = try MemorySampler.peak { try PcraftWriter().save(doc, to: url, as: .singleFile) }
        let saved = clock.now - start
        // What the save still holds once it has returned (its writer is gone): nothing, beyond
        // what the allocator keeps for reuse.
        let heapAfterSave = MemorySampler.heapInUse()
        #expect(stats.tilesWritten == tilesPerSide * tilesPerSide)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        let zip64 = size > 1 << 32
        if tilesPerSide >= 96 { #expect(zip64, "\(size) bytes") }

        // The manifest first (its local header gives its length), saying format 2 exactly when
        // the file is ZIP64; ZIP64 end records last.
        let handle = try FileHandle(forReadingFrom: url)
        let header = [UInt8](try handle.read(upToCount: 30) ?? Data())
        func le(_ at: Int, _ n: Int) -> Int { (0 ..< n).reduce(0) { $0 | Int(header[at + $1]) << (8 * $1) } }
        let (manifestLength, skip) = (le(18, 4), le(26, 2) + le(28, 2))
        let manifest = String(decoding: [UInt8](try handle.read(upToCount: skip + manifestLength) ?? Data()).dropFirst(skip), as: UTF8.self)
        try handle.seek(toOffset: UInt64(size - 42))
        let tail = [UInt8](try handle.readToEnd() ?? Data())
        try handle.close()
        #expect(manifest.utf8.count == manifestLength)
        #expect(manifest.contains("\"format_version\": \(zip64 ? 2 : 1),"))
        #expect((Array(tail[0 ..< 4]) == [0x50, 0x4B, 0x06, 0x07]) == zip64, "ZIP64 locator")

        // Load: the peak beyond the memory held once both documents are in memory.
        MemorySampler.releaseFreeMemory()
        let beforeLoad = MemorySampler.now()
        start = clock.now
        let (back, loadPeak) = try MemorySampler.peak { try PcraftFormat.load(contentsOf: url) }
        let loaded = clock.now - start
        MemorySampler.releaseFreeMemory()
        let afterLoad = MemorySampler.now()
        #expect(back == doc)

        var unzipped: Duration?
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip") {
            start = clock.now
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-tqq", url.path]
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "unzip -t")
            unzipped = clock.now - start
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let saveOverhead = Int64(savePeak.resident) - Int64(beforeSave.resident)
        let loadOverhead = Int64(loadPeak.resident) - Int64(afterLoad.resident)
        let saveOverheadFootprint = Int64(savePeak.footprint) - Int64(beforeSave.footprint)
        let loadOverheadFootprint = Int64(loadPeak.footprint) - Int64(afterLoad.footprint)
        let machine = Self.machine
        let heapHeld = Int64(heapAfterSave) - Int64(heapBeforeSave)
        print("""
        ZIP64 receipt: \(size) bytes (\(String(format: "%.2f", Double(size) / Double(1 << 30))) GiB), \(tilesPerSide * tilesPerSide + 1) entries; \
        save \(saved), load \(loaded), unzip -t \(unzipped.map { "\($0)" } ?? "skipped"); \
        RSS: before save \(Self.gb(beforeSave.resident)), save peak \(Self.gb(savePeak.resident)) (overhead \(Self.mb(saveOverhead))); \
        before load \(Self.gb(beforeLoad.resident)), load peak \(Self.gb(loadPeak.resident)), after load \(Self.gb(afterLoad.resident)) \
        (overhead \(Self.mb(loadOverhead))); footprint overheads: save \(Self.mb(saveOverheadFootprint)), load \(Self.mb(loadOverheadFootprint)); \
        heap in use after the save, beyond before it: \(Self.mb(heapHeld)); \
        process max RSS \(Self.gb(UInt64(usage.ru_maxrss))); \(machine)
        """)
        if let report = env["PCRAFT_ZIP64_BIG_REPORT"] {
            try Self.report(report, [
                "tiles_per_side": tilesPerSide, "file_bytes": size, "entries": tilesPerSide * tilesPerSide + 1, "zip64": zip64,
                "save_s": Double(saved.components.seconds) + Double(saved.components.attoseconds) / 1e18,
                "load_s": Double(loaded.components.seconds) + Double(loaded.components.attoseconds) / 1e18,
                "rss_before_save": beforeSave.resident, "rss_save_peak": savePeak.resident, "save_overhead": saveOverhead,
                "rss_before_load": beforeLoad.resident, "rss_load_peak": loadPeak.resident, "rss_after_load": afterLoad.resident,
                "load_overhead": loadOverhead, "footprint_save_overhead": saveOverheadFootprint, "footprint_load_overhead": loadOverheadFootprint,
                "max_rss": usage.ru_maxrss, "machine": machine, "heap_held_after_save": heapHeld,
            ])
        }
    }

    /// Loads a kept file (`PCRAFT_ZIP64_BIG_LOAD`) in a process that has done nothing else: the
    /// peak beyond the memory the loaded document holds.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PCRAFT_ZIP64_BIG_LOAD"] != nil, "loads a kept file; set PCRAFT_ZIP64_BIG_LOAD"))
    func loadOverhead() throws {
        let env = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: env["PCRAFT_ZIP64_BIG_LOAD"]!)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        MemorySampler.releaseFreeMemory()
        let before = MemorySampler.now()
        let start = ContinuousClock.now
        let (doc, peak) = try MemorySampler.peak { try PcraftFormat.load(contentsOf: url) }
        let loaded = ContinuousClock.now - start
        MemorySampler.releaseFreeMemory()
        let after = MemorySampler.now()
        let tiles = doc.layers.first?.surface?.tileCount ?? 0
        #expect(tiles > 0)
        let overhead = Int64(peak.resident) - Int64(after.resident)
        print("""
        ZIP64 load receipt: \(size) bytes (\(String(format: "%.2f", Double(size) / Double(1 << 30))) GiB), \(tiles) tiles; load \(loaded); \
        RSS: before load \(Self.gb(before.resident)), load peak \(Self.gb(peak.resident)), after load \(Self.gb(after.resident)) \
        (overhead \(Self.mb(overhead)), document \(Self.mb(Int64(after.resident) - Int64(before.resident)))); \
        footprint overhead \(Self.mb(Int64(peak.footprint) - Int64(after.footprint))); \(Self.machine)
        """)
        if let report = env["PCRAFT_ZIP64_BIG_REPORT"] {
            try Self.report(report, [
                "phase": "load", "file_bytes": size, "tiles": tiles,
                "load_s": Double(loaded.components.seconds) + Double(loaded.components.attoseconds) / 1e18,
                "rss_before_load": before.resident, "rss_load_peak": peak.resident, "rss_after_load": after.resident, "load_overhead": overhead,
                "footprint_load_overhead": Int64(peak.footprint) - Int64(after.footprint), "machine": Self.machine,
            ])
        }
    }

    static var machine: String {
        "\(sysctl("hw.model")), \(sysctl("machdep.cpu.brand_string")), "
            + String(format: "%.0f GB RAM, macOS ", Double(ProcessInfo.processInfo.physicalMemory) / 1e9) + ProcessInfo.processInfo.operatingSystemVersionString
    }

    /// Appends `line` to the JSON-lines file at `path`.
    static func report(_ path: String, _ line: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        data.append(0x0A)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(data)
            h.closeFile()
        } else {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}
