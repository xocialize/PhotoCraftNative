// Port of photocraft-io (crates/io/tests/psd_background.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// A PSD's Background is recognised by its structure (the bottom record, transparency-protected,
// stored without a transparency channel), whatever its name in the Photoshop language that saved
// the file.

import Foundation
import PCDocument
import PCPSD
import Testing
@testable import PCIO

@Suite struct PSDBackgroundTests {
    init() { ExportSweep.install() }
    /// `testgen.layered` with its bottom layer turned into a Photoshop Background named `name`.
    static func file(_ name: String, transparencyChannel: Bool) throws -> PSDFile {
        var f = try PSDKit.layered(.psd, .rgb, 8, .rle)
        var bottom = f.layers[0]
        bottom.name = Array(name.utf8.filter { $0 < 0x80 })
        bottom.blocks.removeAll { $0.key == "luni" || $0.key == "lspf" }
        bottom.blocks.append(.unicodeName(name))
        bottom.flags.insert(.transparencyProtected)
        if !transparencyChannel { bottom.channels.removeAll { $0.id == -1 } }
        f.layers[0] = bottom
        return f
    }

    @Test func aLocalizedBackgroundIsTheBackground() throws {
        for name in ["Hintergrund", "背景", "Arrière-plan"] {
            let (d, _) = try PSDKit.psdToDocument(try PSDBackgroundTests.file(name, transparencyChannel: false))
            let bg = try #require(d.background, "\(name): no Background")
            #expect(bg.name == name)
            #expect(bg.locks.transparency && bg.locks.position, "\(name)")
            #expect(bg.id == d.layers[0].id)
        }
    }

    @Test func aProtectedLayerWithTransparencyIsNotTheBackground() throws {
        // Lock Transparent Pixels on an ordinary bottom layer: it keeps its transparency channel.
        let (d, _) = try PSDKit.psdToDocument(try PSDBackgroundTests.file("Background", transparencyChannel: true))
        #expect(d.layers[0].locks.transparency)
        #expect(d.background == nil)
    }
}
