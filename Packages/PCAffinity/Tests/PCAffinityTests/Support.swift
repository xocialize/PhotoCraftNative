// Port of photocraft-affinity (crates/affinity/src/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Test helpers: a seeded generator standing in for proptest, byte builders, and a large-stack runner
// for building deliberately deep synthetic documents.

import Foundation
@testable import PCAffinity
import PCAffinitySynth

typealias F = Synth.F
typealias Tag = Affinity.Tag

/// SplitMix64: deterministic cases, so a failure reproduces.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { Synth.bytesLE(v) }
func be<T: FixedWidthInteger>(_ v: T) -> [UInt8] { Synth.bytesBE(v) }
func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }
func crc(_ b: some Collection<UInt8>) -> UInt32 { Synth.crc32(Array(b)) }

extension Array where Element == UInt8 {
    mutating func put(_ bytes: [UInt8], at offset: Int) {
        replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}

/// The error a throwing call ends with, or nil when it succeeds.
func failure<T>(_ body: () throws -> T) -> AffinityError? {
    do {
        _ = try body()
        return nil
    } catch let error as AffinityError {
        return error
    } catch {
        return .malformed("not an AffinityError: \(error)")
    }
}

func isUnsupported(_ e: AffinityError?) -> Bool {
    if case .unsupported? = e { return true }
    return false
}

func isLimit(_ e: AffinityError?) -> Bool {
    if case .limit? = e { return true }
    return false
}

final class Box<T>: @unchecked Sendable {
    var value: T?
}

/// Run `body` on a thread with a `stack`-byte stack and wait for its result.
func onThread<T>(stack: Int, _ body: @escaping @Sendable () -> T) -> T {
    let box = Box<T>()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        box.value = body()
        done.signal()
    }
    thread.stackSize = stack
    thread.start()
    done.wait()
    return box.value!
}

/// Run `body` on a 64 MiB stack. Swift Testing runs tests on threads with small stacks; building
/// (and dropping) a 2000-level synthetic object tree recurses once per level in the test builders.
func onLargeStack<T>(_ body: @escaping @Sendable () -> T) -> T {
    onThread(stack: 64 << 20, body)
}

// MARK: - Synthetic document pieces (after photocraft-io's tests)

func rgba(_ r: Float, _ g: Float, _ b: Float, _ a: Float) -> F {
    .structure([r, g, b, a].flatMap { le($0.bitPattern) })
}

/// A fill descriptor holding a solid RGBA colour: ids `id`, `id + 1`, `id + 2`.
func solid(_ id: UInt32, _ c: F) -> F {
    .def(id, ["FDsc"], [("FDeF", .def(id + 1, ["FilS"], [("Colr", .def(id + 2, ["RGBA"], [("_col", c)]))]))])
}

/// One 18-byte curve record: an anchor at (x, y).
func anchor(_ x: Double, _ y: Double, role: UInt8 = 0) -> [UInt8] {
    le(x.bitPattern) + le(y.bitPattern) + [1, role]
}

/// A raw field: type code, tag, payload (for value kinds the synthetic builder has no case for).
func rawField(_ code: UInt8, _ tag: Tag, _ payload: [UInt8]) -> (Tag, F) {
    (tag, .raw([code] + le(tag.rawValue) + payload))
}

/// An array of f64 values (`Doub`, dash patterns).
func f64Array(_ tag: Tag, _ v: [Double]) -> (Tag, F) {
    rawField(0x80 | 0x0a, tag, le(UInt32(v.count)) + v.flatMap { le($0.bitPattern) })
}

/// An array of i32 values (`Ints`).
func i32Array(_ tag: Tag, _ v: [Int32]) -> (Tag, F) {
    rawField(0x80 | 0x07, tag, le(UInt32(v.count)) + v.flatMap { le($0) })
}

/// Four i32 values (`BitR`).
func ints4(_ tag: Tag, _ v: [Int32]) -> (Tag, F) {
    rawField(0x17, tag, v.flatMap { le($0) })
}

/// A blob (`Data` of an embedded file).
func blob(_ tag: Tag, _ b: [UInt8]) -> (Tag, F) {
    rawField(0x2d, tag, le(UInt32(b.count)) + b)
}

/// A document: `UVCn.UPPI` = dpi, `DocR` holding `spreads`.
func document(_ spreads: [F], dpi: Double = 144, extra: [(Tag, F)] = []) -> [UInt8] {
    Synth.stream([
        ("UVCn", .obj("UVCn", [("UPPI", .f64(dpi))])),
        ("DocR", .def(1, ["DocN"], [("Chld", .shared(spreads))])),
    ] + extra)
}

func spread(_ id: UInt32, _ children: [F], bounds: [Double] = [0, 0, 200, 100], fields: [(Tag, F)] = []) -> F {
    .def(id, ["Sprd"], [("SprB", .f64s(bounds)), ("SprT", .bool(true)), ("Chld", .shared(children))] + fields)
}
