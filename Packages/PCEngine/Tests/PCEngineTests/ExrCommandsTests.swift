// Port of photocraft-engine (crates/engine/src/exr_cmds.rs, `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The fixtures photocraft writes with the `exr` crate are written here by a minimal OpenEXR
// writer (uncompressed FLOAT scan lines, single- or multi-part), from the OpenEXR file layout.

import Foundation
import PCDocument
@testable import PCEngine
import Testing

/// A minimal OpenEXR writer: uncompressed scan-line parts of FLOAT channels, each channel one
/// constant value.
fileprivate enum EXRFixture {
    struct Part {
        var name: String
        var channels: [(String, Float)]
    }

    static func u32(_ v: UInt32, _ b: inout [UInt8]) { b += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
    static func i32(_ v: Int32, _ b: inout [UInt8]) { u32(UInt32(bitPattern: v), &b) }
    static func cString(_ s: String, _ b: inout [UInt8]) { b += Array(s.utf8) + [0] }
    static func attribute(_ name: String, _ type: String, _ value: [UInt8], _ b: inout [UInt8]) {
        cString(name, &b)
        cString(type, &b)
        i32(Int32(value.count), &b)
        b += value
    }

    static func file(_ parts: [Part], width w: Int, height h: Int) -> [UInt8] {
        let multipart = parts.count > 1
        var b: [UInt8] = []
        u32(20_000_630, &b)
        u32(multipart ? 2 | 0x1000 : 2, &b)
        let sorted = parts.map { p in p.channels.sorted { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) } }
        for (pi, p) in parts.enumerated() {
            var ch: [UInt8] = []
            for (name, _) in sorted[pi] {
                cString(name, &ch)
                i32(2, &ch) // FLOAT
                ch += [0, 0, 0, 0]
                i32(1, &ch)
                i32(1, &ch)
            }
            ch.append(0)
            attribute("channels", "chlist", ch, &b)
            attribute("compression", "compression", [0], &b)
            var box: [UInt8] = []
            for v in [0, 0, w - 1, h - 1] { i32(Int32(v), &box) }
            attribute("dataWindow", "box2i", box, &b)
            attribute("displayWindow", "box2i", box, &b)
            attribute("lineOrder", "lineOrder", [0], &b)
            var one: [UInt8] = []
            u32(Float(1).bitPattern, &one)
            attribute("pixelAspectRatio", "float", one, &b)
            attribute("screenWindowCenter", "v2f", [UInt8](repeating: 0, count: 8), &b)
            attribute("screenWindowWidth", "float", one, &b)
            attribute("name", "string", Array(p.name.utf8), &b)
            if multipart {
                attribute("type", "string", Array("scanlineimage".utf8), &b)
                var c: [UInt8] = []
                i32(Int32(h), &c)
                attribute("chunkCount", "int", c, &b)
            }
            b.append(0)
        }
        if multipart { b.append(0) }
        var tables: [Int] = []
        for _ in parts {
            tables.append(b.count)
            b += [UInt8](repeating: 0, count: 8 * h)
        }
        for (pi, _) in parts.enumerated() {
            for y in 0 ..< h {
                let offset = UInt64(b.count)
                for k in 0 ..< 8 { b[tables[pi] + 8 * y + k] = UInt8(truncatingIfNeeded: offset >> (8 * k)) }
                if multipart { i32(Int32(pi), &b) }
                i32(Int32(y), &b)
                var data: [UInt8] = []
                for (_, v) in sorted[pi] { for _ in 0 ..< w { u32(v.bitPattern, &data) } }
                i32(Int32(data.count), &b)
                b += data
            }
        }
        return b
    }

    /// One part per AOV: `Z` and the beauty RGBA.
    static func multipart() -> [UInt8] {
        file([Part(name: "Z", channels: [("Z", 5)]), Part(name: "beauty", channels: [("R", 0.8), ("G", 0.4), ("B", 0.2), ("A", 1)])], width: 4, height: 4)
    }

    /// Two AOV groups (each with alpha) plus the beauty RGBA, in one part.
    static func grouped() -> [UInt8] {
        file([Part(name: "main", channels: [
            ("diffuse.R", 0.3), ("diffuse.G", 0.3), ("diffuse.B", 0.3), ("diffuse.A", 0.5),
            ("specular.R", 0.6), ("specular.G", 0.6), ("specular.B", 0.6), ("specular.A", 0.25),
            ("R", 0.9), ("G", 0.9), ("B", 0.9), ("A", 1),
        ])], width: 4, height: 4)
    }
}

fileprivate func write(_ bytes: [UInt8], _ dir: URL, _ name: String) throws -> String {
    let url = dir.appendingPathComponent(name)
    try Data(bytes).write(to: url)
    return url.path
}

fileprivate func firstPixel(_ l: Layer) -> [Float] {
    guard case .raster(let surface) = l.content else { return [] }
    return surface.pixel(x: 0, y: 0)
}

