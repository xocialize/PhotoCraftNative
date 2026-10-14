// Filter adjustment layers in `.pcraft` (AB-T-0258): the four kinds round-trip in both containers,
// and a document holding one is written as format 3, which a format 2 reader refuses as too new.

import Foundation
@testable import PCFormat
import PCDocument
import PCFoundation
import PCIOCore
import Testing

@Suite struct FilterAdjustmentFormatTests {
    /// `richDoc` plus the four filter adjustment layers: at the root (masked, at an opacity, in a
    /// blend mode), inside a group, clipped, and hidden.
    static func doc() -> Document {
        var d = richDoc(.rgb, .u8)
        var grain = Layer(name: "Grain", content: .adjustment(.filter(.grain(.init(amount: 40, size: 3.5, roughness: 20, seed: 0xfeed_beef)))))
        grain.opacity = 0.75
        grain.blend = .overlay
        var mask = Surface(format: PixelFormat(mode: .grayscale, sample: .u8, alpha: false))
        mask.fill(PixelRect(x0: 2, y0: 2, x1: 9, y1: 7), with: [0.5])
        grain.mask = LayerMask(surface: mask, enabled: true, linked: true, density: 1, feather: 1.5)
        d.layers.append(grain)
        var noise = Layer(name: "Noise", content: .adjustment(.filter(.addNoise(.init(amount: 250, gaussian: true, monochromatic: true, seed: 12)))))
        noise.clipped = true
        d.layers.append(noise)
        d.layers.append(Layer.group("Blurs", [Layer(name: "Gaussian", content: .adjustment(.filter(.gaussianBlur(.init(radius: 7.25)))))]))
        var motion = Layer(name: "Motion", content: .adjustment(.filter(.motionBlur(.init(angle: -45, distance: 120)))))
        motion.visible = false
        d.layers.append(motion)
        return d
    }

    @Test func roundTripsInBothContainersAsFormat3() throws {
        let d = Self.doc()
        let bytes = try save(d)
        #expect(try load(bytes) == d)
        #expect(try Format2Tests.manifestText(bytes).contains("\"format_version\": 3,"))
        #expect(try Format2Tests.manifestText(bytes).contains("\"GaussianBlur\""))
        // A package, and a single file streamed to disk, read back the same.
        let dir = tempDir("filters")
        defer { remove(dir) }
        for (name, container) in [("p.pcraft", PcraftFormat.Container.package), ("s.pcraft", .singleFile)] {
            let url = dir.appendingPathComponent(name)
            _ = try PcraftWriter().save(d, to: url, as: container)
            #expect(try PcraftFormat.load(contentsOf: url) == d, "\(container)")
        }
        // ZIP64 too: still format 3 (which allows it).
        let w = PcraftWriter()
        w.forceZip64 = true
        let (big, _) = try w.saveZip(d)
        #expect(try ZipReader(big).isZip64)
        #expect(try Format2Tests.manifestText(big).contains("\"format_version\": 3,"))
        #expect(try load(big) == d)
    }

    /// Without a filter adjustment layer a save stays photocraft's format 1; with one, a reader of
    /// format 2 (PhotoCraftNative 0.3) refuses the file as too new rather than failing on the kind.
    @Test func onlyFilterDocumentsAreFormat3() throws {
        #expect(try Format2Tests.manifestText(try save(richDoc(.rgb, .u8))).contains("\"format_version\": 1,"))
        #expect(Convert.holdsFilterAdjustment(Self.doc().layers))
        #expect(!Convert.holdsFilterAdjustment(richDoc(.rgb, .u8).layers))
        var tree = try JSONTree.parse(try ZipReader(try save(Self.doc())).read(named: "manifest.json", max: .max))
        #expect { try Migrate.migrateWith(&tree, Array(Migrate.steps.prefix(1)), target: 2) } throws: { e in
            if case FormatError.tooNew(found: 3, supported: 2) = e { return true }
            return false
        }
    }
}
