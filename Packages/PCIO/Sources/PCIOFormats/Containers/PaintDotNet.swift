// Port of photocraft-io (crates/io/src/pdn.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// Native, import-only PDN3 reader. Layout reference: addisonElliott/pypdn's reader; NRBF records
// follow Microsoft's public MS-NRBF specification (see `PaintDotNetNRBF.swift`). No .NET
// deserialization runs: the object graph is data only.

import PCDocument
import PCFoundation
import PCIOCore

/// Paint.NET (`.pdn`, PDN3) import. Import only: Save must not write back to the source.
public enum PaintDotNet {
    // photocraft: "shortcut: imports cap decoded pixels at 1 GiB, use streamed tile decoding for
    // larger PDNs."
    static let maxPixelBytes = 1 << 30
    static let maxLayers = 1024
    /// PDN3 blend modes by their numeric `LayerBlendMode` value.
    public static let modes: [BlendMode] = [
        .normal, .multiply, .linearDodge, .paintNetColorBurn, .paintNetColorDodge, .reflect, .glow, .overlay, .difference,
        .negation, .lighten, .darken, .screen, .xor,
    ]
    /// The older `PaintDotNet.UserBlendOps+<Name>BlendOp` class names, in `modes` order.
    static let oldModes = ["Normal", "Multiply", "Additive", "ColorBurn", "ColorDodge", "Reflect", "Glow", "Overlay", "Difference", "Negation",
                           "Lighten", "Darken", "Screen", "Xor"]

    static func invalid(_ message: String) -> PCIOError { .format("PDN", message) }

    /// `true` for a PDN3 document (its signature).
    public static func isPDN(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && bytes[0 ..< 4].elementsEqual(Array("PDN3".utf8))
    }

    private static func count(_ graph: NRBF.Graph, _ object: NRBF.Value, _ field: String) throws -> Int {
        let n = try graph.integer(try graph.field(object, field))
        guard n >= 0 else { throw invalid("invalid \(field)") }
        return Int(n)
    }

    private static func blend(_ graph: NRBF.Graph, _ layer: NRBF.Value, _ props: NRBF.Value) throws -> BlendMode {
        if let mode = try graph.optionalField(props, "blendMode") {
            let n: Int64
            if case .int(let v) = try graph.resolve(mode) {
                n = v
            } else {
                n = try graph.integer(try graph.field(mode, "value__"))
            }
            guard n >= 0 else { throw invalid("invalid blend mode") }
            guard n < Int64(modes.count) else { throw invalid("unsupported blend mode \(n)") }
            return modes[Int(n)]
        }
        let p = try graph.field(layer, "properties")
        let name = try graph.className(try graph.field(p, "blendOp"))
        let prefix = "PaintDotNet.UserBlendOps+", suffix = "BlendOp"
        guard name.hasPrefix(prefix), name.dropFirst(prefix.count).hasSuffix(suffix) else {
            throw invalid("unsupported blend operation \(name)")
        }
        let short = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard let i = oldModes.firstIndex(of: short), i < modes.count else { throw invalid("unsupported blend operation \(short)") }
        return modes[i]
    }

