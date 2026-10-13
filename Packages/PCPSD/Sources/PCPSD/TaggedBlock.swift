// Additional layer information ("tagged blocks"): stored raw (signature, key, data and the exact
// padding that followed them) so unknown and partly understood blocks round-trip byte for byte;
// `parsed` offers typed views of the simple keys.
// Port of photocraft-psd (crates/psd/src/tagged.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors. Section-divider handling (`lsct` and the older `lsdk`) cross-checked
// against PhotoDemon pdPSDLayer.cls (ParseLayer), BSD-2-Clause, © Tanner Helland and contributors.
//
// Beyond photocraft: in a PSB, a block whose key is not in the 8-byte-length table but whose
// 4-byte reading misaligns the next block is re-read with an 8-byte length (and vice versa), and
// the choice is recorded in `longLengthOverride` so the block is written back the same way. This
// is the failure class of photocraft #200 for keys Adobe adds later.

import Foundation

/// Keys whose length field is 8 bytes in PSB files: the thirteen the Adobe specification lists,
/// plus keys Photoshop writes with 8-byte lengths although the specification omits them.
public let psbLongKeys: Set<FourCC> = [
    "LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph", "FMsk", "lnk2", "FEid", "FXid", "PxSD",
    "lnk3", "lnkE", "pths", "extd", "extn", "FELS", "cinf", "artd",
]

/// Whether `key` uses an 8-byte length in `version` (by the key table).
public func usesLongLength(_ version: PSDVersion, _ key: FourCC) -> Bool {
    version.isPSB && psbLongKeys.contains(key)
}

/// Layer section divider type (`lsct`).
public enum PSDSectionType: Hashable, Sendable {
    /// 0: any other type of layer.
    case other
    /// 1: open folder.
    case openFolder
    /// 2: closed folder.
    case closedFolder
    /// 3: bounding section divider (hidden in the UI; the group's bottom end in file order).
    case boundingDivider
    case unknown(UInt32)

    public init(code: UInt32) {
        switch code {
        case 0: self = .other
        case 1: self = .openFolder
        case 2: self = .closedFolder
        case 3: self = .boundingDivider
        default: self = .unknown(code)
        }
    }

    public var code: UInt32 {
        switch self {
        case .other: 0
        case .openFolder: 1
        case .closedFolder: 2
        case .boundingDivider: 3
        case let .unknown(v): v
        }
    }

    public var isFolder: Bool { self == .openFolder || self == .closedFolder }
}

/// Section divider setting (`lsct` / `lsdk`).
public struct PSDSectionDivider: Hashable, Sendable {
    public var kind: PSDSectionType
    /// Group blend mode (present when the data is 12 bytes or more).
    public var blendMode: PSDBlendMode?
    /// Sub type: 0 normal, 1 scene group (present when 16 bytes or more).
    public var subType: UInt32?

    public init(kind: PSDSectionType, blendMode: PSDBlendMode? = nil, subType: UInt32? = nil) {
        self.kind = kind
        self.blendMode = blendMode
        self.subType = subType
    }
}

/// Typed view of a simple block.
public enum PSDBlockData: Equatable, Sendable {
    /// `luni`
    case unicodeName(String)
    /// `lsct` / `lsdk`
    case sectionDivider(PSDSectionDivider)
    /// `lyid`
    case layerID(UInt32)
    /// `lnsr`
    case nameSource(FourCC)
    /// `clbl`
    case blendClippedAsGroup(Bool)
    /// `infx`
    case blendInteriorElements(Bool)
    /// `knko`: 0 none, 1 shallow, 2 deep.
    case knockout(UInt8)
    /// `tsly`: transparency shapes layer.
    case transparencyShapes(Bool)
    /// `lmgm`: layer mask hides effects.
    case layerMaskHidesEffects(Bool)
    /// `vmgm`: vector mask hides effects.
    case vectorMaskHidesEffects(Bool)
    /// `lspf`: bit 0 transparency, 1 composite, 2 position locked, 31 all.
    case protection(UInt32)
    /// `lclr`: sheet colour index (0 none, 1 red, 2 orange, 3 yellow, 4 green, 5 blue, 6 violet, 7 gray).
    case sheetColor(UInt16)
    /// `iOpa`
    case fillOpacity(UInt8)
    /// `lyvr`: layer version.
    case layerVersion(UInt32)
    /// `shmd`: metadata setting, raw (see `PSDMetadataItem.parse`).
    case metadataSetting(Data)
}

