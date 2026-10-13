// The layered-TIFF container: the private-tag walk (photocraft-codecs `photoshop_tags`) in both
// byte orders, classic and BigTIFF, and the baseline writer checked against ImageIO, which must
// open every file it writes with the same pixels. Partly after photocraft-io
// crates/io/tests/tiff_layers.rs and tiff_pages.rs (the fixture builder), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import Foundation
import ImageIO
import PCFoundation
import PCIOCore
import PCPSD
import Testing
@testable import PCIOFormats

/// A TIFF (classic or BigTIFF, either order) with one 8-bit gray page per `(w, h, level)` and,
/// in IFD0, the given extra BYTE/UNDEFINED tags (after photocraft tiff_pages.rs `tiff`).
private func tiffHandMade(big: Bool, little: Bool, pages: [(UInt32, UInt32, UInt8)], extra: [(UInt16, UInt16, [UInt8])] = []) -> [UInt8] {
    func le(_ v: UInt64, _ n: Int) -> [UInt8] {
        let b = (0 ..< n).map { UInt8(v >> (8 * UInt64($0)) & 0xFF) }
        return little ? b : b.reversed()
    }
    var f: [UInt8] = little ? [0x49, 0x49] : [0x4D, 0x4D]
    if big { f += le(43, 2) + le(8, 2) + le(0, 2) + le(0, 8) } else { f += le(42, 2) + le(0, 4) }
    var nextField = big ? 8 : 4
    let width = big ? 8 : 4
    for (pi, (w, h, level)) in pages.enumerated() {
        let pixelsAt = UInt64(f.count)
        f += [UInt8](repeating: level, count: Int(w * h))
        if f.count % 2 == 1 { f.append(0) }
        var entries: [(UInt16, UInt16, UInt64, [UInt8])] = [
            (256, 4, 1, le(UInt64(w), 4)), (257, 4, 1, le(UInt64(h), 4)), (258, 3, 1, le(8, 2)), (259, 3, 1, le(1, 2)),
            (262, 3, 1, le(1, 2)), (273, 4, 1, le(pixelsAt, 4)), (277, 3, 1, le(1, 2)), (278, 4, 1, le(UInt64(h), 4)),
            (279, 4, 1, le(UInt64(w * h), 4)),
        ]
        var outOfLine: [(Int, [UInt8])] = []
        if pi == 0 {
            for (tag, type, data) in extra {
                if data.count <= width {
                    entries.append((tag, type, UInt64(data.count), data))
                } else {
                    outOfLine.append((entries.count, data))
                    entries.append((tag, type, UInt64(data.count), []))
                }
            }
        }
        for (i, data) in outOfLine {
            if f.count % 2 == 1 { f.append(0) }
            entries[i].3 = le(UInt64(f.count), width)
            f += data
        }
        entries.sort { $0.0 < $1.0 }
        if f.count % 2 == 1 { f.append(0) }
        let ifdAt = UInt64(f.count)
        f.replaceSubrange(nextField ..< nextField + width, with: le(ifdAt, width))
        f += le(UInt64(entries.count), big ? 8 : 2)
        for (tag, type, count, value) in entries {
            f += le(UInt64(tag), 2) + le(UInt64(type), 2) + le(count, big ? 8 : 4)
            f += value + [UInt8](repeating: 0, count: width - value.count)
        }
        nextField = f.count
        f += [UInt8](repeating: 0, count: width)
    }
    return f
}

/// Raw samples of ImageIO's decode of the first image, as stored (`CGImage` data provider).
private struct TIFFDecoded {
    var width: Int, height: Int, bitsPerComponent: Int, bitsPerPixel: Int, bytesPerRow: Int
    var info: CGBitmapInfo, alpha: CGImageAlphaInfo, model: CGColorSpaceModel
    var bytes: [UInt8]

    init?(_ data: [UInt8]) {
        guard let src = CGImageSourceCreateWithData(Data(data) as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary),
              let d = img.dataProvider?.data else { return nil }
        width = img.width; height = img.height; bitsPerComponent = img.bitsPerComponent; bitsPerPixel = img.bitsPerPixel
        bytesPerRow = img.bytesPerRow; info = img.bitmapInfo; alpha = img.alphaInfo; model = img.colorSpace?.model ?? .unknown
        bytes = [UInt8](d as Data)
    }