    /// Reads a memory block's numbered chunks in their on-disk order; each chunk has its own gzip
    /// stream and checksum. Inflates into the bounded destination, checking its exact size.
    static func pixels(_ reader: inout NRBF.Reader, _ length: Int, _ ctl: Interrupt) throws -> [UInt8] {
        let version = try reader.byte()
        if version > 1 {
            throw invalid("unsupported pixel compression \(version)")
        }
        let chunkSize = try reader.beU32()
        if chunkSize == 0 {
            throw invalid("zero pixel chunk size")
        }
        let chunks = (length + chunkSize - 1) / chunkSize
        if chunks > 1_000_000 {
            throw invalid("too many pixel chunks")
        }
        // Uncompressed chunks hold every pixel byte: a file shorter than that is truncated, and
        // is rejected before the buffer is allocated.
        if version == 1 && max(0, reader.bytes.count - reader.pos) < length {
            throw invalid("uncompressed pixel data is truncated")
        }
        var seen = [Bool](repeating: false, count: chunks)
        var data = [UInt8](repeating: 0, count: length)
        for _ in 0 ..< chunks {
            try ctl.check()
            let index = try reader.beU32()
            guard index < seen.count else { throw invalid("pixel chunk index out of bounds") }
            if seen[index] {
                throw invalid("duplicate pixel chunk")
            }
            seen[index] = true
            let size = try reader.beU32()
            let raw = try reader.take(size)
            let (start, o1) = index.multipliedReportingOverflow(by: chunkSize)
            guard !o1 else { throw invalid("pixel offset overflow") }
            let (end, o2) = start.addingReportingOverflow(min(chunkSize, max(0, length - start)))
            guard !o2 else { throw invalid("pixel offset overflow") }
            guard start <= end, end <= data.count else { throw invalid("invalid pixel chunk range") }
            let want = end - start
            if version == 0 {
                let out: [UInt8]
                do {
                    out = try Deflate.gunzip(Array(raw), limit: want)
                } catch PCIOError.limitExceeded(_) {
                    throw invalid("pixel chunk has excess data")
                } catch {
                    throw invalid("invalid gzip pixel chunk: \(OpenRaster.errorText(error))")
                }
                guard out.count == want else { throw invalid("invalid gzip pixel chunk: failed to fill whole buffer") }
                data.replaceSubrange(start ..< end, with: out)
            } else {
                if raw.count != want {
                    throw invalid("incorrect uncompressed pixel chunk size")
                }
                data.replaceSubrange(start ..< end, with: raw)
            }
        }
        return data
    }

