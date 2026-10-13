// Port of photocraft-algo (crates/algo/src/segment/maxflow.rs, segment/maxflow/push_relabel.rs, segment/mod.rs: grid_cut_cancellable, NB, d2, add_fixed_link; selection/distance.rs: edt), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// What Content-Aware Fill's Auto sampling area needs from photocraft's segmentation and selection
// modules: the binary grid labelling by one minimum cut (Boykov & Jolly 2001) on a hybrid
// max-flow — Boykov–Kolmogorov (IEEE PAMI 2004) for small graphs, FIFO push/relabel with global
// relabelling (Goldberg & Tarjan, JACM 1988) for large ones — and the binary Euclidean distance
// transform (Felzenszwalb & Huttenlocher 2012). Ported step for step: which of several minimum
// cuts is reported depends on the augmentation order. Kept inside `InpaintKit` (a later port of
// the segment area can replace it).

import PCFoundation

extension InpaintKit {
    // MARK: Deque

    /// A ring-buffer double-ended queue (Rust `VecDeque`).
    struct Deque<T> {
        private var buf: [T?] = Array(repeating: nil, count: 16)
        private var head = 0
        private(set) var count = 0

        var isEmpty: Bool { count == 0 }

        private mutating func grow() {
            var n: [T?] = Array(repeating: nil, count: buf.count * 2)
            for i in 0..<count { n[i] = buf[(head + i) % buf.count] }
            buf = n
            head = 0
        }

        mutating func pushBack(_ v: T) {
            if count == buf.count { grow() }
            buf[(head + count) % buf.count] = v
            count += 1
        }

        mutating func pushFront(_ v: T) {
            if count == buf.count { grow() }
            head = (head - 1 + buf.count) % buf.count
            buf[head] = v
            count += 1
        }

        mutating func popFront() -> T? {
            if count == 0 { return nil }
            let v = buf[head]
            buf[head] = nil
            head = (head + 1) % buf.count
            count -= 1
            return v
        }
    }

    // MARK: Max-flow

    /// A directed graph with source/sink terminal capacities (photocraft `segment::maxflow::Graph`).
    struct Graph {
        static let none = UInt32.max
        static let terminal = UInt32.max - 1
        static let orphan = UInt32.max - 2
        static let infDist = UInt32.max
        /// Residual capacities at or below this count as saturated.
        static let eps: Float = 1e-5
        static let cancelEvery: UInt32 = 1024

        var first: [UInt32]
        /// Residual terminal capacity: > 0 from the source, < 0 to the sink.
        var trCap: [Float]
        var parent: [UInt32]
        var isSink: [Bool]
        var ts: [UInt32]
        var dist: [UInt32]
        var active: [Bool]
        var head: [UInt32] = []
        var next: [UInt32] = []
        var rCap: [Float] = []
        var flow: Double = 0

        init(nodes: Int, edges: Int) {
            first = [UInt32](repeating: Self.none, count: nodes)
            trCap = [Float](repeating: 0, count: nodes)
            parent = [UInt32](repeating: Self.none, count: nodes)
            isSink = [Bool](repeating: false, count: nodes)
            ts = [UInt32](repeating: 0, count: nodes)
            dist = [UInt32](repeating: 0, count: nodes)
            active = [Bool](repeating: false, count: nodes)
            head.reserveCapacity(edges * 2); next.reserveCapacity(edges * 2); rCap.reserveCapacity(edges * 2)
        }

        var nodeCount: Int { first.count }

        /// Adds capacities from the source and to the sink (accumulating; only the difference kept).
        mutating func addTWeights(_ i: Int, _ capSource: Float, _ capSink: Float) {
            let delta = trCap[i]
            var s = capSource, t = capSink
            if delta > 0 { s += delta } else { t -= delta }
            flow += Double(Float.minimum(s, t))
            trCap[i] = s - t
        }

        /// Adds an edge `i → j` with capacity `cap` and `j → i` with `revCap`.
        mutating func addEdge(_ i: Int, _ j: Int, _ cap: Float, _ revCap: Float) {
            let a = UInt32(head.count)
            head.append(UInt32(j)); next.append(first[i]); rCap.append(cap); first[i] = a
            head.append(UInt32(i)); next.append(first[j]); rCap.append(revCap); first[j] = a + 1
        }