@Suite struct ExrCommandsTests {
    @Test func exrPartsListsPartsGroupsAndViews() throws {
        let dir = try ioDir("exr-parts")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try write(EXRFixture.multipart(), dir, "aov.exr")
        let s = Session()
        let info = try s.execute("file.exrParts", ["path": .string(path)])
        let entries = try #require(info.arrayValue)
        #expect(entries.compactMap { $0["kind"]?.stringValue } == ["part", "part"], "\(info.serialized())")
        #expect(entries.first?["name"] == "Z")
        #expect(entries.last?["name"] == "beauty")
        #expect(entries.last?["channels"] == 4)
    }

    @Test func openExrPartsImportsTheChosenPartAsALayer() throws {
        let dir = try ioDir("exr-open")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try write(EXRFixture.multipart(), dir, "aov.exr")
        let s = Session()
        let r = try s.execute("file.openExrParts", ["path": .string(path), "part/beauty": true, "part/Z": false])
        #expect(r["warnings"]?.arrayValue?.isEmpty == true, "\(r.serialized())")
        let doc = try #require(s.active).doc
        #expect(doc.layers.count == 1)
        #expect(doc.layers.first?.name == "beauty")
        // The beauty pixels survived (R 0.8 at pixel 0).
        let px = try #require(doc.layers.first.map(firstPixel))
        #expect(abs((px.first ?? 0) - 0.8) < 1e-4, "\(px)")
        #expect(s.active?.path == path)
    }

    @Test func openExrPartsRefusesAnEmptySelectionAndUnknownNames() throws {
        let dir = try ioDir("exr-empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try write(EXRFixture.multipart(), dir, "aov.exr")
        let s = Session()
        let e1 = #expect(throws: EngineError.self) { try s.execute("file.openExrParts", ["path": .string(path)]) }
        #expect(e1?.description.contains("no parts or groups selected") == true, "\(String(describing: e1))")
        let e2 = #expect(throws: EngineError.self) { try s.execute("file.openExrParts", ["path": .string(path), "part/nope": true]) }
        #expect(e2?.description.contains("no flat part named nope") == true, "\(String(describing: e2))")
        let e3 = #expect(throws: EngineError.self) { try s.execute("file.openExrParts", ["path": .string(path), "part/beauty": true, "view": "middle"]) }
        #expect(e3?.description.contains(#"it is "both", "left" or "right""#) == true)
        #expect(s.documents.isEmpty)
    }

    @Test func channelGroupsImportFromTheirOwnChannels() throws {
        let dir = try ioDir("exr-groups")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try write(EXRFixture.grouped(), dir, "grouped.exr")
        let s = Session()
        let info = try s.execute("file.exrParts", ["path": .string(path)])
        #expect(info.arrayValue?.compactMap { $0["name"]?.stringValue } == ["main", "diffuse", "specular"], "\(info.serialized())")
        try s.execute("file.openExrParts", ["path": .string(path), "group/diffuse": true])
        let doc = try #require(s.active).doc
        #expect(doc.layers.count == 1)
        #expect(doc.layers.first?.name == "diffuse")
        let px = try #require(doc.layers.first.map(firstPixel))
        // The channels import as stored (straight here): values are untouched.
        #expect(px.count == 4 && abs(px[0] - 0.3) < 1e-4 && abs(px[3] - 0.5) < 1e-4, "\(px)")
    }

    @Test func precompSumsTheLightPathSetAndRefusesAnIncompleteOne() throws {
        let dir = try ioDir("exr-precomp")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try write(EXRFixture.grouped(), dir, "grouped.exr")
        let s = Session()
        // diffuse + specular make the set incomplete: emission is missing.
        let e = #expect(throws: EngineError.self) { try s.execute("file.openExrParts", ["path": .string(path), "precomp": true, "group/diffuse": true]) }
        #expect(e.map { $0.description.contains("missing") && $0.description.contains("emission") } == true, "\(String(describing: e))")
        // A complete set: direct/indirect diffuse+specular and emission.
        let aovs: [(String, Float, Float)] = [
            ("direct_diffuse", 0.10, 1), ("indirect_diffuse", 0.20, 1), ("direct_specular", 0.05, 1), ("indirect_specular", 0.15, 1), ("emission", 0.30, 1),
        ]
        var channels: [(String, Float)] = []
        var expected: Float = 0
        for (name, v, a) in aovs {
            channels += [("\(name).R", v), ("\(name).G", v), ("\(name).B", v), ("\(name).A", a)]
            expected += v * a
        }
        let full = try write(EXRFixture.file([.init(name: "main", channels: channels)], width: 4, height: 4), dir, "full.exr")
        let t = Session()
        let r = try t.execute("file.openExrParts", ["path": .string(full), "precomp": true])
        #expect(r["warnings"]?.arrayValue?.contains { $0.stringValue?.contains("precomp") == true } == true, "\(r.serialized())")
        let doc = try #require(t.active).doc
        let precomp = try #require(doc.layers.first { $0.name == "beauty (precomp)" })
        let px = firstPixel(precomp)
        #expect(abs((px.first ?? 0) - expected) < 1e-3, "\(px) vs \(expected)")
        #expect(doc.mode == .rgb)
    }
}
