// `TySh` (type tool object setting): transform, text descriptor (with EngineData), warp descriptor
// and trailing bounds; plus the document-level `Txt2` text engine block.
// Port of photocraft-text (crates/text/src/psd.rs: parse_tysh, write_tysh, translate_tysh,
// engine_data, parse_txt2), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Layout checked against Compositor IO/PSD/PSDText.swift (MIT, © 2026 Wonder Assembly LLC; no code
// copied).
//
// Lossless: parse/serialize reproduce the block byte for byte (the bytes after the warp descriptor
// are kept raw; photocraft reads them as four f32 bounds).

import Foundation

public struct PSDTypeTool: Equatable, Sendable {
    /// 1.
    public var version: UInt16
    /// xx, xy, yx, yy, tx, ty: text space → document pixels.
    public var transform: [Double]
    /// 50.
    public var textVersion: UInt16
    /// The text descriptor (`Txt `, `EngineData`, `bounds`, `boundingBox`, `Ornt`, `AntA`, …).
    public var text: PSDVersionedDescriptor
    /// 1.
    public var warpVersion: UInt16
    /// The warp descriptor (`warpStyle`, `warpValue`, …).
    public var warp: PSDVersionedDescriptor?
    /// Bytes after the warp descriptor (Photoshop writes 4 × f32 left, top, right, bottom).
    public var trailing: Data

    public init(transform: [Double], text: PSDDescriptor, warp: PSDDescriptor? = PSDTypeTool.defaultWarp(), bounds: [Float] = [0, 0, 0, 0]) {
        version = 1
        self.transform = transform
        textVersion = 50
        self.text = PSDVersionedDescriptor(text)
        warpVersion = 1
        self.warp = warp.map { PSDVersionedDescriptor($0) }
        var w = ByteWriter()
        for b in bounds { w.f32(b) }
        trailing = w.data
    }

    public static func defaultWarp() -> PSDDescriptor {
        PSDDescriptor(classID: "warp")
            .with("warpStyle", .enumerated(type: "warpStyle", value: "warpNone"))
            .with("warpValue", .double(0))
            .with("warpPerspective", .double(0))
            .with("warpPerspectiveOther", .double(0))
            .with("warpRotate", .enumerated(type: "Ornt", value: "Hrzn"))
    }

    public init(bytes: Data) throws {
        self = try bytes.withByteReader { r in
            let version = try r.u16()
            let transform = try (0 ..< 6).map { _ in try r.f64() }
            let textVersion = try r.u16()
            let text = try PSDVersionedDescriptor.read(&r)
            var warpVersion: UInt16 = 1
            var warp: PSDVersionedDescriptor?
            let mark = r
            if r.remaining >= 6 {
                warpVersion = try r.u16()
                if let w = try? PSDVersionedDescriptor.read(&r) { warp = w } else { r = mark }
            }
            var t = PSDTypeTool(transform: transform, text: text.descriptor)
            t.version = version
            t.textVersion = textVersion
            t.text = text
            t.warpVersion = warp == nil ? 1 : warpVersion
            t.warp = warp
            t.trailing = try r.data(r.remaining)
            return t
        }
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        w.u16(version)
        for x in transform.prefix(6) { w.f64(x) }
        for _ in transform.count ..< 6 { w.f64(0) }
        w.u16(textVersion)
        text.write(&w)
        if let warp {
            w.u16(warpVersion)
            warp.write(&w)
        }
        w.put(trailing)
        return w.data
    }

    /// The four f32 bounds after the warp descriptor (left, top, right, bottom), when present.
    public var bounds: [Float]? {
        guard trailing.count >= 16 else { return nil }
        return try? trailing.withByteReader { r in try (0 ..< 4).map { _ in try r.f32() } }
    }

    /// The plain text (`Txt `), with Photoshop's `\r` paragraph breaks.
    public var string: String? { text.descriptor.text("Txt ") }

    /// The parsed EngineData of the text descriptor.
    public var engineData: PSDEngineData? {
        guard let raw = text.descriptor["EngineData"]?.rawBytes else { return nil }
        return try? PSDEngineData.parse(raw)
    }

    /// Replaces the EngineData (serialised in Photoshop's layout).
    public mutating func setEngineData(_ e: PSDEngineData) {
        text.descriptor.set("EngineData", .rawData(e.serialized()))
    }

    /// The block moved by (dx, dy): only the translation changes (text, styles, warp and bounds are
    /// in text space and stay byte for byte).
    public func translated(dx: Double, dy: Double) -> PSDTypeTool {
        var t = self
        t.transform[4] += dx
        t.transform[5] += dy
        return t
    }

    /// Whether the engine text is present and only whitespace (Photoshop draws nothing).
    public var engineTextIsBlank: Bool {
        engineData?.path("EngineDict", "Editor", "Text")?.string.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
    }
}

extension PSDFile {
    /// The parsed document `Txt2` block (text engine data for all type layers).
    public var textEngineData: PSDEngineData? {
        guard let b = globalBlock("Txt2") else { return nil }
        return try? PSDEngineData.parseBare(b.data)
    }
}
