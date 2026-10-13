// Typed tagged blocks: every typed parser must reproduce Photoshop's bytes exactly on the corpus,
// plus synthetic round trips for blocks the corpus lacks.

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PCPSD

@Suite(.enabled(if: Corpus.directory != nil, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)"))
struct TypedBlockCorpusTests {
    /// Parse → serialise → compare for each typed block kind.
    @Test func typedBlocksAreLossless() throws {
        var counts: [String: (ok: Int, total: Int)] = [:]
        var failures: [String] = []
        func check(_ name: String, _ original: Data, _ body: () throws -> Data) {
            var c = counts[name] ?? (0, 0)
            c.total += 1
            do {
                let out = try body()
                if out == original { c.ok += 1 } else { failures.append("\(name): \(out.count) vs \(original.count) bytes") }
            } catch {
                failures.append("\(name): \(error)")
            }
            counts[name] = c
        }
        for url in Corpus.files {
            let f = try PSDFile(contentsOf: url)
            for b in f.layers.flatMap(\.blocks) + f.globalBlocks {
                let k = b.key.string
                switch k {
                case "TySh": check(k, b.data) { try PSDTypeTool(bytes: b.data).serialized() }
                case "lfx2", "lfxs", "lmfx": check(k, b.data) { try PSDObjectEffects(bytes: b.data).serialized() }
                case "lrFX":
                    check(k, b.data) { try PSDLegacyEffects(bytes: b.data).serialized() }
                    let fx = try PSDLegacyEffects(bytes: b.data)
                    for e in fx.entries where e.typed == nil { failures.append("lrFX \(e.key) untyped") }
                case "SoLd", "SoLE": check(k, b.data) { try PSDPlacedLayerData(bytes: b.data).serialized() }
                case "PlLd": check(k, b.data) { try PSDPlacedLayer(bytes: b.data).serialized() }
                case "vmsk", "vsms": check(k, b.data) { try PSDVectorMask(bytes: b.data).serialized() }
                case "vogk", "vscg": check(k, b.data) { try PSDHeaderedDescriptor(bytes: b.data).serialized() }
                case "vstk": check(k, b.data) { try PSDVectorStroke(bytes: b.data).serialized() }
                case "SoCo", "GdFl", "PtFl": check(k, b.data) { try PSDFillSetting(key: b.key, bytes: b.data).serialized() }
                case "shmd": check(k, b.data) { PSDMetadataItem.serialize(try PSDMetadataItem.parse(b.data)) }
                case "CgEd": check(k, b.data) {
                    try b.data.withByteReader { r in
                        var d = try PSDVersionedDescriptor.read(&r).serialized()
                        d.append(try r.data(r.remaining))
                        return d
                    }
                }
                case "Txt2": check(k, b.data) { try PSDEngineData.parseBare(b.data).serializedCompactBare() }
                case "FEid", "FXid": check(k, b.data) { try PSDFilterEffects(bytes: b.data).serialized() }
                case "lnk2", "lnk3", "lnkD", "lnkE": check(k, b.data) { try PSDLinkedFiles(bytes: b.data).serialized() }
                default:
                    if PSDAdjustment.keys.contains(b.key) {
                        check(k, b.data) {
                            guard let a = try PSDAdjustment.parse(key: b.key, data: b.data) else { throw PSDError.invalid("untyped") }
                            return a.serialized()
                        }
                    }
                }
            }
            for r in f.resources {
                switch r.id {
                case 1050: check("res1050 slices", r.data) { try PSDSlices(bytes: r.data).serialized() }
                case 1032: check("res1032 guides", r.data) { try PSDGridAndGuides(bytes: r.data).serialized() }
                case 1005: check("res1005 resolution", r.data) { try PSDResolutionInfo(bytes: r.data).serialized() }
                case 1057: check("res1057 version", r.data) { try PSDVersionInfo(bytes: r.data).serialized() }
                case 1065, 1082, 1083, 1088: check("res\(r.id) descriptor", r.data) { try PSDVersionedDescriptor(bytes: r.data).serialized() }
                case 2000 ... 2997, 1025: check("res\(r.id) path", r.data) { try PSDPathData(bytes: r.data).serialized() }
                default: break
                }
            }
        }
        let summary = counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.ok)/\($0.value.total)" }.joined(separator: ", ")
        print("TYPED lossless: \(summary)")
        #expect(failures.isEmpty, "\(failures.prefix(10))")
    }

    /// EngineData: parse every TySh/Txt2 document; how much of Photoshop's text reproduces exactly.
    @Test func engineDataParsesAndRewrites() throws {
        var parsed = 0, exact = 0, total = 0, txt2 = 0
        var texts: [String] = []
        for url in Corpus.files {
            let f = try PSDFile(contentsOf: url)
            for (i, l) in f.layers.enumerated() {
                guard let t = l.typeTool else { continue }
                total += 1
                guard let raw = t.text.descriptor["EngineData"]?.rawBytes else { continue }
                let e = try PSDEngineData.parse(raw)
                parsed += 1
                if e.serialized() == raw { exact += 1 }
                #expect(try PSDEngineData.parse(e.serialized()) == e, "stable re-parse")
                if let s = e.path("EngineDict", "Editor", "Text")?.string { texts.append(s) }
                #expect(t.string != nil)
                #expect(f.layers[i].kind == .text)
                // Editing round trip: replacing the EngineData keeps the rest of the block.
                var t2 = t
                t2.setEngineData(e)
                #expect(try PSDTypeTool(bytes: t2.serialized()).engineData == e)
            }
            if let e = f.textEngineData {
                txt2 += 1
                #expect(e.entries?.isEmpty == false)
            }
        }
        print("ENGINEDATA: \(parsed)/\(total) TySh parsed, \(exact) rewritten byte for byte, \(txt2) Txt2 parsed; sample texts \(texts.prefix(3))")
        #expect(parsed == total)
        #expect(exact == total, "the writer reproduces Photoshop's EngineData layout")
    }

    @Test func layerKindsAndSmartObjects() throws {
        var kinds: [PSDLayerKind: Int] = [:]
        var smart = 0, resolvedTransforms = 0, withSource = 0, linked = 0
        for url in Corpus.files {
            let f = try PSDFile(contentsOf: url)
            linked += f.linkedFiles.count
            for (i, l) in f.layers.enumerated() {
                kinds[l.kind, default: 0] += 1
                if let so = f.smartObject(layer: i) {
                    smart += 1
                    if so.transform?.count == 8 { resolvedTransforms += 1 }
                    if so.linkedFile != nil { withSource += 1 }
                    #expect(!so.uniqueID.isEmpty)
                }
                if l.kind == .shape {
                    #expect(l.vectorMask != nil && l.fill != nil)
                }
                if let fx = l.objectEffects { _ = fx.effects }
            }
        }
        print("KINDS \(kinds.sorted { "\($0.key)" < "\($1.key)" }.map { "\($0.key):\($0.value)" }); smart objects \(smart) (\(resolvedTransforms) with transforms, \(withSource) with their source file resolved; \(linked) linked-file items)")
        #expect(smart > 0 && smart == resolvedTransforms)
    }

    @Test func thumbnailsDecodeWithImageIO() throws {
        var n = 0
        for url in Corpus.files {
            let f = try PSDFile(contentsOf: url)
            guard case let .thumbnail(t)? = f.resource(PSDResourceID.thumbnail)?.typed else { continue }
            guard let src = CGImageSourceCreateWithData(t.imageData as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                Issue.record("thumbnail of \(url.lastPathComponent) does not decode")
                continue
            }
            #expect(img.width == Int(t.width) && img.height == Int(t.height))
            n += 1
        }
        print("THUMBNAILS decoded: \(n)")
    }
}

