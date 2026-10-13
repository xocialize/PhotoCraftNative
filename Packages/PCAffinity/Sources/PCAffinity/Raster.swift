// Port of photocraft-affinity (crates/affinity/src/raster.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Pixel layers (`Rstr`) and placed images (`ImgN`). A placed image keeps its original file
// (`DyBm.Bckg` → archive entry `c/N`), which is imported as is; other pixels are planar tiles of
// 256 bytes × 256 rows per channel, each its own archive entry.

extension Affinity {
    enum Raster {
        /// Pixels decoded per layer (the content's bounding box, not the canvas).
        static let maxPixels: UInt64 = 64 << 20
        static let tile = 256
        static let tileBytes = tile * tile

        static func dimension(_ s: Stream, _ bitmap: ObjID, _ tag: Tag) -> UInt32 {
            s.int(bitmap, tag).flatMap { UInt32(exactly: $0) } ?? 0
        }

        static func nodeImage(_ r: Reader, _ id: ObjID, _ world: Affine) throws(AffinityError) -> Image? {
            let s = r.s
            guard let bitmap = s.obj(id, "Bitm") else {
                r.warn("pixel layers without pixels")
                return nil
            }
            guard s.isClass(bitmap, "DyBm") else {
                r.warn("pixel layers stored in an unknown way")
                return nil
            }
            let width = dimension(s, bitmap, "BmpW")
            let height = dimension(s, bitmap, "BmpH")
            if width == 0 || height == 0 { return nil }
            // A placed image: the original file, byte for byte.
            let hasTiles = s.field(bitmap, "Sta1") != nil
            if let name = s.entry(bitmap, "Bckg"), !name.isEmpty, s.isClass(id, "ImgN") || !hasTiles {
                do {
                    let bytes = try original(r, name)
                    return Image(width: width, height: height, pixels: .encoded(bytes), transform: world)
                } catch AffinityError.limit(let e) {
                    throw .limit(e)
                } catch {
                    r.warn("an embedded image file that could not be read (its cached pixels were used)")
                }
            }
            // The content's bounding box, so a mostly empty canvas-sized layer stays small.
            var crop = (UInt32(0), UInt32(0), width, height)
            if case .ints(let v)? = s.field(id, "BitR"), v.count == 4, v[0] > Int64(Int32.min) + 1 {
                func c(_ x: Int64, _ hi: UInt32) -> UInt32 { UInt32(min(max(x, 0), Int64(hi))) }
                crop = (c(v[0], width), c(v[1], height), c(v[2], width), c(v[3], height))
            }
            if s.field(bitmap, "Bckg") != nil, hasTiles, !s.isClass(id, "ImgN") {
                r.warn("edited placed images use their stored pixels")
            }
            return try decode(r, bitmap, crop, world)
        }

        /// A mask layer (`MRst`): one channel of coverage as grey pixels (white shows, black hides).
        static func mask(_ r: Reader, _ id: ObjID, _ world: Affine) throws(AffinityError) -> Image? {
            let s = r.s
            guard let bitmap = s.obj(id, "Bitm") else { return nil }
            let width = dimension(s, bitmap, "BmpW")
            let height = dimension(s, bitmap, "BmpH")
            let format = s.enumeration(bitmap, "Frmt")?.id
            guard width != 0, height != 0, format == 6 || format == 7 else {
                r.warn("pixel masks in an unknown format (imported without them)")
                return nil
            }
            return try decode(r, bitmap, (0, 0, width, height), world)
        }

        /// An embedded document or symbol instance (`EmbN`), as the picture of it Affinity caches.
        static func embedded(_ r: Reader, _ id: ObjID, _ world: Affine) throws(AffinityError) -> Image? {
            let s = r.s
            guard let cache = s.obj(id, "Bitm").flatMap({ s.obj($0, "Cach") }) else { return nil }
            guard let bbox = s.obj(id, "Bitm").flatMap({ s.floats($0, "ChBB", count: 4) }) else { return nil }
            let width = dimension(s, cache, "BmpW")
            let height = dimension(s, cache, "BmpH")
            if width == 0 || height == 0 { return nil }
            let (x0, y0, x1, y1) = (bbox[0], bbox[1], bbox[2], bbox[3])
            // The instance's origin is the centre of the embedded content (checked against the
            // thumbnails of documents with embedded documents and SVG files).
            let (cx, cy) = ((x0 + x1) / 2, (y0 + y1) / 2)
            let place = Affine((x1 - x0) / Double(width), 0, 0, (y1 - y0) / Double(height), x0 - cx, y0 - cy).then(world)
            return try decode(r, cache, (0, 0, width, height), place)
        }

