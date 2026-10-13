// Port of photocraft-algo (crates/algo/src/segment/maxflow.rs, segment/maxflow/push_relabel.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Hybrid max-flow / min-cut: Boykov–Kolmogorov (Boykov & Kolmogorov, PAMI 2004: two search trees
// grow towards each other, each contact an augmenting path, orphans re-adopted) and FIFO
// push/relabel with periodic exact distances to both terminals (Goldberg & Tarjan, JACM 1988),
// used for large finite graphs with both terminal directions (Quick Selection's area costs).
// Inherently sequential: CPU only. A faithful port (same queues, same tie order), so cuts match
// photocraft's.

import Foundation

extension SelectionKit {
/// A FIFO/LIFO ring buffer (Rust's `VecDeque`).
struct Deque<T> {
    private var buf: [T]
    private var head = 0
    private(set) var count = 0
    private let fill: T

    init(fill: T) { self.fill = fill; buf = [T](repeating: fill, count: 16) }

    var isEmpty: Bool { count == 0 }

    private mutating func grow() {
        var nb = [T](repeating: fill, count: buf.count * 2)
        for i in 0..<count { nb[i] = buf[(head + i) & (buf.count - 1)] }
        buf = nb
        head = 0
    }

    mutating func pushBack(_ v: T) {
        if count == buf.count { grow() }
        buf[(head + count) & (buf.count - 1)] = v
        count += 1
    }

    mutating func pushFront(_ v: T) {
        if count == buf.count { grow() }
        head = (head - 1) & (buf.count - 1)
        buf[head] = v
        count += 1
    }

    mutating func popFront() -> T? {
        if count == 0 { return nil }
        let v = buf[head]
        head = (head + 1) & (buf.count - 1)
        count -= 1
        return v
    }
}

/// A directed graph with source/sink terminal capacities (photocraft `maxflow::Graph`).
struct MaxFlowGraph {
    static let none = UInt32.max
    static let terminal = UInt32.max - 1
    static let orphan = UInt32.max - 2
    static let infDist = UInt32.max
    /// Residual capacities at or below this count as saturated.
    static let eps: Float = 1e-5
    /// Max-flow steps between cancellation checks.
    static let cancelEvery: UInt32 = 1024

    // Nodes.
    var first: [UInt32]
    /// Residual terminal capacity: > 0 from the source, < 0 to the sink.
    var trCap: [Float]
    var parent: [UInt32]
    var isSink: [Bool]
    var ts: [UInt32]
    var dist: [UInt32]
    var active: [Bool]
    // Arcs, in pairs: arc a and its reverse a ^ 1.
    var head: [UInt32] = []
    var next: [UInt32] = []
    var rCap: [Float] = []
    var flow: Double = 0

    /// A graph with `nodes` nodes and room for `edges` undirected edge pairs.
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

    /// Adds capacities from the source and to the sink (accumulating); only the difference is kept.
    mutating func addTWeights(_ i: Int, _ capSource: Float, _ capSink: Float) {
        let delta = trCap[i]
        var s = capSource, t = capSink
        if delta > 0 { s += delta } else { t -= delta }
        flow += Double(Float.minimum(s, t))
        trCap[i] = s - t
    }

    /// Adds an edge i → j with capacity `cap` and j → i with `revCap`.
    mutating func addEdge(_ i: Int, _ j: Int, _ cap: Float, _ revCap: Float) {
        let a = UInt32(head.count)
        head.append(UInt32(j)); next.append(first[i]); rCap.append(cap); first[i] = a
        head.append(UInt32(i)); next.append(first[j]); rCap.append(revCap); first[j] = a + 1
    }

    /// After `maxflow`: is node i on the source side of the minimum cut?
    func inSource(_ i: Int) -> Bool { parent[i] != Self.none && !isSink[i] }

    /// Computes the maximum flow (= minimum cut capacity).
    @discardableResult
    mutating func maxflow() -> Double { maxflow(cancel: { false }) ?? flow }

    /// `maxflow` that stops (nil) when `cancel` returns true, asked every few thousand steps.
    mutating func maxflow(cancel: () -> Bool) -> Double? {
        if nodeCount >= 4096 {
            var source = false, sink = false
            for c in trCap {
                if !c.isFinite { return bk(cancel) }
                if c > Self.eps { source = true }
                if c < -Self.eps { sink = true }
            }
            if source && sink && rCap.allSatisfy({ $0.isFinite && $0 >= 0 }) { return pushRelabel(cancel) }
        }
        return bk(cancel)
    }

    @discardableResult
    mutating func maxflowBK() -> Double { bk({ false }) ?? flow }

    // MARK: Boykov–Kolmogorov

