// Shape layers and vector data: `vogk` (vector origination), `vscg` (vector stroke content), `vstk`
// (vector stroke), `pths` (unicode path names), `brst` (channel blending restrictions), plus the
// layer-level accessors tying them to `vmsk`/`vsms` vector masks and the blending ranges.
// Format knowledge ported from photocraft-io (crates/io/src/vector_map.rs, blocks.rs: brst, blend-if)
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors; origination keys cross-checked
// against Compositor IO/PSD/PSDVector.swift (MIT, © 2026 Wonder Assembly LLC; no code copied).

import Foundation

/// A block that is a u32 header (version or key) followed by a versioned descriptor: `vogk`
/// (version 1) and `vscg` (fill key such as `SoCo`).
public struct PSDHeaderedDescriptor: Equatable, Sendable {
    public var header: UInt32
    public var descriptor: PSDVersionedDescriptor
    public var tail: Data

    public init(header: UInt32, descriptor: PSDDescriptor) {
        self.header = header
        self.descriptor = PSDVersionedDescriptor(descriptor)
        tail = Data()
    }

    public init(bytes: Data) throws {
        (header, descriptor, tail) = try bytes.withByteReader { r in (try r.u32(), try PSDVersionedDescriptor.read(&r), try r.data(r.remaining)) }
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        w.u32(header)
        descriptor.write(&w)
        w.put(tail)
        return w.data
    }

    /// `vscg`: the fill kind (`SoCo`, `GdFl`, `PtFl`).
    public var fillKey: FourCC { FourCC(rawValue: header) }
}

/// One live-shape origination record of `vogk` (`keyDescriptorList` item).
public struct PSDShapeOrigination: Equatable, Sendable {
    public var descriptor: PSDDescriptor
    /// 1 rectangle, 2 rounded rectangle, 4 line, 5 ellipse, 6 polygon, 7 custom shape…
    public var originType: Int? { descriptor.number("keyOriginType").map { Int($0) } }
    /// Bounding box left, top, right, bottom in document pixels.
    public var boundingBox: (left: Double, top: Double, right: Double, bottom: Double)? {
        guard let b = descriptor.descriptor("keyOriginShapeBBox"), let l = b.number("Left"), let t = b.number("Top "),
              let r = b.number("Rght"), let bt = b.number("Btom") else { return nil }
        return (l, t, r, bt)
    }
    /// Corner radii (top-left, top-right, bottom-right, bottom-left) of rounded rectangles.
    public var cornerRadii: [Double]? {
        guard let d = descriptor.descriptor("keyOriginRRectRadii") else { return nil }
        let r = ["topLeft", "topRight", "bottomRight", "bottomLeft"].compactMap { d.number($0) }
        return r.count == 4 ? r : nil
    }
}

/// `vstk` stroke settings (a versioned descriptor of class `strokeStyle`).
public struct PSDVectorStroke: Equatable, Sendable {
    public var descriptor: PSDVersionedDescriptor
    public var tail: Data

    public init(bytes: Data) throws {
        (descriptor, tail) = try bytes.withByteReader { r in (try PSDVersionedDescriptor.read(&r), try r.data(r.remaining)) }
    }

    public func serialized() -> Data {
        var d = descriptor.serialized()
        d.append(tail)
        return d
    }

    var d: PSDDescriptor { descriptor.descriptor }
    public var strokeEnabled: Bool { d.bool("strokeEnabled") ?? false }
    public var fillEnabled: Bool { d.bool("fillEnabled") ?? true }
    /// Points or pixels as stored (`#Pnt` / `#Pxl` unit float).
    public var lineWidth: Double? { d.number("strokeStyleLineWidth") }
    public var opacity: Double? { d.number("strokeStyleOpacity").map { $0 / 100 } }
    /// `strokeStyleButtCap` / `RoundCap` / `SquareCap`.
    public var lineCap: String? { d.enumValue("strokeStyleLineCapType") }
    /// `strokeStyleMiterJoin` / `RoundJoin` / `BevelJoin`.
    public var lineJoin: String? { d.enumValue("strokeStyleLineJoinType") }
    /// `strokeStyleAlignInside` / `Center` / `Outside`.
    public var alignment: String? { d.enumValue("strokeStyleLineAlignment") }
    public var dashes: [Double] { d.list("strokeStyleLineDashSet")?.compactMap(\.number) ?? [] }
    /// The stroke's paint (`strokeStyleContent`): a solid colour's `Clr `, gradient or pattern.
    public var content: PSDDescriptor? { d.descriptor("strokeStyleContent") }
    public var color: PSDColor? { content?.descriptor("Clr ").flatMap(PSDColor.init(descriptor:)) }
}

