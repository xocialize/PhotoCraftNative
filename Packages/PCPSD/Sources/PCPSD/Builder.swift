// `PSDBuilder`: new PSD/PSB files from pixel buffers — layers, groups, masks, a caller-supplied
// merged composite, ICC profile and resolution.
// Port of photocraft-psd (crates/psd/src/builder.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors. Group-marker channel layout (four channels of length 2) cross-checked
// against PhotoDemon pdPSDLayer.cls (ParseLayer notes, WriteLayerData), BSD-2-Clause, © Tanner
// Helland and contributors.
//
// Beyond photocraft's builder, for Photoshop acceptance (photocraft #1281, #2469):
// * 32-bit RGB/Gray documents (with the HDR toning colour mode data Photoshop requires, #291) and
//   8/16-bit Lab, besides RGB/Gray/CMYK at 8/16;
// * the layer info is padded to a multiple of 4 in both placements (what Photoshop writes; psd-tools
//   misreads blocks after an Lr16 body padded only to even);
// * 16-bit layers go into a global `Lr16` block and 32-bit into `Lr32`, with an empty section layer
//   info, as Photoshop does; with merged transparency an empty `Mt16`/`Mt32` comes first and the
//   count stays positive (Photoshop 27.11 refuses the layer info before its matte block);
// * each raster record carries the blocks Photoshop writes for a plain layer (luni lnsr lyid clbl
//   infx knko lspf lclr fxrp) and each group record those of a group (luni lnsr=lset lyid lsct lspf
//   lclr fxrp, folder lsct with sub-type 0); record flags are 0x08 on raster layers and 0x18 on group
//   records, blending ranges carry cc + 2 entries (40 bytes for RGB) — all observed in the corpus;
//   group records carry raw (length-2) channels;
// * every layer block's data is zero-padded to a multiple of 4 inside its length, extra blocks
//   included (Photoshop 4-aligns all of its layer blocks and refuses an unaligned `grdm`);
// * blend modes follow Photoshop 27.11's table for the document's mode and depth
//   (`PSDBlendMode.allowedModes`): by default an unavailable mode is replaced by
//   `PSDBlendMode.nearestAllowed` with a warning in the built file's `warnings` (`blendModePolicy`);
// * empty channels are always raw; ZIP at 32 bits is written as ZIP with prediction (Photoshop reads
//   code 2 at 32 bits as predicted);
// * the merged image defaults to RLE (Photoshop never writes ZIP merged data), resolution 72 dpi.

import Foundation

/// Interleaved pixels with alpha last: colour channels of the document's mode, then alpha. CMYK is
/// given as ink amounts (0 = no ink) and stored inverted; Lab as stored (L 0...max, a/b centred).
public enum PSDPixels: Equatable, Sendable {
    case u8([UInt8])
    case u16([UInt16])
    case f32([Float])

    var depth: UInt16 {
        switch self {
        case .u8: 8
        case .u16: 16
        case .f32: 32
        }
    }

    var count: Int {
        switch self {
        case let .u8(v): v.count
        case let .u16(v): v.count
        case let .f32(v): v.count
        }
    }

    /// Planar big-endian plane of interleaved component `c` (`spp` samples per pixel).
    func plane(_ c: Int, spp: Int, n: Int, invert: Bool) -> [UInt8] {
        switch self {
        case let .u8(v):
            return (0 ..< n).map { invert ? 255 - v[$0 * spp + c] : v[$0 * spp + c] }
        case let .u16(v):
            var out = [UInt8](repeating: 0, count: n * 2)
            for i in 0 ..< n {
                let s = invert ? 65535 - v[i * spp + c] : v[i * spp + c]
                out[i * 2] = UInt8(s >> 8)
                out[i * 2 + 1] = UInt8(s & 0xFF)
            }
            return out
        case let .f32(v):
            return PSDSamples.bytes(f32: (0 ..< n).map { invert ? 1 - v[$0 * spp + c] : v[$0 * spp + c] })
        }
    }