/// A tagged block, stored raw.
public struct PSDTaggedBlock: Equatable, Sendable {
    /// `8BIM` or `8B64` (`MIB8` / `46B8` for a block kept in little-endian layout from a TIFF).
    public var signature: FourCC
    public var key: FourCC
    /// Block data exactly as covered by the length field.
    public var data: Data
    /// Bytes that followed the data before the next block. `nil` means the default: zero padding
    /// to a multiple of 4 for global blocks and 2 for layer blocks. Parsing yields `nil` whenever
    /// the stored padding equals the default, so the model stays canonical.
    public var padding: [UInt8]?
    /// PSB only: the length field width when it differs from the key table (`nil` = table).
    public var longLengthOverride: Bool?

    public init(key: FourCC, data: Data, signature: FourCC = "8BIM", padding: [UInt8]? = nil) {
        self.signature = signature
        self.key = key
        self.data = data
        self.padding = padding
        longLengthOverride = nil
    }

    public init(key: FourCC, bytes: [UInt8]) { self.init(key: key, data: Data(bytes)) }

    func isLong(_ version: PSDVersion) -> Bool {
        version.isPSB && (longLengthOverride ?? psbLongKeys.contains(key))
    }

    static func defaultPadding(_ len: Int, alignment: Int) -> Int { (alignment - len % alignment) % alignment }

    /// Typed view for simple keys: `nil` for keys without a typed parser, a thrown error when a known
    /// key's data is malformed.
    public func parsed() throws -> PSDBlockData? {
        try data.withByteReader { r -> PSDBlockData? in
            switch key {
            case "luni": return .unicodeName(try PSDUnicodeString.read(&r).string)
            case "lsct", "lsdk": return .sectionDivider(try PSDTaggedBlock.parseSection(&r))
            case "lyid": return .layerID(try r.u32())
            case "lnsr": return .nameSource(try r.fourCC())
            case "clbl": return .blendClippedAsGroup(try r.u8() != 0)
            case "infx": return .blendInteriorElements(try r.u8() != 0)
            case "knko": return .knockout(try r.u8())
            case "tsly": return .transparencyShapes(try r.u8() != 0)
            case "lmgm": return .layerMaskHidesEffects(try r.u8() != 0)
            case "vmgm": return .vectorMaskHidesEffects(try r.u8() != 0)
            case "lspf": return .protection(try r.u32())
            case "lclr": return .sheetColor(try r.u16())
            case "iOpa": return .fillOpacity(try r.u8())
            case "lyvr": return .layerVersion(try r.u32())
            case "shmd": return .metadataSetting(data)
            default: return nil
            }
        }
    }

    /// `parsed()` with errors as `nil`.
    public var typed: PSDBlockData? { (try? parsed()) ?? nil }

    static func parseSection(_ r: inout ByteReader) throws -> PSDSectionDivider {
        var s = PSDSectionDivider(kind: PSDSectionType(code: try r.u32()))
        if r.remaining >= 8 {
            let sig = try r.fourCC()
            guard sig == "8BIM" else { throw PSDError.invalidSignature(expected: "8BIM", found: sig) }
            s.blendMode = PSDBlendMode(key: try r.fourCC())
            if r.remaining >= 4 { s.subType = try r.u32() }
        }
        return s
    }

    // MARK: Constructors

    /// `luni`, data padded to a multiple of 4 as Photoshop writes it.
    public static func unicodeName(_ name: String) -> PSDTaggedBlock {
        var w = ByteWriter()
        w.unicodeUnits(Array(name.utf16))
        while w.count % 4 != 0 { w.u8(0) }
        return PSDTaggedBlock(key: "luni", data: w.data)
    }

