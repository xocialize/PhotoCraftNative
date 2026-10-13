// Port of photocraft-algo (crates/algo/src/render2.rs: `Leaf`, `Habit`, `TreeKind`, `TREES`, `tree_type_names`, `TreeSpec`, `TreeCtx`, `tree`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Render › Tree: 34 base tree types (recursive branching, conifers, palms, bamboo) with
// leaves sorted back to front by lighting, as primitives.

import Foundation
import PCFoundation

/// Tree options (Photoshop's Tree dialog) — photocraft `TreeSpec`; fields default when missing.
public struct TreeSpec: Codable, Sendable, Hashable {
    /// 1–34 (see `RenderProc.treeTypeNames`).
    public var baseTreeType: UInt32 = 1
    /// 1 (light from the left) … 3 (above) … 5 (right).
    public var lightDirection: UInt32 = 3
    /// 0–100.
    public var leavesAmount: Float = 50
    /// 0–200 %.
    public var leavesSize: Float = 100
    /// 50–300 %: how high the branching starts.
    public var branchesHeight: Float = 100
    /// 50–200 %.
    public var branchesThickness: Float = 100
    /// Use the type's leaf colour; otherwise `leavesColor`.
    public var defaultLeaves = true
    public var leavesColor = SIMD4<Float>(0.24, 0.52, 0.16, 1)
    /// Use `branchesColor` instead of the type's bark.
    public var customBranchColor = false
    public var branchesColor = SIMD4<Float>(0.36, 0.25, 0.16, 1)
    /// Flat shading (no light variation).
    public var flatShading = false
    public var seed: UInt32 = 0
    /// Base position as a fraction of the canvas.
    public var x: Float = 0.5
    public var y: Float = 0.95
    /// Height as a fraction of the canvas height.
    public var size: Float = 0.8

    public init() {}

    enum CodingKeys: String, CodingKey {
        case baseTreeType, lightDirection, leavesAmount, leavesSize, branchesHeight, branchesThickness, defaultLeaves, leavesColor,
             customBranchColor, branchesColor, flatShading, seed, x, y, size
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TreeSpec()
        baseTreeType = try c.decodeIfPresent(UInt32.self, forKey: .baseTreeType) ?? d.baseTreeType
        lightDirection = try c.decodeIfPresent(UInt32.self, forKey: .lightDirection) ?? d.lightDirection
        leavesAmount = try c.decodeIfPresent(Float.self, forKey: .leavesAmount) ?? d.leavesAmount
        leavesSize = try c.decodeIfPresent(Float.self, forKey: .leavesSize) ?? d.leavesSize
        branchesHeight = try c.decodeIfPresent(Float.self, forKey: .branchesHeight) ?? d.branchesHeight
        branchesThickness = try c.decodeIfPresent(Float.self, forKey: .branchesThickness) ?? d.branchesThickness
        defaultLeaves = try c.decodeIfPresent(Bool.self, forKey: .defaultLeaves) ?? d.defaultLeaves
        leavesColor = try c.decodeIfPresent(SIMD4<Float>.self, forKey: .leavesColor) ?? d.leavesColor
        customBranchColor = try c.decodeIfPresent(Bool.self, forKey: .customBranchColor) ?? d.customBranchColor
        branchesColor = try c.decodeIfPresent(SIMD4<Float>.self, forKey: .branchesColor) ?? d.branchesColor
        flatShading = try c.decodeIfPresent(Bool.self, forKey: .flatShading) ?? d.flatShading
        seed = try c.decodeIfPresent(UInt32.self, forKey: .seed) ?? d.seed
        x = try c.decodeIfPresent(Float.self, forKey: .x) ?? d.x
        y = try c.decodeIfPresent(Float.self, forKey: .y) ?? d.y
        size = try c.decodeIfPresent(Float.self, forKey: .size) ?? d.size
    }
}

extension RenderProcKit {
    /// Leaf form of a tree type.
    enum Leaf { case none, round, oval, needle, heart, blossom, long, frond }

    /// Branch architecture of a tree type.
    enum Habit {
        /// Recursive branching (deciduous trees).
        case branching
        /// A dominant stem with whorls of side branches (conifers).
        case conifer
        /// A tall trunk crowned with fronds.
        case palm
        /// Several straight jointed stalks.
        case bamboo
    }

