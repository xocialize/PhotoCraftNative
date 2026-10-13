// The EngineData writers of PCIOText (Photoshop's layout by default, photocraft's on request),
// against PCPSD's parser.
// Port of photocraft-text (crates/text/src/engine_data.rs inline tests: `write_parse_roundtrip`,
// `tiny_reals_round_trip_as_numbers`), plus the byte layout photocraft writes; MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCPSD
import Testing
@testable import PCIOText

@Suite struct EngineWriterTests {
    static let sample: [UInt8] = bytes("\n\n<<\n\t/EngineDict\n\t<<\n\t\t/Editor\n\t\t<<\n\t\t\t/Text (") + [0xFE, 0xFF, 0, 0x48, 0, 0x69, 0, 0x5C, 0x29, 0, 0x0D]
        + bytes(")\n\t\t>>\n\t\t/Nums [ 1.0 .5 -2 0 ]\n\t\t/Flag true\n\t\t/Kind /Roman\n\t\t/Runs [\n\t\t<<\n\t\t\t/A 1\n\t\t>>\n\t\t]\n\t>>\n>>")

    @Test func writeParseRoundTrip() throws {
        let v = try PSDEngineData.parse(Data(Self.sample))
        #expect(v.at("EngineDict", "Editor", "Text")?.str == "Hi)\r")
        for layout in [PSDText.EngineDataLayout.photoshop, .photocraft] {
            let out = PSDText.engineDataBytes(v, layout: layout)
            #expect(try PSDEngineData.parse(Data(out)) == v)
            // Stable: writing twice gives identical bytes.
            #expect(PSDText.engineDataBytes(try PSDEngineData.parse(Data(out)), layout: layout) == out)
        }
    }

    /// The default is Photoshop's layout (the sample's own bytes). photocraft's layout, byte for
    /// byte, opens an array of containers on the line after its key and ends with a newline.
    @Test func photoshopLayoutByDefaultPhotocraftOnRequest() throws {
        let v = try PSDEngineData.parse(Data(Self.sample))
        #expect(PSDText.engineDataBytes(v) == Self.sample)
        #expect(PSDText.engineDataBytes(v) == [UInt8](v.serialized()))
        let expected = bytes("\n\n<<\n\t/EngineDict\n\t<<\n\t\t/Editor\n\t\t<<\n\t\t\t/Text (") + [0xFE, 0xFF, 0, 0x48, 0, 0x69, 0, 0x5C, 0x29, 0, 0x0D]
            + bytes(")\n\t\t>>\n\t\t/Nums [ 1.0 .5 -2 0 ]\n\t\t/Flag true\n\t\t/Kind /Roman\n\t\t/Runs\n\t\t[\n\t\t<<\n\t\t\t/A 1\n\t\t>>\n\t\t]\n\t>>\n>>\n")
        #expect(PSDText.engineDataBytes(v, layout: .photocraft) == expected)
    }

    @Test func bareLayout() {
        let items = [E.Entry("98", .d([("0", .int(14))])), E.Entry("0", .emptyDict), E.Entry("x", .int(3))]
        // Photoshop's `Txt2`: one line.
        #expect(PSDText.engineDataBareBytes(items) == bytes(" /98 << /0 14 >> /0 << >> /x 3"))
        #expect(PSDText.engineDataBareBytes(items, layout: .photocraft) == bytes("\n\n/98\n\t<<\n\t\t/0 14\n\t>>\n/0\n\t<<\n\t>>\n/x 3\n"))
        for layout in [PSDText.EngineDataLayout.photoshop, .photocraft] {
            #expect(PSDText.parseTxt2(PSDText.engineDataBareBytes(items, layout: layout)) == .dict(items))
        }
    }

    @Test func tinyRealsRoundTripAsNumbers() throws {
        for value in [0.000004, -0.000004] {
            let source = E.d([("EngineDict", .d([("StyleRun", .array([.d([("BaselineShift", .real(value))])]))]))])
            for layout in [PSDText.EngineDataLayout.photoshop, .photocraft] {
                let parsed = try PSDEngineData.parse(Data(PSDText.engineDataBytes(source, layout: layout)))
                #expect(parsed.at("EngineDict", "StyleRun")?.arr?.first?.get("BaselineShift")?.f64 == 0)
            }
        }
    }

    @Test func accessorsFollowPhotocraft() {
        // Paths follow dictionary keys only; reals saturate like Rust's `as`.
        let v = E.d([("a", .array([.int(1), .int(2)])), ("r", .real(1e300)), ("n", .real(.nan))])
        #expect(v.at("a", "1") == nil)
        #expect(v.get("r")?.i64 == Int64.max)
        #expect(v.get("n")?.i64 == 0)
    }
}
