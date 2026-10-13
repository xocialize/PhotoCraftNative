// Port of photocraft-engine (crates/engine/src/analysis_cmds.rs: selection measurements — `Feature`, `measure_features`, `median`, `summary`, `selection_rows`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Record Measurements on a selection: the selection (coverage ≥ 50 %) is split into 8-connected
// features (two-pass union-find); each gets its area, marching-squares perimeter, bounds and the
// gray statistics of the composite under it.

import Foundation
import PCDocument
import PCFoundation

extension AnalysisCommands {
    /// Measurements of one selection feature (or the summary of all).
    struct Feature: Equatable, Sendable {
        var area: Double = 0
        var perimeter: Double = 0
        var bounds: PixelRect = .empty
        var grayMin: Double = 0
        var grayMax: Double = 0
        var grayMean: Double = 0
        var grayMedian: Double = 0
        var histogram: [UInt64] = []

        var circularity: Double { perimeter > 0 ? min(4 * Double.pi * area / (perimeter * perimeter), 1) : 0 }
    }

    /// Largest area Record Measurements handles in one pass (#933).
    static let maxMeasurePixels: UInt64 = 400_000_000

    /// Union-find root with path halving.
    static func root(_ parent: inout [UInt32], _ i0: UInt32) -> UInt32 {
        var i = i0
        while parent[Int(i)] != i {
            parent[Int(i)] = parent[Int(parent[Int(i)])]
            i = parent[Int(i)]
        }
        return i
    }

    /// Gray value range of a depth: what a "gray value" of 1.0 reads as.
    static func grayRange(_ depth: SampleType) -> Double {
        switch depth {
        case .u8: 255
        case .u16: 32768
        default: 1
        }
    }

    /// The median of 16-bit samples, as a fraction of 65535 (photocraft `median`: the mean of the
    /// two middle values for an even count).
    static func median(_ v: [UInt16]) -> Double {
        if v.isEmpty { return 0 }
        let mid = v.count / 2
        // A counting pass is exact for 16-bit values and linear for large features.
        var counts = [Int](repeating: 0, count: 65536)
        for x in v { counts[Int(x)] += 1 }
        func nth(_ k: Int) -> Int {
            var seen = 0
            for (value, c) in counts.enumerated() {
                seen += c
                if seen > k { return value }
            }
            return 65535
        }
        let m = Double(nth(mid))
        let r = v.count % 2 == 0 ? (m + Double(nth(mid - 1))) / 2 : m
        return r / 65535
    }

