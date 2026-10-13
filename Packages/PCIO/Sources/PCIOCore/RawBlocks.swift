// The preserved-block list the PSD exporter edits (photocraft's `Vec<([u8; 4], Vec<u8>)>`), and
// helpers for it.
// Port support for photocraft-io (crates/io/src/psd_export.rs, blocks.rs, comps_map.rs,
// vector_map.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import PCDocument
import PCPSD

/// An ordered list of (key, data) tagged blocks.
public typealias RawBlocks = [(key: FourCC, data: [UInt8])]

public enum RawBlockList {
    /// Replaces the data of the first `key` block, else inserts before the first `before` block,
    /// else appends (photocraft `upsert`).
    public static func upsert(_ raw: inout RawBlocks, _ key: FourCC, _ data: [UInt8], before: FourCC? = nil) {
        if let i = raw.firstIndex(where: { $0.key == key }) {
            raw[i].data = data
            return
        }
        if let b = before, let i = raw.firstIndex(where: { $0.key == b }) {
            raw.insert((key, data), at: i)
        } else {
            raw.append((key, data))
        }
    }

    /// The index of the first block whose key is the first of `keys` present (priority order).
    public static func firstIndex(_ raw: RawBlocks, _ keys: [FourCC]) -> Int? {
        for k in keys { if let i = raw.firstIndex(where: { $0.key == k }) { return i } }
        return nil
    }

    /// The data of the first `key` block.
    public static func get(_ raw: RawBlocks, _ key: FourCC) -> [UInt8]? { raw.first { $0.key == key }?.data }

    /// PCDocument's preserved blocks as a raw list.
    public static func from(_ blocks: [PSDLayerBlock]) -> RawBlocks { blocks.map { (FourCC($0.key), $0.data) } }

    /// A raw list as PCDocument's preserved blocks.
    public static func toDocument(_ raw: RawBlocks) -> [PSDLayerBlock] { raw.map { PSDLayerBlock(key: $0.key.psdKey, data: $0.data) } }
}
