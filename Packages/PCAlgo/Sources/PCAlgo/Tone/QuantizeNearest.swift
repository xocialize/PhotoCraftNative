// Port of photocraft-algo (crates/algo/src/quantize/nearest.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Exact nearest colour search. Balanced median splits bound recursion to O(log n); small
// palettes use a linear scan; no colour buckets, sampling or approximate distances. Ties go to
// the lowest original index, as a linear scan with strict comparison would.

extension Quantize {
    struct Nearest: Sendable {
        struct Entry: Sendable {
            var point: SIMD3<Float>
            var index: Int
            var axis: Int
        }

        private(set) var entries: [Entry]
        let tree: Bool

        init<S: Sequence>(_ points: S) where S.Element == SIMD3<Float> {
            var e = points.enumerated().map { Entry(point: $0.element, index: $0.offset, axis: 0) }
            let tree = e.count > 64 && e.allSatisfy { $0.point.x.isFinite && $0.point.y.isFinite && $0.point.z.isFinite }
            if tree { e.withUnsafeMutableBufferPointer { Self.partition($0) } }
            entries = e
            self.tree = tree
        }

        @inline(__always)
        static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            let d0 = a.x - b.x, d1 = a.y - b.y, d2 = a.z - b.z
            return d0 * d0 + d1 * d1 + d2 * d2
        }

        func find(_ point: SIMD3<Float>) -> Int {
            var best: (Float, Int) = (.greatestFiniteMagnitude, 0)
            if !tree {
                // Still in original order: strict comparison already breaks ties.
                for e in entries {
                    let d = Self.distance(e.point, point)
                    if d < best.0 { best = (d, e.index) }
                }
            } else if point.x.isFinite && point.y.isFinite && point.z.isFinite {
                entries.withUnsafeBufferPointer { Self.search($0, point, &best) }
            }
            // Non-finite queries against finite tree entries: no distance beats MAX, index 0.
            return best.1
        }

        @inline(__always)
        static func consider(_ e: Entry, _ point: SIMD3<Float>, _ best: inout (Float, Int)) {
            let d = distance(e.point, point)
            if d < best.0 || (d == best.0 && e.index < best.1) { best = (d, e.index) }
        }

        /// Median split on the widest axis (the median element keeps that axis); photocraft uses
        /// `select_nth_unstable_by` — any arrangement with the median in place gives the same
        /// (exact) answers, so a full sort by (axis value, index) is used.
        static func partition(_ e: UnsafeMutableBufferPointer<Entry>) {
            if e.count <= 8 { return }
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for x in e {
                for k in 0..<3 { lo[k] = Float.minimum(lo[k], x.point[k]); hi[k] = Float.maximum(hi[k], x.point[k]) }
            }
            // `max_by(total_cmp)`: the last of equal widths.
            var axis = 0
            for k in 1..<3 where (hi[axis] - lo[axis]).isTotallyOrdered(belowOrEqualTo: hi[k] - lo[k]) { axis = k }
            let mid = e.count / 2
            let sorted = e.sorted { a, b in
                let (va, vb) = (a.point[axis], b.point[axis])
                if va.isTotallyOrdered(belowOrEqualTo: vb) && vb.isTotallyOrdered(belowOrEqualTo: va) { return a.index < b.index }
                return va.isTotallyOrdered(belowOrEqualTo: vb)
            }
            for i in 0..<e.count { e[i] = sorted[i] }
            e[mid].axis = axis
            partition(UnsafeMutableBufferPointer(rebasing: e[0..<mid]))
            partition(UnsafeMutableBufferPointer(rebasing: e[(mid + 1)...]))
        }

        static func search(_ e: UnsafeBufferPointer<Entry>, _ point: SIMD3<Float>, _ best: inout (Float, Int)) {
            if e.count <= 8 {
                for x in e { consider(x, point, &best) }
                return
            }
            let mid = e.count / 2
            let pivot = e[mid]
            let left = UnsafeBufferPointer(rebasing: e[0..<mid]), right = UnsafeBufferPointer(rebasing: e[(mid + 1)...])
            consider(pivot, point, &best)
            let delta = point[pivot.axis] - pivot.point[pivot.axis]
            let (near, far) = delta <= 0 ? (left, right) : (right, left)
            if !near.isEmpty { search(near, point, &best) }
            // The splitting plane is a lower bound in the same f32 arithmetic as `distance`;
            // equality is searched too: a lower original index may win a distance tie.
            if !far.isEmpty && delta * delta <= best.0 { search(far, point, &best) }
        }
    }
}
