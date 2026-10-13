// Smart objects: `PlLd` (placed layer, CS2 on), `SoLd`/`SoLE` (placed layer data, CS3 on) and the
// linked-file blocks `lnk2`/`lnk3`/`lnkD`/`lnkE` that embed or reference the source files.
// Format knowledge ported from photocraft-psd (crates/psd/src/tagged.rs: check_structure,
// check_embedded_item) and photocraft-io (crates/io/src/linked.rs, smart_map.rs, blocks.rs),
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors; item layout from Adobe's
// specification ("Linked Layer", "Placed Layer", "Placed Layer Data").
//
// Beyond photocraft (#2465 "CS2-era smart object unavailable"): a layer with only a `PlLd` block
// (no `SoLd`, as CS2 wrote) resolves through the PlLd unique id; linked items whose open-descriptor
// flag is missing or whose data length disagrees with the item are still read (the data runs to the
// item's end); every item stays raw so unknown versions round-trip.

import Foundation

/// `PlLd`: the legacy placed-layer record (Photoshop still writes it beside `SoLd`).
public struct PSDPlacedLayer: Equatable, Sendable {
    /// `plcL`.
    public var type: FourCC
    /// 3.
    public var version: UInt32
    public var uniqueID: String
    public var pageNumber: UInt32
    public var totalPages: UInt32
    public var antiAliasPolicy: UInt32
    /// 0 unknown, 1 vector, 2 raster, 3 image stack.
    public var placedLayerType: UInt32
    /// Corners of the placed content: x0 y0 x1 y1 x2 y2 x3 y3 (top-left, top-right, bottom-right,
    /// bottom-left) in document pixels.
    public var transform: [Double]
    public var warpVersion: UInt32
    public var warp: PSDVersionedDescriptor?
    public var trailing: Data

    public init(bytes: Data) throws {
        self = try bytes.withByteReader { r in
            let type = try r.fourCC()
            guard type == "plcL" else { throw PSDError.invalid("PlLd: expected plcL, found \(type)") }
            let version = try r.u32()
            let uid = String(decoding: try r.pascal(align: 1), as: UTF8.self)
            let page = try r.u32(), total = try r.u32(), aa = try r.u32(), kind = try r.u32()
            let transform = try (0 ..< 8).map { _ in try r.f64() }
            var warpVersion: UInt32 = 0
            var warp: PSDVersionedDescriptor?
            if r.remaining >= 8 {
                let mark = r
                warpVersion = try r.u32()
                if let w = try? PSDVersionedDescriptor.read(&r) { warp = w } else { r = mark; warpVersion = 0 }
            }
            return PSDPlacedLayer(type: type, version: version, uniqueID: uid, pageNumber: page, totalPages: total, antiAliasPolicy: aa,
                                  placedLayerType: kind, transform: transform, warpVersion: warpVersion, warp: warp, trailing: try r.data(r.remaining))
        }
    }

    public init(type: FourCC = "plcL", version: UInt32 = 3, uniqueID: String, pageNumber: UInt32 = 1, totalPages: UInt32 = 1, antiAliasPolicy: UInt32 = 16,
                placedLayerType: UInt32 = 2, transform: [Double], warpVersion: UInt32 = 0, warp: PSDVersionedDescriptor?, trailing: Data = Data()) {
        self.type = type
        self.version = version
        self.uniqueID = uniqueID
        self.pageNumber = pageNumber
        self.totalPages = totalPages
        self.antiAliasPolicy = antiAliasPolicy
        self.placedLayerType = placedLayerType
        self.transform = transform
        self.warpVersion = warpVersion
        self.warp = warp
        self.trailing = trailing
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        w.fourCC(type)
        w.u32(version)
        w.pascal(Array(uniqueID.utf8), align: 1)
        w.u32(pageNumber); w.u32(totalPages); w.u32(antiAliasPolicy); w.u32(placedLayerType)
        for i in 0 ..< 8 { w.f64(i < transform.count ? transform[i] : 0) }
        if let warp {
            w.u32(warpVersion)
            warp.write(&w)
        }
        w.put(trailing)
        return w.data
    }
}

