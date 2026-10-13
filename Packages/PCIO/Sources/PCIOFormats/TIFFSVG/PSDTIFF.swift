// Port of photocraft-psd (crates/psd/src/tiff.rs: everything but the `transcode` module, which is
// PSDTIFFTranscode.swift), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Photoshop layer data embedded in TIFF files (layered TIFF).
//
// Photoshop keeps a layered TIFF's layers in two private tags, described by Adobe's *Photoshop
// TIFF Technical Notes* (March 2002) together with the PSD specification:
//
// * **37724 `ImageSourceData`**: the string `"Adobe Photoshop Document Data Block\0"`
//   (`"Adobe Photoshop Document Data V0002\0"` for PSB-sized data, whose long keys carry 8-byte
//   lengths) followed by tagged blocks in the usual `8BIM` + key + length + data form, each padded
//   to a multiple of 4. `Layr` (8-bit), `Lr16` and `Lr32` hold the layer info, the same structure
//   as a PSD's layer info section; `LMsk` holds the global layer mask; every other block is a
//   global additional-layer-information block (`Patt`, `Anno`, `FMsk`, `Txt2`, …).
// * **34377**: the PSD image resources (`8BIM` resource blocks, without the section length).
//
// **Byte order.** Adobe's note is silent, but Photoshop files show (and open-source readers such
// as psdtags implement) that the block structure follows the TIFF's byte order: in an Intel-order
// (`II`) file every integer and double is little-endian and every four-character signature and key
// is stored reversed (`MIB8`, `ryaL`), while the pixel samples inside channel data stay big-endian
// as in a PSD, and RLE row-count tables follow the container. `ImageSourceData.fromBytes`
// normalizes either order to the big-endian PSD model, and `toBytes` writes either order, by
// transcoding every structure it knows field by field (`PSDTIFF.Transcode`). A block the
// transcoder does not know is never dropped on the way in: its bytes are kept verbatim with the
// signature `MIB8` (`46B8` for `8B64`) marking that they are in little-endian layout
// (`PSDTIFF.isForeignOrder`), so a later save to a little-endian TIFF writes it back exactly. Only
// a save to the *other* byte order has to drop such a block, with a warning: a byte-swapped block
// passed through unchanged would be read as garbage by every other application (and would end the
// block list for readers that stop at a bad signature).
//
// Errors are PCPSD's `PSDError` (photocraft `PsdError`); `PCIOError.wrap` maps them.

import Foundation
import PCPSD

/// Photoshop layer data in TIFF tags 37724 and 34377 (photocraft `photocraft_psd::tiff`).
public enum PSDTIFF {
    /// The byte order of a TIFF container (and so of the Photoshop data inside it).
    public enum ByteOrder: Sendable, Hashable, CaseIterable {
        /// Motorola order (`MM`); the PSD byte order.
        case big
        /// Intel order (`II`).
        case little

        var isLittle: Bool { self == .little }
    }

    /// TIFF tag of the Photoshop image resources.
    public static let resourcesTag: UInt16 = 34377
    /// TIFF tag of `ImageSourceData` (the layers).
    public static let imageSourceDataTag: UInt16 = 37724

    /// Header string of 37724 data with PSD-sized (4-byte) lengths.
    public static let signature: [UInt8] = Array("Adobe Photoshop Document Data Block\0".utf8)
    /// Header string of 37724 data with PSB-sized (8-byte) lengths for the long keys.
    public static let signaturePSB: [UInt8] = Array("Adobe Photoshop Document Data V0002\0".utf8)

    /// The layer-info block key Photoshop uses for a bit depth.
    public static func layerInfoKey(_ depth: UInt16) -> FourCC {
        switch depth {
        case 16: "Lr16"
        case 32: "Lr32"
        default: "Layr"
        }
    }

    /// `true` for `MIB8` / `46B8`: the signatures given to a block whose data was kept verbatim
    /// from a little-endian TIFF because its layout is unknown (photocraft
    /// `TaggedBlock::is_foreign_order_signature`). Such a block is written back exactly into a
    /// little-endian TIFF and cannot go into a big-endian file (a PSD) without being dropped.
    public static func isForeignOrderSignature(_ signature: FourCC) -> Bool {
        Records.isForeignMarker(signature.rawValue)
    }

    /// Whether `block`'s data is in little-endian layout (photocraft `TaggedBlock::is_foreign_order`).
    public static func isForeignOrder(_ block: PSDTaggedBlock) -> Bool { isForeignOrderSignature(block.signature) }

