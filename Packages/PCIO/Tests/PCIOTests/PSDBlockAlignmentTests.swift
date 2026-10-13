// Port of photocraft-io (crates/io/tests/psd_block_alignment.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Every layer-level tagged block of an exported PSD/PSB is a multiple of 4 bytes long. Photoshop
// pads layer-level blocks to 4 inside the length field; all of its own files do, and a regenerated
// block that stopped at an even but unaligned size left the layer record's extra data unaligned:
// a Pattern Fill's `PtFl` came out 2 bytes short of the boundary for half of all pattern names.

import Foundation
import PCDocument
import PCFoundation
import PCPSD
import Testing
@testable import PCIO

@Suite struct PSDBlockAlignmentTests {
    init() { ExportSweep.install() }
    static func pattern(_ name: String) -> Pattern {
        var s = Surface(format: .rgba8)
        s.fill(rect(0, 0, 8, 8), with: [0.8, 0.8, 0.8, 1])
        s.fill(rect(0, 0, 4, 4), with: [0.2, 0.4, 0.9, 1])
        return Pattern(id: "059289fb-0000-4000-8000-000000000001", name: name, width: 8, height: 8, surface: s)
    }

    /// One Pattern Fill layer per name; the name's length moves the descriptor's size by two bytes
    /// per character, so consecutive lengths cover every residue modulo 4.
    static func doc(_ depth: SampleType, _ names: [String]) -> Document {
        var d = Document(name: "p", size: PixelSize(width: 40, height: 24), mode: .rgb, depth: depth)
        for name in names {
            let p = pattern(name)
            let fill = PatternFill(name: name, scale: 1, id: p.id, angle: 0, link: true, phase: .zero)
            d.patterns.append(p)
            d.layers.append(Layer(name: "Fill \(name)", content: .fill(.pattern(fill))))
        }
        return d
    }

    @Test(arguments: PSDKit.conventions) func layerBlocksAreFourByteAligned(_ photoshop: Bool) throws {
        let names = ["A", "Ab", "Abc", "Abcd", "Dots", "Checker", "Wood grain"]
        for depth in [SampleType.u8, .u16, .f32] {
            for path in ["x.psd", "x.psb"] {
                let bytes = try PSDKit.export(PSDBlockAlignmentTests.doc(depth, names), path, PSDKit.options(photoshop)).bytes
                let file = try PSDFile(bytes: bytes)
                var fills = 0
                for layer in file.layers {
                    for b in layer.blocks {
                        #expect(b.data.count % 4 == 0, "\(depth) \(path): layer \(layer.displayName) block \(b.key.string) is \(b.data.count) bytes")
                    }
                    if layer.block("PtFl") != nil { fills += 1 }
                }
                #expect(fills == names.count, "\(depth) \(path): every pattern fill keeps its PtFl block")
            }
        }
    }
}
