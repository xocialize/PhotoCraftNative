// Nested layer tree reconstruction from section dividers, and flattening a tree back to records.
// Port of photocraft-psd (crates/psd/src/tree.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors. Group marker semantics (type 3 divider below the children, the folder
// record above them, `lsdk` honoured as `lsct`) cross-checked against PhotoDemon pdPSDLayer.cls and
// Compositor IO/PSD/PSDReader.swift (MIT, © 2026 Wonder Assembly LLC; no code copied).

/// A node of the layer tree. Children are in file order (bottom to top).
public indirect enum PSDLayerNode: Hashable, Sendable {
    /// A non-group layer: its index in `PSDFile.layers`.
    case layer(index: Int)
    /// A group: the folder record's index, the bounding divider's (when found), and the children.
    case group(index: Int, divider: Int?, children: [PSDLayerNode])

    public var index: Int {
        switch self {
        case let .layer(i), let .group(i, _, _): i
        }
    }

    public var children: [PSDLayerNode] {
        if case let .group(_, _, c) = self { return c }
        return []
    }

    public var isGroup: Bool { if case .group = self { true } else { false } }

    /// Nodes in this subtree, including itself.
    public var count: Int { 1 + children.reduce(0) { $0 + $1.count } }

    /// Record indices of the subtree in file order (divider, children, folder).
    public var recordIndices: [Int] {
        switch self {
        case let .layer(i): [i]
        case let .group(i, d, c): (d.map { [$0] } ?? []) + c.flatMap(\.recordIndices) + [i]
        }
    }
}

extension PSDFile {
    /// The nested layer tree, roots and children bottom to top. Malformed nesting is tolerated: a
    /// folder without a matching divider becomes an empty group; unclosed dividers at the end are
    /// dropped and their children hoisted to the enclosing level.
    public func layerTree() -> [PSDLayerNode] { layerTree(maxDepth: Int.max) }

    /// `layerTree()` with at most `maxDepth` levels of groups: a group nested that deep keeps its node
    /// but not its children. Built iteratively, so no file can make it recurse.
    public func layerTree(maxDepth: Int) -> [PSDLayerNode] {
        PSDFile.buildTree(layers.map(\.sectionType), maxDepth: maxDepth)
    }

    static func buildTree(_ types: [PSDSectionType], maxDepth: Int) -> [PSDLayerNode] {
        var stack: [(divider: Int?, children: [PSDLayerNode])] = [(nil, [])]
        func push(_ node: PSDLayerNode) {
            if stack.count <= (maxDepth == Int.max ? Int.max : maxDepth + 1) { stack[stack.count - 1].children.append(node) }
        }
        for (i, t) in types.enumerated() {
            switch t {
            case .boundingDivider:
                stack.append((i, []))
            case .openFolder, .closedFolder:
                let (divider, children) = stack.count > 1 ? stack.removeLast() : (nil, [])
                push(.group(index: i, divider: divider, children: children))
            default:
                push(.layer(index: i))
            }
        }
        while stack.count > 1 {
            let (_, children) = stack.removeLast()
            stack[stack.count - 1].children.append(contentsOf: children)
        }
        return stack.first?.children ?? []
    }
}