        /// After `maxflow`: is node `i` on the source side of the minimum cut?
        func inSource(_ i: Int) -> Bool { parent[i] != Self.none && !isSink[i] }

        /// The maximum flow; nil when `cancel` stopped it.
        mutating func maxflow(_ cancel: () -> Bool) -> Double? {
            if nodeCount >= 4096 {
                var source = false, sink = false
                for c in trCap {
                    if !c.isFinite { return bk(cancel) }
                    source = source || c > Self.eps
                    sink = sink || c < -Self.eps
                }
                if source && sink && rCap.allSatisfy({ $0.isFinite && $0 >= 0 }) { return pushRelabel(cancel) }
            }
            return bk(cancel)
        }

        // Boykov–Kolmogorov.
        mutating func bk(_ cancel: () -> Bool) -> Double? {
            let n = nodeCount
            var queue = Deque<UInt32>(), orphans = Deque<UInt32>()
            for i in 0..<n {
                active[i] = false
                ts[i] = 0
                if abs(trCap[i]) > Self.eps {
                    isSink[i] = trCap[i] < 0
                    parent[i] = Self.terminal
                    dist[i] = 1
                    active[i] = true
                    queue.pushBack(UInt32(i))
                } else {
                    parent[i] = Self.none
                }
            }
            var time: UInt32 = 0
            var steps: UInt32 = 0
            while let iu = queue.popFront() {
                steps &+= 1
                if steps % Self.cancelEvery == 0 && cancel() { return nil }
                let i = Int(iu)
                active[i] = false
                if parent[i] == Self.none { continue }
                // Growth stage.
                var contact = Self.none
                let sink = isSink[i]
                var a = first[i]
                while a != Self.none {
                    let au = Int(a)
                    let j = Int(head[au])
                    let cap = sink ? rCap[au ^ 1] : rCap[au]
                    if cap > Self.eps {
                        if parent[j] == Self.none {
                            isSink[j] = sink
                            parent[j] = a ^ 1
                            ts[j] = ts[i]
                            dist[j] = dist[i] &+ 1
                            if !active[j] { active[j] = true; queue.pushBack(UInt32(j)) }
                        } else if isSink[j] != sink {
                            contact = sink ? a ^ 1 : a
                            break
                        } else if ts[j] <= ts[i] && dist[j] > dist[i] {
                            parent[j] = a ^ 1
                            ts[j] = ts[i]
                            dist[j] = dist[i] &+ 1
                        }
                    }
                    a = next[au]
                }
                if contact == Self.none { continue }
                // Keep scanning this node after the augmentation.
                if !active[i] { active[i] = true; queue.pushFront(UInt32(i)) }
                time &+= 1
                augment(Int(contact), &orphans)
                // Adoption stage.
                while let o = orphans.popFront() { adopt(Int(o), time, &queue, &orphans) }
            }
            return flow
        }

        mutating func augment(_ m: Int, _ orphans: inout Deque<UInt32>) {
            let u = Int(head[m ^ 1]), v = Int(head[m])
            // Bottleneck.
            var b = rCap[m]
            var x = u
            while true {
                let a = parent[x]
                if a == Self.terminal { break }
                b = Float.minimum(b, rCap[Int(a) ^ 1])
                x = Int(head[Int(a)])
            }
            b = Float.minimum(b, trCap[x])
            x = v
            while true {
                let a = parent[x]
                if a == Self.terminal { break }
                b = Float.minimum(b, rCap[Int(a)])
                x = Int(head[Int(a)])
            }
            b = Float.minimum(b, -trCap[x])
            // Push.
            rCap[m ^ 1] += b
            rCap[m] -= b
            x = u
            while true {
                let a = parent[x]
                if a == Self.terminal { break }
                let au = Int(a)
                rCap[au] += b
                rCap[au ^ 1] -= b
                let up = Int(head[au])
                if rCap[au ^ 1] <= Self.eps { parent[x] = Self.orphan; orphans.pushBack(UInt32(x)) }
                x = up
            }
            trCap[x] -= b
            if trCap[x] <= Self.eps { parent[x] = Self.orphan; orphans.pushBack(UInt32(x)) }
            x = v
            while true {
                let a = parent[x]
                if a == Self.terminal { break }
                let au = Int(a)
                rCap[au ^ 1] += b
                rCap[au] -= b
                let up = Int(head[au])
                if rCap[au] <= Self.eps { parent[x] = Self.orphan; orphans.pushBack(UInt32(x)) }
                x = up
            }
            trCap[x] += b
            if trCap[x] >= -Self.eps { parent[x] = Self.orphan; orphans.pushBack(UInt32(x)) }
            flow += Double(b)
        }