    /// The contents of an `ImageSourceData` tag, in the big-endian PSD model.
    public struct ImageSourceData: Equatable, Sendable {
        /// PSD (4-byte lengths) or PSB (8-byte lengths for the long keys).
        public var version: PSDVersion
        /// The byte order the data was read in (what `toBytes` should normally write back).
        public var byteOrder: ByteOrder
        /// The layers, from the `Layr` / `Lr16` / `Lr32` block.
        public var layerInfo: PSDLayerInfo?
        /// Which key held the layer info (`Layr` when there was none).
        public var layerInfoKey: FourCC
        /// The `LMsk` block.
        public var globalLayerMask: PSDGlobalLayerMask?
        /// Every other block, in stored order.
        public var globalBlocks: [PSDTaggedBlock]
        /// Bytes after the last block that do not form a block.
        public var trailing: [UInt8]

        public init(version: PSDVersion = .psd, byteOrder: ByteOrder = .big, layerInfo: PSDLayerInfo? = nil, layerInfoKey: FourCC = "Layr",
                    globalLayerMask: PSDGlobalLayerMask? = nil, globalBlocks: [PSDTaggedBlock] = [], trailing: [UInt8] = []) {
            self.version = version
            self.byteOrder = byteOrder
            self.layerInfo = layerInfo
            self.layerInfoKey = layerInfoKey
            self.globalLayerMask = globalLayerMask
            self.globalBlocks = globalBlocks
            self.trailing = trailing
        }

        /// Parses a 37724 tag. Returns the data together with warnings about blocks that were
        /// dropped because they could not be converted from the file's byte order.
        public static func fromBytes(_ data: [UInt8]) throws -> (data: ImageSourceData, warnings: [String]) {
            let version: PSDVersion
            if data.count >= 36, data[0 ..< 36].elementsEqual(PSDTIFF.signature) {
                version = .psd
            } else if data.count >= 36, data[0 ..< 36].elementsEqual(PSDTIFF.signaturePSB) {
                version = .psb
            } else {
                throw PSDError.invalid("not Photoshop image source data (missing \"Adobe Photoshop Document Data Block\")")
            }
            var rest = Array(data[36...])
            let byteOrder = try blockOrder(rest[...])
            var warnings: [String] = []
            if byteOrder.isLittle {
                (rest, warnings) = try Transcode.transcodeBlocks(rest, version, .little, .big)
            }
            var (blocks, trailing) = try PSDTaggedBlock.readBlocks(Data(rest), version: version, alignment: 2)
            // Blocks in a TIFF are padded to 4 (`toBytes` re-pads them), so zero padding is the
            // canonical default here, as even-length padding is in a PSD.
            for i in blocks.indices {
                if let p = blocks[i].padding, p.count <= 3, p.allSatisfy({ $0 == 0 }) { blocks[i].padding = nil }
            }
            var layerInfo: PSDLayerInfo?
            var layerInfoKey: FourCC = "Layr"
            if let i = blocks.firstIndex(where: { ["Layr", "Lr16", "Lr32"].contains($0.key) }) {
                let b = blocks.remove(at: i)
                layerInfo = try PSDLayerInfo(body: b.data, version: version)
                layerInfoKey = b.key
            }
            let globalLayerMask = blocks.firstIndex { $0.key == "LMsk" }.map { PSDGlobalLayerMask(data: [UInt8](blocks.remove(at: $0).data)) }
            let isd = ImageSourceData(version: version, byteOrder: byteOrder, layerInfo: layerInfo, layerInfoKey: layerInfoKey,
                                      globalLayerMask: globalLayerMask, globalBlocks: blocks, trailing: trailing)
            return (isd, warnings)
        }

