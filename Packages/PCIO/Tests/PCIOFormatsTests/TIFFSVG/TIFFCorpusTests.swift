// The layered-TIFF transcoder against the 36-file Photoshop corpus (`PCPSD_CORPUS`, skipped when
// absent), and PCPSD's public layer-info body reader/writer (which the transcoder uses) against
// PCPSD's own PSD writer.
// Mirrors the intent of photocraft-io crates/io/tests/tiff_corpus.rs (MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors) at the PSD-model level: that test needs the
// document importer/exporter, this one checks the transcoder underneath it.

import Foundation
import PCPSD
import Testing
@testable import PCIOFormats

private typealias TIFFCorpusISD = PSDTIFF.ImageSourceData

/// The layer-info body PCPSD writes into a PSD's layer and mask section, padding included.
private func tiffPCPSDLayerInfoBody(_ file: PSDFile) throws -> [UInt8]? {
    guard file.layerInfo != nil else { return nil }
    var f = file
    f.layerInfoPlacement = .section
    let b = [UInt8](try f.serialized())
    func u32(_ at: Int) -> Int { Int(UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])) }
    func u64(_ at: Int) -> Int { u32(at) << 32 | u32(at + 4) }
    let long = file.header.version.isPSB
    var at = 26
    at += 4 + u32(at)
    at += 4 + u32(at)
    at += long ? 8 : 4
    let n = long ? u64(at) : u32(at)
    at += long ? 8 : 4
    return Array(b[at ..< at + n])
}

/// `info` without padding, for comparisons across containers.
private func tiffUnpadded(_ info: PSDLayerInfo?) -> PSDLayerInfo? {
    guard var i = info else { return nil }
    i.padding = nil
    return i
}

/// Blocks with the default (zero, ≤ 3 bytes) padding tiffNormalised, as a TIFF stores them.
private func tiffNormalised(_ blocks: [PSDTaggedBlock]) -> [PSDTaggedBlock] {
    blocks.map { b in
        var b = b
        if let p = b.padding, p.count <= 3, p.allSatisfy({ $0 == 0 }) { b.padding = nil }
        return b
    }
}

/// Keys named in "<key> block (…) dropped" warnings.
private func tiffDroppedKeys(_ warnings: [String]) -> Set<FourCC> {
    Set(warnings.compactMap { w in w.range(of: " block (").map { FourCC(String(w[..<$0.lowerBound])) } })
}

/// `info` without layer blocks whose key is in `keys`.
private func tiffWithout(_ keys: Set<FourCC>, _ info: PSDLayerInfo?) -> PSDLayerInfo? {
    guard var i = tiffUnpadded(info) else { return nil }
    for k in i.layers.indices { i.layers[k].blocks.removeAll { keys.contains($0.key) } }
    return i
}

@Suite struct TIFFCorpusTests {
    /// The public layer-info body writer the transcoder uses produces the bytes of PCPSD's PSD
    /// writer exactly (generated files), and the public reader reads them back.
    @Test func layerInfoWriterMatchesPCPSD() throws {
        var checked = 0
        for c in TIFFTestGen.allCases() {
            guard let info = c.file.layerInfo, let body = try tiffPCPSDLayerInfoBody(c.file) else { continue }
            let w = [UInt8](try info.serializedUnpaddedBody(version: c.file.header.version))
            #expect(body.starts(with: w), "\(c.name)")
            #expect(body.count - w.count <= 3, "\(c.name)")
            // And the reader reads PCPSD's body back to the model.
            #expect(tiffUnpadded(try PSDLayerInfo(body: Data(body), version: c.file.header.version)) == tiffUnpadded(info), "\(c.name)")
            checked += 1
        }
        #expect(checked > 30)
    }

