// Photoshop 27.11's own Light-mode Brightness/Contrast layers (ps-oracle batch M3, RESULTS.md §5d):
// every job's PSD reads back as the descriptor Photoshop stored (`brightnessExposure` as a double,
// `center` / Cntr and the four tone keys as integers, `brightnessMode` Light), and survives
// document → PSD → document. The batch is `PCIO_M3_DIR`, default `<fixtures>/ps-measure/M3`
// (`Fixtures`); skipped without it.
// New in the port (PCRender phase 5); no photocraft counterpart.

import Foundation
import PCDocument
import Testing
@testable import PCIO

/// The batch: `PCIO_M3_DIR`, default `<fixtures>/ps-measure/M3` (a separate type: the suite's
/// trait cannot refer to the suite itself).
enum M3Batch {
    static var directory: URL? { Fixtures.directory("PCIO_M3_DIR", default: "ps-measure/M3") }
}

@Suite(.enabled(if: M3Batch.directory != nil, "Photoshop batch M3 not present (set PHOTOCRAFT_FIXTURES or PCIO_M3_DIR)"))
struct PhotoshopLightModeTests {
    static func brightnessContrast(_ d: Document) -> Adjustment.BrightnessContrast? {
        for e in d.walk() { if case .adjustment(.brightnessContrast(let b)) = e.layer.content { return b } }
        return nil
    }

    @Test func m3LightLayersReadAsStored() throws {
        let root = try #require(M3Batch.directory)
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any])
        let jobs = try #require(manifest["jobs"] as? [[String: Any]])
        var checked = 0
        for job in jobs {
            guard let id = job["id"] as? String, id.hasPrefix("light-"), let result = job["result"] as? [String: Any],
                  let stored = result["stored"] as? [String: Any], let psd = result["psd"] as? String else { continue }
            func num(_ k: String) -> Float { Float((stored[k] as? NSNumber)?.doubleValue ?? 0) }
            let bytes = [UInt8](try Data(contentsOf: root.appendingPathComponent(psd)))
            let doc = try MapsKit.importFile(bytes, "x.psd", options: MapsKit.options(photoshop: true)).document
            let b = try #require(Self.brightnessContrast(doc), "\(id): no Brightness/Contrast layer")
            let want = Adjustment.BrightnessContrast(contrast: num("center"), mode: .light, exposure: num("brightnessExposure"),
                                                     whites: num("brightnessWhites"), blacks: num("brightnessBlacks"),
                                                     highlights: num("brightnessHighlights"), shadows: num("brightnessShadows"))
            #expect(stored["brightnessMode"] as? String == "brightnessModeLight", "\(id)")
            #expect(b.mode == .light && b.contrast == want.contrast && b.exposure == want.exposure && b.whites == want.whites
                    && b.blacks == want.blacks && b.highlights == want.highlights && b.shadows == want.shadows, "\(id): \(b)")
            let r = try MapsKit.export(doc, "x.psd", options: MapsKit.options(photoshop: true))
            let back = try MapsKit.importFile(r.bytes, "x.psd", options: MapsKit.options(photoshop: true)).document
            #expect(Self.brightnessContrast(back) == b, "\(id): round trip")
            checked += 1
        }
        #expect(checked >= 29)
    }
}
