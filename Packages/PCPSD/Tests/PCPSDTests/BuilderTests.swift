// Builder and pixel extraction tests.
// Port of photocraft-psd (crates/psd/tests/builder.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors; extended for 32-bit, Lab, group masks and the Photoshop-acceptance rules.

import Foundation
import Testing
@testable import PCPSD

func rgbaPattern(_ w: Int, _ h: Int, _ seed: UInt8) -> [UInt8] {
    var v: [UInt8] = []
    for y in 0 ..< h {
        for x in 0 ..< w {
            v += [UInt8(truncatingIfNeeded: x * 10) ^ seed, UInt8(truncatingIfNeeded: y * 20), UInt8(truncatingIfNeeded: x + y) ^ seed,
                  (x + y) % 3 == 0 ? 0 : UInt8(200 + x % 50)]
        }
    }
    return v
}

func built(_ b: PSDBuilder, sourceLocation: SourceLocation = #_sourceLocation) throws -> PSDFile {
    let bytes = try b.serialized()
    let f = try PSDFile(data: bytes)
    #expect(try f.serialized() == bytes, "byte stable", sourceLocation: sourceLocation)
    #expect(f == (try b.build()), "model stable", sourceLocation: sourceLocation)
    return f
}

@Suite struct BuilderTests {
    @Test(arguments: [PSDVersion.psd, .psb])
    func rgba8AllCompressions(version: PSDVersion) throws {
        for c in PSDCompression.all {
            let px = rgbaPattern(7, 5, 3)
            var b = PSDBuilder(width: 10, height: 8, version: version)
            b.compression = c
            b.pushLayer(PSDLayerSpec(name: "L", left: -2, top: 1, width: 7, height: 5, pixels: .u8(px)))
            let f = try built(b)
            let img = try f.layer(0)!.rgba8()
            #expect(img.left == -2 && img.top == 1 && img.width == 7 && img.height == 5)
            #expect(img.data == px, "\(version) \(c)")
        }
    }