    /// Imports a PDN3 document: every bitmap layer with its name, visibility, opacity and blend
    /// mode (the six Paint.NET-only modes included). The result is read-only as a source.
    public static func importDocument(name: String, bytes: [UInt8], interrupt ctl: Interrupt) throws -> ImportResult {
        var reader = NRBF.Reader(bytes)
        if !(try reader.take(4)).elementsEqual(Array("PDN3".utf8)) {
            throw invalid("unsupported document signature (expected PDN3)")
        }
        let h = try reader.take(3)
        let headerSize = Int(h[h.startIndex]) | Int(h[h.startIndex + 1]) << 8 | Int(h[h.startIndex + 2]) << 16
        _ = try reader.take(headerSize)
        if !(try reader.take(2)).elementsEqual([0, 1]) {
            throw invalid("unsupported PDN3 serialization version")
        }
        let graph = try NRBF.parse(&reader, ctl)
        let root = graph.root
        if try graph.className(root) != "PaintDotNet.Document" {
            throw invalid("root object is not a Paint.NET document")
        }
        let width = try count(graph, root, "width")
        let height = try count(graph, root, "height")
        let (rowBytes, o1) = width.multipliedReportingOverflow(by: 4)
        guard !o1 else { throw invalid("canvas size overflow") }
        let (canvasBytes, o2) = rowBytes.multipliedReportingOverflow(by: height)
        guard !o2 else { throw invalid("canvas size overflow") }
        if width == 0 || height == 0 || width > Int(Int32.max) || height > Int(Int32.max) || canvasBytes > maxPixelBytes {
            throw invalid("canvas is empty or exceeds the 1 GiB pixel limit")
        }
        let list = try graph.field(root, "layers")
        let items = try graph.array(try graph.field(list, "ArrayList+_items"))
        let len = try count(graph, list, "ArrayList+_size")
        if len == 0 || len > maxLayers {
            throw invalid("document must have 1..1024 bitmap layers")
        }
        guard len <= items.count else { throw invalid("layer list count exceeds its array") }
        var layouts: [Int32: Int] = [:]
        var output: [(id: Int32, layer: Layer)] = []
        output.reserveCapacity(len)
        for layer in items[0 ..< len] {
            try ctl.check()
            if try graph.className(layer) != "PaintDotNet.BitmapLayer" {
                throw invalid("only PDN3 bitmap layers are supported")
            }
            if try count(graph, layer, "Layer+width") != width || count(graph, layer, "Layer+height") != height {
                throw invalid("layer dimensions do not match the canvas")
            }
            let surface = try graph.field(layer, "surface")
            if try graph.className(surface) != "PaintDotNet.Surface" || count(graph, surface, "width") != width
                || count(graph, surface, "height") != height {
                throw invalid("invalid bitmap surface")
            }
            let stride = try count(graph, surface, "stride")
            if stride < rowBytes {
                throw invalid("surface stride is too short for BGRA32 pixels")
            }
            guard case .ref(let id) = try graph.field(surface, "scan0") else { throw invalid("missing pixel memory reference") }
            if let old = layouts.updateValue(stride, forKey: id), old != stride {
                throw invalid("shared pixel memory has inconsistent strides")
            }
            let props = try graph.field(layer, "Layer+properties")
            let opacity = try count(graph, props, "opacity")
            if opacity > 255 {
                throw invalid("opacity exceeds 255")
            }
            var l = Layer.raster(try graph.string(try graph.field(props, "name")), format: .rgba8)
            l.visible = try graph.boolean(try graph.field(props, "visible"))
            l.opacity = Float(opacity) / 255
            l.blend = try blend(graph, layer, props)
            output.append((id, l))
        }
        let blocks = graph.objects(ofClass: "PaintDotNet.MemoryBlock")
        var total = 0
        // Validate every allocation before decoding any block.
        for (id, block) in blocks {
            let length = try count(graph, block, "length64")
            guard let stride = layouts[id] else { throw invalid("unreferenced pixel memory block") }
            let (expected, o) = stride.multipliedReportingOverflow(by: height)
            guard !o else { throw invalid("pixel length overflow") }
            if length != expected {
                throw invalid("pixel memory length does not match the surface")
            }
            if try graph.boolean(try graph.field(block, "hasParent")) || !graph.boolean(try graph.field(block, "deferred")) {
                throw invalid("unsupported non-deferred or parented pixel memory")
            }
            let (sum, o3) = total.addingReportingOverflow(length)
            guard !o3 else { throw invalid("pixel length overflow") }
            total = sum
            if total > maxPixelBytes {
                throw invalid("decoded pixels exceed the 1 GiB limit")
            }
        }
        var surfaces: [Int32: Surface] = [:]
        for (i, (id, block)) in blocks.enumerated() {
            let length = try count(graph, block, "length64")
            var data = try pixels(&reader, length, ctl)
            guard let stride = layouts[id] else { throw invalid("missing surface layout") }
            var surface = Surface(format: .rgba8)
            // BGRA rows (padded to `stride`) to tightly packed RGBA.
            var packed = [UInt8](repeating: 0, count: rowBytes * height)
            try data.withUnsafeMutableBufferPointer { src in
                try packed.withUnsafeMutableBufferPointer { dst in
                    for y in 0 ..< height {
                        if y % 64 == 0 { try ctl.check() }
                        let s = y * stride, d = y * rowBytes
                        guard s + rowBytes <= src.count else { throw invalid("invalid pixel row") }
                        var x = 0
                        while x < rowBytes {
                            dst[d + x] = src[s + x + 2]
                            dst[d + x + 1] = src[s + x + 1]
                            dst[d + x + 2] = src[s + x]
                            dst[d + x + 3] = src[s + x + 3]
                            x += 4
                        }
                    }
                }
            }
            data = []
            surface.writeInterleaved(PixelRect(x0: 0, y0: 0, x1: Int32(width), y1: Int32(height)), packed)
            surfaces[id] = surface
            ctl.progress(0.05 + 0.95 * Float(i + 1) / Float(blocks.count))
        }
        if reader.pos != bytes.count {
            throw invalid("unexpected trailing data")
        }
        var document = Document(name: name, size: PixelSize(width: width, height: height), mode: .rgb, depth: .u8)
        for (id, var layer) in output {
            guard let s = surfaces[id] else { throw invalid("missing pixel memory block") }
            layer.content = .raster(s)
            document.layers.append(layer)
        }
        var warnings: [String] = []
        if let meta = try graph.optionalField(root, "userMetadataItems") {
            if case .null = try graph.resolve(meta) {
            } else if !(try graph.array(meta)).isEmpty {
                warnings.append("Paint.NET document metadata was not imported")
            }
        }
        return ImportResult(document: document, warnings: warnings, sourceReadOnly: true, previewOnly: false)
    }
}
