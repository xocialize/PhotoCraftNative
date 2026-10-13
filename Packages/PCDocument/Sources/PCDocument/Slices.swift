// Web slices (Slice tool, Layer › New Layer Based Slice, Save for Web): pure data plus the
// auto-slice partition and Photoshop-style numbering.
// Port of photocraft-doc (crates/doc/src/slices.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// A document keeps its user slices (drawn with the Slice tool) and layer-based slices (they follow
// a layer's bounds, effects included). Auto slices are never stored: they are the rectangles that
// fill the rest of the canvas, recomputed whenever they are needed, exactly like Photoshop
// regenerates them after every slice edit.

import PCFoundation

/// Where a slice comes from (PSD `ESliceOrigin`). JSON: `"auto"`, `"layer"`, `"user"`.
public enum SliceOrigin: String, CaseIterable, Hashable, Sendable, Codable {
    /// Fills the canvas around user and layer slices; regenerated, never edited.
    case auto
    /// Follows a layer's content bounds (Layer › New Layer Based Slice).
    case layer
    /// Drawn with the Slice tool (or promoted from an auto slice).
    case user

    /// PSD resource 1050 code: 0 auto, 1 layer, 2 user.
    public var code: UInt32 {
        switch self { case .auto: 0; case .layer: 1; case .user: 2 }
    }

    public init(code: UInt32) {
        switch code { case 0: self = .auto; case 1: self = .layer; default: self = .user }
    }

    public var id: String { rawValue }
}

/// Slice Options › Slice Type. JSON: `"image"`, `"noImage"`, `"table"`.
public enum SliceKind: String, CaseIterable, Hashable, Sendable, Codable {
    /// Exported as an image file.
    case image
    /// An HTML cell with text (or nothing); no image is written.
    case noImage
    /// A nested table (ImageReady legacy; exported like Image).
    case table

    /// PSD resource 1050 code: 0 no image, 1 image, 2 table.
    public var code: UInt32 {
        switch self { case .noImage: 0; case .image: 1; case .table: 2 }
    }

    public init(code: UInt32) {
        switch code { case 0: self = .noImage; case 2: self = .table; default: self = .image }
    }

    public var id: String { rawValue }

    public init?(id: String) {
        switch id {
        case "image", "img": self = .image
        case "noImage", "none", "no-image": self = .noImage
        case "table": self = .table
        default: return nil
        }
    }
}

/// One slice and its Slice Options. JSON keys are camelCase and optional.
public struct Slice: Hashable, Sendable, Codable {
    /// Stable id (PSD `sliceID`), unique within the document.
    public var id: UInt32 = 0
    public var groupId: UInt32 = 0
    public var origin: SliceOrigin = .user
    /// The layer a layer-based slice follows.
    public var layer: LayerId?
    /// Slice Options › Name (empty = the generated `<document>_<NN>`).
    public var name: String = ""
    /// Document pixels. Layer-based slices: the layer's bounds (with effects) plus `outsets`.
    public var rect: PixelRect = .empty
    public var kind: SliceKind = .image
    public var url: String = ""
    public var target: String = ""
    public var message: String = ""
    public var alt: String = ""
    public var cellTextIsHtml = false
    public var cellText: String = ""
    /// HTML alignment of no-image cells (0 default, 1 left, 2 centre, 3 right / top, middle, …).
    public var horizontalAlign: UInt32 = 0
    public var verticalAlign: UInt32 = 0
    /// Slice background (ARGB, 8-bit); nil = none.
    public var background: SIMD4<UInt8>?
    /// Layer-based slices: extra margin [top, left, bottom, right].
    public var outsets: SIMD4<Int32> = .zero

    public init(id: UInt32 = 0, origin: SliceOrigin = .user, rect: PixelRect = .empty, name: String = "") {
        self.id = id; self.origin = origin; self.rect = rect; self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case id, groupId, origin, layer, name, rect, kind, url, target, message, alt, cellTextIsHtml, cellText
        case horizontalAlign, verticalAlign, background, outsets
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(.id, or: 0)
        groupId = try c.decode(.groupId, or: 0)
        origin = try c.decode(.origin, or: .user)
        layer = try c.decodeIfPresent(LayerId.self, forKey: .layer)
        name = try c.decode(.name, or: "")
        rect = try c.decode(.rect, or: .empty)
        kind = try c.decode(.kind, or: .image)
        url = try c.decode(.url, or: "")
        target = try c.decode(.target, or: "")
        message = try c.decode(.message, or: "")
        alt = try c.decode(.alt, or: "")
        cellTextIsHtml = try c.decode(.cellTextIsHtml, or: false)
        cellText = try c.decode(.cellText, or: "")
        horizontalAlign = try c.decode(.horizontalAlign, or: 0)
        verticalAlign = try c.decode(.verticalAlign, or: 0)
        background = try c.decodeIfPresent(SIMD4<UInt8>.self, forKey: .background)
        outsets = try c.decode(.outsets, or: .zero)
    }
}

