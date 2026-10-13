// Port of photocraft-io (crates/io/src/channel_map.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// Alpha / spot channel options ⇄ PSD `DisplayInfo` image resources (1077, and the older 1007).
//
// Layout (Adobe PSD spec, "DisplayInfo"): resource 1077 starts with a 4-byte version (1), then one
// 13-byte record per extra channel: colour space (u16), four u16 colour components, opacity (u16,
// 0..100) and kind (u8: 0 = colour indicates selected areas, 1 = masked ("protected") areas, 2 =
// spot channel). Resource 1007 has the same records without the version and the spot kind, each
// followed by a padding byte (14 bytes).

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD

public enum ChannelMap {
    public static let displayInfo: UInt16 = 1077, displayInfoOld: UInt16 = 1007
    /// Quick Mask information: channel id (u16) and an "initially empty" flag (u8).
    public static let quickMaskInfo: UInt16 = 1022

    static let spaceRGB: UInt16 = 0
    static let spaceHSB: UInt16 = 1
    static let spaceCMYK: UInt16 = 2
    static let spaceLab: UInt16 = 7
    static let spaceGray: UInt16 = 8

    /// Resource 1077 for `channels` (in file order): a version, then 13 bytes per channel (colour
    /// space, four components, opacity, kind). Every corpus file, Photoshop's included, uses 13;
    /// 14-byte records (the older 1007 layout) shift every channel after the first.
    /// `transparency`: the merged image's transparency channel comes first and gets a record too.
    public static func displayInfo(_ channels: [AlphaChannel], _ transparency: Bool) -> [UInt8] {
        var out: [UInt8] = [0, 0, 0, 1]
        if transparency {
            // As Photoshop writes it: red, 100 %, masked areas.
            out += [0, 0, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 100, 1]
        }
        for c in channels {
            let color: PCColor, opacity: Float, kind: UInt8
            if let spot = c.spot {
                (color, opacity, kind) = (spot.color, spot.solidity, 2)
            } else {
                (color, opacity, kind) = (c.color, c.opacity, c.indicates == .selectedAreas ? 0 : 1)
            }
            let rgb = color.rgb
            out += [UInt8(spaceRGB >> 8), UInt8(spaceRGB & 0xFF)]
            for v in [rgb.x, rgb.y, rgb.z, 0] {
                let q: UInt16 = roundCast(rustClamp(v, 0, 1) * 65535)
                out += [UInt8(q >> 8), UInt8(q & 0xFF)]
            }
            let o: UInt16 = roundCast(rustClamp(opacity, 0, 1) * 100)
            out += [UInt8(o >> 8), UInt8(o & 0xFF)]
            out.append(kind)
        }
        return out
    }

    /// Applies a DisplayInfo resource (`versioned` = 1077: 13-byte records after a version; else the
    /// older 1007 with 14-byte records) to the imported channels in order, after skipping `skip`
    /// records (the merged transparency channel's).
    public static func applyDisplayInfo(_ data: [UInt8], _ versioned: Bool, _ skip: Int, _ channels: inout [AlphaChannel]) {
        let body: ArraySlice<UInt8> = versioned ? (data.count >= 4 ? data[4...] : []) : data[...]
        let size = versioned ? 13 : 14
        let records = body.count / size
        let first = max(skip, 0)
        guard records > first else { return }
        for (ci, ri) in zip(channels.indices, first ..< records) {
            let base = body.startIndex + ri * size
            func u(_ i: Int) -> UInt16 { UInt16(body[base + i]) << 8 | UInt16(body[base + i + 1]) }
            let color = decodeColor(u(0), [u(2), u(4), u(6), u(8)])
            let opacity = Float(min(u(10), 100)) / 100
            switch body[base + 12] {
            case 2:
                channels[ci].spot = SpotInk(color: color, solidity: opacity)
            case let k:
                // An alpha channel, not an ink (a Multichannel import starts every channel as one).
                channels[ci].spot = nil
                channels[ci].color = color
                channels[ci].opacity = opacity
                channels[ci].indicates = k == 0 ? .selectedAreas : .maskedAreas
            }
        }
    }

    /// A PSD colour structure (space id + four u16 components) as an RGB colour; unknown spaces (book
    /// colours…) read the first three components as RGB. See `decodeKnownColor`.
    public static func decodeColor(_ space: UInt16, _ c: [UInt16]) -> PCColor {
        func n(_ i: Int) -> Float { Float(i < c.count ? c[i] : 0) / 65535 }
        return decodeKnownColor(space, c) ?? .rgb(n(0), n(1), n(2))
    }

    /// A PSD colour structure in one of the spaces Photoshop writes for plain colours (0 RGB, 1 HSB,
    /// 2 CMYK, 7 Lab, 8 Grayscale) as an RGB colour, or nil for any other space id. CMYK goes
    /// through the colour-managed conversion (the active document CMYK profile), Lab through the
    /// D50 Lab → sRGB conversion.
    public static func decodeKnownColor(_ space: UInt16, _ c: [UInt16]) -> PCColor? {
        func comp(_ i: Int) -> UInt16 { i < c.count ? c[i] : 0 }
        func n(_ v: UInt16) -> Float { Float(v) / 65535 }
        switch space {
        case spaceRGB:
            return .rgb(n(comp(0)), n(comp(1)), n(comp(2)))
        case spaceHSB:
            let rgb = hsbToRGB(n(comp(0)) * 360, n(comp(1)), n(comp(2)))
            return .rgb(rgb.x, rgb.y, rgb.z)
        // Photoshop colour structures store CMYK inverted (65535 = no ink).
        case spaceCMYK:
            let cmyk = PCColor(mode: .cmyk, c: SIMD4(1 - n(comp(0)), 1 - n(comp(1)), 1 - n(comp(2)), 1 - n(comp(3))), alpha: 1)
            let rgb = cmyk.rgb
            return .rgb(rgb.x, rgb.y, rgb.z)
        case spaceLab:
            let l = Float(min(comp(0), 10000)) / 10000
            let a = Float(Int16(bitPattern: comp(1))) / 100
            let b = Float(Int16(bitPattern: comp(2))) / 100
            let lab = PCColor(mode: .lab, c: SIMD4(l, (a + 128) / 255, (b + 128) / 255, 0), alpha: 1)
            let rgb = lab.rgb
            return .rgb(rgb.x, rgb.y, rgb.z)
        case spaceGray:
            let v = 1 - Float(min(comp(0), 10000)) / 10000
            return .rgb(v, v, v)
        default:
            return nil
        }
    }

    /// HSB (hue in degrees, saturation and brightness 0..1) → RGB.
    static func hsbToRGB(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
        var hh: Float = 0
        if h.isFinite {
            // Rust's `rem_euclid`.
            var r = h.truncatingRemainder(dividingBy: 360)
            if r < 0 { r += 360 }
            hh = r / 60
        }
        let (s, v) = (rustClamp(s, 0, 1), rustClamp(v, 0, 1))
        let fl = hh.rounded(.down)
        let f = hh - fl
        let (p, q, t) = (v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f)))
        switch satCast(fl) as UInt8 {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }
}

/// Rust's `f32::clamp`: NaN stays NaN.
private func rustClamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { v.isNaN ? v : min(max(v, lo), hi) }
