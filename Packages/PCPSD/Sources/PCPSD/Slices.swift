// Slices image resource (1050): version 6 binary layout (with its optional trailing descriptor), and
// versions 7/8 as one versioned descriptor.
// Port of photocraft-psd (crates/psd/src/slices.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors. Writing always produces version 6 (or 7 via `descriptorBytes`); callers
// wanting byte-exact output keep the raw resource while slices are unchanged.

import Foundation

public struct PSDSlice: Hashable, Sendable {
    public var id: UInt32 = 0
    public var groupID: UInt32 = 0
    /// 0 auto-generated, 1 layer-based, 2 user-drawn.
    public var origin: UInt32 = 0
    /// `lyid` of a layer-based slice.
    public var layerID: UInt32?
    public var name = ""
    /// 0 no image, 1 image, 2 table.
    public var kind: UInt32 = 1
    /// Left, top, right, bottom.
    public var rect: [Int32] = [0, 0, 0, 0]
    public var url = ""
    public var target = ""
    public var message = ""
    public var alt = ""
    public var cellTextIsHTML = false
    public var cellText = ""
    public var horizontalAlign: UInt32 = 0
    public var verticalAlign: UInt32 = 0
    /// Alpha, red, green, blue.
    public var color: [UInt8] = [0, 0, 0, 0]
    /// Top, left, bottom, right outsets of a layer-based slice.
    public var outsets: [Int32] = [0, 0, 0, 0]
    public init() {}
}

public struct PSDSlices: Equatable, Sendable {
    /// Version read (6, 7 or 8).
    public var version: UInt32 = 6
    /// Top, left, bottom, right.
    public var bounds: [Int32] = [0, 0, 0, 0]
    public var groupName = ""
    public var slices: [PSDSlice] = []
    /// Version 7/8 source: the descriptor as read, written back unchanged while the parsed fields are.
    var source: (descriptor: PSDVersionedDescriptor, tail: Data, bounds: [Int32], groupName: String, slices: [PSDSlice])?
    /// Version 6: the bytes after the slice records (the Photoshop 7+ descriptor), kept likewise.
    var v6Tail: (tail: Data, bounds: [Int32], groupName: String, slices: [PSDSlice])?
    public init() {}

    public static func == (a: PSDSlices, b: PSDSlices) -> Bool {
        a.version == b.version && a.bounds == b.bounds && a.groupName == b.groupName && a.slices == b.slices
    }

    public init(bytes: Data) throws {
        self = try bytes.withByteReader { r in
            let version = try r.u32()
            switch version {
            case 6: return try PSDSlices.readV6(&r)
            case 7, 8:
                let vd = try PSDVersionedDescriptor.read(&r)
                let tail = try r.data(r.remaining)
                let d = vd.descriptor
                var s = PSDSlices()
                s.version = version
                s.bounds = PSDSlices.bounds(d, "bounds") ?? [0, 0, 0, 0]
                s.groupName = d.text("baseName") ?? ""
                s.slices = (d.list("slices") ?? []).compactMap { $0.descriptor.map(PSDSlices.slice(from:)) }
                s.source = (vd, tail, s.bounds, s.groupName, s.slices)
                return s
            default:
                throw PSDError.invalid("unsupported slices resource version \(version)")
            }
        }
    }

    static func ustr(_ r: inout ByteReader) throws -> String { try PSDUnicodeString.read(&r).string }