    /// Every corpus PSD → `fromPSD` → `toBytes` in both byte orders → `fromBytes` → `intoPSD`
    /// gives the original layer info and blocks back (the little-endian path minus the blocks it
    /// reports dropped), and the private writer matches PCPSD's on real files.
    @Test(.enabled(if: TIFFCorpus.directory != nil, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)"))
    func corpusRoundTripsThroughBothByteOrders() throws {
        var files = 0, bigEqual = 0, littleEqual = 0, writerEqual = 0, littleLossless = 0
        var dropped: [String: Int] = [:]
        var layers = 0, layerBlocks = 0, globalBlocks = 0
        for url in TIFFCorpus.files {
            let name = url.lastPathComponent
            let file = try PSDFile(data: try Data(contentsOf: url))
            files += 1
            layers += file.layers.count
            layerBlocks += file.layers.reduce(0) { $0 + $1.blocks.count }
            globalBlocks += file.globalBlocks.count
            if let info = file.layerInfo, let body = try tiffPCPSDLayerInfoBody(file) {
                let w = [UInt8](try info.serializedUnpaddedBody(version: file.header.version))
                if body.starts(with: w), body.count - w.count <= 3 { writerEqual += 1 } else { Issue.record("\(name): layer-info writer differs") }
            } else {
                writerEqual += 1
            }
            let isd = TIFFCorpusISD.fromPSD(file)
            for order in PSDTIFF.ByteOrder.allCases {
                let (bytes, w) = try isd.toBytes(order)
                let (back, w2) = try TIFFCorpusISD.fromBytes(bytes)
                #expect(w2.isEmpty, "\(name) \(order): \(w2)")
                #expect(back.byteOrder == (bytes.count > 36 ? order : .big), "\(name)")
                let psd = back.intoPSD(header: file.header, resources: file.resources, imageData: file.imageData)
                let keys = tiffDroppedKeys(w)
                for k in keys { dropped[k.string, default: 0] += 1 }
                if order == .big {
                    #expect(w.isEmpty, "\(name): \(w)")
                    let ok = tiffUnpadded(psd.layerInfo) == tiffUnpadded(file.layerInfo) && psd.globalBlocks == tiffNormalised(file.globalBlocks)
                        && psd.globalLayerMask == file.globalLayerMask && psd.layerMaskTrailing == file.layerMaskTrailing
                        && psd.layerInfoPlacement == file.layerInfoPlacement
                    #expect(ok, "\(name): big-endian round trip differs")
                    if ok { bigEqual += 1 }
                    // The big-endian bytes are a fixed point.
                    let (again, _) = try back.toBytes(.big)
                    #expect(again == bytes, "\(name): big-endian bytes not stable")
                } else {
                    #expect(w.allSatisfy { $0.contains(" block (") }, "\(name): \(w)")
                    let ok = tiffWithout(keys, psd.layerInfo) == tiffWithout(keys, file.layerInfo)
                        && psd.globalBlocks == tiffNormalised(file.globalBlocks.filter { !keys.contains($0.key) })
                        && psd.globalLayerMask == file.globalLayerMask && psd.layerMaskTrailing == file.layerMaskTrailing
                    #expect(ok, "\(name): little-endian round trip differs")
                    if ok { littleEqual += 1 }
                    if ok, keys.isEmpty { littleLossless += 1 }
                    // A second generation is a fixed point.
                    let (again, _) = try back.toBytes(.little)
                    #expect(try TIFFCorpusISD.fromBytes(again).data.toBytes(.little).bytes == again, "\(name)")
                }
            }
        }
        print("TIFF corpus: \(files) files (\(layers) layers, \(layerBlocks) layer blocks, \(globalBlocks) global blocks); "
            + "big-endian equal \(bigEqual)/\(files), little-endian equal \(littleEqual)/\(files) (lossless \(littleLossless)), "
            + "layer-info writer = PCPSD \(writerEqual)/\(files); dropped on the little-endian path: \(dropped.sorted { $0.key < $1.key })")
        #expect(files == TIFFCorpus.files.count)
        #expect(bigEqual == files && littleEqual == files && writerEqual == files)
    }
}
