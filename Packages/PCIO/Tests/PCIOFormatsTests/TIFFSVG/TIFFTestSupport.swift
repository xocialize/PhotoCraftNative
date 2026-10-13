// Test support for the layered-TIFF and SVG tests: the deterministic synthetic PSD generator
// (PCPSD's `PSDTestGen`), the corpus location, and big-endian byte helpers.
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCPSD
import PCPSDTestSupport

/// PCPSD's synthetic PSD generator (product `PCPSDTestSupport`, the port of photocraft-psd
/// testgen.rs).
typealias TIFFTestGen = PSDTestGen

enum TIFFCorpus {
    /// `PCPSD_CORPUS`, default `<fixtures>/psd-corpus` (`Fixtures`); nil when absent.
    static var directory: URL? { Fixtures.psdCorpus }

    static var files: [URL] {
        guard let dir = directory, let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { ["psd", "psb"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// Big-endian building helpers for hand-made fixtures (photocraft `WriteExt`).
struct TIFFBytes {
    var b: [UInt8] = []
    mutating func u8(_ v: UInt8) { b.append(v) }
    mutating func u16(_ v: UInt16) { b += [UInt8(v >> 8), UInt8(v & 0xFF)] }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) { b += [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xFFFF_FFFF)) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func put(_ s: String) { b += Array(s.utf8) }
    mutating func put(_ x: [UInt8]) { b += x }
}

extension Array where Element == UInt8 {
    /// Whether `needle` occurs anywhere (photocraft `windows(n).any(|w| w == needle)`).
    func tiffContains(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= count else { return needle.isEmpty }
        let first = needle[0]
        var i = 0
        while i <= count - needle.count {
            if self[i] == first, self[i ..< i + needle.count].elementsEqual(needle) { return true }
            i += 1
        }
        return false
    }

    func tiffRange(of needle: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= count else { return nil }
        var i = 0
        while i <= count - needle.count {
            if self[i ..< i + needle.count].elementsEqual(needle) { return i ..< i + needle.count }
            i += 1
        }
        return nil
    }
}