    /// Sample `c` of pixel (x, y) as a normalised float.
    func sample(_ x: Int, _ y: Int, _ c: Int) -> Float {
        let bpc = bitsPerComponent / 8
        let at = y * bytesPerRow + (x * bitsPerPixel / 8) + c * bpc
        let order = info.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        switch bpc {
        case 1: return Float(bytes[at]) / 255
        case 2:
            let lo = order == CGBitmapInfo.byteOrder16Little.rawValue
            let v = lo ? UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 : UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
            return Float(v) / 65535
        default:
            let lo = order == CGBitmapInfo.byteOrder32Little.rawValue
            let v = lo ? UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
                : UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
            return info.contains(.floatComponents) ? Float(bitPattern: v) : Float(v) / Float(UInt32.max)
        }
    }
}

/// A deterministic test image: a ramp per channel, alpha with transparent, partial and opaque.
private func tiffTestImage(_ mode: ColorMode, _ sample: SampleType, alpha: Bool, w: Int = 37, h: Int = 23) -> (LayeredTIFF.Image, [Float]) {
    let cc = mode == .cmyk ? 4 : mode == .grayscale ? 1 : 3
    let ch = cc + (alpha ? 1 : 0)
    var values: [Float] = []
    var bytes: [UInt8] = []
    for y in 0 ..< h {
        for x in 0 ..< w {
            for c in 0 ..< ch {
                var v: Float
                if alpha, c == cc {
                    v = [Float(1), 0.5, 1, 0.25, 1][(x + y) % 5]
                } else {
                    v = Float((x * 7 + y * 13 + c * 61) % 256) / 255
                }
                switch sample {
                case .u8:
                    let q = UInt8((v * 255).rounded())
                    bytes.append(q)
                    v = Float(q) / 255
                case .u16:
                    let q = UInt16((v * 65535).rounded())
                    bytes += [UInt8(q & 0xFF), UInt8(q >> 8)]
                    v = Float(q) / 65535
                case .f32:
                    bytes += withUnsafeBytes(of: v.bitPattern.littleEndian) { Array($0) }
                }
                values.append(v)
            }
        }
    }
    return (LayeredTIFF.Image(width: w, height: h, mode: mode, alpha: alpha, sample: sample, samples: bytes), values)
}

@Suite struct TIFFContainerTests {
    @Test func photoshopTagsInEveryContainerAndOrder() throws {
        let resources = Array("8BIM".utf8) + [3, 0xED, 0, 0, 0, 0, 0, 16] + [UInt8](repeating: 7, count: 16)
        let layers = PSDTIFF.signature + Array("8BIMPatt".utf8) + [0, 0, 0, 0]
        let xmp = Array("<x:xmpmeta xmlns:x='adobe:ns:meta/'/>".utf8)
        for big in [false, true] {
            for little in [false, true] {
                let bytes = tiffHandMade(big: big, little: little, pages: [(6, 4, 50), (3, 5, 90)],
                                     extra: [(34377, 1, resources), (37724, 7, layers), (700, 1, xmp)])
                let tags = try #require(LayeredTIFF.photoshopTags(bytes))
                #expect(tags.resources == resources && tags.layers == layers && tags.xmp == xmp, "big \(big) little \(little)")
                #expect(tags.byteOrder == (little ? .little : .big) && tags.bigTIFF == big)
                // Inline payloads (≤ 4 / 8 bytes) are read from the entry itself.
                let short = tiffHandMade(big: big, little: little, pages: [(2, 2, 9)], extra: [(34377, 7, [1, 2, 3])])
                #expect(LayeredTIFF.photoshopTags(short)?.resources == [1, 2, 3])
                #expect(LayeredTIFF.photoshopTags(short)?.layers == nil)
                // A tag of the wrong type reads as absent.
                let wrong = tiffHandMade(big: big, little: little, pages: [(2, 2, 9)], extra: [(37724, 3, [1, 2, 3, 4, 5, 6])])
                #expect(LayeredTIFF.photoshopTags(wrong)?.layers == nil)
                // ImageIO opens the hand-made file (BigTIFF included) as its first page.
                let d = try #require(TIFFDecoded(bytes), "ImageIO cannot open big \(big) little \(little)")
                #expect(d.width == 6 && d.height == 4)
            }
        }
        #expect(LayeredTIFF.photoshopTags(Array("\u{89}PNG\r\n\u{1A}\n".utf8)) == nil)
        #expect(LayeredTIFF.photoshopTags([]) == nil)
    }

