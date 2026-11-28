// Port of photocraft-affinity (crates/affinity/src/geometry.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Outlines of curves (`PCvD` node lists), parametric shapes (`Shpe` objects) and compounds, in node
// space.

extension Affinity {
    enum Geometry {
        /// Nodes per curve object.
        static let maxNodes = 4_000_000
        /// Compounds nested in compounds. photocraft recurses without a bound, so a compound that lists
        /// itself among its operands (a shared object linked back into its own `Chld`) would recurse
        /// until the stack overflows; deeper nesting than this is reported and skipped here.
        static let maxCompoundDepth = 32

        /// The node-space outline of a curve, shape or compound node, and whether it fills even-odd.
        /// Instances (master-page or symbol copies) take the geometry of their master.
        static func outline(_ r: Reader, _ id: ObjID, _ cls: Tag, _ world: Affine, depth: Int = 0) -> (Path, Bool)? {
            if depth == 0 { r.beginOutline() }
            guard r.chargeOutlineVisit() else { return nil }
            guard let result = outlineUncharged(r, id, cls, world, depth: depth) else { return nil }
            // A compound's operands were charged as they were copied in.
            if cls != "Comp", !r.chargeOutlinePoints(result.0) { return nil }
            return result
        }

        private static func outlineUncharged(_ r: Reader, _ id: ObjID, _ cls: Tag, _ world: Affine, depth: Int) -> (Path, Bool)? {
            let s = r.s
            switch cls {
            case "PCrv", "TxtC":
                guard let crvs = s.obj(id, "Crvs") ?? s.obj(id, "MCrM").flatMap({ s.obj($0, "Crvs") }),
                      let path = curves(r, crvs)
                else { return nil }
                return (path, path.subpaths.count > 1)
            case "Comp":
                guard depth < maxCompoundDepth else {
                    r.warn("compound shapes nested too deeply (or containing themselves)")
                    return nil
                }
                // One path of all the operands' contours in the compound's space, filled even-odd: this
                // matches add and subtract operands in every public sample; a true union of overlapping
                // added operands would differ.
                var path = Path()
                for c in s.objs(id, "Chld") {
                    let local = s.floats(c, "Xfrm", count: 6).map(Affine.fromXfrm) ?? .identity
                    guard let childClass = s.classTag(c) else { return nil }
                    if let op = s.enumeration(c, "ComO")?.id, op != 0, op != 2 {
                        r.warn("compound shapes that intersect or exclude (imported as add)")
                    }
                    if case let (p, _)? = outline(r, c, childClass, local.then(world), depth: depth + 1) {
                        guard r.chargeOutlinePoints(p) else { return nil }
                        path.subpaths.append(contentsOf: p.transformed(local).subpaths)
                    }
                }
                return (path, true)
            default:
                let shape: ObjID
                let boxOwner: ObjID
                if let sh = s.obj(id, "Shpe") {
                    (shape, boxOwner) = (sh, id)
                } else {
                    guard let master = s.obj(id, "ShpM"), let sh = s.obj(master, "Shpe") else { return nil }
                    (shape, boxOwner) = (sh, master)
                }
                guard let b = s.floats(boxOwner, "ShpB", count: 4) else { return nil }
                return Shapes.shape(r, shape, b, world)
            }
        }

        /// `PCvD.Data`: positional `[u8, u32 count, then per subpath: bool closed, 18-byte records]`.
        /// A record is (f64 x, f64 y, u8 kind, u8 role): role 0 is an anchor, 1 the out-handle of the
        /// anchor before it, 2 the in-handle of the anchor after it. A closed subpath repeats its first
        /// anchor at the end. `CnrD` live corners are rounded on the stored polyline.
        static func curves(_ r: Reader, _ crvs: ObjID) -> Path? {
            let s = r.s
            guard let data = s.obj(crvs, "Data") else { return nil }
            var fields = s.positional(data).makeIterator()
            guard fields.next() != nil else { return nil }
            guard case .uint(let n)? = fields.next() else { return nil }
            // Each subpath takes at least two fields, so a count beyond the fields present ends early.
            let count = Int(clamping: n)
            let corners = s.obj(crvs, "CnrD").flatMap { cornerRadii(s.positional($0)) }
            var path = Path()
            var seen = 0
            var index = 0
            while index < count {
                guard case .bool(let closed)? = fields.next() else { return nil }
                guard case .array(let records)? = fields.next() else { return nil }
                seen += records.count
                if seen > maxNodes {
                    r.warn("curves with more than four million nodes")
                    return nil
                }
                guard let anchors = anchors(records) else { return nil }
                let radii = index == 0 ? corners : nil
                if let sp = subpath(anchors, closed, radii) { path.subpaths.append(sp) }
                index += 1
            }
            if corners != nil, count > 1 {
                r.warn("rounded corners on curves with several subpaths (only the first is rounded)")
            }
            return path
        }