@Suite struct TypedBlockSyntheticTests {
    @Test func engineDataSyntax() throws {
        let sample = Data("\n\n<<\n\t/EngineDict\n\t<<\n\t\t/Editor\n\t\t<<\n\t\t\t/Text (\u{FE}\u{FF}\u{0}H\u{0}i\u{0}\\)\u{0}\r)\n\t\t>>\n\t\t/Nums [ 1.0 .5 -2 0 ]\n\t\t/Flag true\n\t\t/Kind /Roman\n\t\t/Runs [\n\t\t<<\n\t\t\t/A 1\n\t\t>>\n\t\t]\n\t>>\n>>".unicodeScalars.map { UInt8($0.value) })
        let v = try PSDEngineData.parse(sample)
        #expect(v.path("EngineDict", "Editor", "Text")?.string == "Hi)\r")
        #expect(v.path("EngineDict", "Nums")?.array?.compactMap(\.double) == [1, 0.5, -2, 0])
        #expect(v.path("EngineDict", "Flag")?.bool == true)
        #expect(v.path("EngineDict", "Kind") == .name("Roman"))
        #expect(v.path("EngineDict", "Runs", "0", "A")?.int == 1)
        let bytes = v.serialized()
        #expect(try PSDEngineData.parse(bytes) == v)
        #expect(try PSDEngineData.parse(bytes).serialized() == bytes)
        #expect(String(decoding: bytes, as: UTF8.self).contains("/Runs [\n"), "arrays open on the key's line, like Photoshop")
        for cut in 0 ..< sample.count { _ = try? PSDEngineData.parse(sample.prefix(cut)) }
        #expect(throws: PSDError.self) { try PSDEngineData.parse(Data("<< /A".utf8)) }
        #expect(throws: PSDError.self) { try PSDEngineData.parse(Data([UInt8](repeating: UInt8(ascii: "["), count: 200))) }
        #expect(try PSDEngineData.parse(Data("junk<< /A null /B <48 69> >>".utf8)) == .dict([.init("A", .null), .init("B", .hex([0x48, 0x69]))]))
        #expect(PSDEngineData.formatReal(1) == "1.0" && PSDEngineData.formatReal(0.5) == ".5" && PSDEngineData.formatReal(-0.25) == "-.25")
        #expect(PSDEngineData.formatReal(12.125) == "12.125" && PSDEngineData.formatReal(0.000004) == "0.0")
    }

