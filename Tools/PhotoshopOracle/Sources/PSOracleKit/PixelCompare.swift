// Pixel comparisons in PCPSD's *stored* domain: Photoshop's exports (TIFF/Raw) are mapped back to
// how a PSD stores samples (CMYK inverted, Lab a/b offset, palette indices, bitmap bits), so equal
// pixels compare exactly at every depth. Differences are reported per channel in native units and
// in 8-bit levels (16-bit ÷ 257, 32-bit float × 255, 1-bit × 255).

import Foundation
import PCPSD

public struct ChannelDiff: Codable, Sendable {
    public var channel: String
    public var max: Double
    public var mean: Double
    public var max8: Double
    public var mean8: Double
    public var differing: Int
}

public struct PixelDiff: Codable, Sendable {
    public var channels: [ChannelDiff]
    public var pixels: Int
    public var note: String?

    public var max8: Double { channels.map(\.max8).max() ?? 0 }
    public var mean8: Double { channels.isEmpty ? 0 : channels.map(\.mean8).reduce(0, +) / Double(channels.count) }
    public var exact: Bool { channels.allSatisfy { $0.differing == 0 } }

    public var summary: String {
        let per = channels.map { "\($0.channel) \(fmt($0.max8))/\(fmt($0.mean8, 3))" }.joined(separator: " ")
        return "max \(fmt(max8)) mean \(fmt(mean8, 3)) [\(per)]" + (note.map { " (\($0))" } ?? "")
    }
}

func fmt(_ v: Double, _ digits: Int = 2) -> String {
    if v == 0 { return "0" }
    if v == v.rounded(), abs(v) < 1e6 { return String(Int(v)) }
    return String(format: "%.\(digits)f", v)
}

public enum PixelCompare {
    // MARK: stored samples

