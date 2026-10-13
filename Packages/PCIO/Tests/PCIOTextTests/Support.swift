// Test helpers shared by the PCIOText tests (the helpers of photocraft-text's tests.rs and the
// photocraft-io tests they come from), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.

import Foundation
import PCDocument
import PCFoundation
import PCPSD
@testable import PCIOText

typealias E = PSDEngineData

func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

func point(_ text: String, _ sizePt: Float) -> TextLayer {
    TextLayer(text: text, fontFamily: "Inter", sizePt: sizePt)
}

func styled(_ text: String, _ style: CharStyle) -> TextLayer {
    var t = TextLayer(text: text)
    t.runs = [TextRun(len: text.utf8.count, style: style)]
    return t
}

func runsOf(_ text: String, _ styles: [(Int, CharStyle)]) -> TextLayer {
    var t = TextLayer(text: text)
    t.runs = styles.map { TextRun(len: $0.0, style: $0.1) }
    return t
}

func charStyle(family: String = "", size: Float = 12, _ edit: (inout CharStyle) -> Void = { _ in }) -> CharStyle {
    var s = CharStyle()
    s.fontFamily = family
    s.sizePt = size
    edit(&s)
    return s
}

func build(_ t: TextLayer, _ dpi: Float = 72, ink: SIMD4<Float>? = nil) -> [UInt8] { PSDText.buildTySh(t, dpi: dpi, ink: ink) }

func load(_ tysh: [UInt8], _ dpi: Float = 72) -> TextLayer? { PSDText.textLayer(fromTySh: tysh, dpi: dpi) }

func withTextIndex(_ tysh: [UInt8], _ index: Int32) -> [UInt8] {
    var t = PSDText.parseTySh(tysh)!
    t.text.items.removeAll { $0.key.is("TextIndex") }
    t.text.items.append(PSDDescriptor.Item("TextIndex", .integer(index)))
    return PSDText.writeTySh(t)
}

/// `str` as an EngineData string's raw bytes (UTF-16BE with `FE FF`, `( ) \` escaped).
func edString(_ s: String) -> [UInt8] {
    var v: [UInt8] = []
    for u in s.utf16 {
        for x in [UInt8(u >> 8), UInt8(u & 0xFF)] {
            if x == UInt8(ascii: "(") || x == UInt8(ascii: ")") || x == UInt8(ascii: "\\") { v.append(UInt8(ascii: "\\")) }
            v.append(x)
        }
    }
    return v
}

/// `Txt2` as Photoshop writes it (a bare `/key value` sequence; text objects at `/1 /1`, style
/// runs at `/0 /6 /0`, auto-kern mode at `/11`), for the layer text `text`.
func txt2WithModes(_ text: String, _ modes: [(Int, Int64)]) -> [UInt8] {
    txt2WithStyles(text, modes.map { ($0.0, "/11 \($0.1)") })
}

/// `txt2WithModes` with each style run's keys given as EngineData text (`"/11 1 /85 2"`).
func txt2WithStyles(_ text: String, _ styles: [(Int, String)]) -> [UInt8] {
    var v = bytes("\n\n/98 << /0 14 >> /0 << >> /1 << /1 [ << /0 << /0 (") + [0xFE, 0xFF]
    v += edString(text + "\r")
    v += bytes(") /6 << /0 [ ")
    for (len, keys) in styles {
        v += bytes("<< /0 << /0 << /0 (\u{fe}\u{ff}) /6 << /0 0 \(keys) >> >> >> /1 \(len) >> ")
    }
    v += bytes("] >> >> >> ] >>")
    return v
}

/// A `Txt2` shaped like Photoshop's: document resources and settings beside the text objects
/// (`/0`, `/1 /0`, `/1 /2`), style runs carrying a full style (font, size, leading) besides the
/// auto-kern mode, a Latin-1 string without a byte-order mark, reals, and a second object no
/// layer names. `modes` are the object's `(UTF-16 length, auto-kern mode)` runs for "AVA\r".
func photoshopTxt2(_ modes: [(Int, Int64)]) -> [UInt8] {
    var v = bytes("\n\n/98 << /0 14 >> /0 << /1 << /0 [ << /0 << /0 (MyriadPro-Regular) /2 0 >> >> ] >> >> /1 << /0 << /0 1 /1 .5 >> /1 [ << /0 << /0 (")
    v += [0xFE, 0xFF, 0, 0x41, 0, 0x56, 0, 0x41, 0, 0x0D]
    v += bytes(") /6 << /0 [ ")
    for (len, m) in modes {
        v += bytes("<< /0 << /0 << /0 (\u{fe}\u{ff}) /6 << /0 0 /1 12.0 /2 14.5 /11 \(m) >> >> >> /1 \(len) >> ")
    }
    v += bytes("] >> /7 << /0 1 >> >> /21 << /1 [ 1.25 2.5 ] >> >> << /0 << /0 (")
    v += [0xFE, 0xFF, 0, 0x42, 0, 0x0D]
    v += bytes(") >> /21 << /1 [ 3.0 ] >> >> ] /2 << /0 7 >> >> /3 << /0 .25 >>")
    return v
}

/// `Txt2` with one text object for `text` whose rendered frame is frame 0, and that frame: for
/// point text an anchor `point`, and a frame-to-text matrix `matrix` (recent Photoshop, #1317).
func txt2WithFrame(_ text: String, _ point: (Double, Double)?, _ matrix: [Double]) -> [UInt8] {
    var v = txt2WithModes(text, [(text.utf16.count + 1, 1)])
    // Close the object's model early: `… >> >> ] >>` → `… >> /1 << /2 [ frame ] >> >> ] >>`.
    let tail = bytes("] >> >> >> ] >>")
    precondition(v.suffix(tail.count).elementsEqual(tail))
    v.removeLast(tail.count)
    v += bytes("] >> >> /1 << /2 [ << /6 [ << /10 0 >> ] >> ] >> >> ] >>")
    let pt = point.map { "/0 [ \(String(format: "%.5f", $0.0)) \(String(format: "%.5f", $0.1)) ] " } ?? ""
    let m = matrix.map { String(format: "%.5f", $0) }.joined(separator: " ")
    let frames = "/0 << /8 << /0 [ << /0 << \(pt)/2 << /2 [ \(m) ] >> >> >> ] >> >>"
    let needle = bytes("/0 << >> ")
    let at = (0 ... v.count - needle.count).first { v[$0 ..< $0 + needle.count].elementsEqual(needle) }!
    v.replaceSubrange(at ..< at + needle.count, with: bytes(frames) + [0x20])
    return v
}

/// The corpus directory (`PCPSD_CORPUS`, default `<fixtures>/psd-corpus`), nil when absent.
enum Corpus {
    static var directory: URL? { Fixtures.psdCorpus }

    static var files: [URL] {
        guard let dir = directory, let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { ["psd", "psb"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