    func alphaIsOpaque(spp: Int, n: Int) -> Bool {
        switch self {
        case let .u8(v): (0 ..< n).allSatisfy { v[$0 * spp + spp - 1] == 255 }
        case let .u16(v): (0 ..< n).allSatisfy { v[$0 * spp + spp - 1] == 65535 }
        case let .f32(v): (0 ..< n).allSatisfy { v[$0 * spp + spp - 1] >= 1 }
        }
    }

    /// Transparent RGB composites are stored against white (Photoshop's merged data); others straight.
    func compositePlane(_ c: Int, spp: Int, n: Int, matte: Bool, invert: Bool) -> [UInt8] {
        guard matte else { return plane(c, spp: spp, n: n, invert: invert) }
        switch self {
        case let .u8(v):
            return (0 ..< n).map { i in
                let color = UInt32(v[i * spp + c]), a = UInt32(v[i * spp + spp - 1])
                return a == 0 ? v[i * spp + c] : UInt8((color * a + 127) / 255 + 255 - a)
            }
        case let .u16(v):
            return PSDSamples.bytes(u16: (0 ..< n).map { i in
                let color = UInt32(v[i * spp + c]), a = UInt32(v[i * spp + spp - 1])
                return a == 0 ? v[i * spp + c] : UInt16((color * a + 32767) / 65535 + 65535 - a)
            })
        case let .f32(v):
            return PSDSamples.bytes(f32: (0 ..< n).map { i in
                let color = v[i * spp + c], a = v[i * spp + spp - 1]
                return a <= 0 ? color : color * a + 1 - a
            })
        }
    }
}

/// A layer mask given as 8-bit samples.
public struct PSDMaskSpec: Equatable, Sendable {
    /// Mask rectangle in document coordinates.
    public var rect: PSDRect
    /// `rect.width × rect.height` samples (0 hidden, 255 shown).
    public var data: [UInt8]
    /// Value outside the rectangle.
    public var defaultColor: UInt8
    public var disabled: Bool
    public init(rect: PSDRect, data: [UInt8], defaultColor: UInt8 = 255, disabled: Bool = false) {
        self.rect = rect
        self.data = data
        self.defaultColor = defaultColor
        self.disabled = disabled
    }
}

/// A raster layer.
public struct PSDLayerSpec: Equatable, Sendable {
    /// Written as the legacy Pascal name and `luni`.
    public var name: String
    public var left: Int32
    public var top: Int32
    public var width: Int
    public var height: Int
    /// Must match the builder's mode and depth.
    public var pixels: PSDPixels
    public var blendMode: PSDBlendMode = .normal
    public var opacity: UInt8 = 255
    /// `iOpa` when not 255.
    public var fillOpacity: UInt8?
    public var visible = true
    public var clipping = false
    public var mask: PSDMaskSpec?
    /// Extra blocks, written verbatim; a block replaces a default block with the same key.
    public var extraBlocks: [PSDTaggedBlock] = []

