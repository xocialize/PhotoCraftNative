// Port of photocraft-io (crates/io/tests/layer_labels.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Layer colour labels keep Photoshop's `lclr` sheet-colour indices, through PSD at every depth.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import Testing
@testable import PCIO

@Suite struct LayerLabelsTests {
    init() { ExportSweep.install() }
    @Test func layerLabelsKeepThePSDIndices() {
        let labels: [LabelColor] = [.none, .red, .orange, .yellow, .green, .blue, .violet, .gray, .seafoam, .indigo, .magenta, .fuchsia]
        for (i, color) in labels.enumerated() {
            #expect(Blocks.labelIndex(color) == UInt16(i))
            #expect(Blocks.labelFromIndex(UInt16(i)) == color)
        }
        for i: UInt16 in [12, 255, .max] { #expect(Blocks.labelFromIndex(i) == LabelColor.none) }
    }

    @Test(arguments: PSDKit.conventions) func layerLabelsPSDRoundtripAllColorsAndDepths(_ photoshop: Bool) throws {
        for depth in SampleType.allCases {
            var doc = Document(name: "Labels", size: PixelSize(width: 2, height: 2), mode: .rgb, depth: depth)
            for color in LabelColor.all {
                var child = Layer.raster("Child", format: doc.pixelFormat)
                child.label = color
                var group = Layer.group(color.label, [child])
                group.label = color
                doc.layers.append(group)
            }
            let bytes = try PSDKit.export(doc, "labels.psd", PSDKit.options(photoshop)).bytes
            let back = try PSDKit.importFile("labels.psd", bytes, photoshop: photoshop).document
            func labels(_ d: Document) -> [String] { d.walk().map { "\($0.layer.name):\($0.layer.label)" } }
            #expect(labels(back) == labels(doc), "\(depth)")
            #expect(back.depth == depth)
        }
    }

    @Test func layerLabelsTruncatedSheetColorIsNotALabel() {
        #expect(throws: (any Error).self) { try PSDTaggedBlock(key: "lclr", bytes: [0]).parsed() }
    }
}