    /// Splits `mask` (w×h, true = selected) into 8-connected features and measures each against
    /// the gray image `gray` (0–1). Features come in scan order of their first pixel; `origin`
    /// offsets the reported bounds.
    static func measureFeatures(_ mask: [Bool], _ gray: [Float], _ w: Int, _ h: Int, origin: (Int32, Int32), range: Double) -> [Feature] {
        let none = UInt32.max
        guard w > 0, h > 0, mask.count >= w * h, gray.count >= w * h else { return [] }
        // Two-pass connected components.
        var label = [UInt32](repeating: none, count: w * h)
        var parent: [UInt32] = []
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if !mask[i] { continue }
                var nbrs: [UInt32] = [none, none, none, none]
                if x > 0 { nbrs[0] = label[i - 1] }
                if y > 0 {
                    nbrs[1] = label[i - w]
                    if x > 0 { nbrs[2] = label[i - w - 1] }
                    if x + 1 < w { nbrs[3] = label[i - w + 1] }
                }
                var best = none
                for n in nbrs where n != none { best = min(best, root(&parent, n)) }
                if best == none {
                    best = UInt32(parent.count)
                    parent.append(best)
                } else {
                    for n in nbrs where n != none {
                        let r = root(&parent, n)
                        if r != best {
                            let (a, b) = (min(r, best), max(r, best))
                            parent[Int(b)] = a
                            best = a
                        }
                    }
                }
                label[i] = best
            }
        }
        // Compact roots → feature indices in order of first appearance.
        var index = [UInt32](repeating: none, count: parent.count)
        var n: UInt32 = 0
        for i in label.indices where label[i] != none {
            let r = Int(root(&parent, label[i]))
            if index[r] == none {
                index[r] = n
                n += 1
            }
            label[i] = index[r]
        }
        let count = Int(n)
        // Perimeter: marching squares over the pixel-centre grid (padded with unselected pixels),
        // per row band in parallel, each cell's length attributed to the feature of a pixel in it.
        let halfDiag = 0.5.squareRoot()
        let rows = h + 1
        let chunks = max(1, min(rows, ProcessInfo.processInfo.activeProcessorCount))
        var partial = [Double](repeating: 0, count: chunks * count)
        label.withUnsafeBufferPointer { lab in
            partial.withUnsafeMutableBufferPointer { out in
                let labels = SendableBuffer(UnsafeMutableBufferPointer(mutating: lab))
                let acc = SendableBuffer(out)
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    @inline(__always) func at(_ x: Int, _ y: Int) -> UInt32 {
                        x < 0 || y < 0 || x >= w || y >= h ? none : labels[y * w + x]
                    }
                    let lo = rows * c / chunks - 1, hi = rows * (c + 1) / chunks - 1
                    for y in lo..<hi {
                        for x in -1..<w {
                            let q = (at(x, y), at(x + 1, y), at(x + 1, y + 1), at(x, y + 1))
                            let inside = (q.0 != none ? 1 : 0) + (q.1 != none ? 1 : 0) + (q.2 != none ? 1 : 0) + (q.3 != none ? 1 : 0)
                            let len: Double
                            switch inside {
                            case 1, 3: len = halfDiag
                            case 2 where (q.0 != none) == (q.2 != none): len = 2 * halfDiag
                            case 2: len = 1
                            default: len = 0
                            }
                            if len > 0 {
                                let f = q.0 != none ? q.0 : (q.1 != none ? q.1 : (q.2 != none ? q.2 : q.3))
                                acc[c * count + Int(f)] += len
                            }
                        }
                    }
                }
            }
        }
        var per = [Double](repeating: 0, count: count)
        for c in 0..<chunks { for f in 0..<count { per[f] += partial[c * count + f] } }
        // Area, bounds and gray values.
        var feats = [Feature](repeating: Feature(grayMin: .greatestFiniteMagnitude, grayMax: -.greatestFiniteMagnitude,
                                                 histogram: [UInt64](repeating: 0, count: 256)), count: count)
        var box = [(Int32, Int32, Int32, Int32)](repeating: (.max, .max, .min, .min), count: count)
        var sums = [Double](repeating: 0, count: count)
        var values = [[UInt16]](repeating: [], count: count)
        for y in 0..<h {
            for x in 0..<w {
                let l = label[y * w + x]
                if l == none { continue }
                let li = Int(l)
                feats[li].area += 1
                let (px, py) = (Int32(clamping: Int(origin.0) + x), Int32(clamping: Int(origin.1) + y))
                box[li] = (min(box[li].0, px), min(box[li].1, py), max(box[li].2, px &+ 1), max(box[li].3, py &+ 1))
                let g = Double(gray[y * w + x])
                feats[li].grayMin = min(feats[li].grayMin, g)
                feats[li].grayMax = max(feats[li].grayMax, g)
                sums[li] += g
                // NaN reads as 0 (Rust's saturating `as` casts).
                let c = g.isNaN ? 0 : min(max(g, 0), 1)
                feats[li].histogram[Int((c * 255).rounded())] += 1
                values[li].append(UInt16((c * 65535).rounded()))
            }
        }
        for i in 0..<count {
            feats[i].bounds = PixelRect(x0: box[i].0, y0: box[i].1, x1: box[i].2, y1: box[i].3)
            feats[i].perimeter = per[i]
            feats[i].grayMean = sums[i] / max(feats[i].area, 1) * range
            feats[i].grayMin *= range
            feats[i].grayMax *= range
            feats[i].grayMedian = median(values[i]) * range
        }
        return feats
    }

    /// Summary over features (area-weighted mean, pooled median).
    static func summary(_ feats: [Feature], _ allValuesMedian: Double) -> Feature {
        let area = feats.reduce(0) { $0 + $1.area }
        var hist = [UInt64](repeating: 0, count: 256)
        var b = PixelRect.empty
        for f in feats {
            for i in hist.indices where i < f.histogram.count { hist[i] += f.histogram[i] }
            b = b.isEmpty ? f.bounds : b.union(f.bounds)
        }
        return Feature(area: area, perimeter: feats.reduce(0) { $0 + $1.perimeter }, bounds: b,
                       grayMin: feats.map(\.grayMin).reduce(.greatestFiniteMagnitude) { min($0, $1) },
                       grayMax: feats.map(\.grayMax).reduce(-.greatestFiniteMagnitude) { max($0, $1) },
                       grayMean: feats.reduce(0) { $0 + $1.grayMean * $1.area } / max(area, 1),
                       grayMedian: allValuesMedian, histogram: hist)
    }

    /// Selection mask (coverage ≥ 0.5) over `r` (`n` pixels), or every pixel without a selection.
    static func selectionMask(_ d: Document, _ r: PixelRect, _ n: Int) -> [Bool] {
        guard let sel = d.selection else { return [Bool](repeating: true, count: n) }
        let c = max(sel.channels, 1)
        let v = sel.readRegion(r)
        var out = [Bool](repeating: false, count: n)
        for i in 0..<n where i * c < v.count { out[i] = v[i * c] >= 0.5 }
        return out
    }

    /// The composite's luminosity over `r` (0.30 R + 0.59 G + 0.11 B).
    static func grayImage(_ s: Session, _ d: Document, _ r: PixelRect) throws -> [Float] {
        let buf = try s.services.renderer.render(d, region: r)
        var out = [Float](repeating: 0, count: buf.px.count)
        buf.px.withUnsafeBufferPointer { px in
            out.withUnsafeMutableBufferPointer { o in
                let src = SendableBuffer(UnsafeMutableBufferPointer(mutating: px)), dst = SendableBuffer(o)
                let n = px.count, chunks = max(1, min(n / 65536 + 1, ProcessInfo.processInfo.activeProcessorCount))
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    for i in (n * c / chunks)..<(n * (c + 1) / chunks) {
                        let p = src[i]
                        dst[i] = 0.30 * p.x + 0.59 * p.y + 0.11 * p.z
                    }
                }
            }
        }
        return out
    }

    /// The summary row's feature and the features of the selection (or the whole image).
    static func selectionRows(_ s: Session, _ d: Document) throws -> (Feature, [Feature]) {
        let r = d.selection.map { $0.contentBounds.intersect(d.bounds) } ?? d.bounds
        if r.isEmpty { throw EngineError.other("the selection is empty") }
        // A legal 65536×65536 document is 2^32 pixels: refuse what can't be measured in one pass
        // instead of overflowing (#933).
        let n64 = UInt64(r.width) * UInt64(r.height)
        guard n64 <= maxMeasurePixels else {
            throw EngineError.other("the area is too large to measure (\(r.width)×\(r.height) px; max \(maxMeasurePixels / 1_000_000) megapixels): select a smaller region")
        }
        let n = Int(n64)
        let (w, h) = (r.width, r.height)
        let mask = selectionMask(d, r, n)
        let gray = try grayImage(s, d, r)
        let range = grayRange(d.depth)
        let feats = measureFeatures(mask, gray, w, h, origin: (r.x0, r.y0), range: range)
        if feats.isEmpty { throw EngineError.other("the selection is empty") }
        var all: [UInt16] = []
        all.reserveCapacity(n)
        // In f32, as photocraft computes the pooled values.
        for i in 0..<min(n, gray.count) where mask[i] { all.append(gray[i].isNaN ? 0 : UInt16((min(max(gray[i], 0), 1) * 65535).rounded())) }
        return (summary(feats, median(all) * range), feats)
    }
}
