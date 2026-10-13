// Port of photocraft-affinity (crates/affinity/src/preview.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// The indexed PNG thumbnail Affinity stores next to the archive: Affinity's own render of the
// document, at most 512 pixels on the long side in real files, never the document itself.

extension Affinity {
    public static let maxPreviewBytes = 16 << 20
    public static let maxPreviewDimension: UInt32 = 4096

    /// The embedded thumbnail, at its own dimensions, never the native document dimensions.
    public struct Preview: Hashable, Sendable {
        /// Exactly one complete PNG (every chunk CRC checked; pixels not yet decoded).
        public var png: [UInt8]
        /// Where `png` sits in the file.
        public var range: Range<Int>
        public var width: UInt32
        public var height: UInt32
    }

    /// Read only the indexed `Thmb` record (identical in container versions 8 to 12), checking every
    /// PNG chunk CRC. Compressed pixels must still be validated by the consuming image decoder, with
    /// allocation limits (photocraft decodes it within 128 MiB; ImageIO with a 4096² cap here).
    public static func preview(_ bytes: [UInt8]) throws(AffinityError) -> Preview {
        let h = try header(bytes)
        guard h.thumbnailOffset != 0 else { throw .unsupported("no embedded preview") }
        guard let offset = Int(exactly: h.thumbnailOffset) else { throw .malformed("thumbnail offset overflow") }
        guard offset >= 72 else { throw .malformed("thumbnail overlaps the file header") }
        guard offset <= bytes.count else { throw .malformed("thumbnail offset outside file") }
        let record = PreviewBytes(bytes: bytes, base: offset)
        guard try record.slice(0, 8).elementsEqual([0xFF, 0xFF, 0xFF, 0xFF] + Array("Thmb".utf8)) else {
            throw .malformed("missing indexed thumbnail")
        }
        guard try record.le32(8) == 1, try record.slice(28, 1).elementsEqual([1]) else {
            throw .unsupported("thumbnail record version or encoding")
        }
        let size = Int(try record.le32(24))
        guard size <= maxPreviewBytes else { throw .limit("encoded preview exceeds 16 MiB") }
        guard try record.le32(16) == 29, try record.le32(20) == 0, UInt64(try record.le32(12)) == UInt64(size) + 13 else {
            throw .malformed("inconsistent thumbnail record lengths")
        }
        let pngStart = offset + 29
        _ = try record.slice(29, size)
        let png = PreviewBytes(bytes: bytes, base: pngStart, end: pngStart + size)
        guard try png.slice(0, 8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
              try png.be32(8) == 13,
              try png.slice(12, 4).elementsEqual("IHDR".utf8)
        else { throw .malformed("thumbnail is not a PNG") }
        let width = try png.be32(16)
        let height = try png.be32(20)
        guard width != 0, height != 0, width <= maxPreviewDimension, height <= maxPreviewDimension else {
            throw .limit("preview dimensions must be 1..4096")
        }
        // Bound work by bytes, not a file-supplied chunk count, and require exactly one complete PNG.
        var pos = 8
        var palette = false
        var imageData = false
        var imageDataEnded = false
        while true {
            let length = Int(try png.be32(pos))
            let (chunkSize, overflow) = length.addingReportingOverflow(12)
            guard !overflow else { throw .malformed("PNG chunk overflow") }
            let chunk = try png.slice(pos, chunkSize)
            let base = chunk.startIndex
            let checksumInput = chunk[(base + 4)..<(base + chunkSize - 4)]
            let stored = chunk[(base + chunkSize - 4)..<(base + chunkSize)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard Checksum.crc32(checksumInput) == stored else { throw .malformed("PNG chunk checksum") }
            let kind = Array(chunk[(base + 4)..<(base + 8)])
            guard kind.allSatisfy({ (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }) else {
                throw .malformed("PNG chunk type")
            }
            let name = Affinity.lossy(kind)
            switch name {
            case "IHDR" where pos == 8:
                break
            case "IHDR":
                throw .malformed("duplicate PNG header")
            case "PLTE":
                guard !palette, !imageData else { throw .malformed("PNG palette order") }
                palette = true
            case "IDAT":
                guard !imageDataEnded else { throw .malformed("non-contiguous PNG image data") }
                imageData = true
            case "IEND":
                guard imageData else { throw .malformed("PNG has no image data") }
            default:
                // An unknown chunk whose first letter is uppercase is critical.
                if (0x41...0x5A).contains(kind[0]) { throw .unsupported("unknown critical PNG chunk") }
            }
            if imageData, name != "IDAT" { imageDataEnded = true }
            // Native sample previews are plain, single-frame PNGs. Pixel allocation limits do not
            // necessarily bound aggregate compressed metadata; leave these layouts unsupported.
            if ["zTXt", "iTXt", "iCCP"].contains(name) { throw .unsupported("compressed PNG metadata in the preview") }
            if ["acTL", "fcTL", "fdAT"].contains(name) { throw .unsupported("animated PNG preview") }
            let (next, overflow2) = pos.addingReportingOverflow(chunkSize)
            guard !overflow2 else { throw .malformed("PNG offset overflow") }
            pos = next
            if name == "IEND" {
                guard length == 0, pos == size else { throw .malformed("PNG end or trailing data") }
                break
            }
        }
        return Preview(png: Array(bytes[pngStart..<(pngStart + size)]), range: pngStart..<(pngStart + size), width: width, height: height)
    }

    /// Bounds-checked reads relative to `base`, never past `end` (photocraft's `bytes_at`, `le32`, `be32`).
    private struct PreviewBytes {
        let bytes: [UInt8]
        let base: Int
        var end: Int

        init(bytes: [UInt8], base: Int, end: Int? = nil) {
            self.bytes = bytes
            self.base = base
            self.end = min(end ?? bytes.count, bytes.count)
        }

        func slice(_ offset: Int, _ length: Int) throws(AffinityError) -> ArraySlice<UInt8> {
            let (start, o1) = base.addingReportingOverflow(offset)
            let (stop, o2) = start.addingReportingOverflow(length)
            guard !o1, !o2, offset >= 0, length >= 0 else { throw .malformed("offset overflow") }
            guard start <= end, stop <= end else { throw .malformed("truncated record") }
            return bytes[start..<stop]
        }

        func le32(_ offset: Int) throws(AffinityError) -> UInt32 {
            try slice(offset, 4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }

        func be32(_ offset: Int) throws(AffinityError) -> UInt32 {
            try slice(offset, 4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
    }
}