    /// One base tree type (photocraft `TreeKind`).
    struct TreeKind {
        var name: String
        var habit: Habit
        var levels: UInt32
        var children: UInt32
        /// Branch spread (degrees from the parent).
        var spread: Float
        /// Child / parent length ratio.
        var ratio: Float
        /// Trunk share of the total height.
        var trunk: Float
        /// Downward bend per unit length at deep levels (willow > 0, upright < 0).
        var droop: Float
        /// Random bend.
        var wiggle: Float
        /// Trunk radius as a fraction of the height.
        var thick: Float
        var leaf: Leaf
        var leafCol: SIMD3<Float>
        var bark: SIMD3<Float>
        /// Fruit or blossom accent dots.
        var accent: SIMD3<Float>?
    }

    static let brown = SIMD3<Float>(0.36, 0.25, 0.16)
    static let greyBark = SIMD3<Float>(0.45, 0.42, 0.38)
    static let green = SIMD3<Float>(0.24, 0.52, 0.16)
    static let darkGreen = SIMD3<Float>(0.12, 0.36, 0.14)

    // swiftlint:disable comma
    static func tk(_ name: String, _ habit: Habit, _ levels: UInt32, _ children: UInt32, _ spread: Float, _ ratio: Float, _ trunk: Float,
                   _ droop: Float, _ wiggle: Float, _ thick: Float, _ leaf: Leaf, _ leafCol: SIMD3<Float>, _ bark: SIMD3<Float>,
                   _ accent: SIMD3<Float>?) -> TreeKind {
        TreeKind(name: name, habit: habit, levels: levels, children: children, spread: spread, ratio: ratio, trunk: trunk, droop: droop,
                 wiggle: wiggle, thick: thick, leaf: leaf, leafCol: leafCol, bark: bark, accent: accent)
    }