    @Test func typeToolRoundTrip() throws {
        let e = PSDEngineData.dict([.init("EngineDict", .dict([.init("Editor", .dict([.init("Text", .string("Hello\r"))]))]))])
        var text = PSDDescriptor(classID: "TxLr").with("Txt ", .text(.nulTerminated("Hello")))
        text = text.with("EngineData", .rawData(e.serialized()))
        let t = PSDTypeTool(transform: [1, 0, 0, 1, 10, 20], text: text, bounds: [0, -10, 40, 2])
        let back = try PSDTypeTool(bytes: t.serialized())
        #expect(back == t)
        #expect(back.string == "Hello" && back.engineData == e && back.bounds == [0, -10, 40, 2])
        #expect(back.translated(dx: 5, dy: -5).transform == [1, 0, 0, 1, 15, 15])
        #expect(!back.engineTextIsBlank)
    }

    @Test func legacyEffectsRecords() throws {
        var w = ByteWriter()
        w.u32(0); w.u32(5 << 16); w.u32(75 << 16); w.u32(120 << 16); w.u32(4 << 16)
        PSDColorRecord(space: 0, components: [0xFF00, 0, 0, 0]).write(&w)
        w.fourCC("8BIM"); w.fourCC("mul "); w.u8(1); w.u8(1); w.u8(191)
        let fx = PSDLegacyEffects(entries: [.init(key: "cmnS", data: Data([0, 0, 0, 0, 1, 0, 0])), .init(key: "dsdw", data: w.data)])
        let back = try PSDLegacyEffects(bytes: fx.serialized())
        #expect(back == fx)
        #expect(back.entries[0].typed == .commonState(version: 0, visible: true))
        guard case let .dropShadow(s)? = back.entries[1].typed else { Issue.record("no shadow"); return }
        #expect(s.blur == 5 && s.angle == 120 && s.distance == 4 && s.blendMode == .multiply && s.enabled && s.opacity == 191)
    }

