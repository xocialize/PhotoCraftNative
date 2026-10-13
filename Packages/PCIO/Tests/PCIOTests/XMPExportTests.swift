// Port of photocraft-io (crates/io/tests/xmp_export.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// #647: the default export embeds the document's whole XMP packet, as Save As does, and layered
// saves (PSD, `.pcraft`) always keep it. photocraft's Export As › Metadata: None
// (`XmpEmbed::None`, `metadata_none_embeds_no_xmp`) has no PCIO option; WebP export is
// PCPlatform's codec layer.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Testing
@testable import PCIO

@Suite struct XMPExportTests {
    init() { ExportSweep.install() }
    typealias Kit = FlatKit

    static let xmp = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF>"
        + "<photoshop:DocumentAncestors><rdf:Bag><rdf:li>xmp.did:11111111-2222-3333-4444-555555555555</rdf:li></rdf:Bag></photoshop:DocumentAncestors>"
        + "<photoshop:TextLayers><rdf:Bag><rdf:li>Secret campaign copy</rdf:li></rdf:Bag></photoshop:TextLayers>"
        + "</rdf:RDF></x:xmpmeta>"

    static func docWithXMP() -> Document {
        var d = Document(name: "x", size: PixelSize(width: 8, height: 6), mode: .rgb, depth: .u8)
        var s = Surface(format: d.pixelFormat)
        s.fill(rect(0, 0, 8, 6), with: [0.5, 0.4, 0.3, 1])
        d.layers.append(Layer(name: "flat", content: .raster(s)))
        d.metadata.xmp = xmp
        return d
    }

    static func leaksXMP(_ bytes: [UInt8]) -> Bool {
        let s = String(decoding: bytes, as: UTF8.self)
        return s.contains("x:xmpmeta") || s.contains("DocumentAncestors") || s.contains("Secret campaign copy")
    }

    @Test func allEmbedsTheWholePacketByDefault() throws {
        for ext in ["png", "jpg"] {
            let r = try Kit.export(Self.docWithXMP(), "out.\(ext)")
            #expect(Self.leaksXMP(r.bytes), "\(ext): the default export must embed the packet")
        }
    }

    @Test func layeredSavesKeepTheXMP() throws {
        let psd = try Kit.export(Self.docWithXMP(), "out.psd")
        #expect(Self.leaksXMP(psd.bytes), "PSD always keeps the document XMP")
        let pcraft = try Kit.export(Self.docWithXMP(), "out.pcraft")
        #expect(Self.leaksXMP(pcraft.bytes), ".pcraft always keeps the document XMP")
    }
}