    /// The base tree types (index = `baseTreeType` − 1) — photocraft `TREES`.
    static let trees: [TreeKind] = [
        tk("Oak", .branching, 5, 3, 38.0, 0.72, 0.35, 0.05, 0.35, 0.035, .round, green, brown, nil),
        tk("Maple", .branching, 5, 3, 34.0, 0.74, 0.32, 0.0, 0.25, 0.03, .heart, SIMD3(0.3, 0.55, 0.15), brown, nil),
        tk("Pine", .conifer, 3, 2, 70.0, 0.5, 0.15, 0.25, 0.1, 0.025, .needle, darkGreen, brown, nil),
        tk("Palm", .palm, 1, 9, 0.0, 0.0, 0.85, 0.0, 0.15, 0.022, .frond, SIMD3(0.25, 0.5, 0.18), SIMD3(0.55, 0.45, 0.32), nil),
        tk("Birch", .branching, 5, 2, 28.0, 0.75, 0.4, 0.1, 0.3, 0.02, .oval, SIMD3(0.45, 0.65, 0.2), SIMD3(0.88, 0.86, 0.82), nil),
        tk("Weeping Willow", .branching, 5, 3, 40.0, 0.78, 0.3, 0.9, 0.2, 0.035, .long, SIMD3(0.45, 0.62, 0.22), greyBark, nil),
        tk("Cherry Blossom", .branching, 5, 3, 42.0, 0.7, 0.3, 0.0, 0.45, 0.03, .blossom, SIMD3(0.98, 0.75, 0.82), SIMD3(0.3, 0.2, 0.17), nil),
        tk("Bamboo", .bamboo, 1, 5, 6.0, 0.0, 1.0, 0.0, 0.05, 0.012, .long, SIMD3(0.35, 0.6, 0.2), SIMD3(0.55, 0.65, 0.3), nil),
        tk("Cypress", .branching, 5, 3, 10.0, 0.8, 0.1, -0.1, 0.1, 0.02, .needle, darkGreen, brown, nil),
        tk("Baobab", .branching, 3, 4, 50.0, 0.55, 0.65, 0.0, 0.3, 0.09, .round, SIMD3(0.35, 0.55, 0.2), SIMD3(0.55, 0.47, 0.4), nil),
        tk("Ginkgo", .branching, 4, 3, 30.0, 0.72, 0.35, 0.0, 0.2, 0.025, .heart, SIMD3(0.75, 0.75, 0.2), greyBark, nil),
        tk("Spruce", .conifer, 3, 2, 80.0, 0.45, 0.1, 0.45, 0.08, 0.025, .needle, SIMD3(0.1, 0.3, 0.2), brown, nil),
        tk("Bare Winter Tree", .branching, 6, 2, 34.0, 0.74, 0.3, 0.05, 0.35, 0.03, .none, green, SIMD3(0.3, 0.25, 0.22), nil),
        tk("Apple", .branching, 5, 3, 46.0, 0.68, 0.3, 0.1, 0.4, 0.03, .round, green, brown, SIMD3(0.85, 0.1, 0.1)),
        tk("Acacia", .branching, 4, 3, 55.0, 0.75, 0.45, -0.25, 0.25, 0.03, .round, SIMD3(0.35, 0.5, 0.18), brown, nil),
        tk("Poplar", .branching, 5, 3, 12.0, 0.8, 0.15, -0.15, 0.1, 0.025, .oval, SIMD3(0.3, 0.55, 0.15), greyBark, nil),
        tk("Elm", .branching, 5, 2, 24.0, 0.8, 0.3, 0.15, 0.25, 0.032, .oval, green, brown, nil),
        tk("Magnolia", .branching, 4, 3, 40.0, 0.7, 0.3, 0.0, 0.3, 0.03, .blossom, SIMD3(0.98, 0.9, 0.92), SIMD3(0.35, 0.28, 0.25), SIMD3(0.85, 0.5, 0.65)),
        tk("Banana", .palm, 1, 7, 0.0, 0.0, 0.6, 0.0, 0.05, 0.04, .frond, SIMD3(0.45, 0.7, 0.2), SIMD3(0.5, 0.6, 0.3), nil),
        tk("Bonsai", .branching, 4, 3, 60.0, 0.6, 0.45, 0.2, 0.7, 0.05, .round, darkGreen, SIMD3(0.4, 0.3, 0.22), nil),
        tk("Jacaranda", .branching, 5, 3, 44.0, 0.72, 0.3, 0.0, 0.35, 0.03, .blossom, SIMD3(0.6, 0.45, 0.85), brown, nil),
        tk("Autumn Maple", .branching, 5, 3, 34.0, 0.74, 0.32, 0.0, 0.25, 0.03, .heart, SIMD3(0.85, 0.3, 0.1), brown, nil),
        tk("Golden Autumn", .branching, 5, 3, 36.0, 0.72, 0.33, 0.05, 0.3, 0.03, .round, SIMD3(0.9, 0.7, 0.15), brown, nil),
        tk("Olive", .branching, 4, 3, 48.0, 0.68, 0.35, 0.1, 0.6, 0.04, .long, SIMD3(0.5, 0.58, 0.42), greyBark, SIMD3(0.25, 0.28, 0.12)),
        tk("Fir", .conifer, 3, 2, 75.0, 0.5, 0.12, 0.15, 0.05, 0.025, .needle, SIMD3(0.12, 0.38, 0.22), brown, nil),
        tk("Cedar", .conifer, 3, 3, 88.0, 0.6, 0.2, 0.0, 0.15, 0.03, .needle, SIMD3(0.2, 0.4, 0.25), brown, nil),
        tk("Lemon", .branching, 4, 3, 45.0, 0.68, 0.3, 0.05, 0.35, 0.03, .oval, darkGreen, brown, SIMD3(0.98, 0.88, 0.15)),
        tk("Wisteria", .branching, 5, 3, 45.0, 0.72, 0.3, 0.7, 0.3, 0.03, .blossom, SIMD3(0.7, 0.55, 0.9), SIMD3(0.35, 0.3, 0.27), nil),
        tk("Young Sapling", .branching, 3, 2, 30.0, 0.7, 0.45, 0.0, 0.2, 0.015, .oval, SIMD3(0.4, 0.7, 0.2), SIMD3(0.45, 0.35, 0.22), nil),
        tk("Dead Tree", .branching, 5, 2, 45.0, 0.68, 0.4, 0.1, 0.8, 0.035, .none, green, SIMD3(0.32, 0.29, 0.26), nil),
        tk("Coconut Palm", .palm, 1, 11, 0.0, 0.0, 0.88, 0.0, 0.35, 0.018, .frond, SIMD3(0.3, 0.55, 0.15), SIMD3(0.6, 0.5, 0.36), SIMD3(0.4, 0.3, 0.15)),
        tk("Shrub", .branching, 4, 4, 55.0, 0.7, 0.05, 0.0, 0.35, 0.02, .round, green, brown, nil),
        tk("Plum Blossom", .branching, 5, 2, 48.0, 0.7, 0.3, 0.1, 0.6, 0.03, .blossom, SIMD3(0.95, 0.6, 0.7), SIMD3(0.25, 0.18, 0.15), nil),
        tk("Cloud Pine", .branching, 4, 3, 70.0, 0.65, 0.35, 0.2, 0.5, 0.035, .needle, SIMD3(0.15, 0.4, 0.2), SIMD3(0.35, 0.27, 0.2), nil),
    ]
    // swiftlint:enable comma