    @Test func objectEffectsView() throws {
        var d = PSDDescriptor().with("Scl ", .unitFloat(unit: "#Prc", value: 100)).with("masterFXSwitch", .boolean(true))
        d = d.with("DrSh", .descriptor(PSDDescriptor(classID: "DrSh").with("enab", .boolean(true)).with("Md  ", .enumerated(type: "BlnM", value: "Mltp"))
                .with("Clr ", .descriptor(PSDColor.rgb(red: 1, green: 0, blue: 0).descriptor)).with("Opct", .unitFloat(unit: "#Prc", value: 75))))
        d = d.with("solidFillMulti", .list([.descriptor(PSDDescriptor(classID: "SoFi").with("enab", .boolean(false)))]))
        let fx = PSDObjectEffects(d)
        let back = try PSDObjectEffects(bytes: fx.serialized())
        #expect(back == fx && back.isEnabled && back.scale == 100)
        #expect(back.effects.map(\.key) == ["DrSh", "solidFillMulti"])
        #expect(back.effects[0].blendMode == .multiply && back.effects[0].opacity == 0.75 && back.effects[0].color == .rgb(red: 1, green: 0, blue: 0))
        #expect(!back.effects[1].isEnabled)
    }

    @Test func colorsAndFills() throws {
        for c in [PSDColor.rgb(red: 0.2, green: 0.4, blue: 0.6), .hsb(hue: 120, saturation: 0.5, brightness: 0.25), .cmyk(cyan: 0.1, magenta: 0.2, yellow: 0.3, black: 0.4),
                  .lab(l: 50, a: -20, b: 30), .gray(0.3)] {
            let back = PSDColor(descriptor: c.descriptor)
            #expect(back != nil)
            if let back, case let (r1, g1, b1)? = back.approximateRGB, case let (r2, g2, b2)? = c.approximateRGB {
                #expect(abs(r1 - r2) < 1e-9 && abs(g1 - g2) < 1e-9 && abs(b1 - b2) < 1e-9)
            }
        }
        let soco = PSDFillSetting.solid(.rgb(red: 1, green: 0.5, blue: 0))
        let f = try PSDFillSetting(key: "SoCo", bytes: soco.data)
        #expect(f.solidColor == .rgb(red: 1, green: 0.5, blue: 0))
        let grad = PSDDescriptor(classID: "Grdn").with("Nm  ", .text("G")).with("GrdF", .enumerated(type: "GrdF", value: "CstS")).with("Intr", .double(4096))
            .with("Clrs", .list([.descriptor(PSDDescriptor(classID: "Clrt").with("Clr ", .descriptor(PSDColor.gray(0).descriptor)).with("Type", .enumerated(type: "Clry", value: "UsrS"))
                    .with("Lctn", .integer(0)).with("Mdpn", .integer(50))),
                .descriptor(PSDDescriptor(classID: "Clrt").with("Clr ", .descriptor(PSDColor.gray(1).descriptor)).with("Type", .enumerated(type: "Clry", value: "UsrS"))
                    .with("Lctn", .integer(4096)).with("Mdpn", .integer(50)))]))
            .with("Trns", .list([.descriptor(PSDDescriptor(classID: "TrnS").with("Opct", .unitFloat(unit: "#Prc", value: 100)).with("Lctn", .integer(0)).with("Mdpn", .integer(50)))]))
        let gd = PSDFillSetting(key: "GdFl", descriptor: PSDDescriptor().with("Grad", .descriptor(grad)).with("Angl", .unitFloat(unit: "#Ang", value: 90))
            .with("Type", .enumerated(type: "GrdT", value: "Lnr ")))
        let g = try PSDFillSetting(key: "GdFl", bytes: gd.serialized())
        #expect(g.gradient?.colorStops.count == 2 && g.gradient?.colorStops[1].location == 1 && g.gradient?.opacityStops[0].opacity == 1)
        #expect(g.angle == 90 && g.gradientType == "Lnr ")
    }