/// The document's slices (PSD resource 1050). JSON keys are camelCase and optional.
public struct Slices: Hashable, Sendable, Codable {
    /// Group name (PSD: the base name, usually the document name).
    public var groupName: String = ""
    /// User and layer-based slices, in creation order (later slices are on top).
    public var list: [Slice] = []

    public init(groupName: String = "", list: [Slice] = []) { self.groupName = groupName; self.list = list }

    public var isEmpty: Bool { list.isEmpty }

    /// A fresh slice id (Photoshop counts from 1; auto slices use ids too, so leave room). nil when
    /// the stored ids have exhausted the UInt32 id space.
    public var nextId: UInt32? {
        let m = list.map(\.id).max() ?? 0
        return m == .max ? nil : m + 1
    }

    public func get(_ id: UInt32) -> Slice? { list.first { $0.id == id } }

    /// Read/write access to a slice by id (setting nil is ignored).
    public subscript(id id: UInt32) -> Slice? {
        get { get(id) }
        set {
            guard let newValue, let i = list.firstIndex(where: { $0.id == id }) else { return }
            list[i] = newValue
        }
    }

    enum CodingKeys: String, CodingKey { case groupName, list }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupName = try c.decode(.groupName, or: "")
        list = try c.decode(.list, or: [])
    }
}

/// A slice as shown and exported: user/layer slices plus generated auto slices, numbered the way
/// Photoshop numbers them (top-to-bottom, left-to-right, from 1).
public struct ResolvedSlice: Hashable, Sendable {
    /// 1-based display number.
    public var number: Int
    /// The stored slice (nil for auto slices).
    public var id: UInt32?
    public var origin: SliceOrigin
    public var rect: PixelRect
    /// The slice's name, or the generated `<base>_<NN>`.
    public var name: String
    public var kind: SliceKind
}

