// Port of photocraft-engine (crates/engine/src/layer_menu_cmds.rs `defringe`) and the small photocraft-algo / photocraft-compose pieces it uses (crates/algo/src/selection/distance.rs `edt`, crates/compose/src/masks.rs `feather_sigma`/`gaussian`/`build_mask` for a pixel mask), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// CPU references for Layer › Matting and Layer Mask › Apply: the Euclidean distance transform,
// Defringe's colour growth, and a feathered pixel mask's softened coverage (what the compositor
// displays for a mask with Feather > 0). The matting decontamination is PCAlgo's
// (`LayerMenuCommands+Segment.swift`).

import PCDocument
import PCFoundation

extension LayerMenuCommands {
    enum Algo {
        // MARK: Distance transform

        /// photocraft-algo's result for a mask with no `true` pixel.
        static let emptyDistance: Float = 1e10

        /// Euclidean distance to the nearest `true` pixel, row-major (Felzenszwalb and
        /// Huttenlocher: nearest seeds along columns, then a lower envelope of parabolas along
        /// rows). Inconsistent dimensions give an empty result.
        static func edt(_ inside: [Bool], _ w: Int, _ h: Int) -> [Float] {
            let n = w * h
            if w <= 0 || h <= 0 || inside.count != n { return [] }
            if !inside.contains(true) { return [Float](repeating: emptyDistance, count: n) }
            if !inside.contains(false) { return [Float](repeating: 0, count: n) }
            let noSeed = UInt32.max
            // Vertical distance to the nearest seed in each column.
            var vertical = [UInt32](repeating: noSeed, count: n)
            for x in 0..<w {
                var nearest: Int?
                for y in 0..<h {
                    if inside[y * w + x] { nearest = y }
                    if let s = nearest { vertical[y * w + x] = UInt32(y - s) }
                }
                nearest = nil
                for y in stride(from: h - 1, through: 0, by: -1) {
                    if vertical[y * w + x] == 0 { nearest = y }
                    if let s = nearest { vertical[y * w + x] = min(vertical[y * w + x], UInt32(s - y)) }
                }
            }
            var out = [Float](repeating: 0, count: n)
            var sites = [Int](repeating: 0, count: w)
            var starts = [Double](repeating: 0, count: w)
            for y in 0..<h {
                let row = y * w
                var count = 0
                for q in 0..<w where vertical[row + q] != noSeed {
                    let fq = Double(vertical[row + q]) * Double(vertical[row + q])
                    var start = -Double.infinity
                    while count > 0 {
                        let p = sites[count - 1]
                        let dp = Double(vertical[row + p])
                        start = (fq - dp * dp) / (2 * Double(q - p)) + (Double(q) + Double(p)) * 0.5
                        if start > starts[count - 1] { break }
                        count -= 1
                    }
                    if count == 0 { start = -Double.infinity }
                    sites[count] = q
                    starts[count] = start
                    count += 1
                }
                if count == 0 {
                    for x in 0..<w { out[row + x] = emptyDistance }
                    continue
                }
                var k = 0
                for x in 0..<w {
                    while k + 1 < count && starts[k + 1] < Double(x) { k += 1 }
                    let site = sites[k]
                    let dx = Double(x - site), dv = Double(vertical[row + site])
                    out[row + x] = Float((dx * dx + dv * dv).squareRoot())
                }
            }
            return out
        }

        // MARK: Defringe

        /// Layer › Matting › Defringe: edge pixels (within `width` of transparency) take the colour
        /// of the nearest pixels further inside, grown outward one pixel at a time. Alpha is
        /// unchanged.
        static func defringe(_ px: inout [SIMD4<Float>], _ w: Int, _ h: Int, _ width: Int) {
            guard w > 0, h > 0, px.count == w * h else { return }
            let outside = px.map { $0.w <= 0.01 }
            if !outside.contains(true) { return }
            let dist = edt(outside, w, h)
            guard dist.count == px.count else { return }
            var known = (0..<px.count).map { !outside[$0] && dist[$0] > Float(width) }
            var todo = (0..<px.count).filter { !outside[$0] && !known[$0] }
            let around: [(Int, Int)] = [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)]
            while !todo.isEmpty {
                var next: [Int] = []
                var updates: [(Int, SIMD3<Float>)] = []
                for i in todo {
                    let (x, y) = (i % w, i / w)
                    var acc = SIMD3<Float>(repeating: 0)
                    var n: Float = 0
                    for (dx, dy) in around {
                        let (nx, ny) = (x + dx, y + dy)
                        if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                        let j = ny * w + nx
                        if known[j] {
                            acc += SIMD3(px[j].x, px[j].y, px[j].z)
                            n += 1
                        }
                    }
                    if n > 0 { updates.append((i, acc / n)) } else { next.append(i) }
                }
                // An isolated fringe with no core colour nearby.
                if updates.isEmpty { break }
                for (i, c) in updates {
                    px[i] = SIMD4(c, px[i].w)
                    known[i] = true
                }
                todo = next
            }
        }