    static func readV6(_ r: inout ByteReader) throws -> PSDSlices {
        var s = PSDSlices()
        s.bounds = [try r.i32(), try r.i32(), try r.i32(), try r.i32()]
        s.groupName = try ustr(&r)
        let n = Int(try r.u32())
        guard n <= r.remaining / 16 else { throw PSDError.invalid("slice count exceeds the resource size") }
        for _ in 0 ..< n {
            var x = PSDSlice()
            x.id = try r.u32()
            x.groupID = try r.u32()
            x.origin = try r.u32()
            if x.origin == 1 { x.layerID = try r.u32() }
            x.name = try ustr(&r)
            x.kind = try r.u32()
            x.rect = [try r.i32(), try r.i32(), try r.i32(), try r.i32()]
            x.url = try ustr(&r)
            x.target = try ustr(&r)
            x.message = try ustr(&r)
            x.alt = try ustr(&r)
            x.cellTextIsHTML = try r.u8() != 0
            x.cellText = try ustr(&r)
            x.horizontalAlign = try r.u32()
            x.verticalAlign = try r.u32()
            x.color = [try r.u8(), try r.u8(), try r.u8(), try r.u8()]
            s.slices.append(x)
        }
        // Optional trailing descriptor (Photoshop 7+): per-slice extras such as outsets. Kept raw
        // (with the records' snapshot) so an unchanged resource is written back exactly.
        let tailData = Data(r.rest)
        if r.remaining >= 4, let vd = try? PSDVersionedDescriptor.read(&r), let items = vd.descriptor.list("slices") {
            for v in items {
                guard let d = v.descriptor else { continue }
                let extra = slice(from: d)
                if let i = s.slices.firstIndex(where: { $0.id == extra.id }) { s.slices[i].outsets = extra.outsets }
            }
        }
        s.v6Tail = (tailData, s.bounds, s.groupName, s.slices)
        return s
    }

    static func int(_ d: PSDDescriptor, _ key: String) -> Int64? { d[key]?.number.map { Int64($0) } }

    static func bounds(_ d: PSDDescriptor, _ key: String) -> [Int32]? {
        guard let b = d.descriptor(key) else { return nil }
        func g(_ k: String) -> Int32 { Int32(clamping: int(b, k) ?? 0) }
        return [g("Top "), g("Left"), g("Btom"), g("Rght")]
    }

    static func slice(from d: PSDDescriptor) -> PSDSlice {
        var s = PSDSlice()
        let b = bounds(d, "bounds") ?? [0, 0, 0, 0]
        if d.enumValue("bgColorType") == "Clr ", let c = d.descriptor("bgColor") {
            func g(_ k: String) -> UInt8 { UInt8(clamping: int(c, k) ?? 0) }
            s.color = [c["alpha"] != nil ? g("alpha") : 255, g("Rd  "), g("Grn "), g("Bl  ")]
        }
        s.id = UInt32(truncatingIfNeeded: int(d, "sliceID") ?? 0)
        s.groupID = UInt32(truncatingIfNeeded: int(d, "groupID") ?? 0)
        switch d.enumValue("origin") {
        case "autoGenerated"?: s.origin = 0
        case "layerGenerated"?, "layer"?: s.origin = 1
        default: s.origin = 2
        }
        s.layerID = int(d, "layerID").map { UInt32(truncatingIfNeeded: $0) }
        s.name = d.text("Nm  ") ?? ""
        switch d.enumValue("Type") {
        case "noImage"?: s.kind = 0
        case "Tbl "?, "table"?: s.kind = 2
        default: s.kind = 1
        }
        s.rect = [b[1], b[0], b[3], b[2]]
        s.url = d.text("url") ?? ""
        s.target = d.text("null") ?? ""
        s.message = d.text("Msge") ?? ""
        s.alt = d.text("altTag") ?? ""
        s.cellTextIsHTML = d.bool("cellTextIsHTML") ?? false
        s.cellText = d.text("cellText") ?? ""
        s.outsets = ["topOutset", "leftOutset", "bottomOutset", "rightOutset"].map { Int32(clamping: int(d, $0) ?? 0) }
        return s
    }