    /// `lsct` with all fields present.
    public static func sectionDivider(_ kind: PSDSectionType, blendMode: PSDBlendMode? = nil, subType: UInt32? = nil) -> PSDTaggedBlock {
        var w = ByteWriter()
        w.u32(kind.code)
        if let b = blendMode {
            w.fourCC("8BIM")
            w.fourCC(b.key)
            if let s = subType { w.u32(s) }
        }
        return PSDTaggedBlock(key: "lsct", data: w.data)
    }

    public static func layerID(_ id: UInt32) -> PSDTaggedBlock { u32Block("lyid", id) }
    public static func nameSource(_ src: FourCC) -> PSDTaggedBlock { u32Block("lnsr", src.rawValue) }
    static func flag(_ key: FourCC, _ v: UInt8) -> PSDTaggedBlock { PSDTaggedBlock(key: key, bytes: [v, 0, 0, 0]) }
    static func u32Block(_ key: FourCC, _ v: UInt32) -> PSDTaggedBlock {
        var w = ByteWriter()
        w.u32(v)
        return PSDTaggedBlock(key: key, data: w.data)
    }
    public static func blendClippedAsGroup(_ v: Bool) -> PSDTaggedBlock { flag("clbl", v ? 1 : 0) }
    public static func blendInteriorElements(_ v: Bool) -> PSDTaggedBlock { flag("infx", v ? 1 : 0) }
    public static func knockout(_ v: UInt8) -> PSDTaggedBlock { flag("knko", v) }
    public static func transparencyShapes(_ v: Bool) -> PSDTaggedBlock { flag("tsly", v ? 1 : 0) }
    public static func layerMaskHidesEffects(_ v: Bool) -> PSDTaggedBlock { flag("lmgm", v ? 1 : 0) }
    public static func vectorMaskHidesEffects(_ v: Bool) -> PSDTaggedBlock { flag("vmgm", v ? 1 : 0) }
    public static func protection(_ flags: UInt32) -> PSDTaggedBlock { u32Block("lspf", flags) }
    public static func sheetColor(_ color: UInt16) -> PSDTaggedBlock {
        PSDTaggedBlock(key: "lclr", bytes: [UInt8(color >> 8), UInt8(color & 0xFF), 0, 0, 0, 0, 0, 0])
    }
    public static func fillOpacity(_ v: UInt8) -> PSDTaggedBlock { flag("iOpa", v) }

    /// A newly generated layer block whose data is zero-padded to a multiple of 4 *inside* the
    /// length. Photoshop 4-aligns every layer block it writes (12,949 of 12,949 measured), and
    /// Photoshop 27.11 refuses a `grdm` block whose length is not a multiple of 4. The Adobe spec
    /// only asks for even lengths. Use this for blocks a writer generates; preserved blocks keep
    /// their bytes.
    public static func fourAligned(key: FourCC, data: Data, signature: FourCC = "8BIM") -> PSDTaggedBlock {
        PSDTaggedBlock(key: key, data: data, signature: signature).fourAligned()
    }

    /// This block with its data zero-padded to a multiple of 4 inside the length (unchanged when
    /// already aligned).
    public func fourAligned() -> PSDTaggedBlock {
        let pad = (4 - data.count % 4) % 4
        guard pad > 0 else { return self }
        var b = self
        b.data = data + Data(count: pad)
        return b
    }
    public static func layerVersion(_ v: UInt32) -> PSDTaggedBlock { u32Block("lyvr", v) }

    // MARK: Strict structure check

