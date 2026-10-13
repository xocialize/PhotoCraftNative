// Port of photocraft-io (crates/io/src/pattern_map.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// Patterns ⇄ PSD: the global `Patt`/`Pat2`/`Pat3` blocks and `.pat` files.
//
// Import parses the blocks into `Document.patterns` and keeps the raw blocks. Export reuses the
// raw blocks verbatim while they still decode to the document's patterns (byte-exact round trips);
// otherwise they are replaced by one block written from the document.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD

public enum PatternMap {
    /// Global block keys holding patterns.
    public static let patternKeys: [FourCC] = ["Patt", "Pat2", "Pat3"]

    static func psdMode(_ m: ColorMode) -> UInt32 {
        switch m {
        case .grayscale: 1
        case .cmyk: 4
        case .lab: 9
        default: 3
        }
    }

    /// A PSD pattern as a document pattern (indexed patterns become RGB through their palette).
    public static func fromPSD(_ p: PSDPattern) -> Pattern? {
        let (w, h) = (p.width, p.height)
        // `width`/`height` are u32 in photocraft; a surface rect needs them in Int32.
        guard w > 0, h > 0, w <= Int(Int32.max), h <= Int(Int32.max) else { return nil }
        let (n, overflow) = w.multipliedReportingOverflow(by: h)
        guard !overflow else { return nil }
        // 1-bit patterns: expand to 8-bit grey.
        var channels: [[UInt8]]
        var depth: UInt16
        if p.depth == 1 {
            let row = (w + 7) / 8
            func expand(_ plane: [UInt8]) -> [UInt8] {
                var out = [UInt8](repeating: 255, count: n)
                for i in 0 ..< n {
                    let (y, x) = (i / w, i % w)
                    let at = y * row + x / 8
                    if at < plane.count, plane[at] & (0x80 >> UInt8(x % 8)) != 0 { out[i] = 0 }
                }
                return out
            }
            channels = p.channels.map(expand)
            depth = 8
        } else {
            channels = p.channels
            depth = p.depth
        }
        let mode: ColorMode
        switch p.mode {
        case 1, 8:
            mode = .grayscale
        case 2:
            guard let pal = p.palette, let idx = channels.first else { return nil }
            channels = (0 ..< 3).map { c in idx.map { i in pal.indices.contains(Int(i) * 3 + c) ? pal[Int(i) * 3 + c] : 0 } }
            mode = .rgb
        case 4:
            mode = .cmyk
        case 9:
            mode = .lab
        case 3:
            mode = .rgb
        default:
            mode = .grayscale
            channels = Array(channels.prefix(1))
        }
        let s = PSDPixels.sampleForDepth(depth)
        let fmt = PixelFormat(mode: mode, sample: s, alpha: p.alpha != nil)
        let cc = PSDPattern.modeChannels(psdMode(mode))
        guard channels.count >= cc else { return nil }
        var refs: [[UInt8]?] = channels.prefix(cc).map { $0 }
        var fill = [[UInt8]](repeating: PSDPixels.zeroSample(s), count: cc)
        var invert = [Bool](repeating: mode == .cmyk, count: cc)
        if let a = p.alpha {
            refs.append(a)
            fill.append(PSDPixels.maxSample(s))
            invert.append(false)
        }
        var bytes = PSDPixels.interleave(refs, fill, n, s, invert)
        if mode == .lab && s == .u16 { PSDPixels.lab16Chroma(&bytes, refs.count, toDoc: true) }
        let surface = Surface(format: fmt, rect: PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h)), interleaved: bytes)
        return Pattern(id: p.id, name: p.name, width: UInt32(w), height: UInt32(h), surface: surface)
    }

    /// A document pattern as a PSD pattern (its own depth and colour model; other models as RGB).
    public static func toPSD(_ p: Pattern) -> PSDPattern {
        let f = p.surface.format
        let mode: ColorMode = switch f.mode {
        case .grayscale, .rgb, .cmyk, .lab: f.mode
        default: .rgb
        }
        let fmt = PixelFormat(mode: mode, sample: f.sample, alpha: f.alpha)
        let surf = fmt == f ? p.surface : convertModel(p.surface, fmt)
        var bytes = surf.readInterleaved(p.rect)
        let ch = fmt.channels
        if mode == .lab && fmt.sample == .u16 { PSDPixels.lab16Chroma(&bytes, ch, toDoc: false) }
        var invert = [Bool](repeating: mode == .cmyk, count: ch)
        if fmt.alpha { invert[ch - 1] = false }
        var planes = PSDPixels.deinterleave(bytes, ch, fmt.sample, invert)
        let alpha = fmt.alpha ? planes.popLast() : nil
        return PSDPattern(mode: psdMode(mode), width: Int(p.width), height: Int(p.height), name: p.name, id: p.id, palette: nil,
                          depth: PSDPixels.psdDepth(fmt.sample), channels: planes, alpha: alpha)
    }

    /// Patterns decoded from the document's raw pattern blocks (malformed blocks are skipped).
    public static func fromGlobalBlocks(_ doc: Document) -> [Pattern] {
        doc.metadata.psdGlobalBlocks
            .filter { patternKeys.contains(FourCC($0.key)) }
            .flatMap { (try? PSDPattern.parseBlock(Data($0.data))) ?? [] }
            .compactMap(fromPSD)
    }

    /// The pattern block key for a document of `depth`: `Patt` (8-bit), `Pat2` (16-bit), `Pat3`
    /// (32-bit), as Photoshop writes them.
    public static func blockKey(_ depth: SampleType) -> FourCC {
        switch depth {
        case .u16: "Pat2"
        case .f32: "Pat3"
        default: "Patt"
        }
    }

    /// Global blocks to write: the raw ones while they still match `Document.patterns`, else the raw
    /// pattern blocks replaced by one written from the document (at the first one's position).
    /// `depth` is the depth the file is written at (the document's unless the export changes it).
    /// A kept pattern block that does not parse is dropped (see `isReadable`).
    public static func exportGlobalBlocks(_ doc: Document, depth: SampleType? = nil) -> [PSDGlobalBlock] {
        let raw = doc.metadata.psdGlobalBlocks.filter(isReadable)
        if fromGlobalBlocks(doc) == doc.patterns { return raw }
        let key = blockKey(depth ?? doc.depth).psdKey
        let fresh = (try? PSDPattern.writeBlock(doc.patterns.map(toPSD))).map { [UInt8]($0) } ?? []
        var out: [PSDGlobalBlock] = []
        out.reserveCapacity(raw.count + 1)
        var placed = false
        for b in raw {
            if patternKeys.contains(FourCC(b.key)) {
                if !placed {
                    out.append(PSDGlobalBlock(signature: "8BIM", key: key, data: fresh))
                    placed = true
                }
            } else {
                out.append(b)
            }
        }
        if !placed && !doc.patterns.isEmpty { out.append(PSDGlobalBlock(signature: "8BIM", key: key, data: fresh)) }
        return out
    }

    /// Whether `block` is not a pattern block, or a pattern block that parses. Photoshop refuses a
    /// file whose pattern data it cannot read, so export drops a damaged kept block.
    /// Bytes after the last pattern must be zero padding (PCPSD's reader stops quietly before a
    /// tail shorter than a length word).
    public static func isReadable(_ block: PSDGlobalBlock) -> Bool {
        guard patternKeys.contains(FourCC(block.key)) else { return true }
        guard let patterns = try? PSDPattern.parseBlock(Data(block.data)) else { return false }
        var o = 0
        for _ in patterns {
            guard let len = u32(block.data, o) else { return false }
            o += 4 + len + (4 - len % 4) % 4
        }
        return block.data.dropFirst(o).allSatisfy { $0 == 0 }
    }

    /// Reads a `.pat` pattern file.
    public static func readPat(_ bytes: [UInt8]) throws -> [Pattern] {
        let ps: [PSDPattern]
        do {
            ps = try PSDPattern.parsePatFile(Data(bytes))
        } catch {
            throw PCIOError.corrupt("not a readable .pat file: \(error)")
        }
        return ps.compactMap(fromPSD)
    }

    /// Writes patterns as a `.pat` file.
    public static func writePat(_ patterns: [Pattern]) throws -> [UInt8] {
        do {
            return [UInt8](try PSDPattern.writePatFile(patterns.map(toPSD)))
        } catch {
            throw PCIOError.unsupported("\(error)")
        }
    }

    // Photoshop keeps a pattern's transparency in the sheet mask array (index 25); PCPSD's writer
    // does too now, so the bytes PCIO rearranged earlier are written as PCPSD makes them.

    static func u32(_ b: [UInt8], _ at: Int) -> Int? {
        guard at >= 0, at <= b.count - 4 else { return nil }
        return Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3])
    }

    // MARK: Missing patterns

    /// Gives every pattern reference (pattern fills, shape fill and stroke paint, Pattern Overlay,
    /// pattern strokes and glows) whose pattern `doc` does not hold a placeholder pattern of that
    /// name: Photoshop 27.11 refuses a file whose pattern fill has no pattern data. A reference
    /// without an id takes the placeholder's (derived from the name, so it is stable). Returns
    /// the warning, if any. Export calls this on its own copy of the document.
    public static func addMissingPatterns(_ doc: inout Document) -> [String] {
        var patterns = doc.patterns
        var added: [String] = []
        func resolve(_ name: String, _ id: inout String) {
            let found = id.isEmpty ? patterns.contains { $0.name == name } : patterns.contains { $0.id == id }
            if found { return }
            let p = placeholder(name: name, id: id)
            id = p.id
            patterns.append(p)
            added.append(name)
        }
        func resolve(_ fill: inout Fill) {
            guard case var .pattern(p) = fill else { return }
            resolve(p.name, &p.id)
            fill = .pattern(p)
        }
        func resolve(_ paint: inout FxPaint) {
            guard case var .pattern(p) = paint else { return }
            resolve(p.name, &p.id)
            paint = .pattern(p)
        }
        doc.forEachLayerMut { l in
            switch l.content {
            case var .fill(f):
                resolve(&f)
                l.content = .fill(f)
            case var .shape(sh):
                if var f = sh.fill { resolve(&f); sh.fill = f }
                if var st = sh.stroke { resolve(&st.paint); sh.stroke = st }
                l.content = .shape(sh)
            default:
                break
            }
            for i in l.effects.items.indices {
                switch l.effects.items[i] {
                case var .patternOverlay(o):
                    resolve(o.name, &o.id)
                    l.effects.items[i] = .patternOverlay(o)
                case var .stroke(s):
                    resolve(&s.paint)
                    l.effects.items[i] = .stroke(s)
                case var .outerGlow(g):
                    resolve(&g.paint)
                    l.effects.items[i] = .outerGlow(g)
                case var .innerGlow(g):
                    resolve(&g.paint)
                    l.effects.items[i] = .innerGlow(g)
                default:
                    break
                }
            }
        }
        guard !added.isEmpty else { return [] }
        doc.patterns = patterns
        let names = added.map { "\"\(Pattern.displayName($0))\"" }.joined(separator: ", ")
        return ["pattern \(names) is not in the document; a grey placeholder was written in its place (Photoshop refuses a pattern without its pattern data)"]
    }

    /// An 8×8 grey checker standing in for a missing pattern.
    static func placeholder(name: String, id: String) -> Pattern {
        let fmt = PixelFormat(mode: .rgb, sample: .u8, alpha: false)
        let bytes = (0 ..< 64).flatMap { i -> [UInt8] in
            let v: UInt8 = (i / 8 / 4 + i % 8 / 4) % 2 == 0 ? 0xC0 : 0x80
            return [v, v, v]
        }
        let surface = Surface(format: fmt, rect: PixelRect(x0: 0, y0: 0, x1: 8, y1: 8), interleaved: bytes)
        let derived = Pattern(name: name, surface: surface, width: 8, height: 8)
        return id.isEmpty ? derived : Pattern(id: id, name: name, width: 8, height: 8, surface: surface)
    }

    /// photocraft's `Surface::convert` across colour models (per pixel through RGBA). PCFoundation's
    /// `converted(to:)` changes depth only, so other models go through sRGB here.
    static func convertModel(_ s: Surface, _ fmt: PixelFormat) -> Surface {
        let unit = PixelRect(x0: 0, y0: 0, x1: 1, y1: 1)
        let defaultRGBA = Surface(format: s.format, defaultPixel: s.defaultPixelValue).readRGBA(unit)[0]
        var out = Surface(format: fmt, defaultPixel: fmt.components(fromRGBA: defaultRGBA))
        s.forEachTile { c, _ in out.writeRGBA(c.rect, s.readRGBA(c.rect)) }
        return out
    }
}