        mutating func adopt(_ i: Int, _ time: UInt32, _ queue: inout Deque<UInt32>, _ orphans: inout Deque<UInt32>) {
            let sink = isSink[i]
            var best = Self.none
            var dMin = Self.infDist
            var a = first[i]
            while a != Self.none {
                let au = Int(a)
                let cap = sink ? rCap[au] : rCap[au ^ 1]
                let j = Int(head[au])
                if cap > Self.eps && isSink[j] == sink && parent[j] != Self.none {
                    // Does j's path lead to a terminal?
                    var d: UInt32 = 0
                    var k = j
                    while true {
                        if ts[k] == time { d = d.addingReportingOverflow(dist[k]).overflow ? .max : d + dist[k]; break }
                        let pa = parent[k]
                        d &+= 1
                        if pa == Self.terminal { ts[k] = time; dist[k] = 1; break }
                        if pa == Self.orphan { d = Self.infDist; break }
                        k = Int(head[Int(pa)])
                    }
                    if d < Self.infDist {
                        if d < dMin { best = a; dMin = d }
                        // Cache distances along the path.
                        var kk = j
                        var dd = d
                        while ts[kk] != time {
                            ts[kk] = time
                            dist[kk] = dd
                            dd &-= 1
                            kk = Int(head[Int(parent[kk])])
                        }
                    }
                }
                a = next[au]
            }
            if best != Self.none {
                parent[i] = best
                ts[i] = time
                dist[i] = dMin &+ 1
                return
            }
            // No parent: i becomes free.
            parent[i] = Self.none
            a = first[i]
            while a != Self.none {
                let au = Int(a)
                let j = Int(head[au])
                let pj = parent[j]
                if isSink[j] == sink && pj != Self.none {
                    let cap = sink ? rCap[au] : rCap[au ^ 1]
                    if cap > Self.eps && !active[j] { active[j] = true; queue.pushBack(UInt32(j)) }
                    if pj != Self.terminal && pj != Self.orphan && Int(head[Int(pj)]) == i {
                        parent[j] = Self.orphan
                        orphans.pushBack(UInt32(j))
                    }
                }
                a = next[au]
            }
        }

        // FIFO push/relabel with periodic global relabelling.
        mutating func pushRelabel(_ cancel: () -> Bool) -> Double? {
            let n = nodeCount
            guard n < Int(UInt32.max / 2) else { return bk(cancel) }
            let sourceHeight = UInt32(n) + 2
            var back = [Float](repeating: 0, count: n)
            var excess = [Double](repeating: 0, count: n)
            let epsD = Double(Self.eps)
            for i in 0..<n {
                active[i] = false
                if trCap[i] > Self.eps {
                    back[i] = trCap[i]
                    excess[i] = Double(trCap[i])
                    trCap[i] = 0
                }
            }
            globalRelabel(sourceHeight, back)
            var queue = Deque<Int>()
            for i in 0..<n where excess[i] > epsD { active[i] = true; queue.pushBack(i) }
            var work = 0
            let frequency = rCap.count * 2 + n
            var steps: UInt32 = 0
            while let i = queue.popFront() {
                steps &+= 1
                if steps % Self.cancelEvery == 0 && cancel() { return nil }
                active[i] = false
                while excess[i] > epsD {
                    if dist[i] == 1 && trCap[i] < -Self.eps {
                        let delta = Float.minimum(Float(excess[i]), -trCap[i])
                        trCap[i] += delta
                        excess[i] -= Double(delta)
                        flow += Double(delta)
                        if excess[i] <= epsD { break }
                    }
                    if dist[i] == sourceHeight + 1 && back[i] > Self.eps {
                        let delta = Float.minimum(Float(excess[i]), back[i])
                        back[i] -= delta
                        trCap[i] += delta
                        excess[i] -= Double(delta)
                        if excess[i] <= epsD { break }
                    }
                    var a = parent[i]
                    while a != Self.none {
                        let ai = Int(a)
                        let j = Int(head[ai])
                        work += 1
                        if rCap[ai] > Self.eps && dist[i] == (dist[j] == .max ? .max : dist[j] + 1) {
                            let delta = Float.minimum(Float(excess[i]), rCap[ai])
                            rCap[ai] -= delta
                            rCap[ai ^ 1] += delta
                            excess[i] -= Double(delta)
                            excess[j] += Double(delta)
                            if !active[j] && excess[j] > epsD { active[j] = true; queue.pushBack(j) }
                            if excess[i] <= epsD { break }
                        }
                        a = next[ai]
                        parent[i] = a
                    }
                    if excess[i] <= epsD { break }
                    var height: UInt32 = trCap[i] < -Self.eps ? 0 : .max
                    if back[i] > Self.eps { height = min(height, sourceHeight) }
                    a = first[i]
                    while a != Self.none {
                        let ai = Int(a)
                        work += 1
                        if rCap[ai] > Self.eps { height = min(height, dist[Int(head[ai])]) }
                        a = next[ai]
                    }
                    if height == .max { break }
                    dist[i] = height == .max ? .max : height + 1
                    parent[i] = first[i]
                }
                if work >= frequency {
                    globalRelabel(sourceHeight, back)
                    work = 0
                }
            }
            // Report the smallest source-side cut, independently of discharge order.
            for i in 0..<n { parent[i] = Self.none; isSink[i] = true }
            var q2 = Deque<Int>()
            for i in 0..<n where trCap[i] > Self.eps {
                parent[i] = Self.terminal
                isSink[i] = false
                q2.pushBack(i)
            }
            while let i = q2.popFront() {
                var a = first[i]
                while a != Self.none {
                    let ai = Int(a)
                    let j = Int(head[ai])
                    if rCap[ai] > Self.eps && parent[j] == Self.none {
                        parent[j] = Self.terminal
                        isSink[j] = false
                        q2.pushBack(j)
                    }
                    a = next[ai]
                }
            }
            return flow
        }