        struct Anchor {
            var p: Point
            var inHandle: Point?
            var outHandle: Point?
            /// Index of the anchor's record (live corners refer to records).
            var record: Int
        }

        static func record(_ v: Value) -> (Point, UInt8)? {
            guard case .bytes(let b) = v, b.count == 18 else { return nil }
            let x = Double(bitPattern: le64(b, 0))
            let y = Double(bitPattern: le64(b, 8))
            guard x.isFinite, y.isFinite else { return nil }
            return (Point(x: x, y: y), b[17])
        }

        static func le64(_ b: [UInt8], _ at: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<8 { v |= UInt64(b[at + k]) << UInt64(8 * k) }
            return v
        }

        static func anchors(_ records: [Value]) -> [Anchor]? {
            var out: [Anchor] = []
            out.reserveCapacity(records.count / 3 + 1)
            var pendingIn: Point?
            for (i, v) in records.enumerated() {
                guard let rec = record(v) else { return nil }
                let (p, role) = rec
                switch role {
                case 0:
                    out.append(Anchor(p: p, inHandle: pendingIn, outHandle: nil, record: i))
                    pendingIn = nil
                case 1:
                    // A leading out-handle without an anchor is edit state only.
                    if !out.isEmpty { out[out.count - 1].outHandle = p }
                case 2:
                    pendingIn = p
                default:
                    return nil
                }
            }
            return out
        }

        static func subpath(_ anchors: [Anchor], _ closed: Bool, _ radii: [(Int, Double)]?) -> SubPath? {
            guard let first = anchors.first else { return nil }
            if let radii, !radii.isEmpty {
                func corner(_ a: Anchor) -> Double {
                    radii.filter { $0.0 == a.record }.map(\.1).reduce(0.0) { Double.maximum($0, $1) }
                }
                let polyline = anchors.allSatisfy { a in
                    (a.inHandle.map { $0 == a.p } ?? true) && (a.outHandle.map { $0 == a.p } ?? true)
                }
                if polyline {
                    var pts = anchors.map { ($0.p, corner($0)) }
                    // A closed subpath repeats its first anchor; its radius may be on either copy.
                    if closed, pts.count > 1, pts[0].0 == pts[pts.count - 1].0 {
                        let r = pts.removeLast().1
                        pts[0].1 = Double.maximum(pts[0].1, r)
                    }
                    return Shapes.fillet(pts, closed)
                }
            }
            var segments: [Segment] = []
            segments.reserveCapacity(max(0, anchors.count - 1))
            for i in anchors.indices.dropFirst() {
                let a = anchors[i - 1]
                let b = anchors[i]
                segments.append(Segment(a.outHandle ?? a.p, b.inHandle ?? b.p, b.p))
            }
            return SubPath(start: first.p, segments: segments, closed: closed)
        }

        /// `CnrD`: positional `[u8, i32[] record indices, f64[] radii, u8[] types]`.
        static func cornerRadii(_ fields: [Value]) -> [(Int, Double)]? {
            guard fields.count > 2, case .array(let idx) = fields[1], case .array(let rad) = fields[2] else { return nil }
            return zip(idx, rad).compactMap { i, r in
                guard case .int(let i) = i, case .float(let r) = r, r.isFinite, r > 0, let index = Int(exactly: i), index >= 0 else { return nil }
                return (index, r)
            }
        }
    }
}