    /// Strictly re-parses blocks whose data carries its own sizes, so a block a strict reader would
    /// reject is caught before writing: `PlLd` (`plcL`), `SoLd`/`SoLE` (`soLD` with an `Idnt`,
    /// an 8-double `Trnf` and a well-formed `filterFX` stack), `lnk2`/`lnk3`/`lnkD` (linked
    /// files), `lfx2`/`lfxs`/`lmfx` (object effects) and `FEid`/`FXid` (filter effects). Every
    /// inner length must stay inside the block and the parse must end at the data's end apart
    /// from up to three zero bytes. Other keys pass.
    public func checkStructure() throws {
        try data.withByteReader { r in
            switch key {
            case "PlLd":
                try expectKind(&r, "plcL")
                _ = try r.u32()
                _ = try r.pascal(align: 1)
                try r.skip(4 * 4 + 8 * 8)
                _ = try r.u32()
                _ = try PSDVersionedDescriptor.read(&r)
            case "SoLd", "SoLE":
                try expectKind(&r, "soLD")
                _ = try r.u32()
                let d = try PSDVersionedDescriptor.read(&r)
                do { try checkPlacedDescriptor(d.descriptor) } catch let PSDError.invalid(m) { throw PSDError.invalid("\(key): \(m)") }
            case "lfx2", "lfxs", "lmfx":
                _ = try r.u32()
                _ = try PSDVersionedDescriptor.read(&r)
            case "lnk2", "lnk3", "lnkD":
                while r.remaining >= 8 {
                    let len = try r.u64()
                    var item = try r.sub(u64: len)
                    let kind = item.remaining >= 4 ? try item.fourCC() : FourCC("????")
                    guard ["liFD", "liFE", "liFA"].contains(kind) else { throw PSDError.invalid("\(key): linked item of unknown type") }
                    if kind == "liFD" {
                        do { try checkEmbeddedItem(&item) } catch let e as PSDError { throw PSDError.invalid("\(key): embedded file: \(e)") }
                    }
                    let pad = min(Int((4 - len % 4) % 4), r.remaining)
                    try r.skip(pad)
                }
            case "FEid", "FXid":
                do { _ = try PSDFilterEffects(bytes: data) } catch let e as PSDError { throw PSDError.invalid("\(key): \(e)") }
                return
            default:
                return
            }
            let rest = r.rest
            if rest.count > 3 || rest.contains(where: { $0 != 0 }) {
                throw PSDError.invalid("\(key): \(rest.count) unexpected bytes after the block structure")
            }
        }
    }

    private func expectKind(_ r: inout ByteReader, _ kind: FourCC) throws {
        let found = try r.fourCC()
        guard found == kind else { throw PSDError.invalid("expected \(kind) structure, found \(found)") }
    }

    private func checkPlacedDescriptor(_ d: PSDDescriptor) throws {
        guard case .text = d["Idnt"] else { throw PSDError.invalid("no Idnt (unique id)") }
        guard case let .list(l)? = d["Trnf"], l.count == 8, l.allSatisfy({ if case .double = $0 { true } else { false } }) else {
            throw PSDError.invalid("Trnf is not eight doubles")
        }
        guard let fx = d["filterFX"] else { return }
        guard case let .descriptor(fxd) = fx else { throw PSDError.invalid("filterFX is not an object") }
        guard case let .list(list)? = fxd["filterFXList"] else { throw PSDError.invalid("filterFX has no filterFXList") }
        for (i, item) in list.enumerated() {
            guard case let .descriptor(f) = item else { throw PSDError.invalid("filter \(i) is not an object") }
            let ok = f["Nm  "]?.text != nil && f["blendOptions"]?.descriptor != nil && f["enab"]?.bool != nil
                && { if case .integer = f["filterID"] { true } else { false } }()
                && (f["Fltr"] == nil || f["Fltr"]?.descriptor != nil)
            if !ok { throw PSDError.invalid("filter \(i) lacks Nm/blendOptions/enab/filterID") }
        }
    }

    private func checkEmbeddedItem(_ r: inout ByteReader) throws {
        let version = try r.u32()
        guard (1 ... 16).contains(version) else { throw PSDError.invalid("version \(version)") }
        _ = try r.pascal(align: 1)
        _ = try r.unicodeUnits()
        try r.skip(8)
        let len = try r.u64()
        if try r.u8() != 0 { _ = try PSDVersionedDescriptor.read(&r) }
        _ = try r.data(u64: len)
    }

    // MARK: IO

    func write<S: ByteSink>(to s: inout S, version: PSDVersion, alignment: Int) throws {
        try s.fourCC(signature)
        try s.fourCC(key)
        try s.length(UInt64(data.count), long: isLong(version))
        try s.write(data)
        if let p = padding { try s.write(p) } else { try s.zeros(PSDTaggedBlock.defaultPadding(data.count, alignment: alignment)) }
    }