    @Test func malformedContainersReadAsAbsentWithoutTrapping() {
        let layers = PSDTIFF.signature + [UInt8](repeating: 1, count: 40)
        for big in [false, true] {
            let bytes = tiffHandMade(big: big, little: true, pages: [(6, 4, 50)], extra: [(37724, 7, layers)])
            for cut in 0 ..< bytes.count { _ = LayeredTIFF.photoshopTags(Array(bytes[..<cut])) }
            for i in 0 ..< bytes.count {
                var b = bytes
                b[i] ^= 0xFF
                _ = LayeredTIFF.photoshopTags(b)
            }
            // A count pointing far past the end.
            var b = bytes
            if let r = b.tiffRange(of: [0x5C, 0x93]) { b.replaceSubrange(r.upperBound + 2 ..< r.upperBound + 6, with: [0xFF, 0xFF, 0xFF, 0x7F]) }
            #expect(LayeredTIFF.photoshopTags(b)?.layers == nil)
        }
    }

    /// Every layout the writer supports opens in ImageIO with the same samples; the tags read back.
    @Test func writtenFilesOpenInImageIOWithTheSamePixels() throws {
        var opened: [String] = [], refused: [String] = []
        for mode in [ColorMode.grayscale, .rgb, .cmyk] {
            for sample in [SampleType.u8, .u16, .f32] {
                for alpha in [false, true] {
                    let (image0, values) = tiffTestImage(mode, sample, alpha: alpha)
                    for compression in LayeredTIFF.Compression.allCases {
                        for order in PSDTIFF.ByteOrder.allCases {
                            for big in [false, true] {
                                var image = image0
                                image.dpi = (300, 150)
                                image.iccProfile = nil
                                image.xmp = Array("<x:xmpmeta xmlns:x='adobe:ns:meta/'/>".utf8)
                                image.photoshopResources = [UInt8](repeating: 3, count: 9)
                                image.photoshopLayers = PSDTIFF.signature + [1, 2, 3]
                                image.text = [(305, "PhotoCraft"), (315, "artist é")]
                                let name = "\(mode) \(sample) alpha \(alpha) \(compression) \(order) big \(big)"
                                let bytes = try LayeredTIFF.write(image, options: .init(compression: compression, byteOrder: order, bigTIFF: big))
                                let tags = try #require(LayeredTIFF.photoshopTags(bytes), "\(name)")
                                #expect(tags.layers == image.photoshopLayers && tags.resources == image.photoshopResources && tags.xmp == image.xmp, "\(name)")
                                #expect(tags.byteOrder == order && tags.bigTIFF == big, "\(name)")
                                guard let d = TIFFDecoded(bytes) else {
                                    if compression == .none, order == .little, !big { refused.append("\(mode) \(sample)\(alpha ? " +alpha" : "")") }
                                    continue
                                }
                                if compression == .none, order == .little, !big { opened.append("\(mode) \(sample)\(alpha ? " +alpha" : "")") }
                                #expect(d.width == image.width && d.height == image.height, "\(name)")
                                let ch = image.channels
                                // RGB 8-bit comes back as RGBX (alpha "none, skip last").
                                let skip = d.alpha == .noneSkipLast || d.alpha == .noneSkipFirst
                                let dch = d.bitsPerPixel / d.bitsPerComponent - (skip ? 1 : 0)
                                let premultiplied = d.alpha == .premultipliedLast || d.alpha == .premultipliedFirst
                                let alphaFirst = d.alpha == .premultipliedFirst || d.alpha == .first || d.alpha == .noneSkipFirst
                                var worst: Float = 0
                                for y in 0 ..< image.height {
                                    for x in 0 ..< image.width {
                                        let a = alpha ? values[(y * image.width + x) * ch + ch - 1] : 1
                                        for c in 0 ..< min(ch, dch) {
                                            let isAlpha = alpha && c == ch - 1
                                            let dc = alphaFirst ? (isAlpha ? 0 : c + 1) : c
                                            var want = values[(y * image.width + x) * ch + c]
                                            if premultiplied, !isAlpha { want *= a }
                                            worst = max(worst, abs(d.sample(x, y, dc) - want))
                                        }
                                    }
                                }
                                let tolerance: Float = sample == .u8 ? 1.0 / 255 + 1e-6 : sample == .u16 ? 1.0 / 65535 + 1e-6 : 1e-6
                                #expect(dch == ch, "\(name): ImageIO gives \(dch) channels for \(ch)")
                                #expect(worst <= tolerance, "\(name): worst sample difference \(worst)")
                            }
                        }
                    }
                }
            }
        }
        print("ImageIO opens: \(opened.joined(separator: ", ")); refuses: \(refused.isEmpty ? "none" : refused.joined(separator: ", "))")
    }