        /// Decode the tiles of a bitmap inside `crop` (pixels), placed by `world` (bitmap pixels to document).
        static func decode(_ r: Reader, _ bitmap: ObjID, _ crop: (UInt32, UInt32, UInt32, UInt32), _ world: Affine) throws(AffinityError) -> Image? {
            let s = r.s
            let (x0, y0, x1, y1) = crop
            if x1 <= x0 || y1 <= y0 { return nil }
            let (w, h) = (x1 - x0, y1 - y0)
            if UInt64(w) * UInt64(h) > maxPixels {
                r.warn("pixel layers larger than 64 megapixels")
                return nil
            }
            let channels: Int
            let bps: Int
            switch s.enumeration(bitmap, "Frmt")?.id {
            case 0?: (channels, bps) = (4, 1)
            case 1?: (channels, bps) = (4, 2)
            case 6?: (channels, bps) = (1, 1)
            case 7?: (channels, bps) = (1, 2)
            case 4?:
                r.warn("CMYK pixel layers (converted to RGB without the document's colour profile)")
                (channels, bps) = (5, 1)
            default:
                r.warn("pixel layers in grey, Lab or 32-bit formats")
                return nil
            }
            var planes: [[UInt8]] = []
            var cache: [String: [UInt8]] = [:]
            for c in 1...channels {
                planes.append(try plane(r, bitmap, c, bps, (x0, y0, w, h), &cache))
            }
            let n = Int(w) * Int(h)
            var rgba = [UInt8](repeating: 0, count: n * 4)
            func sample(_ p: [UInt8], _ i: Int) -> Double {
                if bps == 2 {
                    let lo = 2 * i < p.count ? p[2 * i] : 0
                    let hi = 2 * i + 1 < p.count ? p[2 * i + 1] : 0
                    return Double(UInt16(lo) | UInt16(hi) << 8) / 65535
                }
                return Double(i < p.count ? p[i] : 0) / 255
            }
            func byte(_ v: Double) -> UInt8 {
                Affinity.saturating((Affinity.clamp(v, 0, 1) * 255).rounded())
            }
            for i in 0..<n {
                let rgb: (Double, Double, Double, Double)
                if channels == 1 {
                    let v = sample(planes[0], i)
                    rgb = (v, v, v, 1)
                } else if channels == 5 {
                    let k = 1 - sample(planes[3], i)
                    rgb = ((1 - sample(planes[0], i)) * k, (1 - sample(planes[1], i)) * k, (1 - sample(planes[2], i)) * k, sample(planes[4], i))
                } else {
                    rgb = (sample(planes[0], i), sample(planes[1], i), sample(planes[2], i), sample(planes[3], i))
                }
                rgba[4 * i] = byte(rgb.0)
                rgba[4 * i + 1] = byte(rgb.1)
                rgba[4 * i + 2] = byte(rgb.2)
                rgba[4 * i + 3] = byte(rgb.3)
            }
            let transform = Affine(1, 0, 0, 1, Double(x0), Double(y0)).then(world)
            return Image(width: w, height: h, pixels: .rgba8(rgba), transform: transform)
        }

        /// The original image file: entry `c/N` is a stream whose root (`Blck`) holds it as `Data`.
        static func original(_ r: Reader, _ name: String) throws(AffinityError) -> [UInt8] {
            let bytes = try r.archive.read(name)
            let s = try Stream.parse(bytes)
            guard let root = s.object(s.root) else { throw .malformed("embedded image") }
            guard case .blob(let b)? = root.get("Data"), !b.isEmpty else { throw .malformed("embedded image without data") }
            return b
        }

        static func tag(_ prefix: String, _ c: Int) -> Tag {
            Tag(prefix + String(c))
        }