        // MARK: Feathered masks

        /// photocraft-compose `feather_sigma`: the Gaussian sigma of a feather of `px` pixels.
        static func featherSigma(_ px: Float) -> Float { px.isFinite ? min(max(px, 0), 1000) : 0 }

        /// Rounds to the 16-bit mask format's levels (the compositor's combined masks are 16-bit).
        static func q16(_ v: Float) -> Float { Float(UInt16(min(max(v, 0), 1) * 65535 + 0.5)) / 65535 }

        /// One clamped box pass of radius `r` over a line (running f32 sum).
        static func blurLine(_ line: inout [Float], _ r: Int) {
            let n = line.count
            if n == 0 { return }
            let scratch = line
            func get(_ i: Int) -> Float { scratch[min(max(i, 0), n - 1)] }
            var acc: Float = 0
            for i in -r...r { acc += get(i) }
            let cnt = Float(2 * r + 1)
            for i in 0..<n {
                line[i] = acc / cnt
                acc += get(i + r + 1) - get(i - r)
            }
        }

        /// Three clamped box passes per axis (an approximate Gaussian of `sigma`).
        static func gaussian(_ v: inout [Float], _ w: Int, _ h: Int, _ sigma: Float) {
            if sigma <= 0 || w == 0 || h == 0 || v.count != w * h { return }
            let ideal = (12 * sigma * sigma / 3 + 1).squareRoot()
            let r = (max(Int(ideal.rounded(.down)) | 1, 1) - 1) / 2
            if r == 0 { return }
            var line = [Float](repeating: 0, count: w)
            for y in 0..<h {
                for x in 0..<w { line[x] = v[y * w + x] }
                for _ in 0..<3 { blurLine(&line, r) }
                for x in 0..<w { v[y * w + x] = line[x] }
            }
            var column = [Float](repeating: 0, count: h)
            for x in 0..<w {
                for y in 0..<h { column[y] = v[y * w + x] }
                for _ in 0..<3 { blurLine(&column, r) }
                for y in 0..<h { v[y * w + x] = column[y] }
            }
        }

        /// A pixel mask's softened coverage: values over `area`, `outside` elsewhere.
        struct FeatheredMask {
            var area: PixelRect
            var values: [Float]
            var outside: Float

            func read(_ rect: PixelRect) -> [Float] {
                var out = [Float](repeating: outside, count: rect.area)
                let inter = area.intersect(rect)
                if inter.isEmpty { return out }
                for y in inter.y0..<inter.y1 {
                    let s = Int(y - area.y0) * area.width + Int(inter.x0 - area.x0)
                    let d = Int(y - rect.y0) * rect.width + Int(inter.x0 - rect.x0)
                    for k in 0..<inter.width { out[d + k] = values[s + k] }
                }
                return out
            }
        }

        /// photocraft-compose `combined_mask` of a layer whose only mask is the enabled, feathered
        /// pixel mask `m`, over `canvas`: density applied, blurred by the feather, 16-bit levels.
        static func featheredMask(_ m: LayerMask, canvas: PixelRect) -> FeatheredMask {
            let sp = featherSigma(m.feather)
            let def = m.surface.defaultPixelValue.first ?? 1
            let pDef = 1 - m.density * (1 - def)
            let grow = Int32((sp * 3).rounded(.up)) + 2
            let cb = m.surface.contentBounds
            let area = (cb.isEmpty ? cb : cb.outset(by: grow)).intersect(canvas)
            if area.isEmpty { return FeatheredMask(area: .empty, values: [], outside: q16(pDef)) }
            var pm: [Float] = []
            m.values(area, into: &pm)
            gaussian(&pm, area.width, area.height, sp)
            return FeatheredMask(area: area, values: pm.map(q16), outside: q16(pDef))
        }
    }
}