/// `SoLd` / `SoLE`: `soLD`, a version (4 or 5) and the placed-layer descriptor.
public struct PSDPlacedLayerData: Equatable, Sendable {
    public var identifier: FourCC
    public var version: UInt32
    public var descriptor: PSDVersionedDescriptor
    public var trailing: Data

    public init(descriptor: PSDDescriptor, version: UInt32 = 4) {
        identifier = "soLD"
        self.version = version
        self.descriptor = PSDVersionedDescriptor(descriptor)
        trailing = Data()
    }

    public init(bytes: Data) throws {
        (identifier, version, descriptor, trailing) = try bytes.withByteReader { r in
            let id = try r.fourCC()
            guard id == "soLD" else { throw PSDError.invalid("SoLd: expected soLD, found \(id)") }
            return (id, try r.u32(), try PSDVersionedDescriptor.read(&r), try r.data(r.remaining))
        }
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        w.fourCC(identifier)
        w.u32(version)
        descriptor.write(&w)
        w.put(trailing)
        return w.data
    }

    var d: PSDDescriptor { descriptor.descriptor }
    /// The source's unique id (`Idnt`), matching a linked-file item.
    public var uniqueID: String? { d.text("Idnt") }
    /// This placement's id (`placed`), matching filter-effects caches.
    public var placedID: String? { d.text("placed") }
    /// The 8-double corner transform (`Trnf`).
    public var transform: [Double]? { d.list("Trnf")?.compactMap(\.number) }
    /// The non-affine (perspective) corner transform, when distorted.
    public var nonAffineTransform: [Double]? { d.list("nonAffineTransform")?.compactMap(\.number) }
    /// Content size (`Sz  `: `Wdth`, `Hght`).
    public var size: (width: Double, height: Double)? {
        guard let s = d.descriptor("Sz  "), let w = s.number("Wdth"), let h = s.number("Hght") else { return nil }
        return (w, h)
    }
    /// Content resolution (`Rslt`).
    public var resolution: Double? { d.number("Rslt") }
    public var warp: PSDDescriptor? { d.descriptor("warp") }
    /// Smart filters (`filterFX` → `filterFXList`).
    public var smartFilters: [PSDDescriptor] { d.descriptor("filterFX")?.list("filterFXList")?.compactMap(\.descriptor) ?? [] }
    public var pageNumber: Double? { d.number("PgNm") }
}

/// One item of a linked-file block. The item bytes are kept verbatim; `info` is a parsed view.
public struct PSDLinkedFile: Equatable, Sendable {
    public struct Info: Equatable, Sendable {
        /// `liFD` embedded data, `liFE` external file, `liFA` alias.
        public var kind: FourCC
        public var version: UInt32
        public var uniqueID: String
        public var fileName: String
        public var fileType: FourCC
        public var creator: FourCC
        public var declaredLength: UInt64
        public var openDescriptor: PSDVersionedDescriptor?
        /// `liFE`: the linked file descriptor.
        public var linkedFileDescriptor: PSDVersionedDescriptor?
        /// `liFE` version > 3: year, month, day, hour, minute, seconds.
        public var timestamp: (year: UInt32, month: UInt8, day: UInt8, hour: UInt8, minute: UInt8, seconds: Double)?
        /// The embedded (or, for `liFE`, cached) file bytes.
        public var data: Data
        /// Version ≥ 5.
        public var childDocumentID: String?
        /// Version ≥ 6.
        public var assetModTime: Double?
        /// Version ≥ 7.
        public var assetLocked: Bool?
        /// The item was read with the lenient layout (no open-descriptor flag / length mismatch).
        public var lenient: Bool

        public static func == (a: Info, b: Info) -> Bool {
            a.kind == b.kind && a.version == b.version && a.uniqueID == b.uniqueID && a.fileName == b.fileName && a.data == b.data
                && a.childDocumentID == b.childDocumentID && a.assetLocked == b.assetLocked && a.declaredLength == b.declaredLength
        }
    }

