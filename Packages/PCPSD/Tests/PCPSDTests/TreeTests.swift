// Layer tree reconstruction.
// Port of photocraft-psd (crates/psd/tests/tree.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

import Foundation
import Testing
@testable import PCPSD

@Suite struct TreeTests {
    static func rec(_ name: String, _ kind: PSDSectionType?) -> PSDLayerRecord {
        var r = PSDLayerRecord(name: Array(name.utf8))
        if let k = kind { r.blocks.append(.sectionDivider(k, blendMode: .passThrough)) }
        return r
    }

    static func fileWith(_ records: [PSDLayerRecord]) -> PSDFile {
        var f = TestGen.mergedOnly(.psd, .rgb, 8, .raw, 1, 1)
        f.layerInfo = PSDLayerInfo(layers: records)
        return f
    }

    static func names(_ f: PSDFile, _ nodes: [PSDLayerNode]) -> String {
        nodes.map { n in
            switch n {
            case let .layer(i): f.layers[i].displayName
            case let .group(i, _, c): "\(f.layers[i].displayName)[\(names(f, c))]"
            }
        }.joined(separator: ",")
    }

    let end = PSDSectionType.boundingDivider, open = PSDSectionType.openFolder, closed = PSDSectionType.closedFolder
    typealias T = TreeTests

    @Test func flatLayers() {
        let f = T.fileWith([T.rec("a", nil), T.rec("b", nil), T.rec("c", nil)])
        #expect(T.names(f, f.layerTree()) == "a,b,c")
        #expect(f.layerTree().allSatisfy { !$0.isGroup })
    }

    @Test func emptyFileHasEmptyTree() {
        #expect(TestGen.mergedOnly(.psd, .rgb, 8, .raw, 1, 1).layerTree().isEmpty)
    }

    @Test func singleGroup() {
        let f = T.fileWith([T.rec("bg", nil), T.rec("</Layer group>", end), T.rec("x", nil), T.rec("y", nil), T.rec("G", open)])
        let t = f.layerTree()
        #expect(T.names(f, t) == "bg,G[x,y]")
        #expect(t[1] == .group(index: 4, divider: 1, children: [.layer(index: 2), .layer(index: 3)]))
        #expect(t[1].recordIndices == [1, 2, 3, 4])
    }

    @Test func closedGroup() {
        let f = T.fileWith([T.rec("</Layer group>", end), T.rec("x", nil), T.rec("G", closed)])
        #expect(T.names(f, f.layerTree()) == "G[x]")
    }

    @Test func nestedGroups() {
        let f = T.fileWith([T.rec("</Layer group>", end), T.rec("a", nil), T.rec("</Layer group>", end), T.rec("b", nil), T.rec("Inner", closed),
                            T.rec("c", nil), T.rec("Outer", open), T.rec("top", nil)])
        let t = f.layerTree()
        #expect(T.names(f, t) == "Outer[a,Inner[b],c],top")
        #expect(t[0].count == 5)
    }

    @Test func emptyGroup() {
        let f = T.fileWith([T.rec("</Layer group>", end), T.rec("G", open)])
        #expect(T.names(f, f.layerTree()) == "G[]")
    }

    @Test func siblingGroups() {
        let f = T.fileWith([T.rec("</Layer group>", end), T.rec("a", nil), T.rec("G1", open), T.rec("</Layer group>", end), T.rec("b", nil), T.rec("G2", open)])
        #expect(T.names(f, f.layerTree()) == "G1[a],G2[b]")
    }

    @Test func deeplyNested() {
        var v: [PSDLayerRecord] = (0 ..< 50).map { _ in T.rec("</Layer group>", end) }
        v.append(T.rec("leaf", nil))
        v += (0 ..< 50).map { T.rec("g\($0)", open) }
        let t = T.fileWith(v).layerTree()
        #expect(t.count == 1)
        #expect(t[0].count == 51)
        var n = t[0]
        var depth = 1
        while let c = n.children.first {
            n = c
            depth += 1
        }
        #expect(depth == 51)
    }

    @Test func maxDepthDropsDeeperChildren() {
        var v = [T.rec("</Layer group>", end), T.rec("</Layer group>", end), T.rec("</Layer group>", end), T.rec("x", nil)]
        v += [T.rec("g2", open), T.rec("g1", open), T.rec("g0", open), T.rec("top", nil)]
        let f = T.fileWith(v)
        #expect(T.names(f, f.layerTree()) == "g0[g1[g2[x]]],top")
        #expect(T.names(f, f.layerTree(maxDepth: Int.max)) == "g0[g1[g2[x]]],top")
        #expect(T.names(f, f.layerTree(maxDepth: 2)) == "g0[g1[g2[]]],top")
        #expect(T.names(f, f.layerTree(maxDepth: 1)) == "g0[g1[]],top")
        #expect(T.names(f, f.layerTree(maxDepth: 0)) == "g0[],top")
    }

    @Test func folderWithoutDividerIsEmptyGroup() {
        let f = T.fileWith([T.rec("a", nil), T.rec("G", open), T.rec("b", nil)])
        #expect(T.names(f, f.layerTree()) == "a,G[],b")
    }

    @Test func unclosedDividerHoistsChildren() {
        let f = T.fileWith([T.rec("a", nil), T.rec("</Layer group>", end), T.rec("b", nil), T.rec("c", nil)])
        #expect(T.names(f, f.layerTree()) == "a,b,c")
    }

    @Test func lsdkIsHonoured() {
        var endRec = T.rec("</Layer group>", nil)
        var b = PSDTaggedBlock.sectionDivider(.boundingDivider)
        b.key = "lsdk"
        endRec.blocks.append(b)
        let f = T.fileWith([endRec, T.rec("x", nil), T.rec("G", open)])
        #expect(T.names(f, f.layerTree()) == "G[x]")
    }

    @Test func otherSectionTypeIsLayer() {
        let f = T.fileWith([T.rec("a", .other), T.rec("b", .unknown(9))])
        #expect(T.names(f, f.layerTree()) == "a,b")
    }

    @Test func generatedLayeredTree() {
        let f = TestGen.layered(.psd, .rgb, 8, .rle)
        let t = f.layerTree()
        let outer = t.first { $0.isGroup }!
        #expect(f.layers[outer.index].displayName == "Outer")
        #expect(outer.children.count == 2)
        let inner = outer.children[1]
        #expect(inner.isGroup)
        #expect(f.layers[inner.index].displayName == "Inner")
        #expect(f.layers[inner.index].sectionType == .closedFolder)
        #expect(f.layers[inner.children[0].index].displayName == "Grüße")
    }
}