    @Test func rgba16LayersScaleTo8Bit() throws {
        let n = 4 * 3
        let px: [UInt16] = (0 ..< n * 4).map { UInt16(truncatingIfNeeded: $0 &* 5003) }
        for c in PSDCompression.all {
            var b = PSDBuilder(width: 4, height: 3, depth: 16)
            b.compression = c
            b.pushLayer(PSDLayerSpec(name: "x", left: 0, top: 0, width: 4, height: 3, pixels: .u16(px)))
            let f = try built(b)
            if case let .globalBlock(_, _, key, _, _) = f.layerInfoPlacement { #expect(key == "Lr16") } else { Issue.record("not Lr16") }
            let l = f.layer(0)!
            #expect(try l.rgba8().data == px.map { UInt8((UInt32($0) * 255 + 32767) / 65535) })
            #expect(PSDSamples.u16(try l.channelBytes(0)) == stride(from: 0, to: px.count, by: 4).map { px[$0] })
        }
    }

    @Test func rgb32LayersAndHDRToning() throws {
        let px: [Float] = (0 ..< 3 * 2 * 4).map { Float($0) / 10 - 0.5 }
        for c in PSDCompression.all {
            var b = PSDBuilder(width: 3, height: 2, depth: 32)
            b.compression = c
            b.pushLayer(PSDLayerSpec(name: "hdr", left: 0, top: 0, width: 3, height: 2, pixels: .f32(px)))
            let f = try built(b)
            #expect(PSDHDRToning.isToningData(f.colorModeData))
            #expect(f.colorModeData.count == 110)
            if case let .globalBlock(_, _, key, _, _) = f.layerInfoPlacement { #expect(key == "Lr32") } else { Issue.record("not Lr32") }
            // ZIP at 32 bits is stored as ZIP with prediction (Photoshop reads code 2 at 32 bits as predicted).
            if c == .zip { #expect(f.layers[0].channel(0)?.compression == .zipPrediction) }
            #expect(PSDSamples.f32(try f.layer(0)!.channelBytes(0)) == stride(from: 0, to: px.count, by: 4).map { px[$0] })
            let n = try f.layer(0)!.normalized()
            #expect(n.planes[0] == stride(from: 0, to: px.count, by: 4).map { px[$0] }, "32-bit stays linear and unclamped")
        }
    }

    @Test func grayscaleBuilder() throws {
        let px: [UInt8] = (0 ..< 6).flatMap { [UInt8($0 * 40), UInt8(255 - $0)] }
        var b = PSDBuilder(width: 3, height: 2, colorMode: .grayscale)
        b.pushLayer(PSDLayerSpec(name: "g", left: 0, top: 0, width: 3, height: 2, pixels: .u8(px)))
        b.setComposite(.u8(px))
        let f = try built(b)
        #expect(f.header.colorMode == .grayscale)
        let img = try f.layer(0)!.rgba8()
        for i in 0 ..< 6 { #expect(Array(img.data[i * 4 ..< i * 4 + 4]) == [px[i * 2], px[i * 2], px[i * 2], px[i * 2 + 1]]) }
        // Gray composites are stored against white like RGB; removing the matte recovers the colour
        // within 8-bit rounding.
        let c = try f.compositeRGBA8()
        for i in 0 ..< 24 { #expect(abs(Int(c.data[i]) - Int(img.data[i])) <= 1) }
        #expect(f.header.channels == 2)
    }

    @Test func grayscale16Builder() throws {
        var b = PSDBuilder(width: 2, height: 1, colorMode: .grayscale, depth: 16)
        b.pushLayer(PSDLayerSpec(name: "g", left: 0, top: 0, width: 2, height: 1, pixels: .u16([0, 65535, 32768, 65535])))
        let f = try built(b)
        #expect(try f.layer(0)!.rgba8().data == [0, 0, 0, 255, 128, 128, 128, 255])
    }

    @Test func cmykBuilderInvertsInk() throws {
        let px: [UInt8] = [0, 0, 0, 0, 255, 0, 0, 0, 255, 255]
        var b = PSDBuilder(width: 2, height: 1, colorMode: .cmyk)
        b.pushLayer(PSDLayerSpec(name: "c", left: 0, top: 0, width: 2, height: 1, pixels: .u8(px)))
        b.setComposite(.u8(px))
        let f = try built(b)
        #expect(f.header.channels == 4)
        let l = f.layer(0)!
        #expect(try l.channelBytes(0) == [255, 255])
        #expect(try l.channelBytes(3) == [255, 0])
        #expect(try l.rgba8().data == [255, 255, 255, 255, 0, 0, 0, 255])
        #expect(try f.compositeRGBA8().data == [255, 255, 255, 255, 0, 0, 0, 255])
        let n = try f.normalizedComposite()
        #expect(n.space == .cmyk && n.planes[3] == [0, 1])
    }

    @Test func cmyk16Builder() throws {
        var b = PSDBuilder(width: 1, height: 1, colorMode: .cmyk, depth: 16)
        b.pushLayer(PSDLayerSpec(name: "c", left: 0, top: 0, width: 1, height: 1, pixels: .u16([0, 0, 0, 0, 65535])))
        let f = try built(b)
        #expect(try f.layer(0)!.rgba8().data == [255, 255, 255, 255])
    }

    @Test func labBuilder() throws {
        // L 255 (100), a = b = 128 (0): white.
        var b = PSDBuilder(width: 1, height: 1, colorMode: .lab)
        b.pushLayer(PSDLayerSpec(name: "lab", left: 0, top: 0, width: 1, height: 1, pixels: .u8([255, 128, 128, 255])))
        let f = try built(b)
        let px = try f.layer(0)!.rgba8().data
        #expect(px.allSatisfy { $0 >= 254 }, "\(px)")
        #expect(try f.compositeRGBA8().data.allSatisfy { $0 >= 254 }, "white placeholder")
    }

    @Test func layerPropertiesRoundTrip() throws {
        var b = PSDBuilder(width: 4, height: 4)
        var spec = PSDLayerSpec(name: "Props \u{1F3A8}", left: 1, top: 1, width: 2, height: 2, pixels: .u8([UInt8](repeating: 9, count: 16)))
        spec.blendMode = .softLight
        spec.opacity = 128
        spec.fillOpacity = 64
        spec.visible = false
        spec.clipping = true
        spec.extraBlocks.append(.sheetColor(4))
        b.pushLayer(spec)
        let f = try built(b)
        let r = f.layers[0]
        #expect(r.displayName == "Props \u{1F3A8}")
        #expect(r.name == Array("Props ?".utf8))
        #expect(r.blendMode == .softLight)
        #expect(r.opacity == 128)
        #expect(r.fillOpacity == 64)
        #expect(!r.isVisible)
        #expect(r.clipping == 1)
        #expect(r.layerID == 1)
        #expect(r.block("lclr")?.typed == .sheetColor(4))
        #expect(r.blocks.filter { $0.key == "lclr" }.count == 1, "extra blocks replace defaults")
    }

    @Test func photoshopDefaultBlocksOrder() throws {
        var b = PSDBuilder(width: 1, height: 1)
        b.pushLayer(PSDLayerSpec(name: "x", left: 0, top: 0, width: 1, height: 1, pixels: .u8([1, 2, 3, 255])))
        let f = try built(b)
        #expect(f.layers[0].blocks.map(\.key.string) == ["luni", "lnsr", "lyid", "clbl", "infx", "knko", "lspf", "lclr", "fxrp"])
        #expect(f.resources.map(\.id) == [1005, 1028, 1082, 1057])
        let body = try f.layerInfo!.bodyBytes(.psd)
        #expect(body.count % 4 == 0, "layer info padded to 4 like Photoshop")
        #expect(f.layers[0].flags.rawValue == 0x08)
        #expect(f.layers[0].blendingRanges.data.count == 40)
    }

    /// Group records match what Photoshop writes (probed across the corpus).
    @Test func photoshopGroupRecordConventions() throws {
        var b = PSDBuilder(width: 2, height: 2)
        var g = PSDGroupSpec(name: "Group 1")
        g.visible = false
        b.beginGroup(g)
        b.pushLayer(PSDLayerSpec(name: "x", left: 0, top: 0, width: 1, height: 1, pixels: .u8([1, 2, 3, 255])))
        try b.endGroup()
        let f = try built(b)
        let divider = f.layers[0], folder = f.layers[2]
        #expect(divider.blocks.map(\.key.string) == ["luni", "lnsr", "lyid", "lsct", "lspf", "lclr", "fxrp"])
        #expect(folder.blocks.map(\.key.string) == ["luni", "lnsr", "lyid", "lsct", "lspf", "lclr", "fxrp"])
        #expect(divider.block("lnsr")?.data == Data("lset".utf8))
        #expect(divider.flags.rawValue == 0x18)
        #expect(folder.flags.rawValue == 0x1A)
        #expect(divider.block("lsct")?.data.count == 4)
        #expect(folder.block("lsct")?.data.count == 16)
        #expect(folder.sectionDivider?.subType == 0)
        #expect(divider.channels.allSatisfy { $0.data.isEmpty && $0.compression == .raw })
        #expect(folder.blendingRanges.data.count == 40)
    }

    @Test func allBlendModesViaBuilder() throws {
        var b = PSDBuilder(width: 1, height: 1)
        b.blendModePolicy = .keep // every key as given, pass-through on a layer included
        for m in PSDBlendMode.all {
            var s = PSDLayerSpec(name: "\(m)", left: 0, top: 0, width: 1, height: 1, pixels: .u8([1, 2, 3, 4]))
            s.blendMode = m
            b.pushLayer(s)
        }
        let f = try built(b)
        #expect(f.layers.map(\.blendMode) == PSDBlendMode.all)
    }

    @Test func masksRoundTrip() throws {
        let maskPx: [UInt8] = (0 ..< 12).map { UInt8($0 * 20) }
        for depth: UInt16 in [8, 16, 32] {
            var b = PSDBuilder(width: 3, height: 3, depth: depth)
            var s = PSDLayerSpec(name: "m", left: 0, top: 0, width: 3, height: 3, pixels: .u8([UInt8](repeating: 100, count: 36)))
            switch depth {
            case 16: s.pixels = .u16([UInt16](repeating: 25700, count: 36))
            case 32: s.pixels = .f32([Float](repeating: 100.0 / 255, count: 36))
            default: break
            }
            s.mask = PSDMaskSpec(rect: PSDRect(x: -1, y: 0, width: 4, height: 3), data: maskPx, defaultColor: 255, disabled: true)
            b.pushLayer(s)
            let f = try built(b)
            let l = f.layer(0)!
            let m = try l.userMask()!.get()
            #expect(m.left == -1 && m.top == 0 && m.width == 4 && m.height == 3)
            #expect(m.data == maskPx)
            #expect(m.defaultValue == 255)
            #expect(l.record.layerMask!.isDisabled)
            #expect(try l.rgba8().data.allSatisfy { $0 == 100 })
        }
    }

    @Test func groupMask() throws {
        var b = PSDBuilder(width: 2, height: 2)
        var g = PSDGroupSpec(name: "G")
        g.mask = PSDMaskSpec(rect: PSDRect(x: 0, y: 0, width: 2, height: 1), data: [0, 255])
        try b.pushGroup(g) { $0.pushLayer(PSDLayerSpec(name: "x", left: 0, top: 0, width: 1, height: 1, pixels: .u8([0, 0, 0, 255]))) }
        let f = try built(b)
        let folder = f.layer(2)!
        #expect(folder.record.sectionType == .openFolder)
        #expect(try folder.userMask()!.get().data == [0, 255])
    }

    @Test func noMaskReturnsNil() throws {
        var b = PSDBuilder(width: 1, height: 1)
        b.pushLayer(PSDLayerSpec(name: "x", left: 0, top: 0, width: 1, height: 1, pixels: .u8([0, 0, 0, 0])))
        #expect(try built(b).layer(0)!.userMask() == nil)
    }

    @Test func emptyLayer() throws {
        var b = PSDBuilder(width: 2, height: 2)
        b.pushLayer(PSDLayerSpec(name: "empty", left: 0, top: 0, width: 0, height: 0, pixels: .u8([])))
        let f = try built(b)
        let img = try f.layer(0)!.rgba8()
        #expect(img.width == 0 && img.height == 0 && img.data.isEmpty)
        #expect(f.layers[0].channels.allSatisfy { $0.compression == .raw && $0.data.isEmpty }, "empty channels are raw, length 2")
    }

    @Test func compositeSuppliedWithAlpha() throws {
        let px: [UInt8] = [255, 0, 0, 128, 17, 89, 203, 0]
        var b = PSDBuilder(width: 2, height: 1)
        b.pushLayer(PSDLayerSpec(name: "x", left: 0, top: 0, width: 2, height: 1, pixels: .u8(px)))
        b.setComposite(.u8(px))
        let f = try built(b)
        #expect(f.header.channels == 4)
        #expect(f.layerInfo!.mergedAlpha)
        #expect(f.mergedHasAlpha)
        #expect(f.hasRealMergedData == true)
        #expect(try f.decodeMerged() == [255, 17, 127, 89, 127, 203, 128, 0])
        #expect(try f.compositeRGBA8().data == px)
    }

    @Test func compositeOpaqueDropsAlpha() throws {
        let px: [UInt8] = (0 ..< 6).flatMap { [UInt8($0), UInt8($0), UInt8($0), 255] }
        var b = PSDBuilder(width: 3, height: 2)
        b.setComposite(.u8(px))
        let f = try built(b)
        #expect(f.header.channels == 3)
        #expect(f.layerInfo == nil)
        #expect(try f.compositeRGBA8().data == px)
    }

    @Test func composite16Bit() throws {
        var b = PSDBuilder(width: 2, height: 1, depth: 16)
        b.setComposite(.u16([65535, 0, 0, 65535, 0, 65535, 0, 32768]))
        #expect(try built(b).compositeRGBA8().data == [255, 0, 0, 255, 0, 255, 0, 128])
    }

    @Test func mergedTransparencyMarkerForDeepFiles() throws {
        for depth: UInt16 in [16, 32] {
            var b = PSDBuilder(width: 1, height: 1, depth: depth)
            let px: PSDPixels = depth == 16 ? .u16([1, 2, 3, 30000]) : .f32([0.1, 0.2, 0.3, 0.5])
            b.pushLayer(PSDLayerSpec(name: "x", left: 0, top: 0, width: 1, height: 1, pixels: px))
            b.setComposite(px)
            let f = try built(b)
            #expect(f.globalBlock(depth == 16 ? "Mt16" : "Mt32") != nil)
            #expect(f.mergedHasAlpha)
        }
    }

    @Test func placeholderCompositeIsFlagged() throws {
        var b = PSDBuilder(width: 2, height: 2)
        b.pushLayer(PSDLayerSpec(name: "x", left: 0, top: 0, width: 1, height: 1, pixels: .u8([0, 0, 0, 0])))
        let f = try built(b)
        #expect(f.hasRealMergedData == false)
        #expect(try f.compositeRGBA8().data.allSatisfy { $0 == 255 })
    }

    @Test func builderResources() throws {
        var b = PSDBuilder(width: 1, height: 1)
        b.setResolution(dpi: 300)
        b.setICCProfile(Data([1, 2, 3]))
        let f = try built(b)
        #expect(abs(f.resolution!.vRes - 300) < 1e-9)
        #expect(f.iccProfile == Data([1, 2, 3]))
    }

    @Test func builderErrors() throws {
        var b = PSDBuilder(width: 2, height: 2)
        b.pushLayer(PSDLayerSpec(name: "bad", left: 0, top: 0, width: 2, height: 2, pixels: .u8([0, 0, 0])))
        #expect(throws: PSDError.self) { try b.build() }
        var b2 = PSDBuilder(width: 2, height: 2)
        b2.pushLayer(PSDLayerSpec(name: "wrong depth", left: 0, top: 0, width: 1, height: 1, pixels: .u16([0, 0, 0, 0])))
        #expect(throws: PSDError.self) { try b2.build() }
        var b3 = PSDBuilder(width: 2, height: 2)
        b3.beginGroup(PSDGroupSpec(name: "open"))
        #expect(throws: PSDError.self) { try b3.build() }
        var b4 = PSDBuilder(width: 2, height: 2)
        #expect(throws: PSDError.self) { try b4.endGroup() }
        #expect(throws: PSDError.self) { try PSDBuilder(width: 1, height: 1, colorMode: .cmyk, depth: 32).build() }
        #expect(throws: PSDError.self) { try PSDBuilder(width: 1, height: 1, colorMode: .indexed).build() }
        var b5 = PSDBuilder(width: 2, height: 2)
        b5.setComposite(.u8([0, 0, 0, 0]))
        #expect(throws: PSDError.self) { try b5.build() }
        var b6 = PSDBuilder(width: 2, height: 2)
        var s = PSDLayerSpec(name: "m", left: 0, top: 0, width: 1, height: 1, pixels: .u8([0, 0, 0, 0]))
        s.mask = PSDMaskSpec(rect: PSDRect(x: 0, y: 0, width: 2, height: 2), data: [0, 0, 0])
        b6.pushLayer(s)
        #expect(throws: PSDError.self) { try b6.build() }
        #expect(throws: PSDError.self) { try PSDBuilder(width: 40000, height: 1).build() }
    }

    @Test func groupProperties() throws {
        var b = PSDBuilder(width: 1, height: 1)
        var g = PSDGroupSpec(name: "G")
        g.blendMode = .multiply
        g.opacity = 77
        g.visible = false
        b.beginGroup(g)
        b.pushLayer(PSDLayerSpec(name: "x", left: 0, top: 0, width: 1, height: 1, pixels: .u8([0, 0, 0, 0])))
        try b.endGroup()
        let f = try built(b)
        let r = f.layers[2]
        #expect(r.displayName == "G")
        #expect(r.opacity == 77)
        #expect(!r.isVisible)
        #expect(r.sectionDivider == PSDSectionDivider(kind: .openFolder, blendMode: .multiply, subType: 0))
        #expect(f.layers[0].sectionType == .boundingDivider)
        #expect(f.layers[0].channels.allSatisfy { $0.compression == .raw && $0.data.isEmpty })
    }

    @Test func psbBuilderLargeCanvasHeader() throws {
        let f = try built(PSDBuilder(width: 40000, height: 1, version: .psb))
        #expect(f.header.width == 40000)
        try f.validate()
    }

    @Test func layerViewsIndices() throws {
        var b = PSDBuilder(width: 1, height: 1)
        for i in 0 ..< 3 { b.pushLayer(PSDLayerSpec(name: "l\(i)", left: 0, top: 0, width: 1, height: 1, pixels: .u8([0, 0, 0, 0]))) }
        let f = try built(b)
        #expect(f.layerViews.map { "\($0.index)\($0.name)" } == ["0l0", "1l1", "2l2"])
        #expect(f.layer(3) == nil)
    }

    /// photocraft tests/tree.rs `builder_groups_tree`.
    @Test func builderGroupsTree() throws {
        func px(_ n: Int) -> PSDPixels { .u8([UInt8](repeating: 255, count: n * 4)) }
        var b = PSDBuilder(width: 2, height: 2)
        b.pushLayer(PSDLayerSpec(name: "bg", left: 0, top: 0, width: 2, height: 2, pixels: px(4)))
        b.beginGroup(PSDGroupSpec(name: "A"))
        b.pushLayer(PSDLayerSpec(name: "a1", left: 0, top: 0, width: 1, height: 1, pixels: px(1)))
        var closed = PSDGroupSpec(name: "B")
        closed.open = false
        b.beginGroup(closed)
        b.pushLayer(PSDLayerSpec(name: "b1", left: 0, top: 0, width: 1, height: 1, pixels: px(1)))
        try b.endGroup()
        try b.endGroup()
        let f = try PSDFile(data: try b.serialized())
        #expect(TreeTests.names(f, f.layerTree()) == "bg,A[a1,B[b1]]")
    }

    /// Seeded replacement for photocraft's `builder_random_layers_roundtrip` proptest.
    @Test func randomLayersRoundTrip() throws {
        var rng = SeededRandom(0xB01D)
        let names = ["", "a", "Layer 1", "äöü", "😀 smile", "12345678901234567890"]
        for _ in 0 ..< 40 {
            let version: PSDVersion = rng.bool() ? .psb : .psd
            let sixteen = rng.bool()
            var b = PSDBuilder(width: 16, height: 16, depth: sixteen ? 16 : 8, version: version)
            b.compression = PSDCompression.all[rng.int(0 ..< 4)]
            var expected: [(String, [UInt8], UInt8, PSDBlendMode, Bool)] = []
            for i in 0 ..< rng.int(0 ..< 6) {
                let (w, h) = (rng.int(0 ..< 9), rng.int(0 ..< 9))
                let px8 = (0 ..< w * h * 4).map { UInt8(truncatingIfNeeded: $0 * 31 + i * 7) }
                var s = PSDLayerSpec(name: names[rng.int(0 ..< names.count)], left: Int32(rng.int(-20 ..< 20)), top: Int32(rng.int(-20 ..< 20)),
                                     width: w, height: h, pixels: sixteen ? .u16(px8.map { UInt16($0) * 257 }) : .u8(px8))
                s.opacity = rng.byte()
                s.blendMode = PSDBlendMode.all[rng.int(0 ..< 28)]
                s.visible = rng.bool()
                b.pushLayer(s)
                // The builder substitutes what Photoshop does not accept (pass-through on a layer).
                let blend = PSDBlendMode.nearestAllowed(s.blendMode, mode: .rgb, depth: sixteen ? 16 : 8, isGroup: false)
                expected.append((s.name, px8, s.opacity, blend, s.visible))
            }
            let bytes = try b.serialized()
            let f = try PSDFile(data: bytes)
            #expect(try f.serialized() == bytes)
            #expect(f.layers.count == expected.count)
            for (l, e) in zip(f.layerViews, expected) {
                #expect(l.name == e.0)
                #expect(try l.rgba8().data == e.1)
                #expect(l.record.opacity == e.2 && l.record.blendMode == e.3 && l.record.isVisible == e.4)
            }
        }
    }
}
