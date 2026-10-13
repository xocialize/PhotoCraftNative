// The block-level tests of photocraft-io crates/io/tests/layer_labels.rs (MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors). They exercise PCIOCore's label helpers and
// PCPSD's `lclr` parser; the PSD round trip of every label is the lead's (it needs export/import).

import Foundation
import PCDocument
import PCIOCore
import PCPSD
import Testing

@Suite struct DocumentMapsLabelTests {
    @Test func layerLabelsKeepThePSDIndices() {
        let labels: [LabelColor] = [.none, .red, .orange, .yellow, .green, .blue, .violet, .gray, .seafoam, .indigo, .magenta, .fuchsia]
        for (i, color) in labels.enumerated() {
            #expect(Blocks.labelIndex(color) == UInt16(i))
            #expect(Blocks.labelFromIndex(UInt16(i)) == color)
        }
        for i: UInt16 in [12, 255, .max] {
            #expect(Blocks.labelFromIndex(i) == LabelColor.none)
        }
    }

    @Test func layerLabelsTruncatedSheetColorIsNotALabel() {
        let block = PSDTaggedBlock(key: "lclr", bytes: [0])
        #expect(throws: (any Error).self) { _ = try block.parsed() }
    }
}
