// Layered TIFF: Photoshop layer data carried in the TIFF tags 37724 (`ImageSourceData`) and 34377
// (image resources). Import rebuilds a PSD model from the TIFF's pixels plus those two tags and
// hands it to the PSD importer, so everything the PSD path understands opens from a TIFF as well.
// Export runs the PSD exporter and stores its layer section and resources in the tags, in the byte
// order the TIFF is written in, next to the flattened composite the TIFF itself carries.
// Port of photocraft-io (crates/io/src/tiff_layers.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors. The container and the transcoder are PCIOFormats' `LayeredTIFF` and
// `PSDTIFF` (photocraft-psd tiff.rs).

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCIOFormats
import PCPSD

enum TIFFLayers {
    /// `true` when saving `doc` as TIFF writes layer data: anything beyond a single Background
    /// layer (one plain, transparency-locked raster layer), which a flat TIFF already represents.
    /// A lone unlocked layer keeps its layer data, as in Photoshop.
    static func wouldWriteLayers(_ doc: Document) -> Bool {
        guard doc.layers.count == 1, let l = doc.layers.first, case .raster = l.content else { return true }
        let plain = l.visible && l.opacity >= 1 && l.fillOpacity >= 1 && l.blend == .normal && l.mask == nil && l.vectorMask == nil
            && !l.effects.hasVisibleEffects && !l.clipped
        return !(plain && l.locks.transparency)
    }

    /// Documents a layered TIFF can hold: the composite must be in the document's model (Lab TIFFs
    /// are not written), and there must be layers to keep (Multichannel has none).
    static func layeredMode(_ doc: Document) -> Bool {
        [.grayscale, .rgb, .cmyk].contains(doc.pixelFormat.mode) && doc.mode != .multichannel && !doc.layers.isEmpty
    }

    static func setResource(_ resources: inout [PSDImageResource], _ id: UInt16, _ data: [UInt8]?) {
        resources.removeAll { $0.id == id }
        if let d = data { resources.append(PSDImageResource(id: id, data: Data(d))) }
    }

    /// Opens a TIFF carrying Photoshop layer data; nil for a TIFF without it (or not a TIFF).
    static func importIfLayered(_ name: String, _ bytes: [UInt8], _ options: IOOptions) throws -> ImportResult? {
        guard let tags = LayeredTIFF.photoshopTags(bytes), let layers = tags.layers, !layers.isEmpty else { return nil }
        let img: DecodedImage
        do { img = try options.codec.decode(bytes) } catch { throw PCIOError.wrap(error) }
        var warnings: [String] = []
        // Rotating the composite but not the layers would misalign them: a layered TIFF keeps its
        // stored orientation.
        let orientationWarning = img.orientation != 1 ? "the TIFF's orientation tag was ignored so the layers stay aligned with the image" : nil
        let isd: PSDTIFF.ImageSourceData
        do {
            let (d, w) = try PSDTIFF.ImageSourceData.fromBytes(layers)
            isd = d
            warnings += w.map { "layer data: \($0)" }
        } catch {
            var r = DocumentIO.imageToDocument(name, FlatOrientation.upright(img))
            r.warnings.append("the PSD layer data could not be read (\(PCIOError.wrap(error))); opened flattened")
            return r
        }
        var resources: [PSDImageResource] = []
        if let rb = tags.resources, !rb.isEmpty {
            do {
                let (r, w) = try PSDTIFF.resourcesFromBytes(rb)
                resources = r
                warnings += w.map { "image resources: \($0)" }
            } catch {
                warnings.append("the PSD image resources could not be read: \(PCIOError.wrap(error))")
            }
        }
        // The profile, resolution and XMP are the TIFF's own tags; they win over any copy in the
        // resources.
        setResource(&resources, PSDResourceID.iccProfile, img.iccProfile)
        if let d = img.dpi, d.x > 0 {
            var ri = PSDResolutionInfo(dpi: d.x)
            ri.vResFixed = PSDResolutionInfo(dpi: d.y).vResFixed
            setResource(&resources, PSDResourceID.resolutionInfo, [UInt8](ri.serialized()))
        }
        if let x = tags.xmp { setResource(&resources, PSDResourceID.xmp, x) }
        // The TIFF's pixels become the PSD's merged image: planar, big-endian, CMYK inverted.
        let fmt = img.surface.format
        let mode: PSDColorMode = fmt.mode == .cmyk ? .cmyk : fmt.mode == .grayscale ? .grayscale : .rgb
        let cc = fmt.mode.colorChannels
        let channels = cc + (img.hasAlpha ? 1 : 0)
        let rect = PixelRect(x0: 0, y0: 0, x1: Int32(img.width), y1: Int32(img.height))
        var bytes = img.surface.readInterleaved(rect)
        if !img.hasAlpha {
            // Drop the (opaque) alpha the codec always adds.
            let bps = fmt.sample.bytes, src = fmt.channels * bps, dst = cc * bps
            var out = [UInt8](repeating: 0, count: img.width * img.height * dst)
            for i in 0 ..< img.width * img.height { out.replaceSubrange(i * dst ..< (i + 1) * dst, with: bytes[i * src ..< i * src + dst]) }
            bytes = out
        }
        let planes = PSDPixels.deinterleave(bytes, channels, fmt.sample, (0 ..< channels).map { fmt.mode == .cmyk && $0 < cc })
        let header = PSDHeader(version: isd.version, width: UInt32(img.width), height: UInt32(img.height), channels: UInt16(channels),
                               depth: PSDPixels.psdDepth(fmt.sample), colorMode: mode)
        let file = isd.intoPSD(header: header, resources: resources, imageData: PSDImageData(compression: .raw, data: Data(planes.flatMap { $0 })))
        // The same nesting limit as opening a PSD (#2940).
        try PSDImport.checkGroupDepth(file)
        var (doc, w) = try PSDImport.document(file, options: PSDImportOptions(renderer: options.renderer, interrupt: options.interrupt))
        warnings += w
        doc.name = name
        if doc.iccProfile == nil { doc.iccProfile = img.iccProfile }
        // The TIFF's ASCII tags (description, artist, …) are the document's text metadata.
        if doc.metadata.text.isEmpty { doc.metadata.text = img.text }
        warnings += TextImport.prepare(&doc, renderer: options.renderer)
        if let w = orientationWarning { warnings.append(w) }
        return ImportResult(document: doc, warnings: warnings)
    }

