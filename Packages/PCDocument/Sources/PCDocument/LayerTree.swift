// Layer-tree indexing, navigation and the structural edits operations are built from: fast lookup
// by LayerId, parent/child navigation, insertion at a placement, moves, grouping and ungrouping.
// Port support for photocraft-doc (crates/doc/src/lib.rs tree helpers and the engine's tree
// commands), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// photocraft searches the tree for every lookup; here a `LayerId → LayerPath` index is built on
// first use and dropped whenever `Document.layers` changes (its `didSet`). Copies share the index
// until one of them edits its tree, and in-place edits that keep the tree's shape
// (`updateLayer`, `withRaster`) keep it.

import Synchronization

/// The lazily built id → path index of a layer tree. A cache: it never takes part in equality.
final class LayerIndex: Sendable, Equatable {
    private let state = Mutex<[LayerId: LayerPath]?>(nil)

    static func == (a: LayerIndex, b: LayerIndex) -> Bool { true }

    /// The index of `layers`, built on first use.
    func map(for layers: [Layer]) -> [LayerId: LayerPath] {
        state.withLock { s in
            if let m = s { return m }
            let m = LayerIndex.build(layers)
            s = m
            return m
        }
    }

    /// Every layer's path; a duplicated id (malformed file) maps to its first occurrence in walk
    /// order, as photocraft's search finds it.
    static func build(_ layers: [Layer]) -> [LayerId: LayerPath] {
        var m: [LayerId: LayerPath] = [:]
        var path: LayerPath = []
        func rec(_ ls: [Layer]) {
            for (i, l) in ls.enumerated() {
                path.append(i)
                if m[l.id] == nil { m[l.id] = path }
                if let ch = l.children { rec(ch) }
                path.removeLast()
            }
        }
        rec(layers)
        return m
    }
}

/// Where a layer goes in the tree.
public enum LayerPlacement: Hashable, Sendable {
    /// Directly above the sibling `id` (same parent).
    case above(LayerId)
    /// Directly below the sibling `id` (same parent).
    case below(LayerId)
    /// At the top of a group's children (nil = the root).
    case top(of: LayerId?)
    /// At the bottom of a group's children (nil = the root).
    case bottom(of: LayerId?)
    /// At `index` (0 = bottom) among a group's children (nil = the root).
    case at(index: Int, in: LayerId?)
}

extension Document {
    // MARK: Navigation

    /// The group containing layer `id`; nil for a root-level (or missing) layer.
    public func parent(of id: LayerId) -> LayerId? {
        guard let p = path(of: id), p.count > 1 else { return nil }
        return layer(at: Array(p.dropLast()))?.id
    }

    /// Children (bottom-to-top) of group `parent`, or the root layers for nil; nil when `parent` is
    /// missing or not a group.
    public func children(of parent: LayerId?) -> [Layer]? {
        guard let parent else { return layers }
        return layer(parent)?.children
    }

    /// The sibling list holding `id` (itself included).
    public func siblings(of id: LayerId) -> [Layer]? {
        guard let p = path(of: id) else { return nil }
        return p.count == 1 ? layers : layer(at: Array(p.dropLast()))?.children
    }

    /// Index of `id` among its siblings (0 = bottom).
    public func indexInParent(_ id: LayerId) -> Int? { path(of: id)?.last }

    /// 0 for a root-level layer, 1 inside one group, …
    public func depth(of id: LayerId) -> Int? { path(of: id).map { $0.count - 1 } }

    /// The groups around `id`, nearest first.
    public func ancestors(of id: LayerId) -> [LayerId] {
        guard let p = path(of: id) else { return [] }
        return (1..<max(p.count, 1)).reversed().compactMap { layer(at: Array(p.prefix($0)))?.id }
    }

    /// Whether `id` lies inside group `ancestor` (at any depth).
    public func isDescendant(_ id: LayerId, of ancestor: LayerId) -> Bool {
        guard let p = path(of: id), let a = path(of: ancestor), a.count < p.count else { return false }
        return Array(p.prefix(a.count)) == a
    }

    /// Ids inside group `id`, in walk order (empty for other kinds).
    public func descendants(of id: LayerId) -> [LayerId] {
        guard let l = layer(id) else { return [] }
        return l.structure.enumerated().compactMap { $0.offset % 2 == 0 && $0.offset > 0 ? LayerId($0.element) : nil }
    }

    /// The sibling `offset` places above (+) or below (−) `id`.
    public func sibling(of id: LayerId, offset: Int) -> LayerId? {
        guard let sib = siblings(of: id), let i = indexInParent(id) else { return nil }
        let j = i + offset
        return j >= 0 && j < sib.count ? sib[j].id : nil
    }

    // MARK: Placement

    /// The parent path and child index `placement` designates (before inserting).
    public func resolve(_ placement: LayerPlacement) throws(DocumentError) -> (parent: LayerPath, index: Int) {
        func groupPath(_ g: LayerId?) throws(DocumentError) -> (LayerPath, Int) {
            guard let g else { return ([], layers.count) }
            guard let p = path(of: g) else { throw DocumentError("no layer \(g)") }
            guard let ch = layer(at: p)?.children else { throw DocumentError("layer \(g) is not a group") }
            return (p, ch.count)
        }
        switch placement {
        case .above(let id), .below(let id):
            guard let p = path(of: id) else { throw DocumentError("no layer \(id)") }
            let i = p[p.count - 1]
            if case .above = placement { return (Array(p.dropLast()), i + 1) }
            return (Array(p.dropLast()), i)
        case .top(let g):
            let (p, n) = try groupPath(g)
            return (p, n)
        case .bottom(let g):
            let (p, _) = try groupPath(g)
            return (p, 0)
        case .at(let index, let g):
            let (p, n) = try groupPath(g)
            guard index >= 0, index <= n else { throw DocumentError("index \(index) is outside 0...\(n)") }
            return (p, index)
        }
    }