    /// Serialized size as a layer block (2-byte alignment).
    public func encodedLength(_ version: PSDVersion, alignment: Int = 2) -> Int {
        8 + (isLong(version) ? 8 : 4) + data.count + (padding?.count ?? PSDTaggedBlock.defaultPadding(data.count, alignment: alignment))
    }
}

/// `8BIM` / `8B64`, or the markers `MIB8` / `46B8` that a layered-TIFF transcoder gives a block
/// kept verbatim in little-endian layout (photocraft tagged.rs `is_sig`).
func hasBlockSignature(_ raw: UnsafeRawBufferPointer) -> Bool {
    guard raw.count >= 4 else { return false }
    let v = UInt32(bigEndian: raw.loadUnaligned(as: UInt32.self))
    return v == FourCC("8BIM").rawValue || v == FourCC("8B64").rawValue || v == FourCC("MIB8").rawValue || v == FourCC("46B8").rawValue
}

/// Smallest `k ≤ 3` after which the next signature (or the region's end) follows, if any.
private func alignedPadding(_ rest: UnsafeRawBufferPointer) -> Int? {
    for k in 0 ... 3 {
        if k == rest.count { return k }
        if k < rest.count, hasBlockSignature(UnsafeRawBufferPointer(rebasing: rest[k...])) { return k }
    }
    return nil
}

/// Reads tagged blocks until the reader is exhausted. Bytes that do not form a block (fewer than 12
/// bytes, or no valid signature) are returned as trailing data. `consume` may take a block's
/// payload instead of storing it (the global `Lr16`/`Lr32` layer info).
func readBlocks(_ r: inout ByteReader, version: PSDVersion, alignment: Int,
                consume: (Int, PSDTaggedBlock) throws -> Bool = { _, _ in false }) throws -> ([PSDTaggedBlock], [UInt8]) {
    var blocks: [PSDTaggedBlock] = []
    while true {
        let rest = r.rest
        if rest.count < 12 || !hasBlockSignature(rest) {
            let trailing = Array(rest)
            try r.skip(rest.count)
            return (blocks, trailing)
        }
        let start = r.pos
        let signature = try r.fourCC()
        let key = try r.fourCC()
        let tableLong = usesLongLength(version, key)
        var long = tableLong
        var override: Bool?
        if version.isPSB {
            // Try the table's width; fall back to the other when it does not land on a block boundary.
            let primary = try? probeBlock(r, long: tableLong)
            if primary == nil || primary == .some(false) {
                if (try? probeBlock(r, long: !tableLong)) == .some(true) {
                    long = !tableLong
                    override = long
                }
            }
        }
        let len = try r.lengthField(long: long)
        let data = try r.data(u64: len)
        let rest2 = r.rest
        let def = PSDTaggedBlock.defaultPadding(data.count, alignment: alignment)
        let pad = alignedPadding(rest2) ?? (rest2.count >= def && rest2.prefix(def).allSatisfy { $0 == 0 } ? def : 0)
        let padBytes = try r.bytes(pad)
        let padding: [UInt8]? = (padBytes.count == def && padBytes.allSatisfy { $0 == 0 }) ? nil : padBytes
        var block = PSDTaggedBlock(key: key, data: data, signature: signature, padding: padding)
        block.longLengthOverride = override
        _ = start
        if try !consume(blocks.count, block) { blocks.append(block) }
    }
}

/// Whether reading a length of the given width at `r` ends on a block boundary (`true`), fits but
/// misaligns (`false`), or overruns (throws).
private func probeBlock(_ reader: ByteReader, long: Bool) throws -> Bool {
    var r = reader
    let len = try r.lengthField(long: long)
    guard len <= UInt64(r.remaining) else { throw PSDError.unexpectedEOF(offset: r.pos, needed: 1) }
    try r.skip(Int(len))
    return alignedPadding(r.rest) != nil
}

func writeBlocks<S: ByteSink>(_ blocks: [PSDTaggedBlock], to s: inout S, version: PSDVersion, alignment: Int) throws {
    for b in blocks { try b.write(to: &s, version: version, alignment: alignment) }
}
