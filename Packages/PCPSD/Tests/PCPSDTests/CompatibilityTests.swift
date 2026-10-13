// Photoshop-acceptance checks and colour-managed images.

import CoreGraphics
import Foundation
import Testing
@testable import PCPSD

@Suite struct CompatibilityTests {
    @Test func builderOutputHasNoIssues() throws {
        for (mode, depth) in [(PSDColorMode.rgb, UInt16(8)), (.rgb, 16), (.rgb, 32), (.grayscale, 8), (.grayscale, 32), (.cmyk, 8), (.lab, 16)] {
            for version in PSDVersion.allCases {
                let f = try ImageIOOracleTests.document(mode: mode, depth: depth, version: version, compression: .rle, alpha: .opaque).build()
                let issues = f.compatibilityIssues(decodeChannels: true)
                #expect(issues.isEmpty, "\(mode) \(depth) \(version): \(issues)")
            }
        }
    }

    @Test func detectsWhatPhotoshopRejects() throws {
        var f = try PSDBuilder(width: 4, height: 4, depth: 32).build()
        f.colorModeData = Data()
        #expect(f.compatibilityIssues().contains { $0.severity == .error && $0.message.contains("HDR toning") })
        var g = TestGen.small(.psd, .raw)
        g.layers.removeFirst()   // drops nothing structural; now remove the divider's folder
        g.layers.removeLast()
        #expect(g.compatibilityIssues().contains { $0.message.contains("bounding divider") })
        var h = TestGen.small(.psd, .raw)
        h.layers[0].mask = .none
        #expect(h.compatibilityIssues().contains { $0.message.contains("mask channel without a mask record") })
        var z = TestGen.small(.psd, .zip)
        z.header.depth = 32
        #expect(z.compatibilityIssues().contains { $0.message.contains("ZIP") })
        var bad = TestGen.small(.psd, .rle)
        bad.layers[0].channels[1].data = Data(repeating: 0x7F, count: 8)
        #expect(bad.compatibilityIssues(decodeChannels: true).contains { $0.message.contains("does not decode") })
    }

    @Test(.enabled(if: Corpus.directory != nil, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)")) func corpusHasNoErrors() throws {
        var warnings = 0
        for url in Corpus.files {
            let issues = try PSDFile(contentsOf: url).compatibilityIssues(decodeChannels: true)
            #expect(!issues.contains { $0.severity == .error }, "\(url.lastPathComponent): \(issues)")
            warnings += issues.count
        }
        print("COMPAT corpus: 0 errors, \(warnings) warnings")
    }

    @Test func colorManagedCompositeMatchesPlainRGB() throws {
        var b = PSDBuilder(width: 5, height: 3)
        b.setComposite(Pixels.pattern(5, 3, spp: 4, depth: 8, seed: 4, alpha: .opaque))
        let f = try PSDFile(data: try b.serialized())
        let plain = try f.compositeRGBA8()
        let managed = PSDColorManagement.srgbRGBA8(try f.normalizedComposite(), icc: nil)!
        #expect(zip(plain.data, managed).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
        #expect(try f.compositeCGImage()?.width == 5)
    }

    @Test func labFormulaAgreesWithCoreGraphics() throws {
        var b = PSDBuilder(width: 4, height: 1, colorMode: .lab)
        b.setComposite(.u8([255, 128, 128, 255, 128, 200, 60, 255, 60, 90, 180, 255, 10, 128, 128, 255]))
        let f = try PSDFile(data: try b.serialized())
        let ours = try f.compositeRGBA8().data
        let cg = PSDColorManagement.srgbRGBA8(try f.normalizedComposite(), icc: nil)!
        let worst = zip(ours, cg).map { abs(Int($0) - Int($1)) }.max()!
        print("LAB formula vs CoreGraphics: max difference \(worst)")
        #expect(worst <= 6)
    }

    @Test func cmykThroughGenericProfile() throws {
        var b = PSDBuilder(width: 2, height: 1, colorMode: .cmyk)
        b.setComposite(.u8([0, 0, 0, 0, 255, 0, 0, 0, 255, 255]))
        let f = try PSDFile(data: try b.serialized())
        let px = PSDColorManagement.srgbRGBA8(try f.normalizedComposite(), icc: nil)!
        #expect(px[0] > 240 && px[1] > 240 && px[2] > 240, "no ink is white: \(px)")
        #expect(px[4] < 60 && px[5] < 60 && px[6] < 60, "full K is near black: \(px)")
    }
}

/// 32-bit documents need HDR toning colour-mode data (`hdrt`); Photoshop refuses them otherwise.
@Suite struct HDRToningRuleTests {
    static func rule(_ f: PSDFile) -> [PSDCompatibilityIssue] { f.compatibilityIssues().filter { $0.rule == .hdrToningMissingAt32Bit } }

    @Test func firesOnModelsWithoutToningAndTheWriterRepairsThem() throws {
        for (name, colorModeData) in [("empty", Data()), ("garbage", Data([1, 2, 3, 4, 5]))] {
            // Old TestGen style: 32-bit merged-only and layered files without hdrt.
            for var f in [PSDTestGen.mergedOnly(.psd, .rgb, 32, .rle, 5, 3), PSDTestGen.layered(.psb, .grayscale, 32, .zip)] {
                f.colorModeData = colorModeData
                let issues = Self.rule(f)
                #expect(issues.count == 1 && issues[0].severity == .error && issues[0].message.hasPrefix("PHOTOSHOP REFUSES THE FILE"), "\(name)")
                // Every write of a 32-bit model carries hdrt.
                let back = try PSDFile(data: f.serialized())
                #expect(back.colorModeData == PSDHDRToning.defaultData(), "\(name)")
                #expect(Self.rule(back).isEmpty)
                #expect(try back.serialized() == f.serialized())
            }
        }
        // Lower depths keep their colour-mode data as is.
        var g = PSDTestGen.mergedOnly(.psd, .grayscale, 16, .raw, 2, 2)
        g.colorModeData = Data()
        #expect(try PSDFile(data: g.serialized()).colorModeData.isEmpty)
    }

    @Test func silentOnBuilderAndGeneratorOutput() throws {
        for mode in [PSDColorMode.rgb, .grayscale] {
            for version in PSDVersion.allCases {
                var b = PSDBuilder(width: 3, height: 2, colorMode: mode, depth: 32, version: version)
                let cc = mode == .rgb ? 3 : 1
                b.pushLayer(PSDLayerSpec(name: "f", left: 0, top: 0, width: 1, height: 1, pixels: .f32([Float](repeating: 0.25, count: cc + 1))))
                let f = try PSDFile(data: b.serialized())
                #expect(f.colorModeData == PSDHDRToning.defaultData())
                #expect(Self.rule(f).isEmpty)
            }
        }
        for c in PSDTestGen.allCases() where c.file.header.depth == 32 { #expect(Self.rule(c.file).isEmpty, "\(c.name)") }
    }
}