    /// Inserts `layer` (with its children) at `placement`. Fails, leaving the document unchanged,
    /// when the placement doesn't exist, an id of the inserted subtree is already in the document,
    /// or the result would nest deeper than `maxGroupDepthLimit`. Returns the layer's id.
    @discardableResult
    public mutating func insert(_ layer: Layer, at placement: LayerPlacement) throws(DocumentError) -> LayerId {
        let (parent, index) = try resolve(placement)
        let ids = layer.structure
        let existing = self.index.map(for: layers)
        var seen = Set<UInt64>()
        for k in stride(from: 0, to: ids.count, by: 2) {
            let id = LayerId(ids[k])
            if existing[id] != nil || !seen.insert(ids[k]).inserted { throw DocumentError("layer id \(id) is already in the document") }
        }
        let subDepth = stride(from: 1, to: ids.count, by: 2).map { Int(ids[$0]) }.max() ?? 0
        guard parent.count + subDepth <= maxGroupDepthLimit else {
            throw DocumentError("layers can't be nested more than \(maxGroupDepthLimit) groups deep")
        }
        let done = Document.mutateSiblings(&layers, parent: parent[...]) { sib -> Bool in
            guard index >= 0, index <= sib.count else { return false }
            sib.insert(layer, at: index)
            return true
        } ?? false
        guard done else { throw DocumentError("can't insert at \(placement)") }
        return layer.id
    }

    /// Moves layer `id` (with its children) to `placement`. Fails, leaving the document unchanged,
    /// when either is missing, the placement is inside the moved layer, or the result would nest
    /// too deep. Placing a layer relative to itself is a no-op.
    public mutating func move(_ id: LayerId, to placement: LayerPlacement) throws(DocumentError) {
        switch placement {
        case .above(let t), .below(let t): if t == id { return }
        case .top(let g), .bottom(let g), .at(_, let g): if g == id { throw DocumentError("can't move a group into itself") }
        }
        let target: LayerId? = switch placement {
        case .above(let t), .below(let t): t
        case .top(let g), .bottom(let g), .at(_, let g): g
        }
        if let t = target, isDescendant(t, of: id) { throw DocumentError("can't move a group into itself") }
        let before = self
        guard let l = remove(id) else { throw DocumentError("no layer \(id)") }
        do {
            try insert(l, at: placement)
        } catch {
            self = before
            throw error
        }
    }

    /// Wraps `ids` in a new group (Layer › Group Layers): the group takes the place of the top-most
    /// of them and holds them in stacking order. Layers inside another selected group move with it.
    /// Returns the new group's id.
    @discardableResult
    public mutating func groupLayers(_ ids: [LayerId], name: String) throws(DocumentError) -> LayerId {
        let wanted = Set(ids)
        let inOrder = allLayerIds.filter { id in wanted.contains(id) && !ancestors(of: id).contains { wanted.contains($0) } }
        guard let topmost = inOrder.last else { throw DocumentError("no layers to group") }
        let before = self
        do {
            let group = Layer.group(name, [])
            let gid = try insert(group, at: .above(topmost))
            for id in inOrder { try move(id, to: .top(of: gid)) }
            return gid
        } catch {
            self = before
            throw error
        }
    }

    /// Replaces group `id` by its children, in place (Layer › Ungroup Layers). Returns their ids.
    @discardableResult
    public mutating func ungroup(_ id: LayerId) throws(DocumentError) -> [LayerId] {
        guard let g = layer(id), let ch = g.children else { throw DocumentError("layer \(id) is not a group") }
        guard let p = path(of: id) else { throw DocumentError("no layer \(id)") }
        let idx = p[p.count - 1]
        let done = Document.mutateSiblings(&layers, parent: p.dropLast()) { sib -> Bool in
            sib.remove(at: idx)
            sib.insert(contentsOf: ch, at: idx)
            return true
        } ?? false
        guard done else { throw DocumentError("can't ungroup \(id)") }
        return ch.map(\.id)
    }

    /// Gives every layer a fresh id (and clears PSD layer ids), remapping the comps, the Last
    /// Document State, variables and layer-based slices that refer to them — for a document made
    /// from a copy (History › New Document, snapshots). Returns old → new ids.
    @discardableResult
    public mutating func reassignLayerIds() -> [LayerId: LayerId] {
        var ids: [LayerId: LayerId] = [:]
        forEachLayerMut { l in
            let new = LayerId.fresh()
            ids[l.id] = new
            l.id = new
            l.psdId = nil
        }
        func remap(_ comp: inout LayerComp) {
            for i in comp.states.indices { if let n = ids[comp.states[i].layer] { comp.states[i].layer = n } }
        }
        for i in layerComps.indices { remap(&layerComps[i]) }
        if var last = lastDocumentState {
            remap(&last)
            lastDocumentState = last
        }
        for i in variables.defs.indices { if let n = ids[variables.defs[i].layer] { variables.defs[i].layer = n } }
        for i in slices.list.indices { if let l = slices.list[i].layer, let n = ids[l] { slices.list[i].layer = n } }
        return ids
    }
}