    /// Item bytes (after its u64 length).
    public var raw: Data
    /// Bytes after the item (Photoshop pads items to 4).
    public var padding: [UInt8]

    public init(raw: Data, padding: [UInt8]? = nil) {
        self.raw = raw
        self.padding = padding ?? [UInt8](repeating: 0, count: (4 - raw.count % 4) % 4)
    }

    /// The item, read strictly first and leniently when that fails.
    public var info: Info? {
        if let i = try? PSDLinkedFile.parse(raw, lenient: false) { return i }
        return try? PSDLinkedFile.parse(raw, lenient: true)
    }

    /// The item read strictly, as photocraft's `check_embedded_item` and Photoshop's layout demand:
    /// a known type, version 1–16, the open-descriptor flag present, and (for `liFD`) the declared
    /// data length inside the item. `nil` when any of that fails.
    public var strictInfo: Info? { try? parsedInfo(strict: true) }

    /// The item, read strictly (`strict`) or leniently; throws what made it unreadable.
    public func parsedInfo(strict: Bool) throws -> Info {
        guard let i = try PSDLinkedFile.parse(raw, lenient: !strict) else { throw PSDError.invalid("linked item unreadable") }
        return i
    }

    static func parse(_ item: Data, lenient: Bool) throws -> Info? {
        try item.withByteReader { r -> Info? in
            let kind = try r.fourCC()
            guard ["liFD", "liFE", "liFA"].contains(kind) else { throw PSDError.invalid("linked item of unknown type \(kind)") }
            let version = try r.u32()
            if !lenient, !(1 ... 16).contains(version) { throw PSDError.invalid("linked item version \(version)") }
            let uid = String(decoding: try r.pascal(align: 1), as: UTF8.self)
            let name = PSDUnicodeString(units: try r.unicodeUnits()).string
            let fileType = try r.fourCC(), creator = try r.fourCC()
            let len = try r.u64()
            var info = Info(kind: kind, version: version, uniqueID: uid, fileName: name, fileType: fileType, creator: creator,
                            declaredLength: len, data: Data(), lenient: lenient)
            if !lenient {
                if try r.u8() != 0 { info.openDescriptor = try PSDVersionedDescriptor.read(&r) }
            } else if r.peekU8() == 0 || r.peekU8() == 1 {
                // Lenient: a flag may or may not be present; take it only if what follows parses.
                let mark = r
                if try r.u8() == 1 {
                    if let d = try? PSDVersionedDescriptor.read(&r) { info.openDescriptor = d } else { r = mark }
                }
            }
            switch kind {
            case "liFE":
                info.linkedFileDescriptor = try PSDVersionedDescriptor.read(&r)
                if version > 3 {
                    info.timestamp = (try r.u32(), try r.u8(), try r.u8(), try r.u8(), try r.u8(), try r.f64())
                }
                let size = try r.u64()
                if version > 2 { info.data = try r.data(u64: min(size, UInt64(r.remaining))) }
            case "liFA":
                try r.skip(min(8, r.remaining))
            default:
                if lenient {
                    info.data = try r.data(Int(min(len, UInt64(r.remaining))))
                } else {
                    info.data = try r.data(u64: len)
                }
            }
            if version >= 5, r.remaining >= 4 { info.childDocumentID = PSDUnicodeString(units: try r.unicodeUnits()).string }
            if version >= 6, r.remaining >= 8 { info.assetModTime = try r.f64() }
            if version >= 7, r.remaining >= 1 { info.assetLocked = try r.u8() != 0 }
            if kind == "liFE", version == 2 { info.data = try r.data(r.remaining) }
            return info
        }
    }

