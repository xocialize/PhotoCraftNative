// `shmd` (metadata setting) layer block, and the HDR toning colour mode data of 32-bit files.
// Port of photocraft-psd (crates/psd/src/metadata.rs, hdr.rs), MIT OR Apache-2.0, © ArtCraft Team
// and the PhotoCraft contributors.

import Foundation

/// One `shmd` item: signature, key (`cmls` layer comp state, `cust`, `mlst`, `tmln`…), a copy-on-
/// sheet-duplication byte, 3 reserved bytes and the data (Photoshop pads it to even inside the
/// stored length, so parse/write is exact).
public struct PSDMetadataItem: Equatable, Sendable {
    public var signature: FourCC
    public var key: FourCC
    public var copyOnSheetDuplication: Bool
    public var reserved: [UInt8]
    public var data: Data

    public init(key: FourCC, data: Data) {
        signature = "8BIM"
        self.key = key
        copyOnSheetDuplication = false
        reserved = [0, 0, 0]
        var d = data
        if d.count % 2 == 1 { d.append(0) }
        self.data = d
    }

    /// The versioned descriptor most items carry (`cmls`: version 16 + descriptor).
    public var descriptor: PSDVersionedDescriptor? {
        // `cmls` and `cust` start with a u32 version, then the versioned descriptor.
        if let v = try? PSDVersionedDescriptor.parsePrefix(data.dropFirst(4)) { return v.0 }
        return try? PSDVersionedDescriptor.parsePrefix(data).0
    }

    public static func parse(_ data: Data) throws -> [PSDMetadataItem] {
        try data.withByteReader { r in
            let n = try r.u32()
            try r.checkCount(UInt64(n), minItemSize: 16)
            var out: [PSDMetadataItem] = []
            for _ in 0 ..< n {
                var it = PSDMetadataItem(key: "    ", data: Data())
                it.signature = try r.fourCC()
                it.key = try r.fourCC()
                it.copyOnSheetDuplication = try r.u8() != 0
                it.reserved = try r.bytes(3)
                it.data = try r.data(Int(try r.u32()))
                out.append(it)
            }
            guard r.isAtEnd else { throw PSDError.invalid("trailing bytes after metadata items") }
            return out
        }
    }

    public static func serialize(_ items: [PSDMetadataItem]) -> Data {
        var w = ByteWriter()
        w.u32(UInt32(items.count))
        for it in items {
            w.fourCC(it.signature)
            w.fourCC(it.key)
            w.u8(it.copyOnSheetDuplication ? 1 : 0)
            w.put(Array((it.reserved + [0, 0, 0]).prefix(3)))
            w.u32(UInt32(it.data.count))
            w.put(it.data)
        }
        return w.data
    }
}

/// HDR toning settings: the colour mode data every 32-bit Photoshop file carries. Photoshop 2026
/// refuses a 32-bit file whose colour mode data is empty ("the open options are incorrect",
/// photocraft #291), so writers must emit it. Layout observed from Photoshop-saved files
/// (photocraft-corpus); unknown fields hold the values Photoshop writes for a new document.
public enum PSDHDRToning {
    public static let toningKey: FourCC = "hdrt"
    public static let extraKey: FourCC = "hdra"

    public static func isToningData(_ d: Data) -> Bool { d.count >= 4 && Array(d.prefix(4)) == toningKey.bytes }

    /// A version 3 `hdrt` record (method 2, preset "Linear", identity curve) and a version 6
    /// `hdra` record: 110 bytes.
    public static func defaultData() -> Data {
        var w = ByteWriter(capacity: 110)
        w.fourCC(toningKey)
        w.u32(3)
        w.f32(0.23)
        w.u32(2)
        w.unicodeUnits(Array("Linear".utf16) + [0])
        w.u16(2); w.u16(2)
        for (input, output) in [(UInt16(0), UInt16(0)), (255, 255)] { w.u16(output); w.u16(input) }
        w.put([1, 1]); w.zeros(8)
        w.f32(16); w.u32(1); w.u32(0); w.f32(1)
        w.fourCC(extraKey)
        w.u32(6); w.u32(0); w.f32(20); w.f32(30); w.u32(0); w.u32(0); w.f32(1)
        w.zeros(6)
        return w.data
    }

    /// The colour mode data a writer emits for `depth` when it has nothing of its own to keep.
    public static func colorModeData(depth: UInt16) -> Data { depth == 32 ? defaultData() : Data() }
}