    /// The tree builder's state (photocraft `TreeCtx`).
    struct TreeCtx {
        let kind: TreeKind
        let spec: TreeSpec
        var rng: RenderProc.Rng
        var branches: [RenderProc.Prim] = []
        var leaves: [(Float, RenderProc.Prim)] = []
        let bark: SIMD3<Float>
        let leaf: SIMD3<Float>
        let light: (Float, Float)
        let centre: SIMD2<Float>
        let leafPx: Float

        /// Brightness of a leaf at `p` (lit side of the crown brighter).
        mutating func lightAt(_ p: SIMD2<Float>) -> Float {
            if spec.flatShading { return 1 }
            let dx = p.x - centre.x, dy = p.y - centre.y
            let l = Float.maximum((dx * dx + dy * dy).squareRoot(), 1)
            return 0.78 + 0.32 * ((dx * light.0 + dy * light.1) / l) + 0.12 * rng.sym()
        }

        mutating func addLeaf(_ p: SIMD2<Float>, _ dir: Float) {
            typealias Prim = RenderProc.Prim
            let s = leafPx * rng.range(0.7, 1.2)
            let ang = dir + rng.sym() * 1.2
            let k = lightAt(p)
            let col = leaf
            let prim: Prim
            switch kind.leaf {
            case .none: return
            case .round: prim = Prim.ellipse(p, s, s * 0.85, ang, shade(col, k * 1.1), shade(col, k * 0.8))
            case .oval: prim = Prim.ellipse(p, s * 1.2, s * 0.55, ang, shade(col, k * 1.1), shade(col, k * 0.8))
            case .long: prim = Prim.ellipse(p, s * 1.6, s * 0.28, ang, shade(col, k * 1.1), shade(col, k * 0.8))
            case .heart: prim = Prim.ellipse(p, s * 0.9, s * 1.1, ang, shade(col, k * 1.1), shade(col, k * 0.75))
            case .needle:
                // A tuft of needles fanning out from the twig.
                let n = 7
                for j in 0..<n {
                    let a = ang + (Float(j) / Float(n - 1) - 0.5) * 2.4 + rng.sym() * 0.15
                    let l = s * rng.range(1.1, 1.7)
                    let q = SIMD2(p.x + cosf(a) * l, p.y + sinf(a) * l)
                    let kk = k + 0.1 * rng.sym()
                    leaves.append((kk, Prim.capsule(p, q, Float.maximum(s * 0.1, 0.45), Float.maximum(s * 0.05, 0.3), shade(col, kk * 0.85), shade(col, kk * 1.1))))
                }
                return
            case .blossom: prim = Prim.ellipse(p, s * 0.75, s * 0.75, 0, shade(col, k * 1.08), shade(col, k * 0.85))
            case .frond: prim = Prim.ellipse(p, s * 1.6, s * 0.3, ang, shade(col, k), shade(col, k * 0.8))
            }
            let order = k + rng.f() * 0.05
            leaves.append((order, prim))
            if let acc = kind.accent, rng.f() < 0.12 {
                let qx = p.x + rng.sym() * s
                let qy = p.y + rng.sym() * s
                let r = Float.maximum(s * 0.45, 1)
                leaves.append((k + 1, Prim.ellipse(SIMD2(qx, qy), r, r, 0, shade(acc, k * 1.15), shade(acc, k * 0.75))))
            }
        }