    /// Version 6 (plus the outsets descriptor when any slice has outsets); a version 7/8 resource
    /// whose slices were not changed is written back exactly as read.
    public func serialized() -> Data {
        if let src = source, src.bounds == bounds, src.groupName == groupName, src.slices == slices {
            var w = ByteWriter()
            w.u32(version)
            src.descriptor.write(&w)
            w.put(src.tail)
            return w.data
        }
        var w = ByteWriter()
        w.u32(6)
        for v in bounds { w.i32(v) }
        PSDUnicodeString(groupName).write(&w)
        w.u32(UInt32(slices.count))
        for s in slices {
            w.u32(s.id); w.u32(s.groupID); w.u32(s.origin)
            if s.origin == 1 { w.u32(s.layerID ?? 0) }
            PSDUnicodeString(s.name).write(&w)
            w.u32(s.kind)
            for v in s.rect { w.i32(v) }
            for t in [s.url, s.target, s.message, s.alt] { PSDUnicodeString(t).write(&w) }
            w.u8(s.cellTextIsHTML ? 1 : 0)
            PSDUnicodeString(s.cellText).write(&w)
            w.u32(s.horizontalAlign); w.u32(s.verticalAlign)
            w.put(s.color)
        }
        if version == 6, let t = v6Tail, t.bounds == bounds, t.groupName == groupName, t.slices == slices {
            w.put(t.tail)
            return w.data
        }
        if slices.contains(where: { $0.outsets != [0, 0, 0, 0] }) {
            let list: [PSDDescriptor.Value] = slices.map { s in
                .descriptor(PSDDescriptor(classID: "slice")
                    .with("sliceID", .integer(Int32(bitPattern: s.id)))
                    .with("topOutset", .integer(s.outsets[0])).with("leftOutset", .integer(s.outsets[1]))
                    .with("bottomOutset", .integer(s.outsets[2])).with("rightOutset", .integer(s.outsets[3])))
            }
            PSDVersionedDescriptor(PSDDescriptor().with("slices", .list(list))).write(&w)
        }
        return w.data
    }

    static func boundsValue(_ tlbr: [Int32]) -> PSDDescriptor.Value {
        .descriptor(PSDDescriptor(classID: "Rct1").with("Top ", .integer(tlbr[0])).with("Left", .integer(tlbr[1]))
            .with("Btom", .integer(tlbr[2])).with("Rght", .integer(tlbr[3])))
    }

    /// Version 7 descriptor form (what newer Photoshop versions write).
    public func descriptorBytes() -> Data {
        func en(_ t: String, _ v: String) -> PSDDescriptor.Value { .enumerated(type: PSDDescriptor.ID(t), value: PSDDescriptor.ID(v)) }
        let list: [PSDDescriptor.Value] = slices.map { s in
            var d = PSDDescriptor(classID: "slice")
                .with("sliceID", .integer(Int32(bitPattern: s.id))).with("groupID", .integer(Int32(bitPattern: s.groupID)))
                .with("origin", en("ESliceOrigin", s.origin == 0 ? "autoGenerated" : s.origin == 1 ? "layerGenerated" : "userGenerated"))
            if s.origin == 1, let l = s.layerID { d = d.with("layerID", .integer(Int32(bitPattern: l))) }
            return .descriptor(d.with("Nm  ", .text(PSDUnicodeString(s.name)))
                .with("Type", en("ESliceType", s.kind == 0 ? "noImage" : s.kind == 2 ? "Tbl " : "Img "))
                .with("bounds", PSDSlices.boundsValue([s.rect[1], s.rect[0], s.rect[3], s.rect[2]]))
                .with("url", .text(PSDUnicodeString(s.url))).with("null", .text(PSDUnicodeString(s.target)))
                .with("Msge", .text(PSDUnicodeString(s.message))).with("altTag", .text(PSDUnicodeString(s.alt)))
                .with("cellTextIsHTML", .boolean(s.cellTextIsHTML)).with("cellText", .text(PSDUnicodeString(s.cellText)))
                .with("horzAlign", en("ESliceHorzAlign", "default")).with("vertAlign", en("ESliceVertAlign", "default"))
                .with("bgColorType", en("ESliceBGColorType", "None"))
                .with("topOutset", .integer(s.outsets[0])).with("leftOutset", .integer(s.outsets[1]))
                .with("bottomOutset", .integer(s.outsets[2])).with("rightOutset", .integer(s.outsets[3])))
        }
        let d = PSDDescriptor().with("bounds", PSDSlices.boundsValue(bounds)).with("slices", .list(list))
            .with("baseName", .text(PSDUnicodeString(groupName)))
        var w = ByteWriter()
        w.u32(7)
        PSDVersionedDescriptor(d).write(&w)
        return w.data
    }
}
