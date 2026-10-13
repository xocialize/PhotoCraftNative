// Tests of the private LUT-file port used by Color Lookup.
// Port of photocraft-cms (crates/cms/src/lutfile.rs, `#[cfg(test)] mod tests`; the built-in looks
// test is not ported with them), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCIOMaps

private typealias Lut = AdjustMap.LutFile

private func ok(_ r: Result<Lut, AdjustMap.LutError>) throws -> Lut {
    switch r {
    case let .success(l): return l
    case let .failure(e): throw e
    }
}

private func err(_ r: Result<Lut, AdjustMap.LutError>) -> String? {
    if case let .failure(e) = r { return e.message }
    return nil
}

@Suite struct AdjustLutFileTests {
    private let base = "TITLE \"t\"\nLUT_3D_SIZE 2\n"
    private let rows = "0 0 0\n0 0 1\n0 1 0\n0 1 1\n1 0 0\n1 0 1\n1 1 0\n1 1 1\n"

    @Test func cubeDomainIsKeptAndValidated() throws {
        // The default domain parses as default.
        #expect(try ok(Lut.parseCube(base + rows)).domainIsDefault)
        // DOMAIN_MIN/MAX are kept for the caller to act on.
        let d = try ok(Lut.parseCube("DOMAIN_MIN 0.1 0.2 0.3\nDOMAIN_MAX 0.9 0.8 0.7\n" + base + rows))
        #expect(d.domainMin == SIMD3(0.1, 0.2, 0.3))
        #expect(d.domainMax == SIMD3(0.9, 0.8, 0.7))
        #expect(!d.domainIsDefault)
        // A degenerate domain is a parse error, not a division by zero later.
        let e = err(Lut.parseCube("DOMAIN_MIN 0.5 0.5 0.5\nDOMAIN_MAX 0.5 1 1\n" + base + rows))
        #expect(e?.contains("below DOMAIN_MAX") == true, "\(String(describing: e))")
        #expect(e == "DOMAIN_MIN [0.5, 0.5, 0.5] must lie below DOMAIN_MAX [0.5, 1.0, 1.0]")
    }

    @Test func cube1DDomainIsBakedIntoTheResample() throws {
        // An identity ramp over the domain 0.25...0.75: 0.25 maps to 0, 0.5 to 0.5, 0.75 to 1.
        let l = try ok(Lut.parseCube("LUT_1D_SIZE 2\nLUT_1D_INPUT_RANGE 0.25 0.75\n0 0 0\n1 1 1\n"))
        #expect(l.domainIsDefault, "the domain is baked in, so the cube is plain 0...1")
        func at(_ r: Int) -> Float { l.data[r * 3] }
        // 33-point grid, red fastest: entry r on the red axis is input r / 32.
        #expect(abs(at(0)) < 1e-6, "below the domain saturates to 0")
        #expect(abs(at(16) - 0.5) < 1e-5, "0.5 is the middle of 0.25...0.75: \(at(16))")
        #expect(abs(at(8)) < 1e-5, "0.25 maps to 0: \(at(8))")
        #expect(abs(at(24) - 1) < 1e-5, "0.75 maps to 1: \(at(24))")
        #expect(abs(at(32) - 1) < 1e-6, "above the domain saturates to 1")
        // Per-channel DOMAIN_MIN/MAX work the same way.
        let l2 = try ok(Lut.parseCube("LUT_1D_SIZE 2\nDOMAIN_MIN 0 0 0.5\nDOMAIN_MAX 1 1 1\n0 0 0\n1 1 1\n"))
        let blueMid = l2.data[(16 * 33 * 33) * 3 + 2]
        #expect(abs(blueMid) < 1e-5, "blue 0.5 is the bottom of its domain: \(blueMid)")
        // A degenerate 1D domain is rejected like the 3D one.
        #expect(err(Lut.parseCube("LUT_1D_SIZE 2\nLUT_1D_INPUT_RANGE 1 1\n0 0 0\n1 1 1\n"))?.contains("below DOMAIN_MAX") == true)
    }