        /// A curved branch from `p` heading `ang` (radians, 0 = right, y down); returns its end
        /// point and end heading.
        mutating func limb(_ p: SIMD2<Float>, _ ang: Float, _ len: Float, _ r0: Float, _ r1: Float, _ depth01: Float) -> (SIMD2<Float>, Float) {
            let segs = min(max(PCAMath.usize(len / 6), 2), 10)
            var q = p, a = ang
            let droop = kind.droop * depth01
            let col0 = shade(bark, 0.9 + 0.2 * depth01)
            for k in 0..<segs {
                let t0 = Float(k) / Float(segs)
                let t1 = Float(k + 1) / Float(segs)
                a += kind.wiggle * rng.sym() * 0.25
                // Gravity pulls the heading towards straight down (π/2).
                let down = RenderProcKit.fracPi2
                let diff = atan2f(sinf(down - a), cosf(down - a))
                a += diff * droop * 0.12
                let step = len / Float(segs)
                let nq = SIMD2(q.x + cosf(a) * step, q.y + sinf(a) * step)
                let ra = r0 + (r1 - r0) * t0, rb = r0 + (r1 - r0) * t1
                branches.append(RenderProc.Prim.capsule(q, nq, ra, rb, col0, col0))
                if depth01 > 0.99 && kind.leaf != .none && k > 0 && rng.f() < clampf(spec.leavesAmount, 0, 100) / 100 * 0.9 {
                    addLeaf(nq, a)
                }
                q = nq
            }
            return (q, a)
        }

        mutating func branch(_ p: SIMD2<Float>, _ ang: Float, _ len: Float, _ r: Float, _ level: UInt32) {
            let levels = kind.levels
            let depth01 = Float(level) / Float(max(levels, 1))
            let rEnd = r * 0.62
            let (end, a) = limb(p, ang, len, r, rEnd, depth01)
            if level >= levels {
                let amount = clampf(spec.leavesAmount, 0, 100) / 100
                if kind.leaf != .none {
                    let n = PCAMath.usize((amount * 9).rounded(.toNearestOrAwayFromZero))
                    for _ in 0..<n {
                        let d = len * 0.5 * rng.f()
                        let th = rng.f() * PCAMath.tau
                        addLeaf(SIMD2(end.x + cosf(th) * d, end.y + sinf(th) * d), a)
                    }
                }
                return
            }
            let spread = PCAMath.radians(kind.spread)
            let n = kind.children
            for c in 0..<n {
                let side: Float = n == 1 ? 0 : Float(c) / Float(n - 1) * 2 - 1
                let ca = a + side * spread + rng.sym() * spread * 0.35
                let cl = len * kind.ratio * rng.range(0.8, 1.1)
                let cr = rEnd * rng.range(0.75, 0.95)
                branch(end, ca, cl, cr, level + 1)
            }
        }
    }
}

extension RenderProc {
    /// Names of the base tree types (1-based `baseTreeType` = index + 1).
    public static var treeTypeNames: [String] { RenderProcKit.trees.map(\.name) }