        mutating func globalRelabel(_ sourceHeight: UInt32, _ back: [Float]) {
            for i in 0..<dist.count { dist[i] = .max }
            parent = first
            var queue = Deque<Int>()
            for i in 0..<nodeCount where trCap[i] < -Self.eps { dist[i] = 1; queue.pushBack(i) }
            func bfs(_ queue: inout Deque<Int>) {
                while let i = queue.popFront() {
                    var a = first[i]
                    while a != Self.none {
                        let ai = Int(a)
                        let j = Int(head[ai])
                        if rCap[ai ^ 1] > Self.eps && dist[j] == .max {
                            dist[j] = dist[i] == .max ? .max : dist[i] + 1
                            queue.pushBack(j)
                        }
                        a = next[ai]
                    }
                }
            }
            bfs(&queue)
            // Give sink-unreachable vertices exact distances back to the source.
            for (i, c) in back.enumerated() where c > Self.eps && dist[i] == .max {
                dist[i] = sourceHeight + 1
                queue.pushBack(i)
            }
            bfs(&queue)
        }
    }

    // MARK: Grid cut

    /// Pixel label constraints of `gridCut`.
    static let free: UInt8 = 0, hardFG: UInt8 = 1, hardBG: UInt8 = 2

    /// The 4 forward neighbour offsets of an 8-connected grid and their lengths.
    static let nb: [(Int, Int, Float)] = [(1, 0, 1), (0, 1, 1), (1, 1, Float(2).squareRoot()), (-1, 1, Float(2).squareRoot())]

    @inline(__always)
    static func d2(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let x = a.x - b.x, y = a.y - b.y, z = a.z - b.z
        return x * x + y * y + z * z
    }

