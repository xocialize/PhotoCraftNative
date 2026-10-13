// Port of photocraft-io (crates/io/tests/psd_empty_channels.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Empty layer and mask channels are written raw, with no payload, in both record shapes.

import Foundation
import PCDocument
import PCFoundation
import PCPSD
import Testing
@testable import PCIO

@Suite struct PSDEmptyChannelsTests {
    init() { ExportSweep.install() }
    @Test(arguments: PSDKit.conventions) func emptyLayerAndMaskChannelsUseRawWithoutAPayload(_ photoshop: Bool) throws {
        for mode in [ColorMode.rgb, .grayscale] {
            for depth in [SampleType.u8, .u16, .f32] {
                for ext in ["out.psd", "out.psb"] {
                    var doc = genDoc(mode, depth, .all)
                    var masked = rasterLayer("Uniform mask", doc.pixelFormat, rect(0, 0, 3, 3), 1, true)
                    masked.mask = LayerMask(surface: Surface(format: PixelFormat(mode: .grayscale, sample: depth, alpha: false)), enabled: true, linked: true,
                                            density: 1, feather: 0)
                    doc.layers.append(masked)
                    let bytes = try PSDKit.export(doc, ext, PSDKit.options(photoshop)).bytes
                    let file = try PSDFile(bytes: bytes)
                    var empty = 0, emptyMasks = 0
                    for layer in file.layers {
                        for channel in layer.channels {
                            let r = layer.channelRect(channel.id)
                            guard r.width == 0 || r.height == 0 else { continue }
                            empty += 1
                            if channel.id == -2 { emptyMasks += 1 }
                            #expect(channel.compression == .raw, "\(mode) \(depth) \(ext): \(layer.displayName) channel \(channel.id)")
                            #expect(channel.data.isEmpty)
                        }
                    }
                    #expect(empty > 0)
                    #expect(emptyMasks > 0, "\(mode) \(depth) \(ext)")
                }
            }
        }
    }
}
