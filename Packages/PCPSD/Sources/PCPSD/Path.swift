// Path records: saved paths (resources 2000–2997), the work path (1025) and vector masks
// (`vmsk` / `vsms` layer blocks).
// Port of photocraft-psd (crates/psd/src/path.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors. Subpath assembly cross-checked against Compositor
// IO/PSD/PSDVector.swift (MIT, © 2026 Wonder Assembly LLC; no code copied).
//
// A path is a list of 26-byte records: a 2-byte selector and 24 bytes of data. Knot coordinates are
// signed 8.24 fixed-point fractions of the document height (vertical) and width (horizontal), stored
// vertical first. Bytes 2–3 of a subpath length record hold the path operation (as psd-tools
// documents). Everything else stays raw, so parsing and writing are byte-exact.

import CoreGraphics
import Foundation

/// One 26-byte path record, kept raw.
public struct PSDPathRecord: Hashable, Sendable {
    public enum Selector {
        public static let closedLength: UInt16 = 0
        public static let closedKnotLinked: UInt16 = 1
        public static let closedKnotUnlinked: UInt16 = 2
        public static let openLength: UInt16 = 3
        public static let openKnotLinked: UInt16 = 4
        public static let openKnotUnlinked: UInt16 = 5
        public static let fillRule: UInt16 = 6
        public static let clipboard: UInt16 = 7
        public static let initialFill: UInt16 = 8
    }

    public var selector: UInt16
    /// The 24 data bytes.
    public var data: [UInt8]

    public init(selector: UInt16, data: [UInt8] = [UInt8](repeating: 0, count: 24)) {
        self.selector = selector
        self.data = data.count == 24 ? data : Array((data + [UInt8](repeating: 0, count: 24)).prefix(24))
    }

    func u16(_ at: Int) -> UInt16 { UInt16(data[at]) << 8 | UInt16(data[at + 1]) }
    func i32(_ at: Int) -> Int32 {
        Int32(bitPattern: UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3]))
    }

    public var isLength: Bool { selector == Selector.closedLength || selector == Selector.openLength }
    public var isKnot: Bool { [1, 2, 4, 5].contains(selector) }
}

/// A Bézier knot as fractions of the document size: `(x, y)` pairs.
public struct PSDKnot: Hashable, Sendable {
    public var linked: Bool
    public var pre: CGPoint
    public var anchor: CGPoint
    public var post: CGPoint
    public init(linked: Bool, pre: CGPoint, anchor: CGPoint, post: CGPoint) {
        self.linked = linked
        self.pre = pre
        self.anchor = anchor
        self.post = post
    }
}

/// A subpath: knots, closed flag and path operation.
public struct PSDSubpath: Hashable, Sendable {
    public var closed: Bool
    /// `-1`/`1` combine, `2` subtract, `3` intersect, `0` exclude.
    public var operation: Int16
    public var knots: [PSDKnot]
    public init(closed: Bool, operation: Int16 = -1, knots: [PSDKnot] = []) {
        self.closed = closed
        self.operation = operation
        self.knots = knots
    }
}

public enum PSDFixed {
    /// 8.24 fixed → fraction.
    public static func toDouble(_ v: Int32) -> Double { Double(v) / 16_777_216 }
    /// Fraction → 8.24 fixed (rounded, saturating; NaN → 0).
    public static func fromDouble(_ v: Double) -> Int32 { saturatingInt32(v * 16_777_216) }
}

/// A parsed path record list.
public struct PSDPathData: Hashable, Sendable {
    public var records: [PSDPathRecord]
    /// Bytes after the last whole record (kept).
    public var trailing: [UInt8]

    public init(records: [PSDPathRecord] = [], trailing: [UInt8] = []) {
        self.records = records
        self.trailing = trailing
    }

    public init(bytes: Data) throws {
        guard bytes.count / 26 <= 4_000_000 else { throw PSDError.limitExceeded("path records") }
        let b = bytes.byteArray
        var recs: [PSDPathRecord] = []
        recs.reserveCapacity(b.count / 26)
        var i = 0
        while i + 26 <= b.count {
            recs.append(PSDPathRecord(selector: UInt16(b[i]) << 8 | UInt16(b[i + 1]), data: Array(b[i + 2 ..< i + 26])))
            i += 26
        }
        records = recs
        trailing = Array(b[i...])
    }

    public func serialized() -> Data {
        var w = ByteWriter(capacity: records.count * 26)
        for r in records {
            w.u16(r.selector)
            w.put(r.data)
        }
        w.put(trailing)
        return w.data
    }

    /// `true` when the path starts with all pixels filled (inverted path).
    public var initialFill: Bool {
        records.first { $0.selector == PSDPathRecord.Selector.initialFill }.map { $0.u16(0) != 0 } ?? false
    }

