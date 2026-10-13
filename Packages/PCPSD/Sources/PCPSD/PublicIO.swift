// Public entry points to the structure readers and writers the file reader uses internally:
// tagged blocks, layer records and masks, layer info bodies and image resources. They let other
// containers of the same structures (the layered-TIFF `ImageSourceData` tag, the 34377 resource
// tag) reuse them instead of carrying copies.
// Wraps the ports of photocraft-psd (crates/psd/src/tagged.rs `read_blocks`/`write`, layer.rs
// `LayerRecord::read`/`write`, `LayerMask::parse`, `LayerInfo::read_body`/`write_unpadded`,
// resources.rs `ImageResource::read`/`write`), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

import Foundation

extension PSDTaggedBlock {
    /// Whether `bytes` starts with a block signature: `8BIM` / `8B64`, or `MIB8` / `46B8`, the
    /// markers a layered-TIFF transcoder gives a block kept verbatim in little-endian layout
    /// (photocraft tagged.rs `is_sig`).
    public static func isBlockSignature(_ bytes: some Collection<UInt8>) -> Bool {
        let b = Array(bytes.prefix(4))
        return b.withUnsafeBytes { hasBlockSignature($0) }
    }

    /// `MIB8` / `46B8`: a block whose data is in little-endian layout (kept verbatim from a TIFF).
    public static func isForeignOrderSignature(_ signature: FourCC) -> Bool { signature == "MIB8" || signature == "46B8" }

    /// This block's data is in little-endian layout (signature `MIB8` / `46B8`). Photoshop cannot
    /// read such a block in a PSD.
    public var isForeignOrder: Bool { Self.isForeignOrderSignature(signature) }

    /// Reads tagged blocks until `data` is exhausted (padding detected per block, PSB lengths by the
    /// long-key table with the probing fallback). Bytes that do not form a block — fewer than 12,
    /// or no signature — are returned as `trailing`. `alignment` is 2 inside layer records and 4
    /// for global blocks.
    public static func readBlocks(_ data: Data, version: PSDVersion, alignment: Int = 2) throws -> (blocks: [PSDTaggedBlock], trailing: [UInt8]) {
        try data.withByteReader { r in
            let (blocks, trailing) = try PCPSD.readBlocks(&r, version: version, alignment: alignment)
            return (blocks, trailing)
        }
    }

    /// The blocks serialized back to back (signature, key, 4- or 8-byte length, data, padding).
    public static func serialize(_ blocks: [PSDTaggedBlock], version: PSDVersion, alignment: Int = 2) throws -> Data {
        var s = MemorySink()
        try writeBlocks(blocks, to: &s, version: version, alignment: alignment)
        return s.data
    }

    /// This block serialized.
    public func serialized(version: PSDVersion, alignment: Int = 2) throws -> Data {
        try Self.serialize([self], version: version, alignment: alignment)
    }
}

extension PSDLayerMask {
    /// Parses a layer mask record (the bytes after its u32 length), including Photoshop's
    /// real-before-parameters order (photocraft #949).
    public init(bytes: [UInt8]) throws { self = try PSDLayerMask.parse(bytes) }

    /// The record bytes (without the u32 length).
    public func serialized() -> [UInt8] {
        var w = ByteWriter()
        write(&w)
        return w.bytes
    }

    /// Whether a mask record with parameters stores the real-mask fields before them, as
    /// Photoshop does (photocraft `LayerMask::real_before_parameters`, #949).
    public static func storesRealBeforeParameters(_ record: [UInt8]) -> Bool { realBeforeParameters(record) }
}

extension PSDLayerRecord {
    /// Reads one layer record from the start of `data`. Channel data is not part of a record:
    /// the record's channels come back empty, with their stored lengths (compression field
    /// included) in `channelLengths`. `bytesRead` is the record's size.
    public static func readRecord(_ data: Data, version: PSDVersion) throws -> (record: PSDLayerRecord, channelLengths: [UInt64], bytesRead: Int) {
        try data.withByteReader { r in
            let (rec, lens) = try PSDLayerRecord.read(&r, version: version)
            return (rec, lens, r.pos)
        }
    }

    /// The record bytes (channel lengths from the channels' data; no channel data).
    public func serializedRecord(version: PSDVersion) throws -> Data {
        var w = ByteWriter()
        try writeRecord(&w, version: version)
        return w.data
    }

    /// A legacy (Pascal) layer name as the writer stores it: ASCII, others as `?`, at most 255.
    public static func legacyName(_ name: String) -> [UInt8] { encodeLegacyName(name) }

    /// A legacy name decoded (UTF-8 when valid, else Latin-1).
    public static func decodedLegacyName(_ bytes: [UInt8]) -> String { decodeLegacyName(bytes) }
}

extension PSDLayerInfo {
    /// Parses a layer info body: the bytes its length field covers in the layer and mask section,
    /// or the data of a `Layr` / `Lr16` / `Lr32` block.
    public init(body: Data, version: PSDVersion) throws {
        self = try body.withByteReader { r in try PSDLayerInfo.readBody(&r, version: version) }
    }

    /// The body with its padding (what a length field or a `Lr16` block covers).
    public func serializedBody(version: PSDVersion) throws -> Data { try bodyBytes(version) }

    /// The body without any trailing padding (`padding` ignored).
    public func serializedUnpaddedBody(version: PSDVersion) throws -> Data {
        var s = MemorySink()
        try writeUnpadded(to: &s, version: version)
        return s.data
    }
}

extension PSDImageResource {
    /// Signatures accepted for a resource block (`8BIM` and the older `MeSa` / `AgHg` / `PHUT` /
    /// `DCSR`).
    public static var resourceSignatures: Set<FourCC> { signatures }

    /// Reads resource blocks back to back until `data` ends — the image resource section without
    /// its length, or a TIFF 34377 tag. A block that does not parse ends the list: it and the
    /// rest are returned as `trailing` with the error in `warnings` (the section reader's
    /// leniency). With `strict`, that error is thrown instead.
    public static func readBlocks(_ data: Data, strict: Bool = false) throws -> (resources: [PSDImageResource], trailing: [UInt8], warnings: [String]) {
        try data.withByteReader { r in
            var out: [PSDImageResource] = []
            while !r.isAtEnd {
                let mark = r
                do {
                    out.append(try PSDImageResource.read(&r))
                } catch {
                    if strict { throw error }
                    r = mark
                    let rest = Array(r.rest)
                    return (out, rest, ["image resources: \(error); \(rest.count) bytes kept raw"])
                }
            }
            return (out, [], [])
        }
    }

    /// The resource blocks serialized back to back (no section length).
    public static func serialize(_ resources: [PSDImageResource]) throws -> Data {
        var w = ByteWriter()
        for res in resources { try res.write(&w) }
        return w.data
    }

    /// This resource block serialized (signature, id, padded name, length, data, pad to even).
    public func serializedBlock() throws -> Data { try Self.serialize([self]) }
}
