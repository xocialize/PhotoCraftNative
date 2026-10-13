// Layer effects: object-based effects (`lfx2`, `lfxs` on groups, `lmfx` multiple instances) and the
// legacy Photoshop 5 `lrFX` block.
// Format knowledge ported from photocraft-io (crates/io/src/effects_map.rs: the lfx2 descriptor keys
// and `parse_lrfx`) and photocraft-psd (crates/psd/src/tiff.rs: the lrFX record layout), MIT OR
// Apache-2.0, © ArtCraft Team and the PhotoCraft contributors; record tables from Adobe's
// specification ("Effects Layer", "Object Based Effects Layer Info"). The doc mapping stays in the
// engine; here every structure is typed for reading and kept raw for exact writing.

import Foundation

/// `lfx2` / `lfxs` / `lmfx`: u32 object effects version (0) + versioned descriptor.
public struct PSDObjectEffects: Equatable, Sendable {
    public var effectsVersion: UInt32
    public var descriptor: PSDVersionedDescriptor
    /// Bytes after the descriptor (Photoshop pads the block data to a multiple of 4), kept.
    public var tail: Data

    /// Descriptor keys of the single-instance effects, in Photoshop's order.
    public static let effectKeys = ["DrSh", "IrSh", "OrGl", "IrGl", "ebbl", "SoFi", "ChFX", "GrFl", "patternFill", "FrFX"]
    /// Multi-instance list keys (`lmfx`, and `lfx2` from Photoshop CC 2015 on).
    public static let multiKeys = ["dropShadowMulti", "innerShadowMulti", "solidFillMulti", "gradientFillMulti", "frameFXMulti"]

    public init(_ descriptor: PSDDescriptor, effectsVersion: UInt32 = 0) {
        self.effectsVersion = effectsVersion
        self.descriptor = PSDVersionedDescriptor(descriptor)
        tail = Data()
    }

    public init(bytes: Data) throws {
        (effectsVersion, descriptor, tail) = try bytes.withByteReader { r in
            (try r.u32(), try PSDVersionedDescriptor.read(&r), try r.data(r.remaining))
        }
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        w.u32(effectsVersion)
        descriptor.write(&w)
        w.put(tail)
        return w.data
    }

    /// The global effects switch (`masterFXSwitch`, default on).
    public var isEnabled: Bool { descriptor.descriptor.bool("masterFXSwitch") ?? true }
    /// Effects scale in percent (`Scl `).
    public var scale: Double? { descriptor.descriptor.number("Scl ") }

    public struct Effect: Equatable, Sendable {
        /// Descriptor key (`DrSh`, `dropShadowMulti`, …).
        public var key: String
        public var descriptor: PSDDescriptor
        public var isEnabled: Bool { descriptor.bool("enab") ?? true }
        /// The effect is shown in the layers panel (`present`).
        public var isPresent: Bool { descriptor.bool("present") ?? true }
        public var blendMode: PSDBlendMode? { descriptor.enumValue("Md  ").flatMap(PSDBlendMode.init(descriptorValue:)) }
        /// Opacity 0...1 (`Opct`, percent).
        public var opacity: Double? { descriptor.number("Opct").map { $0 / 100 } }
        public var color: PSDColor? { descriptor.descriptor("Clr ").flatMap(PSDColor.init(descriptor:)) }
    }

    /// Every effect instance (single keys and the items of multi lists), in stored order.
    public var effects: [Effect] {
        var out: [Effect] = []
        for item in descriptor.descriptor.items {
            let k = item.key.name
            if PSDObjectEffects.effectKeys.contains(k), let d = item.value.descriptor {
                out.append(Effect(key: k, descriptor: d))
            } else if PSDObjectEffects.multiKeys.contains(k), let list = item.value.list {
                out += list.compactMap { $0.descriptor.map { Effect(key: k, descriptor: $0) } }
            }
        }
        return out
    }
}

/// The legacy `lrFX` block: u16 version, u16 count, then `8BIM` + key + u32 size + data per effect.
public struct PSDLegacyEffects: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var signature: FourCC
        /// `cmnS`, `dsdw`, `isdw`, `oglw`, `iglw`, `bevl`, `sofi`.
        public var key: FourCC
        /// Bytes after the size field.
        public var data: Data

        public init(key: FourCC, data: Data, signature: FourCC = "8BIM") {
            self.signature = signature
            self.key = key
            self.data = data
        }

        public var typed: PSDLegacyEffect? { try? PSDLegacyEffect.parse(key: key, data: data) }
    }

    public var version: UInt16
    public var entries: [Entry]
    /// Bytes after the last entry.
    public var trailing: Data

    public init(version: UInt16 = 0, entries: [Entry], trailing: Data = Data()) {
        self.version = version
        self.entries = entries
        self.trailing = trailing
    }

    public init(bytes: Data) throws {
        (version, entries, trailing) = try bytes.withByteReader { r in
            let version = try r.u16()
            let count = try r.u16()
            var entries: [Entry] = []
            for _ in 0 ..< count {
                let sig = try r.fourCC()
                guard sig == "8BIM" || sig == "8B64" else { throw PSDError.invalidSignature(expected: "8BIM effect", found: sig) }
                let key = try r.fourCC()
                let size = try r.u32()
                entries.append(Entry(key: key, data: try r.data(Int(size)), signature: sig))
            }
            return (version, entries, try r.data(r.remaining))
        }
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        w.u16(version)
        w.u16(UInt16(entries.count))
        for e in entries {
            w.fourCC(e.signature)
            w.fourCC(e.key)
            w.u32(UInt32(e.data.count))
            w.put(e.data)
        }
        w.put(trailing)
        return w.data
    }
}