    /// Planar big-endian bytes of one channel at `depth` → stored values (1-bit: the bit, 1 = black).
    public static func storedValues(_ bytes: [UInt8], depth: UInt16, width: Int, height: Int) -> [Double] {
        let n = width * height
        var out = [Double](repeating: 0, count: n)
        switch depth {
        case 1:
            let rb = (width + 7) / 8
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let i = y * rb + x / 8
                    out[y * width + x] = i < bytes.count ? Double((bytes[i] >> (7 - UInt8(x % 8))) & 1) : 0
                }
            }
        case 8:
            for i in 0 ..< min(n, bytes.count) { out[i] = Double(bytes[i]) }
        case 16:
            for i in 0 ..< min(n, bytes.count / 2) { out[i] = Double(Int(bytes[2 * i]) << 8 | Int(bytes[2 * i + 1])) }
        default:
            for i in 0 ..< min(n, bytes.count / 4) {
                let o = 4 * i
                out[i] = Double(Float(bitPattern: UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3])))
            }
        }
        return out
    }

    /// Every channel of the merged image section, as stored.
    public static func mergedPlanes(_ f: PSDFile) throws -> [[Double]] {
        let all = try f.decodeMerged()
        let (w, h) = (Int(f.header.width), Int(f.header.height))
        let plane = f.header.rowBytes * h
        let count = Int(f.header.channels)
        guard all.count >= plane * count else { throw PSDError.invalid("merged data too short") }
        return (0 ..< count).map { storedValues(Array(all[$0 * plane ..< ($0 + 1) * plane]), depth: f.header.depth, width: w, height: h) }
    }

    public static func colorChannelCount(_ f: PSDFile) -> Int {
        switch f.header.colorMode {
        case .rgb, .lab: 3
        case .cmyk: 4
        case .multichannel, .unknown: Int(f.header.channels)
        default: 1
        }
    }

    public static func channelNames(_ mode: PSDColorMode, count: Int) -> [String] {
        let names: [String]
        switch mode {
        case .rgb: names = ["R", "G", "B"]
        case .cmyk: names = ["C", "M", "Y", "K"]
        case .lab: names = ["L", "a", "b"]
        case .indexed: names = ["index"]
        case .bitmap: names = ["bit"]
        default: names = ["gray"]
        }
        return (0 ..< count).map { $0 < names.count ? names[$0] : "ch\($0)" }
    }

    /// Photoshop's export → the PSD stored domain (colour samples only).
    public static func referenceColorPlanes(_ ref: ReferenceImage) -> [[Double]] {
        let cc = ref.colorSamples
        var planes = Array(ref.planes.prefix(cc))
        switch ref.photometric {
        case 5: // separated: ink amounts; PSD stores 1 − ink
            if !ref.isFloat { planes = planes.map { $0.map { ref.maxValue - $0 } } }
        case 8: // CIELab: a*, b* signed; PSD stores them offset by half the range
            let half = ref.bits == 16 ? 32768.0 : 128.0, full = half * 2
            for k in 1 ..< min(3, planes.count) { planes[k] = planes[k].map { ($0 + half).truncatingRemainder(dividingBy: full) } }
        default: break
        }
        return planes
    }

    public static func referenceAlpha(_ ref: ReferenceImage) -> [Double]? {
        guard !ref.extraSamples.isEmpty, ref.planes.count > ref.colorSamples else { return nil }
        return ref.planes[ref.colorSamples]
    }

    static func levels(_ v: Double, depth: Int) -> Double {
        switch depth {
        case 1: v * 255
        case 16: v / 257
        case 32: v * 255
        default: v
        }
    }

    /// Per-channel statistics over the pixels where `include` is true (all when nil).
    public static func diff(_ a: [[Double]], _ b: [[Double]], names: [String], depth: Int, include: [Bool]? = nil, note: String? = nil) -> PixelDiff {
        var out: [ChannelDiff] = []
        var counted = 0
        for k in 0 ..< min(a.count, b.count) {
            var mx = 0.0, sum = 0.0, differing = 0, n = 0
            for i in 0 ..< min(a[k].count, b[k].count) where include?[i] ?? true {
                let x = a[k][i], y = b[k][i]
                let d = (x.isNaN && y.isNaN) ? 0 : abs(x - y)
                n += 1
                if d > 0 { differing += 1 }
                mx = max(mx, d.isNaN ? .infinity : d)
                sum += d.isNaN ? 0 : d
            }
            counted = n
            let mean = n > 0 ? sum / Double(n) : 0
            out.append(ChannelDiff(channel: k < names.count ? names[k] : "ch\(k)", max: mx, mean: mean,
                                   max8: levels(mx, depth: depth), mean8: levels(mean, depth: depth), differing: differing))
        }
        return PixelDiff(channels: out, pixels: counted, note: note)
    }

    // MARK: merged image vs Photoshop's flattened composite

    /// PCPSD's merged colour planes against Photoshop's flattened composite.
    public static func merged(_ f: PSDFile, against ref: ReferenceImage) throws -> PixelDiff {
        guard ref.width == Int(f.header.width), ref.height == Int(f.header.height) else {
            throw PSDError.invalid("size \(ref.width)x\(ref.height) vs \(f.header.width)x\(f.header.height)")
        }
        let ours = try mergedPlanes(f)
        let cc = min(colorChannelCount(f), ref.colorSamples)
        let theirs = referenceColorPlanes(ref)
        var note: String?
        if f.header.colorMode == .indexed, let map = ref.colorMap, map.count == 768 {
            // Same indices only mean the same colours when the palettes agree.
            let pal = [UInt8](f.colorModeData)
            if pal.count >= 768 {
                let same = (0 ..< 768).allSatisfy { Int(pal[$0]) == Int(map[$0]) >> 8 }
                if !same { note = "palette differs" }
            }
        }
        return diff(Array(ours.prefix(cc)), Array(theirs.prefix(cc)), names: channelNames(f.header.colorMode, count: cc),
                    depth: Int(f.header.depth), note: note)
    }

    /// PCPSD's merged alpha against the alpha of Photoshop's transparent composite.
    public static func mergedAlpha(_ f: PSDFile, against ref: ReferenceImage) throws -> PixelDiff? {
        guard let theirs = referenceAlpha(ref) else { return nil }
        let ours = try mergedPlanes(f)
        let cc = colorChannelCount(f)
        let alpha: [Double]
        if f.mergedHasAlpha, ours.count > cc { alpha = ours[cc] } else {
            alpha = [Double](repeating: f.header.depth == 32 ? 1 : Double((1 << Int(f.header.depth)) - 1), count: theirs.count)
        }
        return diff([alpha], [theirs], names: ["alpha"], depth: Int(f.header.depth))
    }

    // MARK: one layer vs Photoshop's export of that layer

    /// A layer's colour planes and alpha placed on the canvas, as PCPSD decodes them. With `masked`,
    /// alpha is multiplied by the user mask (its rectangle, default colour outside).
    public static func layerCanvas(_ f: PSDFile, record index: Int, masked: Bool) throws -> (color: [[Double]], alpha: [Double]) {
        let h = f.header
        let (W, H) = (Int(h.width), Int(h.height))
        let r = f.layers[index]
        let maxV = h.depth == 32 ? 1.0 : Double((1 << Int(h.depth)) - 1)
        let cc = colorChannelCount(f)
        let (lw, lh) = try r.rect.size()
        var color = [[Double]](repeating: [Double](repeating: 0, count: W * H), count: cc)
        var alpha = [Double](repeating: 0, count: W * H)
        func place(_ id: Int16, rect: PSDRect, into dst: inout [Double], fillOutside: Double?) throws {
            let (w, hh) = try rect.size()
            let v = storedValues(try r.decodeChannel(id, depth: h.depth, version: h.version), depth: h.depth, width: w, height: hh)
            if let fill = fillOutside { for i in 0 ..< dst.count { dst[i] = fill } }
            for y in 0 ..< hh {
                let cy = Int(rect.top) + y
                guard cy >= 0, cy < H else { continue }
                for x in 0 ..< w {
                    let cx = Int(rect.left) + x
                    guard cx >= 0, cx < W else { continue }
                    dst[cy * W + cx] = v[y * w + x]
                }
            }
        }
        for k in 0 ..< cc where r.channel(Int16(k)) != nil { try place(Int16(k), rect: r.rect, into: &color[k], fillOutside: nil) }
        if r.channel(PSDChannelID.transparency) != nil {
            try place(PSDChannelID.transparency, rect: r.rect, into: &alpha, fillOutside: nil)
        } else if lw > 0, lh > 0 {
            for y in max(0, Int(r.rect.top)) ..< min(H, Int(r.rect.bottom)) {
                for x in max(0, Int(r.rect.left)) ..< min(W, Int(r.rect.right)) { alpha[y * W + x] = maxV }
            }
        }
        if masked, let m = r.layerMask {
            let id: Int16 = r.channel(PSDChannelID.realUserMask) != nil ? PSDChannelID.realUserMask : PSDChannelID.userMask
            if r.channel(id) != nil {
                var mask = [Double](repeating: 0, count: W * H)
                let def = id == PSDChannelID.realUserMask ? (m.real?.background ?? m.defaultColor) : m.defaultColor
                let defV = h.depth == 32 ? Double(def) / 255 : Double(def) / 255 * maxV
                try place(id, rect: r.channelRect(id), into: &mask, fillOutside: defV)
                for i in 0 ..< alpha.count { alpha[i] = h.depth == 32 ? alpha[i] * mask[i] : (alpha[i] * mask[i] / maxV).rounded() }
            }
        }
        return (color, alpha)
    }

    /// One layer as PCPSD decodes it against Photoshop's export of that layer: alpha everywhere,
    /// colour where both sides are not fully transparent.
    public static func layer(_ f: PSDFile, record index: Int, masked: Bool, against ref: ReferenceImage) throws -> (color: PixelDiff, alpha: PixelDiff) {
        guard ref.width == Int(f.header.width), ref.height == Int(f.header.height) else {
            throw PSDError.invalid("layer export size \(ref.width)x\(ref.height)")
        }
        let ours = try layerCanvas(f, record: index, masked: masked)
        let maxV = f.header.depth == 32 ? 1.0 : Double((1 << Int(f.header.depth)) - 1)
        let theirsAlpha = referenceAlpha(ref) ?? [Double](repeating: maxV, count: ref.width * ref.height)
        let theirsColor = referenceColorPlanes(ref)
        let both = zip(ours.alpha, theirsAlpha).map { $0 > 0 && $1 > 0 }
        let cc = min(ours.color.count, theirsColor.count)
        let names = channelNames(f.header.colorMode, count: cc)
        var oursColor = Array(ours.color.prefix(cc))
        var note: String?
        if ref.extraSamples.first == 1 {
            // Photoshop writes associated (premultiplied) alpha: compare premultiplied colour. CMYK and
            // Lab premultiply the TIFF values (ink, signed a/b), so premultiply in that domain.
            note = "premultiplied"
            let isFloat = f.header.depth == 32
            func pm(_ v: Double, _ a: Double) -> Double { isFloat ? v * a : (v * a / maxV).rounded() }
            switch ref.photometric {
            case 5:
                oursColor = oursColor.map { p in zip(p, ours.alpha).map { maxV - pm(maxV - $0, $1) } }
            case 8:
                // Photoshop premultiplies Lab's a/b as the PSD stores them (offset), then writes them signed.
                oursColor = oursColor.map { p in zip(p, ours.alpha).map { pm($0, $1) } }
            default:
                oursColor = oursColor.map { p in zip(p, ours.alpha).map { pm($0, $1) } }
            }
        }
        let c = diff(oursColor, Array(theirsColor.prefix(cc)), names: names, depth: Int(f.header.depth), include: both, note: note)
        let a = diff([ours.alpha], [theirsAlpha], names: ["alpha"], depth: Int(f.header.depth))
        return (c, a)
    }
}