        /// Serializes the data in `order`. Returns the bytes and warnings about blocks that were
        /// dropped because they could not be converted to a little-endian layout.
        public func toBytes(_ order: ByteOrder) throws -> (bytes: [UInt8], warnings: [String]) {
            var blocks: [PSDTaggedBlock] = []
            if let info = layerInfo {
                // Padded to 4 regardless of the model's own padding.
                var body = try info.serializedUnpaddedBody(version: version)
                body.append(contentsOf: [UInt8](repeating: 0, count: Records.defaultPadding(body.count, 4)))
                blocks.append(PSDTaggedBlock(key: layerInfoKey, data: body, padding: []))
            }
            if let m = globalLayerMask { blocks.append(paddedBlock("LMsk", m.data)) }
            for var b in globalBlocks {
                if b.padding == nil {
                    // Padded to 4 like the others; the signature stays (a foreign-order marker included).
                    b.padding = [UInt8](repeating: 0, count: Records.defaultPadding(b.data.count, 4))
                }
                blocks.append(b)
            }
            var body = [UInt8](try PSDTaggedBlock.serialize(blocks, version: version, alignment: 2)) + trailing
            var warnings: [String] = []
            if order.isLittle {
                (body, warnings) = try Transcode.transcodeBlocks(body, version, .big, .little)
            }
            var out = version.isPSB ? PSDTIFF.signaturePSB : PSDTIFF.signature
            out.reserveCapacity(36 + body.count)
            out += body
            return (out, warnings)
        }

        /// The layers, global mask and global blocks of a PSD as image source data (byte order Big).
        public static func fromPSD(_ file: PSDFile) -> ImageSourceData {
            let key: FourCC
            switch file.layerInfoPlacement {
            case let .globalBlock(_, _, k, _, _): key = k
            case .section: key = PSDTIFF.layerInfoKey(file.header.depth)
            }
            return ImageSourceData(version: file.header.version, byteOrder: .big, layerInfo: file.layerInfo, layerInfoKey: key,
                                   globalLayerMask: file.globalLayerMask, globalBlocks: file.globalBlocks, trailing: file.layerMaskTrailing)
        }

        /// Assembles a PSD model from this data plus the parts a TIFF stores natively: the header
        /// (dimensions, depth, colour mode, channel count), the image resources (tag 34377) and
        /// the merged image (the TIFF's pixels).
        public func intoPSD(header: PSDHeader, resources: [PSDImageResource], imageData: PSDImageData) -> PSDFile {
            let placement: PSDLayerInfoPlacement
            if (layerInfoKey == "Lr16" || layerInfoKey == "Lr32"), layerInfo != nil {
                placement = .globalBlock(index: 0, signature: "8BIM", key: layerInfoKey, padding: nil, longLengthOverride: nil)
            } else {
                placement = .section
            }
            return PSDFile(header: header, colorModeData: Data(), resources: resources, layerInfo: layerInfo, layerInfoPlacement: placement,
                           globalLayerMask: globalLayerMask, globalBlocks: globalBlocks, layerMaskTrailing: trailing, imageData: imageData)
        }
    }

    /// A block padded to a multiple of 4, as Photoshop writes them in TIFFs.
    static func paddedBlock(_ key: FourCC, _ data: [UInt8]) -> PSDTaggedBlock {
        PSDTaggedBlock(key: key, data: Data(data), padding: [UInt8](repeating: 0, count: Records.defaultPadding(data.count, 4)))
    }

    /// The byte order of the block list starting at `rest`.
    static func blockOrder(_ rest: ArraySlice<UInt8>) throws -> ByteOrder {
        guard rest.count >= 4 else { return .big }
        let sig = FourCC(bytes: rest.prefix(4))
        switch sig {
        case "8BIM", "8B64": return .big
        case "MIB8", "46B8": return .little
        default: throw PSDError.invalidSignature(expected: "8BIM or MIB8 (Photoshop image source data block)", found: sig)
        }
    }

    /// Parses a 34377 tag (image resources). Little-endian resource blocks (`MIB8`) are
    /// converted; resource payloads other than the typed numeric ones are kept as stored.
    public static func resourcesFromBytes(_ data: [UInt8]) throws -> (resources: [PSDImageResource], warnings: [String]) {
        let order = try blockOrder(data[...])
        var bytes = data
        var warnings: [String] = []
        if order.isLittle {
            (bytes, warnings) = try Transcode.transcodeResources(data, .little, .big)
        }
        let (out, trailing, problems) = try PSDImageResource.readBlocks(Data(bytes))
        // Photoshop pads the tag to an even length: a few trailing zero bytes are not a resource.
        if !trailing.isEmpty, !(trailing.count < 12 && trailing.allSatisfy { $0 == 0 }) {
            throw PSDError.invalid(problems.first ?? "unreadable image resources")
        }
        return (out, warnings)
    }

    /// Serializes image resources for a 34377 tag (big-endian, which every reader expects).
    public static func resourcesToBytes(_ resources: [PSDImageResource]) throws -> [UInt8] {
        [UInt8](try PSDImageResource.serialize(resources))
    }
}