    mutating func bk(_ cancel: () -> Bool) -> Double? {
        let n = nodeCount
        var queue = Deque<UInt32>(fill: 0)
        var orphans = Deque<UInt32>(fill: 0)
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
        while let iq = queue.popFront() {
            steps &+= 1
            if steps % Self.cancelEvery == 0 && cancel() { return nil }
            let i = Int(iq)
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
                        // Arc from the S side to the T side.
                        contact = sink ? a ^ 1 : a
                        break
                    } else if ts[j] <= ts[i] && dist[j] > dist[i] {
                        // Heuristic: shorten paths to the terminal.
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
                    if ts[k] == time {
                        let (s, o) = d.addingReportingOverflow(dist[k])
                        d = o ? UInt32.max : s
                        break
                    }
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

    // MARK: Push/relabel

    @discardableResult
    mutating func maxflowPushRelabel() -> Double { pushRelabel({ false }) ?? flow }

    /// FIFO push/relabel; nil when `cancel` stopped it.
    mutating func pushRelabel(_ cancel: () -> Bool) -> Double? {
        let n = nodeCount
        guard n < Int(UInt32.max / 2) else { return bk(cancel) }
        let sourceHeight = UInt32(n) + 2
        var back = [Float](repeating: 0, count: n)
        var excess = [Double](repeating: 0, count: n)
        for i in 0..<n {
            active[i] = false
            if trCap[i] > Self.eps {
                back[i] = trCap[i]
                excess[i] = Double(trCap[i])
                trCap[i] = 0
            }
        }
        globalRelabel(sourceHeight, back)
        var queue = Deque<Int>(fill: 0)
        let eps = Double(Self.eps)
        for i in 0..<n where excess[i] > eps { active[i] = true; queue.pushBack(i) }
        var work = 0
        let frequency = rCap.count &* 2 &+ n
        var steps: UInt32 = 0
        while let i = queue.popFront() {
            steps &+= 1
            if steps % Self.cancelEvery == 0 && cancel() { return nil }
            active[i] = false
            while excess[i] > eps {
                if dist[i] == 1 && trCap[i] < -Self.eps {
                    let delta = Float.minimum(Float(excess[i]), -trCap[i])
                    trCap[i] += delta
                    excess[i] -= Double(delta)
                    flow += Double(delta)
                    if excess[i] <= eps { break }
                }
                if dist[i] == sourceHeight + 1 && back[i] > Self.eps {
                    let delta = Float.minimum(Float(excess[i]), back[i])
                    back[i] -= delta
                    trCap[i] += delta
                    excess[i] -= Double(delta)
                    if excess[i] <= eps { break }
                }
                var a = parent[i]
                while a != Self.none {
                    let ai = Int(a)
                    let j = Int(head[ai])
                    work += 1
                    let (dj1, o) = dist[j].addingReportingOverflow(1)
                    if rCap[ai] > Self.eps && dist[i] == (o ? UInt32.max : dj1) {
                        let delta = Float.minimum(Float(excess[i]), rCap[ai])
                        rCap[ai] -= delta
                        rCap[ai ^ 1] += delta
                        excess[i] -= Double(delta)
                        excess[j] += Double(delta)
                        if !active[j] && excess[j] > eps { active[j] = true; queue.pushBack(j) }
                        if excess[i] <= eps { break }
                    }
                    a = next[ai]
                    parent[i] = a
                }
                if excess[i] <= eps { break }
                var height: UInt32 = trCap[i] < -Self.eps ? 0 : UInt32.max
                if back[i] > Self.eps { height = min(height, sourceHeight) }
                a = first[i]
                while a != Self.none {
                    let ai = Int(a)
                    work += 1
                    if rCap[ai] > Self.eps { height = min(height, dist[Int(head[ai])]) }
                    a = next[ai]
                }
                if height == UInt32.max { break }
                let (h1, o) = height.addingReportingOverflow(1)
                dist[i] = o ? UInt32.max : h1
                parent[i] = first[i]
            }
            if work >= frequency {
                globalRelabel(sourceHeight, back)
                work = 0
            }
        }
        // Report the smallest source-side cut, independently of discharge order.
        for i in 0..<n { parent[i] = Self.none; isSink[i] = true }
        var q2 = Deque<Int>(fill: 0)
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
        for i in 0..<dist.count { dist[i] = UInt32.max }
        parent = first
        var queue = Deque<Int>(fill: 0)
        for i in 0..<nodeCount where trCap[i] < -Self.eps { dist[i] = 1; queue.pushBack(i) }
        func sweep(_ queue: inout Deque<Int>) {
            while let i = queue.popFront() {
                var a = first[i]
                while a != Self.none {
                    let ai = Int(a)
                    let j = Int(head[ai])
                    if rCap[ai ^ 1] > Self.eps && dist[j] == UInt32.max {
                        let (d1, o) = dist[i].addingReportingOverflow(1)
                        dist[j] = o ? UInt32.max : d1
                        queue.pushBack(j)
                    }
                    a = next[ai]
                }
            }
        }
        sweep(&queue)
        // Sink-unreachable vertices get exact distances back to the source.
        for i in 0..<back.count where back[i] > Self.eps && dist[i] == UInt32.max {
            dist[i] = sourceHeight + 1
            queue.pushBack(i)
        }
        sweep(&queue)
    }

    /// Sum of residual capacities on arcs leaving the source side of the cut (0 after `maxflow`).
    func residualOutOfSourceSide() -> Float {
        var s: Float = 0
        for i in 0..<nodeCount where inSource(i) {
            var a = first[i]
            while a != Self.none {
                let ai = Int(a)
                if !inSource(Int(head[ai])) { s += rCap[ai] }
                a = next[ai]
            }
        }
        return s
    }
}
}
