// Multichannel documents ⇄ PSD colour mode 7.
// Port of photocraft-io (crates/io/src/multichannel_map.rs), MIT OR Apache-2.0, © ArtCraft Team
// and the PhotoCraft contributors.
//
// A Multichannel document has no layers: its image is a set of ink (spot) channels, stored in
// `Document.channels` with ink density as the value (1 = solid ink, like every spot channel). A
// PSD stores the same planes as Photoshop shows them in the Channels panel: 0 (black) = solid ink,
// max = paper. Channel names come from resources 1006 / 1045 and ink colours from DisplayInfo
// (1077), exactly as for spot channels in the other modes.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCIOMaps
import PCPSD

enum Multichannel {
    /// Grid and guides.
    static let gridAndGuides: UInt16 = 1032
    /// Alpha identifiers: one u32 per extra channel.
    static let alphaIdentifiers: UInt16 = 1053
    /// Resources that only describe layers: target layer (1024), layer groups (1026), layer
    /// selection ids (1069) and layer groups enabled (1072).
    static let layerOnlyResources: [UInt16] = [PSDResourceID.layerState, PSDResourceID.layerGroupInfo, 1069, 1072]

    /// Fills `doc` (already in Multichannel mode at the file depth) from the merged planes `all`.
    static func importChannels(_ file: PSDFile, _ all: [UInt8], _ doc: inout Document, _ names: [String], _ warnings: inout [String]) {
        let h = file.header
        let depth = doc.depth
        let (w, hh) = (Int(h.width), Int(h.height))
        let n = w * hh
        let plane = h.rowBytes * hh
        let canvas = PixelRect(x0: 0, y0: 0, x1: Int32(clamping: h.width), y1: Int32(clamping: h.height))
        let fmt = PixelFormat(mode: .grayscale, sample: depth, alpha: false)
        for k in 0 ..< Int(h.channels) {
            guard (k + 1) * plane <= all.count else {
                warnings.append("multichannel: channel \(k + 1) is missing")
                break
            }
            let p = Array(all[k * plane ..< (k + 1) * plane])
            let vals: [Float] = (0 ..< n).map { 1 - PSDPixels.decodeBE(p, $0, depth) }
            var s = Surface(format: fmt)
            s.writeRegion(canvas, vals)
            s.prune()
            let name = k < names.count && !names[k].isEmpty ? names[k] : "Channel \(k + 1)"
            // Without DisplayInfo the channels print in black, as Photoshop shows them.
            var a = AlphaChannel(name: name, surface: s)
            a.spot = SpotInk(color: .black, solidity: 0)
            doc.channels.append(a)
        }
        if let r = file.resource(ChannelMap.displayInfo) {
            ChannelMap.applyDisplayInfo([UInt8](r.data), true, 0, &doc.channels)
        } else if let r = file.resource(ChannelMap.displayInfoOld) {
            ChannelMap.applyDisplayInfo([UInt8](r.data), false, 0, &doc.channels)
        }
    }