    public init(name: String, left: Int32, top: Int32, width: Int, height: Int, pixels: PSDPixels) {
        self.name = name
        self.left = left
        self.top = top
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// A group (folder).
public struct PSDGroupSpec: Equatable, Sendable {
    public var name: String
    public var blendMode: PSDBlendMode = .passThrough
    public var opacity: UInt8 = 255
    public var visible = true
    /// Expanded in the layers panel.
    public var open = true
    public var mask: PSDMaskSpec?
    public var extraBlocks: [PSDTaggedBlock] = []
    public init(name: String) { self.name = name }
}

/// Builds `PSDFile`s. Layers are pushed bottom to top.
public struct PSDBuilder: Sendable {
    public var width: Int
    public var height: Int
    public var colorMode: PSDColorMode
    public var depth: UInt16
    public var version: PSDVersion
    /// Compression of layer channels.
    public var compression: PSDCompression = .rle
    /// Compression of the merged image.
    public var mergedCompression: PSDCompression = .rle
    /// Resources written before the version info (resolution 72 dpi unless replaced).
    public var resources: [PSDImageResource] = [PSDImageResource(id: PSDResourceID.resolutionInfo, data: PSDResolutionInfo(dpi: 72).serialized())]
    /// Write Photoshop's default per-layer blocks (lnsr clbl infx knko lspf lclr fxrp) besides luni/lyid.
    public var photoshopLayerBlocks = true
    /// Write the IPTC (1028) and print-output (1082) resources Photoshop writes into every file.
    public var photoshopDefaultResources = true

    /// What `build()` does with a blend mode Photoshop does not accept in the document's mode and
    /// depth (`PSDBlendMode.isAllowed`), such as pass-through on a layer, Screen at 32 bits, Hue in
    /// Grayscale or an unknown key.
    public enum BlendModePolicy: Hashable, Sendable {
        /// Default. Write `PSDBlendMode.nearestAllowed` instead and add a warning to the built
        /// file's `warnings`. The file opens in Photoshop, though its composite may differ from
        /// the requested mode.
        case substituteNearest
        /// Throw `PSDError.unsupported` from `build()`.
        case refuse
        /// Write the mode as given (negative fixtures, fuzzing). Photoshop may refuse the file.
        case keep
    }

    /// See `BlendModePolicy`. Layers and groups follow the same table, and pass-through is
    /// accepted on groups only.
    public var blendModePolicy: BlendModePolicy = .substituteNearest

    /// Photoshop's default print-output descriptor (resource 1082).
    public static let photoshopPrintOutput = PSDVersionedDescriptor(
        PSDDescriptor(classID: "printOutput")
            .with("PstS", .boolean(true))
            .with("Inte", .enumerated(type: "Inte", value: "Clrm"))
            .with("printSixteenBit", .boolean(false))
            .with("printerName", .text(PSDUnicodeString("")))
            .with("printProofSetup", .descriptor(PSDDescriptor(classID: "proofSetup", name: PSDUnicodeString("Proof Setup"))
                    .with("Bltn", .enumerated(type: "builtinProof", value: "proofCMYK")))))

    enum Entry: Sendable {
        case layer(PSDLayerSpec)
        case groupStart
        case groupEnd(PSDGroupSpec)
    }

    var entries: [Entry] = []
    var openGroups: [PSDGroupSpec] = []
    var composite: PSDPixels?

    public init(width: Int, height: Int, colorMode: PSDColorMode = .rgb, depth: UInt16 = 8, version: PSDVersion = .psd) {
        self.width = width
        self.height = height
        self.colorMode = colorMode
        self.depth = depth
        self.version = version
    }

    public mutating func setResolution(dpi: Double) {
        resources.removeAll { $0.id == PSDResourceID.resolutionInfo }
        resources.insert(PSDImageResource(id: PSDResourceID.resolutionInfo, data: PSDResolutionInfo(dpi: dpi).serialized()), at: 0)
    }

    public mutating func setICCProfile(_ icc: Data) {
        resources.removeAll { $0.id == PSDResourceID.iccProfile }
        resources.append(PSDImageResource(id: PSDResourceID.iccProfile, data: icc))
    }

    public mutating func addResource(_ r: PSDImageResource) { resources.append(r) }

    public mutating func pushLayer(_ spec: PSDLayerSpec) { entries.append(.layer(spec)) }

    public mutating func beginGroup(_ spec: PSDGroupSpec) {
        entries.append(.groupStart)
        openGroups.append(spec)
    }

    public mutating func endGroup() throws {
        guard let g = openGroups.popLast() else { throw PSDError.invalid("endGroup without beginGroup") }
        entries.append(.groupEnd(g))
    }

    /// A group with its children pushed by `body`.
    public mutating func pushGroup(_ spec: PSDGroupSpec, _ body: (inout PSDBuilder) throws -> Void) throws {
        beginGroup(spec)
        try body(&self)
        try endGroup()
    }

    /// The merged composite (straight samples, same format as layers, full canvas). Transparent RGB
    /// is stored against white, as Photoshop does.
    public mutating func setComposite(_ pixels: PSDPixels) { composite = pixels }

    var colorChannels: Int {
        get throws {
            switch colorMode {
            case .rgb, .lab: return 3
            case .grayscale: return 1
            case .cmyk: return 4
            default: throw PSDError.unsupported("builder colour mode \(colorMode)")
            }
        }
    }

    func checkModeDepth() throws {
        let cc = try colorChannels
        _ = cc
        guard [8, 16, 32].contains(depth) else { throw PSDError.unsupported("builder depth \(depth)") }
        if depth == 32, colorMode != .rgb, colorMode != .grayscale {
            throw PSDError.unsupported("32-bit \(colorMode) (Photoshop supports 32 bits for RGB and Grayscale only)")
        }
    }

    func checkPixels(_ p: PSDPixels, n: Int, spp: Int) throws {
        guard p.depth == depth else { throw PSDError.invalid("pixel depth \(p.depth) does not match document depth \(depth)") }
        guard p.count == n * spp else { throw PSDError.invalid("pixel buffer has \(p.count) samples, expected \(n * spp)") }
    }

    func channel(_ id: Int16, _ plane: [UInt8], _ w: Int, _ h: Int) throws -> PSDChannel {
        try PSDChannel.encode(id: id, compression: compression, decoded: plane, width: w, height: h, depth: depth, version: version)
    }

    func emptyChannels(_ cc: Int) -> [PSDChannel] {
        ([-1] + (0 ..< Int16(cc))).map { PSDChannel(id: $0, compression: .raw, data: Data()) }
    }

    func maskChannel(_ m: PSDMaskSpec) throws -> (PSDChannel, PSDMaskData) {
        let (mw, mh) = try m.rect.size()
        guard m.data.count == mw * mh else { throw PSDError.invalid("mask buffer size mismatch") }
        let plane: [UInt8]
        switch depth {
        case 16: plane = PSDSamples.bytes(u16: m.data.map { UInt16($0) * 257 })
        case 32: plane = PSDSamples.bytes(f32: m.data.map { Float($0) / 255 })
        default: plane = m.data
        }
        let ch = try channel(PSDChannelID.userMask, plane, mw, mh)
        return (ch, .mask(PSDLayerMask(rect: m.rect, defaultColor: m.defaultColor, flags: m.disabled ? PSDLayerMask.flagDisabled : 0)))
    }

    func standardBlocks(name: String, id: UInt32, extra: [PSDTaggedBlock], divider: PSDTaggedBlock?) -> [PSDTaggedBlock] {
        var blocks = [PSDTaggedBlock.unicodeName(name)]
        if photoshopLayerBlocks { blocks.append(.nameSource(divider == nil ? "layr" : "lset")) }
        blocks.append(.layerID(id))
        if photoshopLayerBlocks {
            if divider == nil {
                blocks += [.blendClippedAsGroup(true), .blendInteriorElements(false), .knockout(0)]
            }
            if let d = divider { blocks.append(d) }
            blocks += [.protection(0), .sheetColor(0), PSDTaggedBlock(key: "fxrp", data: Data(count: 16))]
        } else if let d = divider {
            blocks.append(d)
        }
        for e in extra.map({ $0.fourAligned() }) {
            if let i = blocks.firstIndex(where: { $0.key == e.key }) { blocks[i] = e } else { blocks.append(e) }
        }
        return blocks
    }

    /// Photoshop's record flag byte: bit 3 always, bit 4 (pixel data irrelevant) on group records.
    func recordFlags(visible: Bool, group: Bool) -> PSDLayerFlags {
        var flags = PSDLayerFlags()
        if photoshopLayerBlocks { flags.setPixelDataIrrelevant(group) }
        flags.isHidden = !visible
        return flags
    }

    /// Photoshop writes cc + 2 blending-range entries (40 bytes for RGB).
    func blendingRanges(_ cc: Int) -> PSDBlendingRanges {
        .full(channels: photoshopLayerBlocks ? cc + 1 : cc)
    }

    /// The blend mode to write for `requested` under `blendModePolicy`.
    func checkedBlendMode(_ requested: PSDBlendMode, isGroup: Bool, name: String, warnings: inout [String]) throws -> PSDBlendMode {
        if blendModePolicy == .keep || PSDBlendMode.isAllowed(requested, mode: colorMode, depth: depth, isGroup: isGroup) { return requested }
        let what = "\(isGroup ? "group" : "layer") \"\(name)\": blend mode \(requested.key) is not available in \(colorMode) \(depth)-bit documents"
        if blendModePolicy == .refuse { throw PSDError.unsupported(what) }
        let substitute = PSDBlendMode.nearestAllowed(requested, mode: colorMode, depth: depth, isGroup: isGroup)
        warnings.append("\(what); wrote \(substitute.key)")
        return substitute
    }

    func layerRecord(_ spec: PSDLayerSpec, cc: Int, id: UInt32) throws -> PSDLayerRecord {
        let (w, h) = (spec.width, spec.height)
        guard w >= 0, h >= 0 else { throw PSDError.invalid("negative layer size") }
        let n = w * h
        let spp = cc + 1
        try checkPixels(spec.pixels, n: n, spp: spp)
        let invert = colorMode == .cmyk
        var channels = [try channel(-1, spec.pixels.plane(cc, spp: spp, n: n, invert: false), w, h)]
        for c in 0 ..< cc { channels.append(try channel(Int16(c), spec.pixels.plane(c, spp: spp, n: n, invert: invert), w, h)) }
        var mask = PSDMaskData.none
        if let m = spec.mask {
            let (ch, md) = try maskChannel(m)
            channels.append(ch)
            mask = md
        }
        let flags = recordFlags(visible: spec.visible, group: false)
        var extra = spec.extraBlocks
        if let f = spec.fillOpacity { extra.insert(.fillOpacity(f), at: 0) }
        return PSDLayerRecord(rect: PSDRect(x: spec.left, y: spec.top, width: UInt32(w), height: UInt32(h)), channels: channels,
                              blendMode: spec.blendMode, opacity: spec.opacity, clipping: spec.clipping ? 1 : 0, flags: flags,
                              mask: mask, blendingRanges: blendingRanges(cc), name: encodeLegacyName(spec.name),
                              blocks: standardBlocks(name: spec.name, id: id, extra: extra, divider: nil))
    }

    /// Builds the file model.
    public func build() throws -> PSDFile {
        guard openGroups.isEmpty else { throw PSDError.invalid("unclosed group") }
        try checkModeDepth()
        let cc = try colorChannels
        var layers: [PSDLayerRecord] = []
        var warnings: [String] = []
        for (k, e) in entries.enumerated() {
            let id = UInt32(k + 1)
            switch e {
            case var .layer(spec):
                spec.blendMode = try checkedBlendMode(spec.blendMode, isGroup: false, name: spec.name, warnings: &warnings)
                layers.append(try layerRecord(spec, cc: cc, id: id))
            case .groupStart:
                layers.append(PSDLayerRecord(channels: emptyChannels(cc), flags: recordFlags(visible: true, group: true),
                                             blendingRanges: blendingRanges(cc), name: Array("</Layer group>".utf8),
                                             blocks: standardBlocks(name: "</Layer group>", id: id, extra: [],
                                                                    divider: .sectionDivider(.boundingDivider))))
            case var .groupEnd(g):
                g.blendMode = try checkedBlendMode(g.blendMode, isGroup: true, name: g.name, warnings: &warnings)
                let flags = recordFlags(visible: g.visible, group: true)
                var channels = emptyChannels(cc)
                var mask = PSDMaskData.none
                if let m = g.mask {
                    let (ch, md) = try maskChannel(m)
                    channels.append(ch)
                    mask = md
                }
                let kind: PSDSectionType = g.open ? .openFolder : .closedFolder
                layers.append(PSDLayerRecord(channels: channels, blendMode: g.blendMode, opacity: g.opacity, flags: flags, mask: mask,
                                             blendingRanges: blendingRanges(cc), name: encodeLegacyName(g.name),
                                             blocks: standardBlocks(name: g.name, id: id, extra: g.extraBlocks,
                                                                    divider: .sectionDivider(kind, blendMode: g.blendMode,
                                                                                             subType: photoshopLayerBlocks ? 0 : nil))))
            }
        }

        let (w, h) = (width, height)
        guard w > 0, h > 0 else { throw PSDError.invalid("document must be at least 1x1") }
        let n = w * h
        let spp = cc + 1
        let invert = colorMode == .cmyk
        var planes: [UInt8] = []
        var withAlpha = false
        var real = false
        if let p = composite {
            try checkPixels(p, n: n, spp: spp)
            withAlpha = !p.alphaIsOpaque(spp: spp, n: n)
            real = true
            for c in 0 ..< cc + (withAlpha ? 1 : 0) {
                planes += p.compositePlane(c, spp: spp, n: n, matte: withAlpha && (colorMode == .rgb || colorMode == .grayscale) && c < cc,
                                           invert: invert && c < cc)
            }
        } else {
            // White: 0xFF in RGB/Gray; no ink (stored inverted as 0xFF) in CMYK; L = 100 a = b = 0 in Lab.
            let bps = Int(depth / 8)
            switch (colorMode, depth) {
            case (.lab, 8): planes = [UInt8](repeating: 255, count: n) + [UInt8](repeating: 128, count: 2 * n)
            case (.lab, 16): planes = [UInt8](repeating: 255, count: n * 2) + PSDSamples.bytes(u16: [UInt16](repeating: 32768, count: 2 * n))
            case (_, 32): planes = PSDSamples.bytes(f32: [Float](repeating: 1, count: n * cc))
            default: planes = [UInt8](repeating: 255, count: n * bps * cc)
            }
        }
        let header = PSDHeader(version: version, width: UInt32(w), height: UInt32(h), channels: UInt16(cc + (withAlpha ? 1 : 0)),
                               depth: depth, colorMode: colorMode)
        try header.validate()
        if version == .psd, w > Int(PSDHeader.maxPSDDimension) || h > Int(PSDHeader.maxPSDDimension) {
            throw PSDError.limitExceeded("PSD dimensions exceed 30000; use PSB")
        }
        let imageData = try PSDImageData.encode(mergedCompression, decoded: planes, header: header)
        var res = resources
        if photoshopDefaultResources {
            // IPTC (record version only) and the print-output descriptor Photoshop writes into every
            // file. Besides matching Photoshop, the pair makes macOS ImageIO label the merged alpha
            // as premultiplied (it delivers premultiplied 8-bit RGB either way), so Preview and
            // QuickLook show transparent composites correctly.
            if !res.contains(where: { $0.id == PSDResourceID.iptc }) {
                res.append(PSDImageResource(id: PSDResourceID.iptc, data: Data([0x1C, 0x02, 0x00, 0x00, 0x02, 0x00, 0x00])))
            }
            if !res.contains(where: { $0.id == PSDResourceID.printInformation }) {
                res.append(PSDImageResource(id: PSDResourceID.printInformation, data: PSDBuilder.photoshopPrintOutput.serialized()))
            }
        }
        res.append(PSDVersionInfo.resource(hasRealMergedData: real))

        // Photoshop's layout (ps-corpus): 8-bit layers in the section, merged transparency as a
        // negative layer count; 16/32-bit layers in a global `Lr16`/`Lr32` block with a positive
        // count, preceded by an empty `Mt16`/`Mt32` matte block when the merged image has alpha.
        // Photoshop 27.11 refuses `Lr16` written before `Mt16`.
        var layerInfo: PSDLayerInfo?
        var placement = PSDLayerInfoPlacement.section
        var globalBlocks: [PSDTaggedBlock] = []
        if !layers.isEmpty {
            let deep = depth == 16 || depth == 32
            var info = PSDLayerInfo(mergedAlpha: withAlpha && !deep, layers: layers)
            try info.pad(to: 4, version: version)
            layerInfo = info
            if deep {
                if withAlpha { globalBlocks.append(PSDTaggedBlock(key: depth == 16 ? "Mt16" : "Mt32", data: Data())) }
                placement = .globalBlock(index: globalBlocks.count, signature: "8BIM", key: depth == 16 ? "Lr16" : "Lr32", padding: nil, longLengthOverride: nil)
            }
        }
        var file = PSDFile(header: header, colorModeData: PSDHDRToning.colorModeData(depth: depth), resources: res,
                           layerInfo: layerInfo, layerInfoPlacement: placement,
                           globalLayerMask: layers.isEmpty ? nil : PSDGlobalLayerMask(), globalBlocks: globalBlocks, imageData: imageData)
        file.warnings = warnings
        return file
    }

    public func serialized() throws -> Data { try build().serialized() }
}
