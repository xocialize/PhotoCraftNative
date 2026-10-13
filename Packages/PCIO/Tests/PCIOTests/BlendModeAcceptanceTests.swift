// Blend modes Photoshop accepts per document mode and depth: Photoshop 27.11 refuses a file
// ("open options are incorrect") whose layer uses a mode it doesn't offer there (Screen at 32
// bits, Darken in Lab, Darker Color in Grayscale, …), and Pass Through on a pixel layer raises a
// modal. The export writes the nearest accepted mode (Normal when none is close) with a warning.
// The table is PCPSD's (`PSDBlendMode.allowedModes`/`nearestAllowed`, measured by the port's
// Photoshop oracle). New in the port; MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import Testing
@testable import PCIO

@Suite struct BlendModeAcceptanceTests {
    init() { ExportSweep.install() }

    static let kinds: [(ColorMode, SampleType)] = [(.rgb, .u8), (.rgb, .u16), (.rgb, .f32), (.grayscale, .u8), (.grayscale, .u16), (.grayscale, .f32),
                                                   (.cmyk, .u8), (.cmyk, .u16), (.lab, .u8), (.lab, .u16)]

    /// One pixel layer and one group per blend mode (Pass Through included).
    static func document(_ mode: ColorMode, _ depth: SampleType) -> Document {
        var d = Document(name: "blends", size: PixelSize(width: 8, height: 8), mode: mode, depth: depth)
        let fmt = d.pixelFormat
        for m in [BlendMode.passThrough] + BlendMode.layerModes where m.hasPSDEquivalent {
            var l = Layer.raster("layer \(m.label)", format: fmt)
            l.withRaster { $0.fill(PixelRect(x0: 1, y0: 1, x1: 4, y1: 4), with: fmt.components(fromRGBA: SIMD4(0.5, 0.25, 0.75, 1))) }
            l.blend = m
            d.layers.append(l)
            var g = Layer.group("group \(m.label)", [Layer.raster("child", format: fmt)])
            g.blend = m
            d.layers.append(g)
        }
        return d
    }

    @Test(arguments: kinds.indices, PSDKit.conventions) func everyModeExportsAsOnePhotoshopAccepts(_ i: Int, _ photoshop: Bool) throws {
        let (mode, depth) = Self.kinds[i]
        var o = photocraftOptions()
        o.photoshopRecordConventions = photoshop
        let r = try DocumentIO.export(Self.document(mode, depth), as: "b.psd", options: o)
        let file = try PSDFile(bytes: r.bytes)
        let fmt = PixelFormat(mode: mode, sample: depth, alpha: true)
        let psdMode = PSDExport.psdMode(mode), psdDepth = PSDPixels.psdDepth(depth)
        let allowed = Set(PSDBlendMode.allowedModes(mode: psdMode, depth: psdDepth).map(\.key.string))
        for rec in file.layers where rec.sectionType != .boundingDivider {
            if let sd = rec.sectionDivider, sd.kind != .boundingDivider {
                let key = (sd.blendMode ?? rec.blendMode).key.string
                #expect(key == "pass" || allowed.contains(key), "\(mode) \(depth) \(rec.displayName): group \(key)")
            } else {
                #expect(allowed.contains(rec.blendMode.key.string), "\(mode) \(depth) \(rec.displayName): \(rec.blendMode.key.string)")
            }
        }
        // Every change is reported, naming the layer and both modes.
        let changed = Self.document(mode, depth).layers.filter { PSDExport.photoshopBlend($0.blend, group: $0.isGroup, fmt).key.string != $0.blend.psdKey }
        for l in changed {
            #expect(r.warnings.contains { $0.contains("\"\(l.name)\"") && $0.contains(l.blend.label) }, "\(mode) \(depth) \(l.name): \(r.warnings)")
        }
        #expect(file.compatibilityIssues(decodeChannels: true).filter { $0.severity == .error }.isEmpty)
    }

    @Test func nearestModes() {
        func key(_ m: BlendMode, _ mode: ColorMode, _ depth: SampleType, group: Bool = false) -> BlendMode? {
            BlendMode(psdKey: PSDExport.photoshopBlend(m, group: group, PixelFormat(mode: mode, sample: depth, alpha: true)).key.string)
        }
        #expect(key(.screen, .rgb, .f32) == .linearDodge)
        #expect(key(.colorBurn, .rgb, .f32) == .multiply)
        #expect(key(.overlay, .rgb, .f32) == .normal)
        #expect(key(.exclusion, .rgb, .f32) == .difference)
        #expect(key(.screen, .grayscale, .f32) == .linearDodge)
        #expect(key(.darkerColor, .grayscale, .u8) == .darken)
        #expect(key(.lighterColor, .grayscale, .u16) == .lighten)
        #expect(key(.luminosity, .grayscale, .u8) == .normal)
        #expect(key(.darken, .lab, .u8) == .darkerColor)
        #expect(key(.lighten, .lab, .u16) == .lighterColor)
        #expect(key(.colorDodge, .lab, .u8) == .linearDodge)
        #expect(key(.difference, .lab, .u8) == .normal)
        #expect(key(.passThrough, .rgb, .u8) == .normal)
        #expect(key(.passThrough, .lab, .u8, group: true) == .passThrough)
        // Everything stays where Photoshop accepts it.
        for m in BlendMode.layerModes where m.hasPSDEquivalent { #expect(key(m, .rgb, .u8) == m && key(m, .cmyk, .u16) == m) }
    }

    /// photocraft's generated documents use every mode in every mode and depth; after the
    /// mapping the round trip holds and the composite is unchanged where the mode was valid.
    @Test(arguments: kinds.indices) func mappedDocumentsRoundTrip(_ i: Int) throws {
        let (mode, depth) = Self.kinds[i]
        let d = genDoc(mode, depth, .all)
        expectDocsEqual(d, try roundtrip(d, options: IOOptions(compositor: MapsKit.compositor)), "\(mode) \(depth)")
    }
}