    @Test func adjustmentsRoundTrip() throws {
        var lv = ByteWriter(); lv.u16(2)
        for i in 0 ..< 29 { lv.u16(UInt16(i)); lv.u16(255 - UInt16(i)); lv.u16(0); lv.u16(255); lv.u16(100 + UInt16(i)) }
        lv.put(Array("Lvls".utf8)); lv.u16(3); lv.u16(29)
        var cv = ByteWriter(); cv.u8(0); cv.u16(1); cv.u32(0b101)
        cv.u16(2); cv.u16(0); cv.u16(0); cv.u16(255); cv.u16(255)
        cv.u16(3); cv.u16(0); cv.u16(10); cv.u16(128); cv.u16(140); cv.u16(255); cv.u16(250)
        cv.put(Array("Crv ".utf8)); cv.u16(4); cv.u32(0)
        var hue = ByteWriter(); hue.u16(2); hue.u8(0); hue.u8(0)
        for x: Int16 in [0, 25, 0, 10, -20, 5] { hue.i16(x) }
        for i in 0 ..< 6 { for x: Int16 in [Int16(i * 60 - 30), Int16(i * 60 - 15), Int16(i * 60 + 15), Int16(i * 60 + 30), 1, 2, 3] { hue.i16(x) } }
        var blnc = ByteWriter(); for x: Int16 in [1, 2, 3, 4, 5, 6, 7, 8, 9] { blnc.i16(x) }; blnc.u8(1); blnc.u8(0)
        var selc = ByteWriter(); selc.u16(1); selc.u16(0); for i in 0 ..< 40 { selc.i16(Int16(i % 7) - 3) }
        var mixr = ByteWriter(); mixr.u16(1); mixr.u16(0); for i in 0 ..< 15 { mixr.i16(Int16(i * 10)) }
        var phfl3 = ByteWriter(); phfl3.u16(3); phfl3.u32(24191); phfl3.u32(25002); phfl3.u32(3827); phfl3.u32(25); phfl3.u8(1)
        var phfl2 = ByteWriter(); phfl2.u16(2); PSDColorRecord(space: 0, components: [65535, 32768, 0, 0]).write(&phfl2); phfl2.u32(50); phfl2.u8(0)
        var grdm = ByteWriter(); grdm.u16(1); grdm.u8(0); grdm.u8(1); grdm.unicodeUnits(Array("Custom".utf16) + [0]); grdm.u16(2)
        for (l, v): (UInt32, UInt16) in [(0, 0), (4096, 65535)] { grdm.u32(l); grdm.u32(50); PSDColorRecord(space: 0, components: [v, v, v, 0]).write(&grdm); grdm.u16(0) }
        grdm.u16(2); for l: UInt32 in [0, 4096] { grdm.u32(l); grdm.u32(50); grdm.u16(255) }
        grdm.u16(2); grdm.u16(2048); grdm.u16(32); grdm.u16(0); grdm.u32(0); grdm.u16(0); grdm.u16(0); grdm.u32(2048); grdm.u16(3); grdm.zeros(16); grdm.u16(0)
        let blocks: [(FourCC, Data)] = [
            ("brit", PSDBrightnessContrast(brightness: 20, contrast: -10).serialized()), ("levl", lv.data), ("curv", cv.data), ("hue2", hue.data),
            ("blnc", blnc.data), ("selc", selc.data), ("mixr", mixr.data), ("phfl", phfl3.data), ("phfl", phfl2.data),
            ("expA", PSDExposure(exposure: 1.5, offset: -0.1, gamma: 0.9).serialized()), ("post", Data([0, 4, 0, 0])), ("thrs", Data([0, 128, 0, 0])),
            ("nvrt", Data()), ("grdm", grdm.data), ("vibA", PSDVersionedDescriptor(PSDDescriptor().with("vibrance", .integer(30))).serialized()),
            ("clrL", { var w = ByteWriter(); w.u16(1); PSDVersionedDescriptor(PSDDescriptor().with("LUTFormat", .enumerated(type: "LUTFormatType", value: "LUTFormatCUBE"))).write(&w); return w.data }()),
        ]
        for (key, data) in blocks {
            let a = try PSDAdjustment.parse(key: key, data: data)
            #expect(a != nil, "\(key)")
            #expect(a?.serialized() == data, "\(key) lossless")
        }
        guard case let .curves(c)? = try PSDAdjustment.parse(key: "curv", data: cv.data) else { return }
        #expect(c.curves.map(\.channel) == [0, 2] && c.curves[1].points.count == 3 && c.curves[1].points[1].input == 140 && c.tail.count == 10)
        guard case let .gradientMap(g)? = try PSDAdjustment.parse(key: "grdm", data: grdm.data) else { return }
        #expect(g.colorStops.count == 2 && g.dither && !g.reverse && g.smoothness == 0.5 && g.name.string == "Custom")
        guard case let .levels(l)? = try PSDAdjustment.parse(key: "levl", data: lv.data) else { return }
        #expect(l.records.count == 29 && l.records[3].gamma == 103 && l.tail.count == 8)
    }

