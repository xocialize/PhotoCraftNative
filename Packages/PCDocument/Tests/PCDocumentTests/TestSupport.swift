// Shared helpers for the PCDocument tests.
// Port of photocraft-doc's test helpers, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.

import Foundation
import PCFoundation
@testable import PCDocument

/// The standard test document: 100 × 50 RGB 8-bit with a white Background.
func makeDoc() -> Document {
    Document.withBackground(name: "t", size: PixelSize(width: 100, height: 50), mode: .rgb, depth: .u8, fill: .white)
}

func encodeJSON<T: Encodable>(_ v: T) throws -> String {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return String(decoding: try e.encode(v), as: UTF8.self)
}

func decodeJSON<T: Decodable>(_ type: T.Type, _ s: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(s.utf8))
}

func roundTrip<T: Codable>(_ v: T) throws -> T {
    try decodeJSON(T.self, try encodeJSON(v))
}

/// The JSON of `v` parsed back as a generic value (for shape checks).
func jsonValue<T: Encodable>(_ v: T) throws -> JSONValue { try JSONValue(encoding: v) }

func close(_ a: Float, _ b: Float, _ eps: Float = 1e-5) -> Bool { abs(a - b) < eps }
func close(_ a: Double, _ b: Double, _ eps: Double) -> Bool { abs(a - b) < eps }
func close(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ eps: Double) -> Bool { abs(a.x - b.x) < eps && abs(a.y - b.y) < eps }
