// The receipt for AB-T-0259 (opt-in): how long File › Save takes on PCRender's realistic20, the
// way PixelAgencyEditor's `DocumentFileTests.openAndSaveAt4096` measures it — a PSD opened through
// the engine, saved as a `.pcraft` package, saved again unchanged, and the package reopened, a
// stroke's worth of tiles changed and saved.
//
//     PCRAFT_SAVE_BENCH=1 [PCRAFT_SAVE_BENCH_SIDE=4096] [PCRAFT_SAVE_BENCH_REPORT=<file>] \
//         swift test -c release --filter PCEngineTests.SaveTimingTests

import Foundation
@testable import PCEngine
import PCDocument
import PCFormat
import PCFoundation
@testable import PCIO
import PCIOCore
import PCRender
import Testing

@Suite struct SaveTimingTests {
    static let enabled = ProcessInfo.processInfo.environment["PCRAFT_SAVE_BENCH"] == "1"
    static let side = Int(ProcessInfo.processInfo.environment["PCRAFT_SAVE_BENCH_SIDE"] ?? "") ?? 4096

    @Test(.enabled(if: SaveTimingTests.enabled))
    func packageSaves() throws {
        let dir = try ioDir("save-bench")
        defer { try? FileManager.default.removeItem(at: dir) }
        var report = "realistic20 at \(Self.side)²\n"
        func time<T>(_ what: String, _ body: () throws -> T) rethrows -> T {
            let start = ContinuousClock.now
            let r = try body()
            let d = ContinuousClock.now - start
            let ms = Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15
            report += "\(what): \(String(format: "%.1f", ms)) ms\n"
            return r
        }
        func tiles(_ o: SaveOutcome) -> String { "  tiles written \(o.stats?.tilesWritten ?? -1), reused \(o.stats?.tilesReused ?? -1)\n" }
        let psd = dir.appendingPathComponent("realistic20.psd")
        try Data(try EngineIO.export(BenchmarkDocuments.realistic20(size: Self.side), as: "psd", services: EngineServices()).bytes).write(to: psd)

        let s = Session()
        try time("open PSD") { _ = try s.openFile(psd.path) }
        let doc = try #require(s.active?.doc)
        let previews = try time("the previews alone (256 and 1024 px)") { try DocumentIO.pcraftPreviews(doc, options: EngineIO.options(s.services)) }
        _ = try time("the previews again (warm)") { try DocumentIO.pcraftPreviews(doc, options: EngineIO.options(s.services)) }
        // Today's previews (before AB-T-0259): a full-resolution composite for each.
        func before(_ side: Int) throws -> RGBA8Image {
            let (px, w, h) = try PSDThumbnail.thumbnailRGBA(doc, compositor: s.services.renderer, side: side)
            return DocumentIO.rgba8(px, w, h)
        }
        let old = try time("the previews as 0.3.0 rendered them (two full composites)") { (try before(256), try before(1024)) }
        report += "  thumbnail vs 0.3.0: \(Self.difference(try #require(previews.thumbnail), old.0))\n"
        report += "  composite vs 0.3.0: \(Self.difference(try #require(previews.composite), old.1))\n"
        let package = dir.appendingPathComponent("realistic20.pcraft").path
        report += tiles(try time("first package save") { try s.saveDocument(to: package) })
        for k in 1...3 { report += tiles(try time("unchanged package save #\(k)") { try s.saveDocument() }) }
        try stroke(s)
        report += tiles(try time("package save after a stroke (same session)") { try s.saveDocument() })

        let s2 = Session()
        try time("open the package") { _ = try s2.openFile(package) }
        try stroke(s2, y: 2000, color: "#00ff00")
        report += tiles(try time("package save after a stroke (reopened)") { try s2.saveDocument() })
        report += tiles(try time("unchanged package save (reopened)") { try s2.saveDocument() })

        // Reopened again, and composited once whole first, as the editor's canvas does through the
        // same renderer when it shows the document.
        let s3 = Session()
        try time("open the package again") { _ = try s3.openFile(package) }
        let shown = try #require(s3.active?.doc)
        _ = try time("the canvas's first composite of it (whole, full resolution)") { try s3.services.renderer.render(shown, region: shown.bounds) }
        try stroke(s3, y: 3000, color: "#ff00ff")
        report += tiles(try time("package save after a stroke (reopened, shown)") { try s3.saveDocument() })

        print(report)
        if let out = ProcessInfo.processInfo.environment["PCRAFT_SAVE_BENCH_REPORT"] {
            try report.write(toFile: out, atomically: true, encoding: .utf8)
        }
    }

    /// A 400 × 40 fill on the full-canvas "particles" layer: three tiles, as the editor's brush
    /// stroke from (1000, 1000) to (1400, 1000).
    func stroke(_ s: Session, y: Int = 980, color: String = "#0000ff") throws {
        let doc = try #require(s.active?.doc)
        var target: LayerId?
        doc.forEachLayer { _, _, l in if l.name == "particles" { target = l.id } }
        try s.execute("layer.select", ["layer": .id(try #require(target))])
        try s.execute("select.rect", ["x": 1000, "y": .int(y), "width": 400, "height": 40])
        try s.execute("edit.fill", ["color": .string(color)])
        try s.execute("select.deselect")
    }

    /// How two previews differ: the largest and mean absolute difference of any channel, in levels.
    static func difference(_ a: RGBA8Image, _ b: RGBA8Image) -> String {
        guard a.width == b.width, a.height == b.height else { return "sizes differ: \(a.width)×\(a.height) vs \(b.width)×\(b.height)" }
        var worst = 0, sum = 0
        for (x, y) in zip(a.data, b.data) {
            let d = abs(Int(x) - Int(y))
            worst = max(worst, d)
            sum += d
        }
        return "\(a.width)×\(a.height), max \(worst) levels, mean \(String(format: "%.4f", Double(sum) / Double(max(a.data.count, 1))))"
    }
}