    @Test func smartObjectBlocks() throws {
        let file = Data("pretend PSB bytes".utf8)
        let item = PSDLinkedFile.embedded(uniqueID: "abc-123", fileName: "inner.psb", fileType: "8BPB", data: file)
        let block = PSDLinkedFiles(items: [item, .embedded(uniqueID: "x", fileName: "y.png", fileType: "PNGf", data: Data([1, 2, 3]))])
        let back = try PSDLinkedFiles(bytes: block.serialized())
        #expect(back == block && back.serialized() == block.serialized())
        let info = back.file(uniqueID: "abc-123")
        #expect(info?.data == file && info?.fileName == "inner.psb" && info?.version == 7 && info?.lenient == false)
        try PSDTaggedBlock(key: "lnk2", data: block.serialized()).checkStructure()

        // A CS2-style item without the open-descriptor flag still resolves (lenient view).
        var cs2 = ByteWriter()
        cs2.fourCC("liFD"); cs2.u32(2); cs2.pascal(Array("old-id".utf8), align: 1); cs2.unicodeUnits(Array("a.psd".utf16))
        cs2.fourCC("8BPS"); cs2.fourCC("8BIM"); cs2.u64(4); cs2.put([9, 8, 7, 6])
        let legacy = PSDLinkedFile(raw: cs2.data)
        #expect(legacy.info?.data == Data([9, 8, 7, 6]) && legacy.info?.lenient == true)

        let placed = PSDPlacedLayerData(descriptor: PSDDescriptor().with("Idnt", .text("abc-123")).with("placed", .text("p-1"))
            .with("Trnf", .list([0, 0, 10, 0, 10, 5, 0, 5].map { .double($0) }))
            .with("Sz  ", .descriptor(PSDDescriptor(classID: "Pnt ").with("Wdth", .double(10)).with("Hght", .double(5)))))
        let pBack = try PSDPlacedLayerData(bytes: placed.serialized())
        #expect(pBack == placed && pBack.uniqueID == "abc-123" && pBack.placedID == "p-1" && pBack.size?.width == 10)
        try PSDTaggedBlock(key: "SoLd", data: placed.serialized()).checkStructure()
        let pl = PSDPlacedLayer(uniqueID: "abc-123", transform: [0, 0, 10, 0, 10, 5, 0, 5], warp: PSDVersionedDescriptor(PSDTypeTool.defaultWarp()))
        #expect(try PSDPlacedLayer(bytes: pl.serialized()) == pl)
        try PSDTaggedBlock(key: "PlLd", data: pl.serialized()).checkStructure()

        // A document whose smart object has only PlLd (CS2) resolves through the global block.
        var b = PSDBuilder(width: 2, height: 2)
        var s = PSDLayerSpec(name: "so", left: 0, top: 0, width: 2, height: 2, pixels: .u8([UInt8](repeating: 255, count: 16)))
        s.extraBlocks = [PSDTaggedBlock(key: "PlLd", data: pl.serialized())]
        b.pushLayer(s)
        var f = try b.build()
        f.globalBlocks.append(PSDTaggedBlock(key: "lnkD", data: PSDLinkedFiles(items: [item]).serialized()))
        let g = try PSDFile(data: try f.serialized())
        let so = g.smartObject(layer: 0)
        #expect(so?.uniqueID == "abc-123" && so?.linkedFile?.data == file && so?.transform?.count == 8 && so?.placedData == nil)
        #expect(g.layers[0].kind == .smartObject)
    }