    /// Binary labelling of a grid by one min cut (photocraft `grid_cut_cancellable`): minimises
    /// `Σ D_p(l_p) + Σ_{p~q} [l_p ≠ l_q] weight(‖z_p − z_q‖²) / dist(p, q)` over the 8-connected
    /// grid. Only free pixels become nodes; links to fixed neighbours fold into terminal capacities.
    /// Returns `true` for foreground; nil when cancelled.
    static func gridCut(_ w: Int, _ h: Int, _ px: [SIMD3<Float>], _ costFG: [Float], _ costBG: [Float], _ fixed: [UInt8],
                        _ weight: (Float) -> Float, _ cancel: () -> Bool) -> [Bool]? {
        let n = w * h
        guard n < Int(UInt32.max) - 2, px.count >= n, costFG.count >= n, costBG.count >= n, fixed.count >= n else { return [] }
        var idx = [UInt32](repeating: .max, count: n)
        var count: UInt32 = 0
        for i in 0..<n where fixed[i] == free { idx[i] = count; count += 1 }
        var out = fixed.map { $0 == hardFG }
        if count == 0 { return out }
        var g = Graph(nodes: Int(count), edges: Int(count) * 4)
        for i in 0..<n where idx[i] != .max { g.addTWeights(Int(idx[i]), costBG[i], costFG[i]) }
        func addFixedLink(_ node: Int, _ f: UInt8, _ wt: Float) {
            if f == hardFG { g.addTWeights(node, wt, 0) } else { g.addTWeights(node, 0, wt) }
        }
        // Raster order over the link starts (photocraft's sparse traversal visits the same ones in
        // the same order); links between two fixed pixels can't change the cut.
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let a = px[i]
                for (dx, dy, len) in nb {
                    let nx = x + dx, ny = y + dy
                    if nx < 0 || nx >= w || ny >= h { continue }
                    let j = ny * w + nx
                    if idx[i] == .max && idx[j] == .max { continue }
                    let wt = weight(d2(a, px[j])) / len
                    switch (idx[i] != .max, idx[j] != .max) {
                    case (true, true): g.addEdge(Int(idx[i]), Int(idx[j]), wt, wt)
                    case (true, false): addFixedLink(Int(idx[i]), fixed[j], wt)
                    case (false, true): addFixedLink(Int(idx[j]), fixed[i], wt)
                    default: break
                    }
                }
            }
        }
        guard g.maxflow(cancel) != nil else { return nil }
        for i in 0..<n where idx[i] != .max { out[i] = g.inSource(Int(idx[i])) }
        return out
    }

    // MARK: Euclidean distance transform

    static let emptyDistance: Float = 1e10

    /// Euclidean distance to the nearest `true` pixel, row-major (photocraft `selection::edt`):
    /// nearest seeds along columns, then the lower envelope of squared-distance parabolas along rows.
    static func edt(_ inside: [Bool], _ w: Int, _ h: Int) -> [Float] {
        let n = w * h
        if n == 0 || n != inside.count { return [] }
        if !inside.contains(true) { return [Float](repeating: emptyDistance, count: n) }
        if !inside.contains(false) { return [Float](repeating: 0, count: n) }
        let noSeed = UInt32.max
        var vertical = [UInt32](repeating: noSeed, count: n)   // column-major
        for x in 0..<w {
            var nearest: Int?
            for y in 0..<h {
                if inside[y * w + x] { nearest = y }
                if let s = nearest { vertical[x * h + y] = UInt32(y - s) }
            }
            nearest = nil
            for y in stride(from: h - 1, through: 0, by: -1) {
                if vertical[x * h + y] == 0 { nearest = y }
                if let s = nearest { vertical[x * h + y] = min(vertical[x * h + y], UInt32(s - y)) }
            }
        }
        var out = [Float](repeating: 0, count: n)
        var costs = [UInt32](repeating: noSeed, count: w)
        var sites = [Int](repeating: 0, count: w)
        var starts = [Double](repeating: 0, count: w)
        for y in 0..<h {
            for x in 0..<w { costs[x] = vertical[x * h + y] }
            var count = 0
            for q in 0..<w where costs[q] != noSeed {
                let fq = Double(costs[q]) * Double(costs[q])
                var start = -Double.infinity
                while count > 0 {
                    let p = sites[count - 1]
                    let dp = Double(costs[p])
                    // (q² − p²)/(2(q − p)) = (q + p)/2, without subtracting large squares.
                    start = (fq - dp * dp) / (2 * Double(q - p)) + (Double(q) + Double(p)) * 0.5
                    if start > starts[count - 1] { break }
                    count -= 1
                }
                if count == 0 { start = -.infinity }
                sites[count] = q
                starts[count] = start
                count += 1
            }
            if count == 0 {
                for x in 0..<w { out[y * w + x] = emptyDistance }
                continue
            }
            var k = 0
            for x in 0..<w {
                while k + 1 < count && starts[k + 1] < Double(x) { k += 1 }
                let site = sites[k]
                let dx = Double(x) - Double(site)
                let v = Double(costs[site])
                out[y * w + x] = Float((dx * dx + v * v).squareRoot())
            }
        }
        return out
    }
}
