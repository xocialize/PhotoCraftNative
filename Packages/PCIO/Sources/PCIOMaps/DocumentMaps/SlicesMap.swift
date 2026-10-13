// Port of photocraft-io (crates/io/src/slices_map.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// Document slices ↔ PSD resource 1050 (see PCPSD `PSDSlices`).
//
// Import keeps user and layer-based slices (auto slices are regenerated from them) and links
// layer-based slices to the layer whose `lyid` they name. Export writes the preserved resource
// byte-for-byte while the slices are unchanged, else a fresh version 6 resource that also lists the
// current auto slices, as Photoshop saves them.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD

public enum SlicesMap {
    /// Image resource id of the slices.
    public static let slices: UInt16 = PSDResourceID.slices

    static func raw(_ doc: Document) -> [UInt8]? { doc.metadata.psdResources.first { $0.id == slices }?.data }

    /// The document's slices from the raw resource (nil or unreadable = no slices).
    public static func slicesFromPSD(_ raw: [UInt8]?, _ doc: Document) -> Slices {
        guard let r = raw, let res = try? PSDSlices(bytes: Data(r)) else { return Slices() }
        var byPsdId: [UInt32: LayerId] = [:]
        doc.forEachLayer { _, _, l in if let p = l.psdId { byPsdId[p] = l.id } }
        func at<T>(_ a: [T], _ i: Int, _ d: T) -> T { i < a.count ? a[i] : d }
        let list = res.slices.filter { $0.origin != 0 }.map { s in
            let layer = s.origin == 1 ? s.layerID.flatMap { byPsdId[$0] } : nil
            var out = Slice(id: s.id)
            out.groupId = s.groupID
            // A layer-based slice whose layer is gone keeps its rect as a user slice.
            out.origin = s.origin == 1 && layer != nil ? .layer : .user
            out.layer = layer
            out.name = s.name
            out.rect = PixelRect(x0: at(s.rect, 0, 0), y0: at(s.rect, 1, 0), x1: at(s.rect, 2, 0), y1: at(s.rect, 3, 0))
            out.kind = SliceKind(code: s.kind)
            out.url = s.url
            out.target = s.target
            out.message = s.message
            out.alt = s.alt
            out.cellTextIsHtml = s.cellTextIsHTML
            out.cellText = s.cellText
            out.horizontalAlign = s.horizontalAlign
            out.verticalAlign = s.verticalAlign
            let color = SIMD4(at(s.color, 0, 0), at(s.color, 1, 0), at(s.color, 2, 0), at(s.color, 3, 0))
            out.background = color[0] != 0 ? color : nil
            out.outsets = SIMD4(at(s.outsets, 0, 0), at(s.outsets, 1, 0), at(s.outsets, 2, 0), at(s.outsets, 3, 0))
            return out
        }
        return Slices(groupName: res.groupName, list: list)
    }

    /// Sets `doc.slices` from its preserved resource (called after layers and ids are imported)
    /// (photocraft `import`).
    public static func importSlices(_ doc: inout Document) {
        doc.slices = slicesFromPSD(raw(doc), doc)
    }

    /// Do the document's slices still match the preserved resource?
    public static func unchanged(_ doc: Document) -> Bool {
        slicesFromPSD(raw(doc), doc) == doc.slices
    }

    /// The resource to write: nil keeps the preserved one, `.some(nil)` drops it, `.some(bytes)` is
    /// a fresh resource. `layerIds` maps document layers to the PSD layer ids being written.
    public static func exportResource(_ doc: Document, _ layerIds: [LayerId: UInt32]) -> (resource: [UInt8]??, warning: String?) {
        if unchanged(doc) { return (nil, nil) }
        if doc.slices.isEmpty { return (.some(nil), nil) }
        var records: [PSDSlice] = doc.slices.list.map { s in
            var r = PSDSlice()
            r.id = s.id
            r.groupID = s.groupId
            r.origin = s.origin.code
            r.layerID = s.layer.flatMap { layerIds[$0] }
            r.name = s.name
            r.kind = s.kind.code
            r.rect = [s.rect.x0, s.rect.y0, s.rect.x1, s.rect.y1]
            r.url = s.url
            r.target = s.target
            r.message = s.message
            r.alt = s.alt
            r.cellTextIsHTML = s.cellTextIsHtml
            r.cellText = s.cellText
            r.horizontalAlign = s.horizontalAlign
            r.verticalAlign = s.verticalAlign
            let c = s.background ?? .zero
            r.color = [c[0], c[1], c[2], c[3]]
            r.outsets = [s.outsets[0], s.outsets[1], s.outsets[2], s.outsets[3]]
            // A layer slice whose layer isn't written becomes a user slice.
            if r.origin == 1 && r.layerID == nil { r.origin = 2 }
            return r
        }
        let taken = doc.slices.list.map(\.rect)
        var used = Set(doc.slices.list.map(\.id))
        // Keep the usual above-max numbering when possible; if stored ids include UInt32.max, use
        // the first available id instead of wrapping or colliding with a reserved one.
        var nextId: UInt32? = doc.slices.nextId ?? 1
        var omittedAutoSlices = false
        for r in autoSlices(canvas: doc.bounds, taken: taken) {
            guard var id = nextId else {
                omittedAutoSlices = true
                break
            }
            while used.contains(id) {
                guard id < .max else {
                    omittedAutoSlices = true
                    break
                }
                id += 1
            }
            if omittedAutoSlices { break }
            used.insert(id)
            nextId = id < .max ? id + 1 : nil
            var rec = PSDSlice()
            rec.id = id
            rec.origin = 0
            rec.kind = 1
            rec.rect = [r.x0, r.y0, r.x1, r.y1]
            records.append(rec)
        }
        var res = PSDSlices()
        res.version = 6
        res.bounds = [0, 0, Int32(truncatingIfNeeded: doc.size.height), Int32(truncatingIfNeeded: doc.size.width)]
        res.groupName = doc.slices.groupName.isEmpty ? doc.sliceBaseName : doc.slices.groupName
        res.slices = records
        let warning = omittedAutoSlices ? "auto slices omitted because the slice id space is exhausted" : nil
        return (.some([UInt8](res.serialized())), warning)
    }
}