    @Test func vectorBlocks() throws {
        let origin = PSDDescriptor().with("keyDescriptorList", .list([.descriptor(PSDDescriptor()
                .with("keyOriginType", .integer(2))
                .with("keyOriginRRectRadii", .descriptor(PSDDescriptor(classID: "radii").with("topLeft", .unitFloat(unit: "#Pxl", value: 4))
                    .with("topRight", .unitFloat(unit: "#Pxl", value: 4)).with("bottomRight", .unitFloat(unit: "#Pxl", value: 4)).with("bottomLeft", .unitFloat(unit: "#Pxl", value: 4))))
                .with("keyOriginShapeBBox", .descriptor(PSDDescriptor(classID: "unitRect").with("Top ", .unitFloat(unit: "#Pxl", value: 1))
                    .with("Left", .unitFloat(unit: "#Pxl", value: 2)).with("Btom", .unitFloat(unit: "#Pxl", value: 11)).with("Rght", .unitFloat(unit: "#Pxl", value: 12)))))]))
        let vogk = PSDHeaderedDescriptor(header: 1, descriptor: origin)
        #expect(try PSDHeaderedDescriptor(bytes: vogk.serialized()) == vogk)
        let stroke = PSDVersionedDescriptor(PSDDescriptor(classID: "strokeStyle").with("strokeEnabled", .boolean(true)).with("fillEnabled", .boolean(true))
            .with("strokeStyleLineWidth", .unitFloat(unit: "#Pnt", value: 3))
            .with("strokeStyleContent", .descriptor(PSDDescriptor(classID: "solidColorLayer").with("Clr ", .descriptor(PSDColor.rgb(red: 0, green: 0, blue: 1).descriptor)))))
        var rec = PSDLayerRecord(blocks: [
            PSDTaggedBlock(key: "vsms", data: PSDVectorMask(path: PSDPathData(subpaths: PathSliceEffectsMetadataTests.sampleSubpaths(), initialFill: false)).serialized()),
            PSDTaggedBlock(key: "vogk", data: vogk.serialized()),
            PSDTaggedBlock(key: "vstk", data: stroke.serialized()),
            PSDTaggedBlock(key: "vscg", data: PSDHeaderedDescriptor(header: FourCC("SoCo").rawValue, descriptor: PSDDescriptor().with("Clr ", .descriptor(PSDColor.gray(0.5).descriptor))).serialized()),
        ])
        #expect(rec.kind == .shape)
        #expect(rec.vectorMask?.path.subpaths.count == 2)
        #expect(rec.shapeOriginations.first?.originType == 2 && rec.shapeOriginations.first?.cornerRadii == [4, 4, 4, 4])
        #expect(rec.shapeOriginations.first?.boundingBox?.right == 12)
        #expect(rec.vectorStroke?.strokeEnabled == true && rec.vectorStroke?.lineWidth == 3 && rec.vectorStroke?.color == .rgb(red: 0, green: 0, blue: 1))
        #expect(rec.fill?.key == "SoCo" && rec.fill?.solidColor == .gray(0.5))
        rec.blocks.append(PSDTaggedBlock(key: "brst", bytes: [0, 0, 0, 1, 0, 0, 0, 2]))
        #expect(rec.blendingRestrictions == [1, 2])
    }
}
