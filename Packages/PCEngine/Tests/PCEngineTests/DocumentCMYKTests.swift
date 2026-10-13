// Strokes and paint commands in a CMYK document convert their colour through the document's own
// CMYK profile (photocraft `with_cmyk_space(doc_cmyk_space(s), …)` in brush_cmds.rs), also when
// documents with different profiles paint at once. MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

import PCDocument
@testable import PCEngine
import PCFoundation
import PCPlatform
import simd
import Testing

@Suite struct DocumentCMYKTests {
    static let rgb = SIMD3<Float>(0.2, 0.6, 0.4)   // #339966

    /// A CMYK document tagged with `profile` (nil: untagged, the built-in coated CMYK).
    static func session(_ profile: String?) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 30, "mode": "cmyk"])
        if let profile { try s.execute("edit.assignProfile", ["profile": .string(profile)]) }
        return s
    }

    /// The Background's stored CMYK at (x, y).
    static func ink(_ s: Session, _ x: Int32, _ y: Int32) -> [Float] {
        Array((s.active?.doc.layers.first?.surface?.pixel(x: x, y: y) ?? []).prefix(4))
    }

    static func close(_ a: [Float], _ b: SIMD4<Float>) -> Bool {
        a.count == 4 && zip(a, [b.x, b.y, b.z, b.w]).allSatisfy { abs($0 - $1) <= 1 / 255 + 1e-6 }
    }

    static let generic = try! ColorSyncCMYKConverter(cmyk: BuiltinProfile.genericCMYK.profile)
    static let coated = try! ColorSyncCMYKConverter(cmyk: BuiltinProfile.coatedCMYK.profile)

    /// PCIO's imports and exports of a CMYK document convert through its own profile too: the
    /// engine's IO options carry the same converter factory the paint commands use.
    @Test func ioOptionsCarryTheDocumentProfileConverter() throws {
        let s = try Self.session(nil)
        let factory = try #require(EngineIO.options(s.services).cmykConverter)
        let generic = try #require(factory([UInt8](BuiltinProfile.genericCMYK.profile.data)) as? ColorSyncCMYKConverter)
        #expect(generic.cmykProfile == BuiltinProfile.genericCMYK.profile)
        #expect(simd_reduce_max(simd_abs(generic.rgbToCMYK(Self.rgb) - Self.generic.rgbToCMYK(Self.rgb))) < 1e-6)
        // The built-in coated CMYK, an RGB profile and no bytes leave the process-wide conversion.
        #expect(factory([UInt8](BuiltinProfile.coatedCMYK.profile.data)) == nil)
        #expect(factory([UInt8](BuiltinProfile.srgb.profile.data)) == nil)
        #expect(factory([]) == nil)
    }

    @Test func strokesConvertThroughTheDocumentProfile() throws {
        let want = Self.generic.rgbToCMYK(Self.rgb), builtIn = Self.coated.rgbToCMYK(Self.rgb)
        #expect(simd_reduce_max(simd_abs(want - builtIn)) > 0.05, "the two profiles must disagree for the test to mean anything")
        let stroke: JSONValue = ["points": [[20, 15]], "size": 12, "hardness": 1.0, "color": "#339966"]
        // Tagged Generic CMYK: the brush colour is the profile's CMYK for #339966.
        let s = try Self.session("generic-cmyk")
        #expect(DocumentCMYK.converter(for: s.active?.doc) != nil)
        try s.execute("paint.stroke", stroke)
        #expect(Self.close(Self.ink(s, 20, 15), want), "\(Self.ink(s, 20, 15)) vs \(want)")
        try s.execute("paint.pencil", ["points": [[3, 3], [10, 3]], "size": 2, "color": "#339966"])
        #expect(Self.close(Self.ink(s, 6, 3), want), "pencil: \(Self.ink(s, 6, 3))")
        try s.execute("paint.bucket", ["x": 35, "y": 25, "color": "#339966", "tolerance": 0])
        #expect(Self.close(Self.ink(s, 35, 25), want), "bucket: \(Self.ink(s, 35, 25))")
        // The live stroke (pen down, before the commit) paints the same ink.
        let live = try BrushCommands.LiveStroke.begin(s, ["points": [[30, 8]], "size": 6, "hardness": 1.0, "color": "#339966"])
        let shown = Array((live.doc.layers.first?.surface?.pixel(x: 30, y: 8) ?? []).prefix(4))
        #expect(Self.close(shown, want), "live: \(shown)")
        // Untagged: the built-in coated CMYK, as before.
        let u = try Self.session(nil)
        #expect(DocumentCMYK.converter(for: u.active?.doc) == nil)
        try u.execute("paint.stroke", stroke)
        #expect(Self.close(Self.ink(u, 20, 15), builtIn), "\(Self.ink(u, 20, 15)) vs \(builtIn)")
        // The scope ends with the command.
        #expect(!(ColorConvert.activeCMYK is ColorSyncCMYKConverter && (ColorConvert.activeCMYK as? ColorSyncCMYKConverter)?.cmykProfile == BuiltinProfile.genericCMYK.profile))
    }

    /// Two documents with different CMYK profiles painting in parallel tasks each get their own.
    @Test func parallelDocumentsKeepTheirOwnProfiles() async throws {
        let cases: [(String?, SIMD4<Float>)] = [("generic-cmyk", Self.generic.rgbToCMYK(Self.rgb)), (nil, Self.coated.rgbToCMYK(Self.rgb)),
                                                ("generic-cmyk", Self.generic.rgbToCMYK(Self.rgb)), (nil, Self.coated.rgbToCMYK(Self.rgb))]
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for (profile, want) in cases {
                group.addTask {
                    let s = try Self.session(profile)
                    var ok = true
                    for i in 0..<12 {
                        let y = 2 + 2 * i
                        try s.execute("paint.stroke", ["points": [[2, .int(y)], [38, .int(y)]], "size": 2, "hardness": 1.0, "color": "#339966"])
                        ok = ok && Self.close(Self.ink(s, 20, Int32(y)), want)
                        await Task.yield()
                    }
                    return ok
                }
            }
            for try await ok in group { #expect(ok) }
        }
    }
}
