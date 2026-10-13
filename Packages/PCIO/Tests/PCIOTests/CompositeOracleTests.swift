// The composite oracle over the Photoshop corpus: PSD import → PCRender composite (CPU and Metal)
// → diff against Photoshop's own merged image. Thresholds are PCRender's (mean ≤ 1 level, ≤ 2 % of
// pixels more than 2 levels off; premultiplied 8-bit levels). Measured, reported, not asserted
// per file. New (photocraft's oracle runs through crates/io/tests/corpus.rs and its external
// corpus); MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCIOCore
import PCRender
import Testing
@testable import PCIO

@Suite(.serialized) struct CompositeOracleTests {
    init() { ExportSweep.install() }
    struct Row {
        var name: String
        var cpu: OracleComparison
        var metal: OracleComparison?
    }

    static func pass(_ o: OracleComparison) -> Bool { o.meanLevels <= 1 && o.fractionOff <= 0.02 }

    /// Composites every file of a corpus on the CPU and on Metal against Photoshop's merged image,
    /// printing `ORACLE` and `MEASURE` lines; returns the rows, skipped and failed files.
    static func run(_ label: String, _ files: [URL]) -> (rows: [Row], skipped: [String], failed: [String]) {
        let rasterizer = PlaceholderRasterizer()
        let compositor = PCRender.DocumentCompositor(rasterizer: rasterizer)
        var rows: [Row] = []
        var skipped: [String] = [], failed: [String] = []
        for url in files {
            do {
                guard let c = try PSDCompositeOracle.oracleCase(contentsOf: url) else {
                    skipped.append(url.lastPathComponent)
                    continue
                }
                let cpu = try PSDCompositeOracle.compare(c, compositor: compositor, backend: .cpu)
                let metal = compositor.metal == nil ? nil : try PSDCompositeOracle.compare(c, compositor: compositor, backend: .metal)
                rows.append(Row(name: c.name, cpu: cpu, metal: metal))
            } catch {
                failed.append("\(url.lastPathComponent): \(error)")
            }
        }
        for r in rows {
            let m = r.metal.map { String(format: " | metal max %.1f mean %.3f off %.2f%%", $0.maxLevels, $0.meanLevels, $0.fractionOff * 100) } ?? ""
            print(String(format: "ORACLE %@ %@: cpu max %.1f mean %.3f off %.2f%% misses %d%@ %@", label, r.name, r.cpu.maxLevels, r.cpu.meanLevels,
                         r.cpu.fractionOff * 100, r.cpu.misses.count, m, pass(r.cpu) ? "PASS" : "FAIL"))
        }
        for f in failed { print("ORACLE \(label) error \(f)") }
        let cpuPass = rows.filter { pass($0.cpu) }.count
        let metalPass = rows.filter { $0.metal.map(pass) ?? false }.count
        let misses = rows.reduce(0) { $0 + $1.cpu.misses.count }
        let meanOfMeans = rows.isEmpty ? 0 : rows.reduce(0) { $0 + Double($1.cpu.meanLevels) } / Double(rows.count)
        let gpuGap = rows.compactMap { r in r.metal.map { abs($0.meanLevels - r.cpu.meanLevels) } }.max() ?? 0
        print("MEASURE \(label) oracle: \(rows.count) files compared, \(skipped.count) skipped (no usable merged image), \(failed.count) failed; pass (mean ≤ 1, ≤ 2% off): CPU \(cpuPass)/\(rows.count), Metal \(metalPass)/\(rows.count); mean of means \(String(format: "%.3f", meanOfMeans)) levels; rasterizer misses \(misses); max |metal−cpu| mean gap \(String(format: "%.3f", gpuGap))")
        return (rows, skipped, failed)
    }

    @Test(.enabled(if: Corpus.available, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)")) func corpusCompositeOracle() throws {
        let (rows, skipped, failed) = CompositeOracleTests.run("psd-corpus", Corpus.files)
        #expect(rows.count + skipped.count == Corpus.files.count)
        #expect(failed.isEmpty)
        #expect(!rows.isEmpty)
        // Metal and the CPU reference agree (PCRender's own parity bound).
        #expect((rows.compactMap { r in r.metal.map { abs($0.meanLevels - r.cpu.meanLevels) } }.max() ?? 0) < 0.5)
    }

    /// The Photoshop-generated corpus: measured and reported, not asserted per file.
    @Test(.enabled(if: Corpus.psAvailable, "Photoshop corpus not present (set PHOTOCRAFT_FIXTURES or PCIO_PS_CORPUS)")) func photoshopCorpusCompositeOracle() throws {
        _ = CompositeOracleTests.run("ps-corpus", Corpus.psFiles)
    }
}