    /// Writes a Multichannel document as a mode-7 PSD (no layer section; every channel a plane).
    static func documentToPSD(_ doc: Document, options: PSDExportOptions) -> (file: PSDFile, warnings: [String]) {
        var warnings: [String] = []
        // Photoshop's Multichannel mode is 8 or 16 bits per channel.
        var sample = doc.depth
        if sample == .f32 {
            warnings.append("32-bit Multichannel written as 16 bits/channel (32-bit Multichannel isn't supported)")
            sample = .u16
        }
        if !doc.layers.isEmpty { warnings.append("Multichannel documents have no layers: the layers were not written") }
        let canvas = doc.bounds
        let channels = Array(doc.channels.prefix(56))
        if doc.channels.count > 56 { warnings.append("only 56 channels fit in PSD; the rest were dropped") }
        var planes: [UInt8] = []
        if channels.isEmpty {
            // A PSD needs at least one channel: an empty (paper) plane.
            for _ in 0 ..< canvas.area { PSDPixels.encodeBE(1, sample, &planes) }
        }
        for ch in channels {
            let v = ch.surface.readRegion(canvas)
            let k = ch.surface.channels
            for i in stride(from: 0, to: v.count, by: k) { PSDPixels.encodeBE(1 - v[i], sample, &planes) }
        }
        let big = doc.size.width > 30_000 || doc.size.height > 30_000
        let sizeExceeds = !options.forcePSB && !big && PSDExport.psdSizeExceedsLimit(doc)
        let version = PSDExport.psdVersion(doc, forcePSB: options.forcePSB, sizeExceedsLimit: sizeExceeds)
        if big && !options.forcePSB {
            warnings.append("document exceeds 30000 px; written as PSB")
        } else if sizeExceeds && !options.forcePSB {
            warnings.append("estimated encoded size exceeds 2 GB; written as PSB")
        }
        let header = PSDHeader(version: version, width: UInt32(doc.size.width), height: UInt32(doc.size.height), channels: UInt16(max(1, channels.count)),
                               depth: PSDPixels.psdDepth(sample), colorMode: .multichannel)
        let imageData = (try? PSDImageData.encode(.rle, decoded: planes, header: header)) ?? (try? PSDImageData.encode(.raw, decoded: planes, header: header))
            ?? PSDImageData(compression: .raw, data: Data(planes))
        var resources = [
            PSDImageResource(id: PSDResourceID.resolutionInfo, data: PSDResolutionInfo(dpi: Double(doc.resolutionDpi)).serialized()),
            PSDImageResource(id: PSDResourceID.globalAngle, data: Data(Exporter.be32(roundCast(doc.globalLight.angle)))),
            PSDImageResource(id: PSDResourceID.globalAltitude, data: Data(Exporter.be32(roundCast(doc.globalLight.altitude)))),
        ]
        // Grid and guides: Photoshop writes it in every file, guides or not.
        resources.append(PSDImageResource(id: gridAndGuides, data: Data(PSDExport.guidesResource(doc))))
        if !channels.isEmpty { resources += PSDExport.channelResources(doc, channels, transparency: false) }
        resources += PSDExport.pathResources(doc, &warnings)
        let ppi: (Float, Float)? = doc.resolutionDpi > 0 ? (doc.resolutionDpi, doc.resolutionDpi) : nil
        if let x = doc.metadata.xmp { resources.append(PSDImageResource(id: PSDResourceID.xmp, data: Data(MetadataExport.exportXmp(x, ppi).utf8))) }
        if let e = doc.metadata.exif { resources.append(PSDImageResource(id: PSDResourceID.exif, data: Data(MetadataExport.exportExif(e, ppi)))) }
        // Every other imported resource, except those that only describe layers and any already written.
        let written = Set(resources.map(\.id))
        for r in doc.metadata.psdResources {
            if layerOnlyResources.contains(r.id) || written.contains(r.id) || !PSDExport.keepImportedResource(doc, r.id, r.data) { continue }
            // Alpha identifiers: one u32 per channel, only while they still match the channels.
            if r.id == alphaIdentifiers && r.data.count != channels.count * 4 { continue }
            resources.append(PSDImageResource(id: r.id, data: Data(r.data), name: PSDExport.legacyName(r.name)))
        }
        if let d = AnnotationsMap.freshScaleResource(doc) { resources.append(PSDImageResource(id: AnnotationsMap.measurementScale, data: Data(d))) }
        resources.append(PSDVersionInfo.resource(hasRealMergedData: true))
        resources = PSDExport.photoshopResourceOrder(resources, kept: doc.metadata.psdResources)
        // Document-level tagged blocks (patterns, notes, …) are valid without a layer section; a
        // kept layer block would describe layers the document doesn't have.
        let globalBlocks = AnnotationsMap.exportBlocks(doc, PatternMap.exportGlobalBlocks(doc))
            .filter { !["Layr", "Lr16", "Lr32"].contains(FourCC($0.key)) }
            .map { PSDExport.globalBlock(FourCC($0.signature), FourCC($0.key), $0.data) }
        let file = PSDFile(header: header, colorModeData: PSDHDRToning.colorModeData(depth: header.depth), resources: resources, layerInfo: nil,
                           layerInfoPlacement: .section, globalLayerMask: globalBlocks.isEmpty ? nil : PSDGlobalLayerMask(), globalBlocks: globalBlocks,
                           imageData: imageData)
        return (file, warnings)
    }
}