    /// Subpaths with their knots. Knots without a length record start or extend a subpath leniently.
    public var subpaths: [PSDSubpath] {
        var out: [PSDSubpath] = []
        var remaining = 0
        for r in records {
            if r.isLength {
                remaining = Int(r.u16(0))
                out.append(PSDSubpath(closed: r.selector == PSDPathRecord.Selector.closedLength, operation: Int16(bitPattern: r.u16(2))))
            } else if r.isKnot {
                let closed = r.selector <= 2
                if remaining == 0, out.last.map({ $0.closed != closed }) ?? true {
                    out.append(PSDSubpath(closed: closed, operation: -1))
                }
                remaining = max(0, remaining - 1)
                func pt(_ i: Int) -> CGPoint { CGPoint(x: PSDFixed.toDouble(r.i32(i * 8 + 4)), y: PSDFixed.toDouble(r.i32(i * 8))) }
                out[out.count - 1].knots.append(PSDKnot(linked: r.selector == 1 || r.selector == 4, pre: pt(0), anchor: pt(1), post: pt(2)))
            }
        }
        return out
    }

    /// A record list: fill rule, initial fill, then each subpath's length record and knots.
    public init(subpaths: [PSDSubpath], initialFill: Bool) {
        var recs = [PSDPathRecord(selector: PSDPathRecord.Selector.fillRule), PSDPathRecord(selector: PSDPathRecord.Selector.initialFill)]
        recs[1].data[1] = initialFill ? 1 : 0
        for s in subpaths {
            var d = [UInt8](repeating: 0, count: 24)
            let n = UInt16(min(s.knots.count, Int(UInt16.max)))
            d[0] = UInt8(n >> 8); d[1] = UInt8(n & 0xFF)
            let op = UInt16(bitPattern: s.operation)
            d[2] = UInt8(op >> 8); d[3] = UInt8(op & 0xFF)
            // Photoshop writes 1 here (psd-tools default); meaning unknown.
            d[5] = 1
            recs.append(PSDPathRecord(selector: s.closed ? PSDPathRecord.Selector.closedLength : PSDPathRecord.Selector.openLength, data: d))
            for k in s.knots.prefix(Int(UInt16.max)) {
                let sel: UInt16 = s.closed ? (k.linked ? 1 : 2) : (k.linked ? 4 : 5)
                var kd = ByteWriter(capacity: 24)
                for p in [k.pre, k.anchor, k.post] {
                    kd.i32(PSDFixed.fromDouble(p.y))
                    kd.i32(PSDFixed.fromDouble(p.x))
                }
                recs.append(PSDPathRecord(selector: sel, data: kd.bytes))
            }
        }
        records = recs
        trailing = []
    }

    /// The path in document pixels (y down) for a `width × height` document.
    public func cgPath(documentWidth: Double, documentHeight: Double) -> CGPath {
        let path = CGMutablePath()
        for s in subpaths where !s.knots.isEmpty {
            func doc(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * documentWidth, y: p.y * documentHeight) }
            path.move(to: doc(s.knots[0].anchor))
            for i in 1 ..< max(1, s.knots.count) {
                path.addCurve(to: doc(s.knots[i].anchor), control1: doc(s.knots[i - 1].post), control2: doc(s.knots[i].pre))
            }
            if s.closed {
                let last = s.knots[s.knots.count - 1], first = s.knots[0]
                path.addCurve(to: doc(first.anchor), control1: doc(last.post), control2: doc(first.pre))
                path.closeSubpath()
            }
        }
        return path
    }
}

/// A vector mask block (`vmsk` / `vsms`): version, flags and path records.
public struct PSDVectorMask: Hashable, Sendable {
    public static let flagInvert: UInt32 = 1
    public static let flagNotLinked: UInt32 = 2
    public static let flagDisabled: UInt32 = 4

    /// Version (3).
    public var version: UInt32
    public var flags: UInt32
    public var path: PSDPathData

    public init(version: UInt32 = 3, flags: UInt32 = 0, path: PSDPathData) {
        self.version = version
        self.flags = flags
        self.path = path
    }

    public init(bytes: Data) throws {
        guard bytes.count >= 8 else { throw PSDError.unexpectedEOF(offset: 0, needed: 8 - bytes.count) }
        (version, flags) = try bytes.withByteReader { r in (try r.u32(), try r.u32()) }
        path = try PSDPathData(bytes: bytes.dropFirst(8))
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        w.u32(version)
        w.u32(flags)
        w.put(path.serialized())
        return w.data
    }

    public var isInverted: Bool { flags & PSDVectorMask.flagInvert != 0 }
    public var isLinked: Bool { flags & PSDVectorMask.flagNotLinked == 0 }
    public var isDisabled: Bool { flags & PSDVectorMask.flagDisabled != 0 }
}