        /// One channel of level 0, cropped to (x0, y0, w, h) pixels; `bps` bytes per sample.
        static func plane(
            _ r: Reader, _ bitmap: ObjID, _ c: Int, _ bps: Int,
            _ area: (UInt32, UInt32, UInt32, UInt32), _ cache: inout [String: [UInt8]]
        ) throws(AffinityError) -> [UInt8] {
            let s = r.s
            let (x0, y0, w, h) = area
            let width = s.int(bitmap, "BmpW").flatMap { Int(exactly: $0) }.flatMap { $0 >= 0 ? $0 : nil } ?? 0
            let height = s.int(bitmap, "BmpH").flatMap { Int(exactly: $0) }.flatMap { $0 >= 0 ? $0 : nil } ?? 0
            func positive(_ t: Tag) -> Int? { s.int(bitmap, t).flatMap { Int(exactly: $0) }.flatMap { $0 >= 0 ? $0 : nil } }
            // Dimensions come from the file: saturate instead of overflowing (photocraft's usize maths).
            let bytesWide = width.multipliedReportingOverflow(by: bps)
            let tw = positive(tag("TWi", c)) ?? divCeil(bytesWide.overflow ? Int.max : bytesWide.partialValue, tile)
            let th = positive(tag("THi", c)) ?? divCeil(height, tile)
            var states: [UInt8] = []
            if case .array(let a)? = s.field(bitmap, tag("Sta", c)) {
                states = a.map { if case .uint(let u) = $0 { UInt8(exactly: u) ?? 255 } else { 255 } }
            }
            let tiles = s.objs(bitmap, tag("Idx", c))
            let row = Int(w) * bps
            var out = [UInt8](repeating: 0, count: row * Int(h))
            let (bx0, bx1) = (Int(x0) * bps, Int(x0 + w) * bps)
            let (py0, py1) = (Int(y0), Int(y0 + h))
            let span = Swift.max(tw, 1)
            let (count, overflow) = tw.multipliedReportingOverflow(by: th)
            let limit = overflow ? Int.max : count
            var next = 0
            for (t, state) in states.enumerated() where t < limit {
                let (ty, tx) = (t / span, t % span)
                let fill: UInt8?
                switch state {
                case 0, 1:
                    fill = nil
                case 2:
                    fill = 0xFF
                case 4:
                    guard next < tiles.count else { throw .malformed("missing pixel tile") }
                    let blck = tiles[next]
                    next += 1
                    let (ox, oy) = (tx * tile, ty * tile)
                    if ox >= bx1 || ox + tile <= bx0 || oy >= py1 || oy + tile <= py0 { continue }
                    guard let name = s.entry(blck, "Data") else { throw .malformed("pixel tile without data") }
                    if cache[name] == nil {
                        var data = try r.archive.read(name)
                        // Older files wrap a tile in a one-field stream: header, then a 64 KiB blob.
                        if data.count == tileBytes + 22, data.starts(with: [0x00, 0xFF, 0x4B, 0x53]) {
                            data = Array(data[21..<(21 + tileBytes)])
                        }
                        guard data.count == tileBytes else { throw .malformed("pixel tile size") }
                        cache[name] = data
                    }
                    guard let tileData = cache[name] else { throw .malformed("pixel tile") }
                    copy(&out, row, (bx0, py0, bx1, py1), (ox, oy)) { x, y in tileData[y * tile + x] }
                    continue
                case 3:
                    r.warn("32-bit pixel layers")
                    fill = nil
                case 5:
                    r.warn("pixel layers drawn from an embedded image (left empty)")
                    fill = nil
                default:
                    throw .malformed("unknown pixel tile state")
                }
                if let v = fill {
                    copy(&out, row, (bx0, py0, bx1, py1), (tx * tile, ty * tile)) { _, _ in v }
                }
            }
            return out
        }

        static func divCeil(_ a: Int, _ b: Int) -> Int {
            a / b + (a % b != 0 ? 1 : 0)
        }

        /// Copy the overlap of a tile at byte column `ox`, row `oy` into the cropped plane.
        static func copy(_ out: inout [UInt8], _ row: Int, _ bounds: (Int, Int, Int, Int), _ origin: (Int, Int), _ at: (Int, Int) -> UInt8) {
            let (bx0, py0, bx1, py1) = bounds
            let (ox, oy) = origin
            let yStart = Swift.max(oy, py0)
            let yEnd = Swift.min(oy + tile, py1)
            let xStart = Swift.max(ox, bx0)
            let xEnd = Swift.min(ox + tile, bx1)
            guard yStart < yEnd, xStart < xEnd else { return }
            for y in yStart..<yEnd {
                for x in xStart..<xEnd {
                    let i = (y - py0) * row + (x - bx0)
                    if i < out.count { out[i] = at(x - ox, y - oy) }
                }
            }
        }
    }
}
