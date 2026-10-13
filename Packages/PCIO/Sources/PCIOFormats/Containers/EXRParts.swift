// Port of photocraft-io (crates/io/src/exr_parts.rs) and of the Cryptomatte listing of
// photocraft-codecs (crates/codecs/src/codecs/exr_cryptomatte.rs: `layers`, `cryptomatte_id`,
// `cryptomatte_key`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Multi-part EXR and channel groups as layers (a Maya/Arnold render writes one part per AOV, or a
// single part with prefixed channel sets like `diffuse.R`): the entries of a file listed for a
// chooser (`entries`), and the chosen ones imported as the layers of one document
// (`importDocument`), with an optional additive beauty precomp from the AOVs.

import CoreGraphics
import Foundation
import PCDocument
import PCFoundation
import PCIOCore

/// Multi-part OpenEXR import (parts and channel groups as layers).
public enum EXRParts {
    /// One selectable line of the chooser: a whole part, a prefixed channel group inside a part,
    /// or a Cryptomatte layer (listed for information; its samples are not image layers).
    public struct Entry: Equatable, Sendable {
        public var kind: EntryKind
        /// The name as shown and selected: the part name, the channel-group prefix, or the
        /// Cryptomatte layer name.
        public var name: String
        /// The part's `view` attribute (stereo files), when it has one.
        public var view: String?
        public var width: UInt32
        public var height: UInt32
        /// Image channels that would import (4 for RGBA, 3 for RGB); Cryptomatte: stream count.
        public var channels: Int
        /// Cryptomatte only: objects in the parsed manifest.
        public var objects: Int?

        public init(kind: EntryKind, name: String, view: String?, width: UInt32, height: UInt32, channels: Int, objects: Int?) {
            self.kind = kind; self.name = name; self.view = view; self.width = width; self.height = height
            self.channels = channels; self.objects = objects
        }
    }

    public enum EntryKind: Sendable, Equatable, Hashable {
        case part, group, cryptomatte
    }

    /// What `importDocument` turns into layers (photocraft `Selection`; its `precomp` flag is the
    /// `precomp` parameter here).
    public struct Selection: Sendable, Equatable {
        /// Part names to import as whole layers.
        public var parts: [String]
        /// Channel-group prefixes to import as layers.
        public var groups: [String]
        /// `"both"`, `"left"` or `"right"`: which stereo views of the parts to consider.
        public var view: String

        public init(parts: [String] = [], groups: [String] = [], view: String = "both") {
            self.parts = parts; self.groups = groups; self.view = view
        }
    }

    /// One channel group: where it lives and which exact channels make up its RGB(A).
    struct Group {
        /// The prefix before the last dot (`diffuse` of `diffuse.R`).
        var prefix: String
        var part: Int
        var channels: [String]
        var alpha: String?
    }