/// A typed legacy effect record.
public enum PSDLegacyEffect: Equatable, Sendable {
    public struct Shadow: Equatable, Sendable {
        public var version: UInt32
        /// Blur, intensity, angle and distance are 16.16 fixed point in practice (photocraft).
        public var blur: Double
        public var intensity: Double
        public var angle: Double
        public var distance: Double
        public var color: PSDColorRecord
        public var blendMode: PSDBlendMode
        public var enabled: Bool
        public var useGlobalAngle: Bool
        /// 0...255.
        public var opacity: UInt8
        public var nativeColor: PSDColorRecord?
    }

    public struct Glow: Equatable, Sendable {
        public var version: UInt32
        public var blur: Double
        public var intensity: Double
        public var color: PSDColorRecord
        public var blendMode: PSDBlendMode
        public var enabled: Bool
        public var opacity: UInt8
        /// Inner glow version 2 only.
        public var invert: Bool?
        public var nativeColor: PSDColorRecord?
    }

    public struct Bevel: Equatable, Sendable {
        public var version: UInt32
        public var angle: Double
        public var strength: Double
        public var blur: Double
        public var highlightBlendMode: PSDBlendMode
        public var shadowBlendMode: PSDBlendMode
        public var highlightColor: PSDColorRecord
        public var shadowColor: PSDColorRecord
        /// 1 outer, 2 inner, 3 emboss, 4 pillow emboss, 5 stroke emboss.
        public var style: UInt8
        public var highlightOpacity: UInt8
        public var shadowOpacity: UInt8
        public var enabled: Bool
        public var useGlobalAngle: Bool
        /// 0 up, 1 down.
        public var direction: UInt8
        public var realHighlightColor: PSDColorRecord?
        public var realShadowColor: PSDColorRecord?
    }

    public struct SolidFill: Equatable, Sendable {
        public var version: UInt32
        public var blendMode: PSDBlendMode
        public var color: PSDColorRecord
        public var opacity: UInt8
        public var enabled: Bool
        public var nativeColor: PSDColorRecord?
    }

    case commonState(version: UInt32, visible: Bool)
    case dropShadow(Shadow)
    case innerShadow(Shadow)
    case outerGlow(Glow)
    case innerGlow(Glow)
    case bevel(Bevel)
    case solidFill(SolidFill)

    static func fixed(_ v: UInt32) -> Double { Double(Int32(bitPattern: v)) / 65536 }

    static func blend(_ r: inout ByteReader) throws -> PSDBlendMode {
        _ = try r.fourCC()
        return PSDBlendMode(key: try r.fourCC())
    }

    public static func parse(key: FourCC, data: Data) throws -> PSDLegacyEffect? {
        try data.withByteReader { r -> PSDLegacyEffect? in
            switch key {
            case "cmnS":
                let v = try r.u32()
                return .commonState(version: v, visible: try r.u8() != 0)
            case "dsdw", "isdw":
                let version = try r.u32()
                let s = Shadow(version: version, blur: fixed(try r.u32()), intensity: fixed(try r.u32()), angle: fixed(try r.u32()),
                               distance: fixed(try r.u32()), color: try .read(&r), blendMode: try blend(&r), enabled: try r.u8() != 0,
                               useGlobalAngle: try r.u8() != 0, opacity: try r.u8(),
                               nativeColor: r.remaining >= 10 ? try .read(&r) : nil)
                return key == "dsdw" ? .dropShadow(s) : .innerShadow(s)
            case "oglw", "iglw":
                let version = try r.u32()
                var g = Glow(version: version, blur: fixed(try r.u32()), intensity: fixed(try r.u32()), color: try .read(&r),
                             blendMode: try blend(&r), enabled: try r.u8() != 0, opacity: try r.u8(), invert: nil, nativeColor: nil)
                if version >= 2 {
                    if key == "iglw", r.remaining >= 1 { g.invert = try r.u8() != 0 }
                    if r.remaining >= 10 { g.nativeColor = try .read(&r) }
                }
                return key == "oglw" ? .outerGlow(g) : .innerGlow(g)
            case "bevl":
                let version = try r.u32()
                var b = Bevel(version: version, angle: fixed(try r.u32()), strength: fixed(try r.u32()), blur: fixed(try r.u32()),
                              highlightBlendMode: try blend(&r), shadowBlendMode: try blend(&r), highlightColor: try .read(&r),
                              shadowColor: try .read(&r), style: try r.u8(), highlightOpacity: try r.u8(), shadowOpacity: try r.u8(),
                              enabled: try r.u8() != 0, useGlobalAngle: try r.u8() != 0, direction: try r.u8())
                if version >= 2, r.remaining >= 20 {
                    b.realHighlightColor = try .read(&r)
                    b.realShadowColor = try .read(&r)
                }
                return .bevel(b)
            case "sofi":
                let version = try r.u32()
                let bm = try blend(&r)
                return .solidFill(SolidFill(version: version, blendMode: bm, color: try .read(&r), opacity: try r.u8(), enabled: try r.u8() != 0,
                                            nativeColor: r.remaining >= 10 ? try .read(&r) : nil))
            default:
                return nil
            }
        }
    }
}