/// Rectangles that tile `canvas` minus `taken`. The canvas is cut into a grid along every slice
/// edge; free cells merge into horizontal runs per row band, then runs with identical columns merge
/// down, which yields the few large auto slices Photoshop shows. Ordered by (y0, x0), as the runs
/// are created band by band.
///
/// photocraft visits every grid cell and tests it against every slice (cubic in the slice count).
/// This sweeps the bands instead: a coverage count per column cell (`CoverCounts`) changes only
/// where a slice starts or ends, and only the free runs next to those columns can open or close,
/// so the work is O((n + output) log n) for n slices, with the same rectangles.
public func autoSlices(canvas: PixelRect, taken: [PixelRect]) -> [PixelRect] {
    if canvas.isEmpty { return [] }
    var rects: [PixelRect] = []
    rects.reserveCapacity(taken.count)
    var xs: [Int32] = [canvas.x0, canvas.x1]
    var ys: [Int32] = [canvas.y0, canvas.y1]
    xs.reserveCapacity(2 * taken.count + 2)
    ys.reserveCapacity(2 * taken.count + 2)
    // A point of the canvas is in a slice exactly when it is in the slice's part on the canvas.
    for r0 in taken {
        let r = r0.intersect(canvas)
        if r.isEmpty { continue }
        rects.append(r)
        xs.append(r.x0); xs.append(r.x1)
        ys.append(r.y0); ys.append(r.y1)
    }
    func sortedUnique(_ v: [Int32]) -> [Int32] {
        var out: [Int32] = []
        out.reserveCapacity(v.count)
        for x in v.sorted() where out.last != x { out.append(x) }
        return out
    }
    xs = sortedUnique(xs)
    ys = sortedUnique(ys)
    func index(_ v: [Int32], _ x: Int32) -> Int {
        var (lo, hi) = (0, v.count)
        while lo < hi {
            let mid = (lo + hi) / 2
            if v[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
    let cells = xs.count - 1, bands = ys.count - 1
    // Each slice as column cells [x0, x1) entering at band y0 and leaving at band y1.
    var starting = [[(Int, Int)]](repeating: [], count: bands + 1)
    var ending = [[(Int, Int)]](repeating: [], count: bands + 1)
    for r in rects {
        let span = (index(xs, r.x0), index(xs, r.x1))
        starting[index(ys, r.y0)].append(span)
        ending[index(ys, r.y1)].append(span)
    }
    var cover = CoverCounts(cells: cells)
    /// Open runs by first cell: (end cell, first band).
    var open: [Int: (end: Int, band: Int)] = [:]
    var out: [PixelRect] = []
    func emit(_ s: Int, _ e: Int, from band: Int, to end: Int) {
        out.append(PixelRect(x0: xs[s], y0: ys[band], x1: xs[e], y1: ys[end]))
    }
    for k in 0..<bands {
        if k == 0 {
            for (a, b) in starting[0] { cover.add(a, b, 1) }
            for (s, e) in cover.freeRuns(touching: 0, cells) { open[s] = (e, 0) }
            continue
        }
        let changed = starting[k] + ending[k]
        if changed.isEmpty { continue }
        // The columns whose coverage changes here, merged.
        var dirty: [(Int, Int)] = []
        for (a, b) in changed.sorted(by: { $0.0 < $1.0 }) {
            if let last = dirty.last, a <= last.1 { dirty[dirty.count - 1].1 = max(last.1, b) } else { dirty.append((a, b)) }
        }
        // Free runs next to or over those columns before and after; every other run carries on.
        var before = Set<Int>()
        var beforeRuns: [(Int, Int)] = []
        for (a, b) in dirty {
            for run in cover.freeRuns(touching: a, b) where before.insert(run.0).inserted { beforeRuns.append(run) }
        }
        for (a, b) in ending[k] { cover.add(a, b, -1) }
        for (a, b) in starting[k] { cover.add(a, b, 1) }
        var after: [Int: Int] = [:]
        for (a, b) in dirty {
            for (s, e) in cover.freeRuns(touching: a, b) { after[s] = e }
        }
        for (s, e) in beforeRuns where after[s] != e {
            if let o = open.removeValue(forKey: s) { emit(s, e, from: o.band, to: k) }
        }
        for (s, e) in after where open[s]?.end != e { open[s] = (e, k) }
    }
    for (s, o) in open { emit(s, o.end, from: o.band, to: bands) }
    // Band by band, left to right: the order the runs were created in.
    out.sort { ($0.y0, $0.x0) < ($1.y0, $1.x0) }
    return out
}

/// How many slices cover each column cell of the current band: a segment tree of counts that are
/// added over whole ranges and never pushed down, so a cell is covered when any node above it has
/// a count. Answers "next free cell" and "next / previous covered cell" in O(log n).
struct CoverCounts {
    let cells: Int
    private var count: [Int32]
    /// Every cell of the node is covered.
    private var full: [Bool]
    /// Some cell of the node is covered.
    private var some: [Bool]

    init(cells: Int) {
        self.cells = cells
        let n = 4 * max(cells, 1)
        count = [Int32](repeating: 0, count: n)
        full = [Bool](repeating: false, count: n)
        some = [Bool](repeating: false, count: n)
    }

    /// Adds `d` slices over cells [a, b).
    mutating func add(_ a: Int, _ b: Int, _ d: Int32) {
        if a < b { add(1, 0, cells, a, b, d) }
    }

    private mutating func add(_ node: Int, _ l: Int, _ r: Int, _ a: Int, _ b: Int, _ d: Int32) {
        if b <= l || r <= a { return }
        if a <= l && r <= b {
            count[node] += d
        } else {
            let mid = (l + r) / 2
            add(2 * node, l, mid, a, b, d)
            add(2 * node + 1, mid, r, a, b, d)
        }
        if count[node] > 0 {
            full[node] = true; some[node] = true
        } else if r - l == 1 {
            full[node] = false; some[node] = false
        } else {
            full[node] = full[2 * node] && full[2 * node + 1]
            some[node] = some[2 * node] || some[2 * node + 1]
        }
    }

    /// The first free cell at or after `from`.
    func firstFree(from: Int) -> Int? { cells == 0 ? nil : firstFree(1, 0, cells, from) }

    private func firstFree(_ node: Int, _ l: Int, _ r: Int, _ from: Int) -> Int? {
        if r <= from || full[node] { return nil }
        if r - l == 1 { return l }
        let mid = (l + r) / 2
        return firstFree(2 * node, l, mid, from) ?? firstFree(2 * node + 1, mid, r, from)
    }

    /// The first covered cell at or after `from`.
    func firstCovered(from: Int) -> Int? { cells == 0 ? nil : firstCovered(1, 0, cells, from) }

    private func firstCovered(_ node: Int, _ l: Int, _ r: Int, _ from: Int) -> Int? {
        if r <= from || !some[node] { return nil }
        if count[node] > 0 { return max(l, from) }
        if r - l == 1 { return nil }
        let mid = (l + r) / 2
        return firstCovered(2 * node, l, mid, from) ?? firstCovered(2 * node + 1, mid, r, from)
    }

    /// The last covered cell before `before`.
    func lastCovered(before: Int) -> Int? { cells == 0 ? nil : lastCovered(1, 0, cells, before) }

    private func lastCovered(_ node: Int, _ l: Int, _ r: Int, _ before: Int) -> Int? {
        if l >= before || !some[node] { return nil }
        if count[node] > 0 { return min(r, before) - 1 }
        if r - l == 1 { return nil }
        let mid = (l + r) / 2
        return lastCovered(2 * node + 1, mid, r, before) ?? lastCovered(2 * node, l, mid, before)
    }

    /// The maximal free runs [s, e) that overlap or border cells [a, b): every run that a change
    /// to those cells can open, close, grow or shrink.
    func freeRuns(touching a: Int, _ b: Int) -> [(Int, Int)] {
        if cells == 0 { return [] }
        let lo = max(a - 1, 0), hi = min(b, cells - 1)
        var out: [(Int, Int)] = []
        var p = lo
        while p <= hi, let z = firstFree(from: p), z <= hi {
            let s = z == lo ? (lastCovered(before: z).map { $0 + 1 } ?? 0) : z
            let e = firstCovered(from: z) ?? cells
            out.append((s, e))
            p = e
        }
        return out
    }
}

extension Document {
    /// The visible part of every stored slice (later slices cover earlier ones, as in Photoshop),
    /// clipped to the canvas.
    func clippedSlices() -> [(UInt32, PixelRect)] {
        let canvas = bounds
        return slices.list.map { ($0.id, $0.rect.intersect(canvas)) }.filter { !$0.1.isEmpty }
    }

    /// Every slice in display order (see `ResolvedSlice`). Without user or layer slices the whole
    /// canvas is one auto slice named `<base>` alone (as Photoshop's Save for Web names it); with
    /// several, generated names are numbered `<base>_NN`.
    public func resolvedSlices() -> [ResolvedSlice] {
        let base = sliceBaseName
        let stored = clippedSlices()
        var all: [(UInt32?, PixelRect)] = stored.map { ($0.0, $0.1) }
        all += autoSlices(canvas: bounds, taken: stored.map(\.1)).map { (nil, $0) }
        // Stable sort by (y0, x0), as photocraft's `sort_by_key`.
        all = all.enumerated().sorted { a, b in
            (a.element.1.y0, a.element.1.x0, a.offset) < (b.element.1.y0, b.element.1.x0, b.offset)
        }.map(\.element)
        let single = all.count == 1
        // `slices.get` by table: the first slice with each id, as `get` finds it.
        var byId: [UInt32: Slice] = [:]
        byId.reserveCapacity(slices.list.count)
        for sl in slices.list where byId[sl.id] == nil { byId[sl.id] = sl }
        return all.enumerated().map { i, entry in
            let s = entry.0.flatMap { byId[$0] }
            let number = i + 1
            let name: String
            if let n = s?.name, !n.isEmpty {
                name = n
            } else if single {
                name = base
            } else {
                name = base + "_" + (number < 10 ? "0\(number)" : "\(number)")
            }
            return ResolvedSlice(number: number, id: entry.0, origin: s?.origin ?? .auto, rect: entry.1, name: name, kind: s?.kind ?? .image)
        }
    }

    /// The base of generated slice names: the document name without extension, file-name safe.
    public var sliceBaseName: String {
        var n = Substring(name)
        if let dot = name.lastIndex(of: ".") { n = name[..<dot] }
        // Per scalar, as Rust's `char::is_alphanumeric`.
        var s = String.UnicodeScalarView()
        for u in n.unicodeScalars {
            let keep = u.properties.isAlphabetic || u.properties.numericType != nil || u == "-" || u == "_"
            s.append(keep ? u : "_")
        }
        return s.isEmpty ? "Untitled" : String(s)
    }
}