    /// A new embedded (`liFD`) item, version 7 as current Photoshop writes. The file name is
    /// NUL-terminated with the terminator counted, as in every item Photoshop writes (86/86 in the
    /// corpus); readers strip it.
    public static func embedded(uniqueID: String, fileName: String, fileType: FourCC, data: Data, creator: FourCC = "8BIM") -> PSDLinkedFile {
        var w = ByteWriter()
        w.fourCC("liFD")
        w.u32(7)
        w.pascal(Array(uniqueID.utf8.prefix(255)), align: 1)
        w.unicodeUnits(Array(fileName.utf16) + [0])
        w.fourCC(fileType)
        w.fourCC(creator)
        w.u64(UInt64(data.count))
        w.u8(0)
        w.put(data)
        w.unicodeUnits([])
        w.f64(0)
        w.u8(0)
        return PSDLinkedFile(raw: w.data)
    }
}

/// A linked-file block (`lnk2`, `lnk3`, `lnkD`, `lnkE`): u64-length items, each padded to 4.
public struct PSDLinkedFiles: Equatable, Sendable {
    public var items: [PSDLinkedFile]
    public var trailing: Data

    public init(items: [PSDLinkedFile]) {
        self.items = items
        trailing = Data()
    }

    public init(bytes: Data) throws {
        (items, trailing) = try bytes.withByteReader { r in
            var items: [PSDLinkedFile] = []
            while r.remaining >= 8 {
                let mark = r
                let len = try r.u64()
                guard len <= UInt64(r.remaining) else {
                    r = mark
                    break
                }
                let raw = try r.data(Int(len))
                let pad = min(Int((4 - len % 4) % 4), r.remaining)
                let p = try r.bytes(pad)
                items.append(PSDLinkedFile(raw: raw, padding: p))
            }
            return (items, try r.data(r.remaining))
        }
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        for it in items {
            w.u64(UInt64(it.raw.count))
            w.put(it.raw)
            w.put(it.padding)
        }
        w.put(trailing)
        return w.data
    }

    public func file(uniqueID: String) -> PSDLinkedFile.Info? {
        items.lazy.compactMap(\.info).first { $0.uniqueID == uniqueID }
    }
}

/// A smart object as the engine sees it: placement, source id and the source file when embedded.
public struct PSDSmartObject: Sendable {
    public var layerIndex: Int
    public var uniqueID: String
    public var placedID: String?
    /// Corner transform (8 doubles).
    public var transform: [Double]?
    public var placedData: PSDPlacedLayerData?
    public var placedLayer: PSDPlacedLayer?
    public var linkedFile: PSDLinkedFile.Info?
    /// `SoLE`: the layer links an external file.
    public var isExternal: Bool
}

extension PSDFile {
    static let linkedFileKeys: [FourCC] = ["lnk2", "lnk3", "lnkD", "lnkE"]

    /// Every linked-file item of the document's global blocks.
    public var linkedFiles: [PSDLinkedFile.Info] {
        globalBlocks.filter { PSDFile.linkedFileKeys.contains($0.key) }
            .compactMap { try? PSDLinkedFiles(bytes: $0.data) }
            .flatMap { $0.items.compactMap(\.info) }
    }

    /// The smart object of layer `index` (`SoLd`/`SoLE`, else a CS2-style lone `PlLd`), with its
    /// source resolved through the global linked-file blocks.
    public func smartObject(layer index: Int) -> PSDSmartObject? {
        guard index >= 0, index < layers.count else { return nil }
        let rec = layers[index]
        let soBlock = rec.block("SoLd") ?? rec.block("SoLE")
        let so = soBlock.flatMap { try? PSDPlacedLayerData(bytes: $0.data) }
        let pl = rec.block("PlLd").flatMap { try? PSDPlacedLayer(bytes: $0.data) }
        guard let uid = so?.uniqueID ?? pl?.uniqueID else { return nil }
        let linked = linkedFiles.first { $0.uniqueID == uid }
        return PSDSmartObject(layerIndex: index, uniqueID: uid, placedID: so?.placedID, transform: so?.transform ?? pl?.transform,
                              placedData: so, placedLayer: pl, linkedFile: linked, isExternal: soBlock?.key == "SoLE")
    }
}
