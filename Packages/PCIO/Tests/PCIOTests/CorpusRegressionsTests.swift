// Port of photocraft-io (crates/io/tests/corpus_regressions.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Synthetic reproductions of failures found by the psd-tools corpus. The corpus files themselves
// are never used: each test rebuilds the relevant structure from our own documents (exported,
// then edited with PCPSD as Photoshop would have written them). Shapes are rendered by the
// injected renderer (the CoreGraphics stand-in for photocraft-vector) and composited by PCRender.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import Testing
@testable import PCIO

@Suite struct CorpusRegressionsTests {
    init() { ExportSweep.install() }
    static func doc(_ depth: SampleType) -> Document {
        Document.withBackground(name: "t", size: PixelSize(width: 32, height: 32), mode: .rgb, depth: depth, fill: .white)
    }

    static func square(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> VectorPath {
        VectorPath([Subpath.polygon([(x0, y0), (x1, y0), (x1, y1), (x0, y1)])])
    }

    static func reimport(_ file: PSDFile) throws -> ImportResult {
        try MapsKit.importFile(MapsKit.bytes(file))
    }

    static func exported(_ d: Document) throws -> PSDFile {
        try PSDFile(bytes: MapsKit.export(d).bytes)
    }

    /// psd-tools 32bit.psd, 300dpi.psd, transparentbg.psd, vector-mask2.psd: shape layers whose
    /// record stores no pixels (empty rect; every 32-bit shape layer) imported as invisible. They
    /// are now rendered from their path and fill.
    @Test(arguments: [SampleType.u8, .u16, .f32]) func shapeLayerWithoutStoredPixelsRendersFromItsPath(_ depth: SampleType) throws {
        var d = Self.doc(depth)
        let sh = ShapeLayer(path: Self.square(8, 8, 24, 24), fill: .solid(.black))
        d.layers.append(MapsKit.shapeLayer("Shape 1", sh, format: d.pixelFormat, canvas: d.bounds))
        var file = try Self.exported(d)
        // Drop the shape record's pixels, as Photoshop does for 32-bit documents.
        let bits = file.header.depth
        var layers = file.layers
        guard var rec = layers.popLast() else {
            Issue.record("no layer records")
            return
        }
        #expect(rec.block("vmsk") != nil || rec.block("vsms") != nil)
        rec.rect = .zero
        for i in rec.channels.indices {
            rec.channels[i] = try PSDChannel.encode(id: rec.channels[i].id, compression: .raw, decoded: [], width: 0, height: 0, depth: bits, version: .psd)
        }
        file.layers = layers + [rec]
        let imp = try Self.reimport(file)
        let f = try MapsKit.flatten(imp.document)
        #expect(f.get(16, 16).x < 0.01, "\(depth): shape interior renders black: \(f.get(16, 16))")
        #expect(f.get(2, 2).x > 0.99, "\(depth): outside stays white")
    }

    /// psd-tools mask-density-vectormask.psd, mask_parameters.psd: vector mask density and feather
    /// were dropped on export (only the user mask's parameters were written).
    @Test(arguments: [false, true]) func vectorMaskDensityAndFeatherSurviveExport(_ withUserMask: Bool) throws {
        var d = Self.doc(.u8)
        var l = Layer.raster("pix", format: d.pixelFormat)
        l.withRaster { $0.fill(rect(0, 0, 32, 32), with: [0, 0, 0, 1]) }
        var vm = VectorMask(path: Self.square(0, 0, 16, 32))
        vm.density = 128.0 / 255
        vm.feather = 1.5
        l.vectorMask = vm
        if withUserMask {
            var m = LayerMask.revealAll()
            m.density = 204.0 / 255
            m.feather = 2.5
            l.mask = m
        }
        d.layers.append(l)
        let r = try MapsKit.export(d)
        #expect(!r.warnings.contains { $0.contains("density") }, "\(r.warnings)")
        let b = try MapsKit.importFile(r.bytes).document
        let back = try #require(b.layers[1].vectorMask)
        #expect(back.density == 128.0 / 255 && back.feather == 1.5, "user mask: \(withUserMask)")
        #expect((b.layers[1].mask != nil) == withUserMask)
        if let m = b.layers[1].mask { #expect(m.density == 204.0 / 255 && m.feather == 2.5) }
    }

    /// psd-tools layer_mask_data.psd, mask-density-layervectormask.psd: a layer with both a user
    /// mask and a vector mask stores the "real" user mask (channel -3) and mask parameters; the
    /// real-mask fields precede the parameters, so the -3 channel failed to decode.
    @Test func realUserMaskWithParametersIsDecoded() throws {
        var d = Self.doc(.u8)
        var l = Layer.raster("pix", format: d.pixelFormat)
        l.withRaster { $0.fill(rect(0, 0, 32, 32), with: [0, 0, 0, 1]) }
        var m = LayerMask.revealAll()
        m.density = 0.5
        l.mask = m
        var vm = VectorMask(path: Self.square(0, 0, 32, 32))
        vm.density = 0.5
        l.vectorMask = vm
        d.layers.append(l)
        var file = try Self.exported(d)
        // Add a real user mask hiding the left half (0) inside its rect, revealing elsewhere.
        var layers = file.layers
        guard var rec = layers.popLast() else {
            Issue.record("no layer records")
            return
        }
        guard case var .mask(pm) = rec.mask else {
            Issue.record("mask record")
            return
        }
        #expect(pm.parameters != nil)
        pm.real = PSDRealMask(flags: 0, background: 255, rect: PSDRect(top: 0, left: 0, bottom: 32, right: 16))
        pm.trailing.removeAll()
        rec.mask = .mask(pm)
        rec.channels.append(try PSDChannel.encode(id: PSDChannelID.realUserMask, compression: .rle, decoded: [UInt8](repeating: 0, count: 16 * 32),
                                                  width: 16, height: 32, depth: 8, version: .psd))
        file.layers = layers + [rec]
        let imp = try Self.reimport(file)
        #expect(imp.warnings.allSatisfy { !$0.contains("could not be decoded") }, "\(imp.warnings)")
        let mask = try #require(imp.document.layers[1].mask)
        // Hidden at density 0.5: 1 - 0.5 · (1 - 0).
        #expect(abs(mask.value(x: 4, y: 4) - 0.5) < 0.01, "real mask hides the left half: \(mask.value(x: 4, y: 4))")
        #expect(mask.value(x: 24, y: 4) == 1, "and reveals outside its rect")
        #expect(mask.density == 128.0 / 255)
        #expect(imp.document.layers[1].vectorMask?.density == 128.0 / 255)
    }

    /// psd-tools layer_mask_data.psd, mask-parameters-no-real-channel.psd: a shape layer whose
    /// vector mask has a density (or feather) shows its fill beyond the path at 1 - density; the
    /// stored pixels hold only the shape. It imports as a fill layer with a soft vector mask.
    @Test func shapeWithVectorMaskDensityImportsAsFillWithSoftMask() throws {
        var d = Self.doc(.u8)
        var l = Layer(name: "Ellipse", content: .fill(.solid(.black)))
        var vm = VectorMask(path: Self.square(8, 8, 24, 24))
        vm.density = 0.8
        l.vectorMask = vm
        d.layers.append(l)
        var file = try Self.exported(d)
        // Photoshop stores the shape alone: replace the record's pixels with the path's coverage.
        var layers = file.layers
        guard var rec = layers.popLast() else {
            Issue.record("no layer records")
            return
        }
        #expect(rec.block("SoCo") != nil && rec.block("vmsk") != nil)
        rec.rect = PSDRect(top: 8, left: 8, bottom: 24, right: 24)
        for i in rec.channels.indices where rec.channels[i].id >= -1 {
            let v: UInt8 = rec.channels[i].id == -1 ? 255 : 0
            rec.channels[i] = try PSDChannel.encode(id: rec.channels[i].id, compression: .raw, decoded: [UInt8](repeating: v, count: 16 * 16),
                                                    width: 16, height: 16, depth: 8, version: .psd)
        }
        file.layers = layers + [rec]
        let imp = try Self.reimport(file)
        let back = imp.document.layers[1]
        if case .fill = back.content {} else { Issue.record("\(back.content.kindName)") }
        #expect(back.vectorMask?.density == 204.0 / 255)
        let f = try MapsKit.flatten(imp.document)
        #expect(f.get(16, 16).x < 0.01, "inside the path: black")
        #expect(abs(f.get(2, 2).x - 0.8) < 0.01, "outside: 20% of the fill shows: \(f.get(2, 2))")
    }

    /// psd-tools adjustment-fillers.psd: a solid-colour shape whose vector path is empty with the
    /// initial-fill record set (it covers the canvas) and no stored pixels rendered nothing.
    @Test func shapeWithoutPixelsAndFullInitialFillCoversTheCanvas() throws {
        var d = Self.doc(.u8)
        var path = VectorPath()
        path.inverted = true
        let sh = ShapeLayer(path: path, fill: .solid(.black))
        d.layers.append(MapsKit.shapeLayer("Color Fill 1", sh, format: d.pixelFormat, canvas: d.bounds))
        var file = try Self.exported(d)
        var layers = file.layers
        guard var rec = layers.popLast() else {
            Issue.record("no layer records")
            return
        }
        rec.rect = .zero
        for i in rec.channels.indices {
            rec.channels[i] = try PSDChannel.encode(id: rec.channels[i].id, compression: .raw, decoded: [], width: 0, height: 0, depth: 8, version: .psd)
        }
        file.layers = layers + [rec]
        let f = try MapsKit.flatten(Self.reimport(file).document)
        #expect(f.get(0, 0).x < 0.01 && f.get(31, 31).x < 0.01, "covers everything: \(f.get(0, 0))")
    }
}