    @Test func resolutionAndProfileReachImageIO() throws {
        var (image, _) = tiffTestImage(.rgb, .u8, alpha: false, w: 8, h: 4)
        image.dpi = (300, 150)
        let profile = try #require(CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData()).map { [UInt8]($0 as Data) }
        image.iccProfile = profile
        let bytes = try LayeredTIFF.write(image)
        let decoded = try ImageIOCodec().decode(bytes)
        #expect(decoded.dpi?.x == 300 && decoded.dpi?.y == 150)
        #expect(decoded.iccProfile == profile)
        let contents = try LayeredTIFF.read(bytes)
        #expect(contents.image.width == 8 && contents.tags.layers == nil)
    }

    @Test func layerDataSurvivesTheContainerInBothOrders() throws {
        // A layered file's tags go out and come back unchanged, in the order the container says
        // (without the generator's planted blocks of unknown layout, which a little-endian file
        // cannot hold).
        var file = TIFFTestGen.layered(.psd, .rgb, 8, .rle)
        for i in file.layers.indices { file.layers[i].blocks.removeAll { ["zOdd", "zNop"].contains($0.key) } }
        let isd = PSDTIFF.ImageSourceData.fromPSD(file)
        let resources = try PSDTIFF.resourcesToBytes(file.resources)
        for order in PSDTIFF.ByteOrder.allCases {
            let (layers, w0) = try isd.toBytes(order)
            #expect(w0.isEmpty, "\(w0)")
            var (image, _) = tiffTestImage(.rgb, .u8, alpha: true, w: 24, h: 16)
            image.photoshopLayers = layers
            image.photoshopResources = resources
            let bytes = try LayeredTIFF.write(image, options: .init(byteOrder: order))
            let tags = try #require(LayeredTIFF.photoshopTags(bytes))
            #expect(tags.byteOrder == order)
            let (back, w) = try PSDTIFF.ImageSourceData.fromBytes(try #require(tags.layers))
            #expect(w.isEmpty)
            #expect(back.byteOrder == order)
            #expect(try back.toBytes(order).bytes == layers)
            #expect(try PSDTIFF.resourcesFromBytes(try #require(tags.resources)).resources == file.resources)
        }
    }

    /// Advanced Blending (`knko`, `infx`, `clbl`, `tsly`, `lmgm`, `vmgm`), fill opacity (`iOpa`),
    /// channel restrictions (`brst`) and Blend If (the records' blending ranges) survive a layered
    /// TIFF with its layer data in either byte order: the writer's own, and the other one made by
    /// transcoding the tag (the same length, spliced in place). After photocraft-io
    /// tiff_layers.rs `advanced_blending_survives_layered_tiff_in_both_byte_orders`, at the PSD
    /// model level.
    @Test func layerDataSplicedInTheOtherOrderReadsTheSame() throws {
        for depth: UInt16 in [8, 16, 32] {
            var file = TIFFTestGen.layered(.psd, .rgb, depth, depth == 8 ? .rle : .zipPrediction)
            for i in file.layers.indices { file.layers[i].blocks.removeAll { ["zOdd", "zNop"].contains($0.key) } }
            file.layers[1].blocks += [.knockout(2), .blendInteriorElements(true), .blendClippedAsGroup(false), .transparencyShapes(false),
                                      .layerMaskHidesEffects(true), .vectorMaskHidesEffects(true), .fillOpacity(64),
                                      PSDTaggedBlock(key: "brst", bytes: [0, 0, 0, 2])]
            file.layers[1].blendingRanges.data = [10, 40, 200, 250, 0, 0, 128, 128] + [UInt8](repeating: 0, count: 32)
            let isd = PSDTIFF.ImageSourceData.fromPSD(file)
            for native in PSDTIFF.ByteOrder.allCases {
                let other: PSDTIFF.ByteOrder = native == .little ? .big : .little
                let (layers, w) = try isd.toBytes(native)
                #expect(w.isEmpty, "\(w)")
                var (image, _) = tiffTestImage(.rgb, .u8, alpha: true, w: 24, h: 16)
                image.photoshopLayers = layers
                let bytes = try LayeredTIFF.write(image, options: .init(byteOrder: native))
                let (swapped, w2) = try PSDTIFF.ImageSourceData.fromBytes(layers).data.toBytes(other)
                #expect(w2.isEmpty, "depth \(depth): blocks dropped while transcoding: \(w2)")
                #expect(swapped.count == layers.count)
                let at = try #require(bytes.tiffRange(of: layers))
                var flipped = bytes
                flipped.replaceSubrange(at, with: swapped)
                for (order, file2) in [(native, bytes), (other, flipped)] {
                    let tags = try #require(LayeredTIFF.photoshopTags(file2))
                    let (back, w3) = try PSDTIFF.ImageSourceData.fromBytes(try #require(tags.layers))
                    #expect(w3.isEmpty)
                    #expect(back.byteOrder == order, "depth \(depth)")
                    var a = back, b = isd
                    a.byteOrder = .big
                    a.layerInfo?.padding = nil
                    b.layerInfo?.padding = nil
                    #expect(a == b, "depth \(depth) \(order)")
                    #expect(back.layerInfo?.layers[1].blendingRanges == file.layers[1].blendingRanges)
                    // ImageIO still opens the composite.
                    #expect(TIFFDecoded(file2)?.width == 24)
                }
            }
        }
    }

    /// Damaged layer data fails to parse (the importer then opens the composite flat), and no
    /// truncation or bit flip of a layered TIFF traps in the tag walk, the transcoder or ImageIO.
    /// After photocraft-io tiff_layers.rs `damaged_layer_data_opens_flattened`.
    @Test func damagedLayeredTIFFsNeverTrap() throws {
        var file = TIFFTestGen.layered(.psd, .rgb, 8, .rle)
        for i in file.layers.indices { file.layers[i].blocks.removeAll { ["zOdd", "zNop"].contains($0.key) } }
        for order in PSDTIFF.ByteOrder.allCases {
            let (layers, _) = try PSDTIFF.ImageSourceData.fromPSD(file).toBytes(order)
            var (image, _) = tiffTestImage(.rgb, .u8, alpha: false, w: 24, h: 16)
            image.photoshopLayers = layers
            image.photoshopResources = try PSDTIFF.resourcesToBytes(file.resources)
            let bytes = try LayeredTIFF.write(image, options: .init(byteOrder: order))
            let at = try #require(bytes.tiffRange(of: layers))
            // Garbage after the signature: no layers.
            var bad = bytes
            for i in at.lowerBound + 36 ..< at.lowerBound + 60 { bad[i] ^= 0xA5 }
            let tags = try #require(LayeredTIFF.photoshopTags(bad))
            #expect(throws: (any Error).self) { try PSDTIFF.ImageSourceData.fromBytes(try #require(tags.layers)) }
            #expect((try? ImageIOCodec().decode(bad)) != nil, "the composite still opens")
            func poke(_ b: [UInt8]) {
                if let t = LayeredTIFF.photoshopTags(b) {
                    if let l = t.layers { _ = try? PSDTIFF.ImageSourceData.fromBytes(l) }
                    if let r = t.resources { _ = try? PSDTIFF.resourcesFromBytes(r) }
                }
                _ = try? ImageIOCodec().decode(b)
            }
            for cut in stride(from: 0, to: bytes.count, by: 97) { poke(Array(bytes[..<cut])) }
            for i in stride(from: 0, to: bytes.count, by: 89) {
                var b = bytes
                b[i] ^= 0x5A
                poke(b)
            }
        }
    }

    @Test func straightAlphaReachesImageIO() throws {
        // A translucent red pixel keeps its colour under the alpha (not matted, not premultiplied).
        let image = LayeredTIFF.Image(width: 4, height: 4, mode: .rgb, alpha: true, sample: .u8,
                                      samples: [UInt8](repeating: 0, count: 0) + Array([[UInt8]](repeating: [255, 0, 0, 128], count: 16).joined()))
        let d = try #require(TIFFDecoded(try LayeredTIFF.write(image)))
        #expect(d.alpha == .last)
        #expect(Array(d.bytes.prefix(4)) == [255, 0, 0, 128])
    }

    @Test func refusesWhatItCannotWrite() {
        let (image, _) = tiffTestImage(.rgb, .u8, alpha: false, w: 4, h: 4)
        var lab = image
        lab.mode = .lab
        #expect(throws: PCIOError.self) { try LayeredTIFF.write(lab) }
        var short = image
        short.samples.removeLast()
        #expect(throws: PCIOError.self) { try LayeredTIFF.write(short) }
        var empty = image
        empty.width = 0
        #expect(throws: PCIOError.self) { try LayeredTIFF.write(empty) }
    }
}