extension PSDLayerRecord {
    /// The vector mask (`vmsk`, or CS6's `vsms`).
    public var vectorMask: PSDVectorMask? {
        (block("vmsk") ?? block("vsms")).flatMap { try? PSDVectorMask(bytes: $0.data) }
    }

    /// Live shape originations (`vogk` → `keyDescriptorList`).
    public var shapeOriginations: [PSDShapeOrigination] {
        guard let b = block("vogk"), let h = try? PSDHeaderedDescriptor(bytes: b.data) else { return [] }
        return h.descriptor.descriptor.list("keyDescriptorList")?.compactMap { $0.descriptor.map(PSDShapeOrigination.init) } ?? []
    }

    /// `vstk`.
    public var vectorStroke: PSDVectorStroke? { block("vstk").flatMap { try? PSDVectorStroke(bytes: $0.data) } }

    /// The shape fill: `vscg` (fill key + descriptor) or the plain `SoCo`/`GdFl`/`PtFl` block.
    public var fill: PSDFillSetting? {
        if let b = block("vscg"), let h = try? PSDHeaderedDescriptor(bytes: b.data) {
            var f = PSDFillSetting(key: h.fillKey, descriptor: h.descriptor.descriptor)
            f.tail = h.tail
            return f
        }
        for key: FourCC in ["SoCo", "GdFl", "PtFl"] {
            if let b = block(key), let f = try? PSDFillSetting(key: key, bytes: b.data) { return f }
        }
        return nil
    }

    /// Object effects (`lmfx` over `lfx2` over a group's `lfxs`).
    public var objectEffects: PSDObjectEffects? {
        (block("lmfx") ?? block("lfx2") ?? block("lfxs")).flatMap { try? PSDObjectEffects(bytes: $0.data) }
    }

    /// Legacy `lrFX` effects.
    public var legacyEffects: PSDLegacyEffects? { block("lrFX").flatMap { try? PSDLegacyEffects(bytes: $0.data) } }

    /// `TySh` type layer.
    public var typeTool: PSDTypeTool? { block("TySh").flatMap { try? PSDTypeTool(bytes: $0.data) } }

    /// Channels excluded from blending (`brst`, Advanced Blending "Channels"): indices of the
    /// unchecked channels.
    public var blendingRestrictions: [UInt32] {
        guard let b = block("brst") else { return [] }
        return (try? b.data.withByteReader { r in try (0 ..< r.remaining / 4).map { _ in try r.u32() } }) ?? []
    }

    /// Blend If ranges: composite gray first, then each channel.
    public var blendIf: [PSDBlendingRanges.Range] { blendingRanges.ranges }

    /// `shmd` metadata items.
    public var metadataItems: [PSDMetadataItem] { block("shmd").flatMap { try? PSDMetadataItem.parse($0.data) } ?? [] }

    /// What kind of layer the record is, from its blocks.
    public var kind: PSDLayerKind {
        switch sectionType {
        case .openFolder, .closedFolder: return .group
        case .boundingDivider: return .groupEnd
        default: break
        }
        if block("TySh") != nil || block("tySh") != nil { return .text }
        if block("SoLd") != nil || block("SoLE") != nil || block("PlLd") != nil { return .smartObject }
        if blocks.contains(where: { PSDAdjustment.keys.contains($0.key) }) { return .adjustment }
        if block("vmsk") != nil || block("vsms") != nil, block("SoCo") != nil || block("GdFl") != nil || block("PtFl") != nil || block("vscg") != nil {
            return .shape
        }
        if block("SoCo") != nil || block("GdFl") != nil || block("PtFl") != nil { return .fill }
        if block("artb") != nil || block("artd") != nil || block("abdd") != nil { return .artboard }
        return .pixel
    }
}

/// Layer kinds as Photoshop distinguishes them.
public enum PSDLayerKind: Hashable, Sendable {
    case pixel, group, groupEnd, text, smartObject, adjustment, fill, shape, artboard
}