    /// Saves `doc` as a layered TIFF. Documents whose colour mode a TIFF cannot hold here (Lab)
    /// are saved flat, with a warning.
    static func exportLayered(_ doc: Document, _ options: IOOptions) throws -> ExportResult {
        if !layeredMode(doc) {
            var r = try DocumentIO.exportFlat(doc, .tiff, options)
            if !doc.layers.isEmpty { r.warnings.append("\(doc.pixelFormat.mode.serdeName) documents are saved as a flat TIFF: their layers are not kept") }
            return r
        }
        var warnings: [String] = []
        let big = doc.size.width > 30_000 || doc.size.height > 30_000
        // The PSD exporter renders the composite the TIFF itself needs: unmatted (the TIFF keeps
        // straight alpha) and uncompressed (its planes are interleaved below).
        var psdOptions = options.psdExportOptions(forcePSB: options.forcePSB || big, interrupt: options.interrupt.span(0, 0.4))
        psdOptions.mergedMatte = false
        psdOptions.mergedCompression = .raw
        psdOptions.imagePreviews = false
        var (file, w) = PSDExport.file(doc, options: psdOptions)
        try options.interrupt.check()
        warnings += w
        let order: PSDTIFF.ByteOrder = LayeredTIFF.writesLittleEndian ? .little : .big
        let layers: [UInt8]
        do {
            let (b, lw) = try PSDTIFF.ImageSourceData.fromPSD(file).toBytes(order)
            layers = b
            warnings += lw.map { "layer data: \($0)" }
        } catch { throw PCIOError.wrap(error) }
        options.interrupt.progress(0.68)
        // The profile and XMP are written as TIFF tags, not as resources. EXIF stays a resource
        // (1058), which the importer reads back from there.
        file.resources.removeAll { $0.id == PSDResourceID.iccProfile || $0.id == PSDResourceID.xmp }
        // The file's own format: a 32-bit CMYK document is written at 16 bits (Photoshop has no
        // 32-bit CMYK mode).
        let fmt = PixelFormat(mode: doc.pixelFormat.mode, sample: PSDPixels.sampleForDepth(file.header.depth), alpha: true)
        let cc = fmt.mode.colorChannels
        let hasAlpha = file.layerInfo?.mergedAlpha ?? false
        let channels = cc + (hasAlpha ? 1 : 0)
        let extra = max(0, Int(file.header.channels) - channels)
        if extra > 0 {
            warnings.append("\(extra) alpha channel(s) are not written to TIFF (one transparency channel only)")
            // Their names, options and Quick Mask flag would describe channels the file lacks.
            file.resources.removeAll { [1006, 1045, 1007, 1077, 1022].contains($0.id) }
        }
        let resources: [UInt8]
        do { resources = try PSDTIFF.resourcesToBytes(file.resources) } catch { throw PCIOError.wrap(error) }
        let n = doc.size.width * doc.size.height
        let bps = fmt.sample.bytes
        let planes = [UInt8](file.imageData.data)
        guard planes.count >= n * bps * channels else { throw PCIOError.unsupported("the merged image is shorter than its header says") }
        // Planar big-endian → interleaved native-endian, un-inverting CMYK colour channels.
        var refs: [[UInt8]?] = []
        for c in 0 ..< channels { refs.append(Array(planes[c * n * bps ..< (c + 1) * n * bps])) }
        let samples = PSDPixels.interleave(refs, [[UInt8]](repeating: PSDPixels.zeroSample(fmt.sample), count: channels), n, fmt.sample,
                                           (0 ..< channels).map { fmt.mode == .cmyk && $0 < cc })
        options.interrupt.progress(0.72)
        let image = LayeredTIFF.Image(width: doc.size.width, height: doc.size.height, mode: fmt.mode, alpha: hasAlpha, sample: fmt.sample,
                                      samples: samples, iccProfile: doc.iccProfile, xmp: doc.metadata.xmp.map { Array($0.utf8) },
                                      dpi: (Double(doc.resolutionDpi), Double(doc.resolutionDpi)),
                                      text: doc.metadata.text.compactMap { t in
                                          LayeredTIFF.textTags.first { tagName($0) == t.key }.map { ($0, t.value) }
                                      },
                                      photoshopResources: resources, photoshopLayers: layers)
        let bytes = try LayeredTIFF.write(image, options: LayeredTIFF.WriteOptions(byteOrder: order, bigTIFF: file.header.version == .psb))
        return ExportResult(bytes: bytes, warnings: warnings)
    }

    /// The metadata-text key of a TIFF ASCII tag (photocraft-codecs' `TEXT_TAGS` names).
    static func tagName(_ tag: UInt16) -> String {
        FlatMetadata.tiffTextTags.first { $0.tag == tag }?.key ?? "\(tag)"
    }
}