    /// The name an AOV normalizes to for the precomp check (`Direct_Diffuse` and `directDiffuse`
    /// are the same AOV).
    static func normalize(_ name: String) -> String {
        String(name.unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || ("0" ... "9").contains($0)) }.map { Character($0) }).lowercased()
    }

    /// The additive AOVs a beauty precomp is built from: the light-path set Arnold writes.
    static let precompRequired = ["directdiffuse", "indirectdiffuse", "directspecular", "indirectspecular", "emission"]
    static let precompOptional = ["transmission", "sss", "volume"]

    /// `(prefix, base)` when the channel name carries a dot (`diffuse.R`); nil unprefixed.
    static func channelBaseSplit(_ name: String) -> (prefix: String, base: String)? {
        guard let dot = name.lastIndex(of: ".") else { return nil }
        let prefix = String(name[..<dot])
        return prefix.isEmpty ? nil : (prefix, String(name[name.index(after: dot)...]))
    }

    /// The prefixed RGB(A) channel sets of every flat part (`diffuse.R/G/B` make the group
    /// `diffuse`). Unprefixed channels are no group, and a prefix ending in digits is a
    /// Cryptomatte stream (`crypto_asset00`), not a group. Each prefix is listed once per part.
    static func groups(_ info: [PartInfo]) -> [Group] {
        var out: [Group] = []
        for part in info where !part.deep {
            var found: [Group] = []
            for c in part.channels {
                guard let (prefix, base) = channelBaseSplit(c.name) else { continue }
                if let last = prefix.unicodeScalars.last, ("0" ... "9").contains(last) { continue }
                if !found.contains(where: { $0.prefix == prefix }) {
                    found.append(Group(prefix: prefix, part: part.index, channels: [], alpha: nil))
                }
                guard let i = found.firstIndex(where: { $0.prefix == prefix }) else { continue }
                switch base {
                case "R", "G", "B": found[i].channels.append(c.name)
                case "A": found[i].alpha = c.name
                default: break
                }
            }
            out += found.filter { $0.channels.count == 3 }
        }
        return out
    }

    /// Lists the entries of a multi-part or channel-grouped EXR for a chooser: flat parts in file
    /// order, then the channel groups, then the Cryptomatte layers as information. A file whose
    /// parts are all deep is refused (the deep decoder composites those).
    public static func entries(_ bytes: [UInt8]) throws -> [Entry] {
        let info = try self.info(bytes)
        if info.allSatisfy({ $0.deep }) {
            throw PCIOError.unsupported("this EXR holds only deep parts; it opens through the deep decoder")
        }
        var out: [Entry] = []
        for part in info where !part.deep {
            let colour = part.channels.filter { ["R", "G", "B", "A", "Y"].contains(String(channelBase($0.name))) }.count
            out.append(Entry(kind: .part, name: part.name ?? "part \(part.index)", view: part.view, width: part.width, height: part.height,
                             channels: colour, objects: nil))
        }
        for group in groups(info) {
            out.append(Entry(kind: .group, name: group.prefix, view: nil, width: 0, height: 0, channels: 3 + (group.alpha != nil ? 1 : 0),
                             objects: nil))
        }
        for layer in try cryptomatteLayers(bytes) {
            out.append(Entry(kind: .cryptomatte, name: layer.name, view: nil, width: 0, height: 0, channels: layer.channels.count,
                             objects: layer.manifest.count))
        }
        return out
    }

    /// An image as an importable layer: half floats become floats (lossless, warned once by the
    /// caller), the layout matches the document's (gray with alpha, or RGBA). Returns whether
    /// the layer is grayscale.
    static func layerSurface(_ img: Image, _ maxSize: inout (Int, Int)) -> (surface: Surface, gray: Bool) {
        let gray = img.layout == .gray || img.layout == .grayAlpha
        maxSize.0 = max(maxSize.0, img.width)
        maxSize.1 = max(maxSize.1, img.height)
        let fmt = PixelFormat(mode: gray ? .grayscale : .rgb, sample: .f32, alpha: true)
        let outCh = fmt.channels
        let inCh = img.layout.channels
        var surface = Surface(format: fmt)
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return (surface, gray) }
        // A band of rows at a time, as photocraft's `image_surface`.
        let rows = max(1, (32 << 20) / max(1, w * outCh * 4))
        var y = 0
        while y < h {
            let y1 = min(h, y + rows)
            var band = [Float](repeating: 1, count: (y1 - y) * w * outCh)
            img.samples.withUnsafeBufferPointer { src in
                band.withUnsafeMutableBufferPointer { dst in
                    for i in 0 ..< (y1 - y) * w {
                        let s = (y * w + i) * inCh
                        for c in 0 ..< inCh { dst[i * outCh + c] = src[s + c] }
                    }
                }
            }
            surface.writeRegion(PixelRect(x0: 0, y0: Int32(y), x1: Int32(w), y1: Int32(y1)), band)
            y = y1
        }
        return (surface, gray)
    }

    /// Imports the chosen entries as the layers of one document: parts whole, groups from their
    /// own channels, half floats kept losslessly as 32-bit float, the linear-light EXR values
    /// tagged linear sRGB. `precomp` adds the additive sum of the file's AOV groups as a top layer
    /// and fails, naming the missing AOVs, when the light-path set is incomplete.
    public static func importDocument(name: String, bytes: [UInt8], selection sel: Selection, precomp: Bool = false) throws -> ImportResult {
        let info = try self.info(bytes)
        if info.isEmpty {
            throw PCIOError.unsupported("the EXR has no parts")
        }
        let allGroups = groups(info)
        func viewPasses(_ view: String?) -> Bool {
            guard let v = view else { return true }
            return sel.view.caseInsensitiveCompare("both") == .orderedSame || v.caseInsensitiveCompare(sel.view) == .orderedSame
        }
        func debugView(_ v: String?) -> String { v.map { "Some(\"\($0)\")" } ?? "None" }
        var chosenParts: [PartInfo] = []
        for want in sel.parts {
            guard let p = info.first(where: { !$0.deep && $0.name == want }) else {
                throw PCIOError.unsupported("no flat part named \(want)")
            }
            if !viewPasses(p.view) {
                throw PCIOError.unsupported("the part \(want) is of the \(debugView(p.view)) view, the filter is \(sel.view)")
            }
            if !chosenParts.contains(where: { $0.index == p.index }) { chosenParts.append(p) }
        }
        var chosenGroups: [Group] = []
        for want in sel.groups {
            guard let g = allGroups.first(where: { $0.prefix == want }) else {
                throw PCIOError.unsupported("no channel group named \(want)")
            }
            let partView = g.part < info.count ? info[g.part].view : nil
            if !viewPasses(partView) {
                throw PCIOError.unsupported("the group \(want) is of the \(debugView(partView)) view, the filter is \(sel.view)")
            }
            if !chosenGroups.contains(where: { $0.prefix == g.prefix }) { chosenGroups.append(g) }
        }
        if chosenParts.isEmpty && chosenGroups.isEmpty && !precomp {
            throw PCIOError.unsupported("no parts or groups selected")
        }

        var layers: [Layer] = []
        var warnings: [String] = []
        var grayOnly = true
        var maxSize = (1, 1)
        var halfSeen = false
        var cache: [Int: Image] = [:]
        for part in chosenParts {
            let img: Image
            if let c = cache[part.index] {
                img = c
            } else {
                img = try decodePart(bytes, part.index)
                cache[part.index] = img
            }
            if img.half { halfSeen = true }
            let (surface, gray) = layerSurface(img, &maxSize)
            grayOnly = grayOnly && gray
            layers.append(Layer(name: part.name ?? "part \(part.index)", content: .raster(surface)))
        }
        for group in chosenGroups {
            let img = try decodeChannels(bytes, group.part, group.channels + (group.alpha.map { [$0] } ?? []))
            if img.half { halfSeen = true }
            let (surface, gray) = layerSurface(img, &maxSize)
            grayOnly = grayOnly && gray
            layers.append(Layer(name: group.prefix, content: .raster(surface)))
        }
        if precomp {
            layers.append(try precompLayer(bytes, allGroups, &maxSize, &warnings))
            grayOnly = false // the precomp is an RGB layer by construction
        }
        if layers.isEmpty {
            throw PCIOError.unsupported("nothing imported")
        }
        if halfSeen {
            warnings.append("16-bit float samples are stored as 32-bit float")
        }
        let mode: ColorMode = grayOnly ? .grayscale : .rgb
        var doc = Document(name: name, size: PixelSize(width: maxSize.0, height: maxSize.1), mode: mode, depth: .f32)
        doc.layers = layers
        if mode == .rgb {
            // OpenEXR holds linear, scene-referred values: tag them linear sRGB, as File › Open does.
            doc.iccProfile = linearSRGBProfile()
        }
        return ImportResult(document: doc, warnings: warnings, sourceReadOnly: false, previewOnly: false)
    }

    /// The ICC profile of linear-light sRGB (photocraft `Builtin::LinearSrgb`; Apple's profile).
    static func linearSRGBProfile() -> [UInt8]? {
        CGColorSpace(name: CGColorSpace.linearSRGB)?.copyICCData().map { [UInt8]($0 as Data) }
    }

    /// The additive beauty from the file's AOV groups: premultiplied RGB summed over the
    /// light-path set, alpha the maximum coverage, straightened back. Fails naming the missing
    /// AOVs when the required set is incomplete; AOVs beyond the set are ignored.
    static func precompLayer(_ bytes: [UInt8], _ allGroups: [Group], _ maxSize: inout (Int, Int), _ warnings: inout [String]) throws -> Layer {
        let have = allGroups.map { normalize($0.prefix) }
        let missing = precompRequired.filter { !have.contains($0) }
        if !missing.isEmpty {
            throw PCIOError.unsupported("the AOV set is incomplete for a beauty precomp; missing: \(missing.joined(separator: ", "))")
        }
        var sum: [Float] = []
        var alpha: [Float] = []
        var size = (0, 0)
        for group in allGroups {
            let n = normalize(group.prefix)
            if !precompRequired.contains(n) && !precompOptional.contains(n) { continue }
            let img = try decodeChannels(bytes, group.part, group.channels + (group.alpha.map { [$0] } ?? []))
            let (w, h) = (img.width, img.height)
            if size == (0, 0) {
                size = (w, h)
                sum = [Float](repeating: 0, count: w * h * 3)
                alpha = [Float](repeating: 0, count: w * h)
            } else if size != (w, h) {
                throw PCIOError.unsupported("the AOV groups differ in size; a beauty precomp needs one common extent")
            }
            // AOV channels are premultiplied by their coverage, as renderers write them: the sum
            // adds the stored RGB as-is, and alpha is the maximum coverage.
            let ch = img.layout.channels
            let gray = img.layout == .gray || img.layout == .grayAlpha
            let hasAlpha = img.layout == .rgba || img.layout == .grayAlpha
            for p in 0 ..< w * h {
                let s = p * ch
                let (r, g, b) = gray ? (img.samples[s], img.samples[s], img.samples[s]) : (img.samples[s], img.samples[s + 1], img.samples[s + 2])
                let a: Float = hasAlpha ? img.samples[s + ch - 1] : 1
                sum[p * 3] += r
                sum[p * 3 + 1] += g
                sum[p * 3 + 2] += b
                alpha[p] = Swift.max(alpha[p], a)
            }
        }
        let (w, h) = size
        if w == 0 || h == 0 {
            throw PCIOError.unsupported("the AOV groups are empty")
        }
        var out = [Float](repeating: 0, count: w * h * 4)
        for p in 0 ..< w * h {
            let a = alpha[p]
            if a > 0 {
                out[p * 4] = sum[p * 3] / a
                out[p * 4 + 1] = sum[p * 3 + 1] / a
                out[p * 4 + 2] = sum[p * 3 + 2] / a
            }
            out[p * 4 + 3] = a
        }
        let img = Image(width: w, height: h, layout: .rgba, half: false, samples: out)
        let (surface, _) = layerSurface(img, &maxSize)
        warnings.append("beauty (precomp) is the additive sum of the file's AOVs; alpha is the maximum coverage")
        return Layer(name: "beauty (precomp)", content: .raster(surface))
    }

    // MARK: - Cryptomatte (listing only)

    /// One Cryptomatte layer of an EXR file (Cryptomatte specification 1.2): per-pixel object or
    /// material IDs with coverage, as written by Arnold, V-Ray, Redshift, Mantra/Karma or Cycles.
    /// Header facts plus the parsed manifest; the samples are not decoded here.
    public struct CryptomatteLayer: Equatable, Sendable {
        /// The part the channels and attributes live in.
        public var part: Int
        /// The `cryptomatte/<key>/name` attribute, e.g. `CryptoAsset` or `crypto_asset`.
        public var name: String
        /// The 7-hex-digit metadata key of the layer.
        public var key: String
        /// The `conversion` attribute, when recorded (canonically `uint32_to_float32`).
        public var conversion: String?
        /// The manifest: object names with their ID values (sorted by name, as serde's map).
        public var manifest: [ManifestEntry]
        /// The `manif_file` sidecar attribute, when the manifest is not embedded.
        public var sidecarManifest: String?
        /// The stream channel bases in file order, e.g. `["crypto_asset00", "crypto_asset01"]`.
        public var channels: [String]
    }

    public struct ManifestEntry: Equatable, Sendable {
        public var id: Float
        public var name: String
    }

    /// A Cryptomatte stream channel (`crypto_asset00.red`): its stream, index, and whether it is
    /// the coverage (green) channel instead of the ID (red).
    static func splitStream(_ channel: String) -> (stream: String, index: UInt32, coverage: Bool)? {
        guard let dot = channel.lastIndex(of: ".") else { return nil }
        let stream = String(channel[..<dot]), suffix = channel[channel.index(after: dot)...]
        let coverage: Bool
        switch suffix {
        case "red", "r": coverage = false
        case "green", "g": coverage = true
        default: return nil
        }
        let scalars = Array(stream.unicodeScalars)
        let digits = scalars.reversed().prefix { ("0" ... "9").contains($0) }.count
        if digits == 0 || digits == scalars.count { return nil }
        guard let index = UInt32(String(String.UnicodeScalarView(scalars.suffix(digits)))) else { return nil }
        return (stream, index, coverage)
    }

    /// MurmurHash3, x86-32 bit variant, seed 0 (public-domain algorithm, Austin Appleby).
    static func murmur3(_ data: [UInt8]) -> UInt32 {
        func rotl(_ x: UInt32, _ r: UInt32) -> UInt32 { x << r | x >> (32 - r) }
        let c1: UInt32 = 0xCC9E_2D51, c2: UInt32 = 0x1B87_3593
        var h: UInt32 = 0
        let blocks = data.count / 4
        for i in 0 ..< blocks {
            var k = UInt32(data[4 * i]) | UInt32(data[4 * i + 1]) << 8 | UInt32(data[4 * i + 2]) << 16 | UInt32(data[4 * i + 3]) << 24
            k = rotl(k &* c1, 15) &* c2
            h ^= k
            h = rotl(h, 13) &* 5 &+ 0xE654_6B64
        }
        let rest = data.count & 3
        if rest > 0 {
            var k: UInt32 = 0
            for j in 0 ..< rest { k |= UInt32(data[4 * blocks + j]) << (8 * j) }
            k = rotl(k &* c1, 15) &* c2
            h ^= k
        }
        h ^= UInt32(truncatingIfNeeded: data.count)
        h ^= h >> 16
        h = h &* 0x85EB_CA6B
        h ^= h >> 13
        h = h &* 0xC2B2_AE35
        return h ^ (h >> 16)
    }

    /// The Cryptomatte ID of a name: the MurmurHash3 bits with the exponent fixed away from 0 and
    /// 255, as a float value.
    public static func cryptomatteID(_ name: String) -> Float {
        var bits = murmur3(Array(name.utf8))
        let exp = (bits >> 23) & 0xFF
        if exp == 0 || exp == 255 { bits ^= 1 << 23 }
        return Float(bitPattern: bits)
    }

    /// The 7-hex-digit metadata key of a layer name (the ID bits without their last digit).
    public static func cryptomatteKey(_ name: String) -> String {
        let hex = String(cryptomatteID(name).bitPattern, radix: 16)
        return String((String(repeating: "0", count: max(0, 8 - hex.count)) + hex).prefix(7))
    }

    /// Parses a manifest JSON (`{"object name": "<8-hex ID bits>"}`) into (ID value, name) pairs.
    /// Entries that are not strings of up to eight hex digits are skipped; a broken document
    /// yields none.
    static func parseManifest(_ json: String) -> [ManifestEntry] {
        guard let data = json.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else { return [] }
        var out: [ManifestEntry] = []
        // serde_json's map is ordered by key.
        for name in map.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
            guard let hex = map[name] as? String else { continue }
            var t = Substring(hex)
            while t.hasPrefix("0x") { t = t.dropFirst(2) }
            if t.hasPrefix("+") { t = t.dropFirst() }
            guard !t.isEmpty, t.allSatisfy(\.isHexDigit), let bits = UInt32(t, radix: 16) else { continue }
            out.append(ManifestEntry(id: Float(bitPattern: bits), name: name))
        }
        return out
    }

    /// Lists every Cryptomatte layer of the file from the headers alone. The embedded manifest
    /// (capped at 16 MiB, JSON) is parsed into (ID, name) pairs.
    public static func cryptomatteLayers(_ bytes: [UInt8]) throws -> [CryptomatteLayer] {
        let file = try File.parse(bytes)
        let manifestCap = 16 << 20
        var out: [CryptomatteLayer] = []
        for (part, header) in file.headers.enumerated() {
            let (w, h) = header.size
            try checkBytes(w, h, 8)
            var keys: [String] = []
            for (name, _) in header.texts where name.hasPrefix("cryptomatte/") {
                let rest = name.dropFirst("cryptomatte/".count)
                guard let slash = rest.firstIndex(of: "/") else { continue }
                let key = String(rest[..<slash])
                if !key.isEmpty && !keys.contains(key) { keys.append(key) }
            }
            for key in keys {
                guard let layerName = header.text("cryptomatte/\(key)/name") else { continue }
                let channels = layerStreams(header, layerName)
                if channels.isEmpty { continue }
                var manifest: [ManifestEntry] = []
                if let m = header.text("cryptomatte/\(key)/manifest"), m.utf8.count <= manifestCap { manifest = parseManifest(m) }
                out.append(CryptomatteLayer(part: part, name: layerName, key: key, conversion: header.text("cryptomatte/\(key)/conversion"),
                                            manifest: manifest, sidecarManifest: header.text("cryptomatte/\(key)/manif_file"), channels: channels))
            }
        }
        out.sort { a, b in
            a.part != b.part ? a.part < b.part : Array(a.name.utf8).lexicographicallyPrecedes(Array(b.name.utf8))
        }
        return out
    }

    /// The stream channel names of a layer (`crypto_asset00`, `crypto_asset01`, …, as the file
    /// spells them), matched leniently: the channel prefix and the `name` attribute differ in case
    /// or `_`/`-` between renderers (`CryptoAsset` vs `crypto_asset`).
    static func layerStreams(_ header: Header, _ name: String) -> [String] {
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") }
        let want = norm(name)
        var found: [(UInt32, String)] = []
        for c in header.channels {
            guard let s = splitStream(c.name), !s.coverage else { continue }
            var stem = Substring(s.stream)
            while let last = stem.unicodeScalars.last, ("0" ... "9").contains(last) { stem = stem.dropLast() }
            if norm(String(stem)) == want { found.append((s.index, s.stream)) }
        }
        found.sort { $0.0 != $1.0 ? $0.0 < $1.0 : Array($0.1.utf8).lexicographicallyPrecedes(Array($1.1.utf8)) }
        var out: [String] = []
        var last: (UInt32, String)?
        for f in found {
            if let l = last, l.0 == f.0, l.1 == f.1 { continue }
            out.append(f.1)
            last = f
        }
        return out
    }
}