    @Test func cubeRoundtripAndIdentity() throws {
        let id = Lut.identity(5)
        var titled = id
        titled.title = "Id"
        let back = try ok(Lut.parseCube(Lut.writeCube(titled)))
        #expect(back.size == 5)
        #expect(back.title == "Id")
        #expect(zip(back.data, id.data).allSatisfy { abs($0 - $1) < 1e-5 })
        // Red varies fastest: entry 1 is (0.25, 0, 0).
        #expect(Array(back.data[3 ..< 6]) == [0.25, 0, 0])
        // CRLF line ends parse the same.
        let crlf = Lut.writeCube(titled).replacingOccurrences(of: "\n", with: "\r\n")
        #expect(try ok(Lut.parseCube(crlf)).data == back.data)
    }

    @Test func cube1DExpands() throws {
        let l = try ok(Lut.parseCube("LUT_1D_SIZE 2\n0 0 0\n0.5 1 1\n"))
        #expect(l.size == 33)
        let last = Array(l.data.suffix(3))
        #expect(abs(last[0] - 0.5) < 1e-6 && abs(last[1] - 1) < 1e-6)
        var larger = "LUT_1D_SIZE 256\n"
        for i in 0 ..< 256 {
            let v = Float(i) / 255
            larger += "\(v) \(v) \(v)\n"
        }
        #expect(try ok(Lut.parseCube(larger)).size == 33)
    }

    @Test func cube1DSizeMultiplicationOverflowIsRejected() {
        #expect(err(Lut.parseCube("LUT_1D_SIZE \(UInt64.max)\n")) != nil)
        #expect(err(Lut.parseCube("LUT_1D_SIZE \(Int.max)\n")) != nil)
    }

    @Test func threeDLBlueFastestAndBitDepth() throws {
        var text = "0 1023\n"
        for r in 0 ..< 2 { for g in 0 ..< 2 { for b in 0 ..< 2 { text += "\(r * 4095) \(g * 4095) \(b * 4095)\n" } } }
        let l = try ok(Lut.parse3dl(text))
        #expect(l.size == 2)
        #expect(l.data == Lut.identity(2).data)
    }

    @Test func lookHexFloats() throws {
        let id = Lut.identity(2)
        let hex = id.data.flatMap { v -> [String] in
            let b = v.bitPattern
            return (0 ..< 4).map { String(format: "%02X", (b >> (8 * UInt32($0))) & 0xFF) }
        }.joined()
        let xml = "<?xml version=\"1.0\"?><look><LUT><size>\"2\"</size><data>\"\(hex)\"</data></LUT></look>"
        #expect(try ok(Lut.parse("a.look", Array(xml.utf8))).data == id.data)
    }

    @Test func look3DSizeExponentOverflowIsRejected() {
        #expect(err(Lut.parseLook("<look><size>\(UInt64.max)</size><data>00</data></look>")) != nil)
    }

    @Test func malformedRejected() {
        #expect(err(Lut.parseCube("LUT_3D_SIZE 2\n0 0 0\n")) != nil)
        #expect(err(Lut.parseCube("garbage")) != nil)
        #expect(err(Lut.parseCube("LUT_3D_SIZE 99999\n")) != nil)
        #expect(err(Lut.parse3dl("1 2 3\n4 5 6\n")) != nil)
        #expect(err(Lut.parseLook("<look></look>")) != nil)
        // Hex and other non-Rust float spellings are not numbers.
        #expect(err(Lut.parseCube("LUT_3D_SIZE 2\n0x1p0 0 0\n")) != nil)
    }

    @Test func writeCubeFormatsLikeRust() {
        let l = Lut(title: "a\"b", size: 2, data: [0, 1, 0.5, 1.0 / 3.0, 0.0078125, -0.0])
        #expect(Lut.writeCube(l) == "TITLE \"a'b\"\nLUT_3D_SIZE 2\n0.000000 1.000000 0.500000\n0.333333 0.007812 -0.000000\n")
    }
}