    /// Builds tree primitives inside `canvas` (photocraft `tree`): branches first, then the leaves
    /// sorted back to front (darker underneath, lit on top).
    public static func tree(_ spec: TreeSpec, canvas: PixelRect) -> [Prim] {
        typealias K = RenderProcKit
        let kind = K.trees[Int(min(max(spec.baseTreeType, 1), UInt32(K.trees.count)) - 1)]
        let h = Float(canvas.height) * clampf(spec.size, 0.05, 2)
        let base = SIMD2(Float(canvas.x0) + Float(canvas.width) * spec.x, Float(canvas.y0) + Float(canvas.height) * spec.y)
        let laDeg: Float = switch min(max(spec.lightDirection, 1), 5) { case 1: 180; case 2: 225; case 3: 270; case 4: 315; default: 0 }
        let la = PCAMath.radians(laDeg)
        let leaf = spec.defaultLeaves ? kind.leafCol : K.rgb(spec.leavesColor)
        let bark = spec.customBranchColor ? K.rgb(spec.branchesColor) : kind.bark
        let thick = clampf(spec.branchesThickness, 50, 200) / 100
        let bh = clampf(spec.branchesHeight, 50, 300) / 100
        var t = K.TreeCtx(kind: kind, spec: spec, rng: Rng(seed: spec.seed, salt: 0x7EE &+ UInt64(spec.baseTreeType)), bark: bark, leaf: leaf,
                          light: (cosf(la), sinf(la)), centre: SIMD2(base.x, base.y - h * 0.65),
                          leafPx: Float.maximum(h * 0.012 * clampf(spec.leavesSize, 0, 200) / 100, 0.6))
        let up = -K.fracPi2
        let r0 = Float.maximum(h * kind.thick * thick, 0.8)
        switch kind.habit {
        case .branching:
            let trunk = Float.minimum(h * kind.trunk * bh, h * 0.92)
            let (top, a) = t.limb(base, up, Float.maximum(trunk, 1), r0, r0 * 0.75, 0)
            // Crown length so the tree reaches about `h`.
            var geo: Float = 0
            for k in 0..<kind.levels { geo += K.powi(kind.ratio, Int32(k)) }
            let first = (Float.maximum(h - trunk, h * 0.08) / Float.maximum(geo, 0.5)) * 1.05
            let n = max(kind.children, 2)
            for c in 0..<n {
                let side = Float(c) / Float(n - 1) * 2 - 1
                let sp = PCAMath.radians(kind.spread) * 0.8
                let ca = a + side * sp + t.rng.sym() * 0.15
                let fl = first * t.rng.range(0.85, 1.05)
                t.branch(top, ca, fl, r0 * 0.7, 1)
            }
        case .conifer:
            let (top, _) = t.limb(base, up, h, r0, r0 * 0.1, 0)
            let start = Float.minimum(h * kind.trunk * bh, h * 0.8)
            let whorls = PCAMath.usize(14 * clampf((h / 300).squareRoot(), 0.6, 2.5))
            let spread = PCAMath.radians(kind.spread)
            for k in 0..<whorls {
                let f = Float(k) / Float(whorls)
                let y = base.y - start - (h - start) * f
                let x = base.x + (top.x - base.x) * ((base.y - y) / h)
                let span = (h - start) * 0.42 * powf(1 - f, 0.9) + h * 0.03
                for side: Float in [-1, 1] {
                    let ang = up + side * spread + t.rng.sym() * 0.1
                    t.branch(SIMD2(x, y), ang, span, Float.maximum(r0 * 0.35 * (1 - f), 0.6), kind.levels)
                    if kind.levels >= 2 {
                        let s2 = sinf(ang + side * 0.5), c2 = cosf(ang + side * 0.5)
                        let mid = SIMD2(x + c2 * span * 0.5, y + s2 * span * 0.5)
                        t.branch(mid, ang + side * 0.6, span * 0.4, Float.maximum(r0 * 0.15, 0.5), kind.levels)
                    }
                }
            }
        case .palm:
            let trunk = Float.maximum(h * kind.trunk * Float.minimum(bh, 1.15), 1)
            let lean = t.rng.sym() * kind.wiggle
            let segs = 12
            var p = base
            for k in 0..<segs {
                let f = Float(k) / Float(segs)
                let a = up + lean * f
                let q = SIMD2(p.x + cosf(a) * trunk / Float(segs), p.y + sinf(a) * trunk / Float(segs))
                let r = r0 * (1 - 0.35 * f)
                let ring = K.shade(bark, k % 2 == 0 ? 1 : 0.85)
                t.branches.append(Prim.capsule(p, q, r, r * 0.97, ring, ring))
                p = q
            }
            let fronds = kind.children
            let flen = h * 0.38 * (clampf(spec.leavesSize, 10, 200) / 100).squareRoot()
            for k in 0..<fronds {
                let a = up + (Float(k) / Float(fronds) - 0.5) * PCAMath.pi * 1.7 + t.rng.sym() * 0.2
                var q = p
                var ang = a
                let fsegs = 10
                let leaflets = PCAMath.usize((clampf(spec.leavesAmount, 0, 100) / 100 * 3).rounded(.toNearestOrAwayFromZero))
                for s in 0..<fsegs {
                    // Fronds arch over and droop towards the ground.
                    let d = K.fracPi2 - ang
                    ang += 0.06 * atan2f(sinf(d), cosf(d))
                    let nq = SIMD2(q.x + cosf(ang) * flen / Float(fsegs), q.y + sinf(ang) * flen / Float(fsegs))
                    let k2 = t.lightAt(nq)
                    t.leaves.append((k2 - 0.1, Prim.capsule(q, nq, Float.maximum(r0 * 0.15, 0.6), Float.maximum(r0 * 0.1, 0.4),
                                                            K.shade(t.leaf, k2 * 0.8), K.shade(t.leaf, k2 * 0.8))))
                    for j in 0..<leaflets {
                        let along = Float(j) / Float(leaflets)
                        let at = SIMD2(q.x + (nq.x - q.x) * along, q.y + (nq.y - q.y) * along)
                        for side: Float in [-1, 1] {
                            let la = ang + side * 1.1
                            let ll = flen * 0.22 * (1 - Float(s) / Float(fsegs) * 0.7)
                            let tip = SIMD2(at.x + cosf(la) * ll, at.y + sinf(la) * ll + ll * 0.25)
                            t.leaves.append((k2, Prim.capsule(at, tip, Float.maximum(ll * 0.08, 0.5), 0.3, K.shade(t.leaf, k2), K.shade(t.leaf, k2 * 0.9))))
                        }
                    }
                    q = nq
                }
            }
            if let acc = kind.accent {
                for _ in 0..<4 {
                    let cx = p.x + t.rng.sym() * r0 * 2
                    let cy = p.y + t.rng.f() * r0 * 2
                    t.leaves.append((2, Prim.disc(SIMD2(cx, cy), r0 * 1.1, K.shade(acc, 1))))
                }
            }
        case .bamboo:
            let stalks = kind.children
            for k in 0..<stalks {
                let x = base.x + (Float(k) - Float(stalks - 1) / 2) * r0 * 5 + t.rng.sym() * r0
                let hh = h * t.rng.range(0.7, 1)
                let a = up + t.rng.sym() * PCAMath.radians(kind.spread) * 0.5
                let joints = 8
                var p = SIMD2(x, base.y)
                for j in 0..<joints {
                    let q = SIMD2(p.x + cosf(a) * hh / Float(joints), p.y + sinf(a) * hh / Float(joints))
                    t.branches.append(Prim.capsule(p, q, r0, r0, K.shade(bark, 1), K.shade(bark, 0.85)))
                    t.branches.append(Prim.capsule(SIMD2(q.x - r0 * 1.1, q.y), SIMD2(q.x + r0 * 1.1, q.y), r0 * 0.25, r0 * 0.25, K.shade(bark, 0.7), K.shade(bark, 0.7)))
                    if j >= joints / 3 {
                        let leaves = PCAMath.usize((clampf(spec.leavesAmount, 0, 100) / 100 * 4).rounded(.toNearestOrAwayFromZero))
                        for _ in 0..<leaves {
                            let side: Float = t.rng.f() < 0.5 ? -1 : 1
                            let la = a + side * t.rng.range(0.6, 1.4)
                            let ll = t.leafPx * 2.2
                            t.addLeaf(SIMD2(q.x + cosf(la) * ll, q.y + sinf(la) * ll), la)
                        }
                    }
                    p = q
                }
            }
        }
        // Back leaves first: darker ones underneath, lit ones on top (a stable sort, as Rust's).
        let order = t.leaves.indices.sorted { i, j in
            let (a, b) = (t.leaves[i].0, t.leaves[j].0)
            return a < b || (!(b < a) && i < j)
        }
        return t.branches + order.map { t.leaves[$0].1 }
    }
}
