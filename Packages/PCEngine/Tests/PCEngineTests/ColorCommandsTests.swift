// Port of photocraft-engine (crates/engine/src/color_cmds.rs `mod tests` and `mod settings_tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Skipped: bench_cmyk_conversion_6016 (an ignored benchmark); input_only_profiles_are_converted_on_open and the two re-encoded-profile cases of
// open_policies (they synthesise ICC profiles with photocraft-cms's writer, which ColorSync has no
// counterpart for). `s.color.*` queries map to `ColorCommands.*` / `ProofSimCommands.*`.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCPlatform
import Testing

@Suite struct ColorCommandsTests {
    func session(_ mode: String, _ depth: Int) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 64, "height": 32, "mode": .string(mode), "depth": .int(depth)])
        return s
    }

    func paintRGB(_ s: Session) throws {
        try s.execute("layer.new.layer")
        try s.edit("paint") { doc, active in
            doc.updateLayer(active!) { l in
                l.withRaster { surf in
                    surf.fill(PixelRect(x0: 0, y0: 0, x1: 16, y1: 16), with: [1, 0, 0, 1])
                    surf.fill(PixelRect(x0: 16, y0: 0, x1: 32, y1: 16), with: [0, 0, 1, 1])
                    surf.fill(PixelRect(x0: 32, y0: 0, x1: 48, y1: 16), with: [0.5, 0.5, 0.5, 0.5])
                }
                l.mask = .revealAll()
            }
        }
    }

    func doc(_ s: Session) -> Document { s.active!.doc }

    func near(_ a: Float, _ b: Float, _ tol: Float) -> Bool { abs(a - b) < tol }

    @Test func modeConversionsAllDepthsWithUndo() throws {
        for depth in [8, 16, 32] {
            let s = try session("rgb", depth)
            try paintRGB(s)
            let before = doc(s).layers[1].surface!.pixel(x: 40, y: 8)
            try s.execute("image.mode.cmyk")
            let d = doc(s)
            #expect(d.mode == .cmyk)
            #expect(d.iccProfile == [UInt8](BuiltinProfile.coatedCMYK.profile.data), "tagged with the destination")
            let l = d.layers[1]
            #expect(l.surface!.format.mode == .cmyk)
            #expect(l.mask!.surface.format.mode == .grayscale, "masks untouched")
            let gray = l.surface!.pixel(x: 40, y: 8)
            #expect(near(gray[4], 0.5, 1e-2), "alpha kept: \(gray)")
            #expect(gray[..<4].allSatisfy { (0...1).contains($0) })
            // Red goes to an M+Y heavy separation.
            let red = l.surface!.pixel(x: 8, y: 8)
            #expect(red[1] > 0.7 && red[2] > 0.7 && red[0] < 0.2, "\(depth): \(red)")
            // Background white → no ink.
            let bg = d.layers[0].surface!.pixel(x: 60, y: 30)
            #expect(bg[..<4].allSatisfy { $0 < 0.01 }, "\(bg)")
            try s.execute("image.mode.lab")
            let lab = doc(s).layers[1].surface!.pixel(x: 40, y: 8)
            #expect(near(lab[1], 128.0 / 255, 0.03) && near(lab[2], 128.0 / 255, 0.03), "\(lab)")
            try s.execute("image.mode.grayscale", ["intent": "perceptual"])
            try s.execute("image.mode.rgb")
            let after = doc(s).layers[1].surface!.pixel(x: 40, y: 8)
            #expect(near(after[0], before[0], 0.04) && near(after[0], after[2], 0.01), "\(depth): \(before) -> \(after)")
            for _ in 0..<4 { try s.execute("edit.undo") }
            #expect(doc(s).mode == .rgb)
            #expect(doc(s).layers[1].surface!.pixel(x: 40, y: 8) == before)
        }
    }

    @Test func rgbLabRGBRoundtrip16bit() throws {
        let s = try session("rgb", 16)
        try paintRGB(s)
        let before = doc(s).layers[1].surface!.pixel(x: 8, y: 8)
        try s.execute("image.mode.lab")
        try s.execute("image.mode.rgb")
        let after = doc(s).layers[1].surface!.pixel(x: 8, y: 8)
        for k in 0..<3 { #expect(near(before[k], after[k], 1.0 / 255), "\(before) -> \(after)") }
    }

    @Test func assignAndConvertProfile() throws {
        let s = try session("rgb", 8)
        try paintRGB(s)
        try s.execute("edit.assignProfile", ["profile": "display-p3"])
        #expect(ColorCommands.documentProfile(doc(s)).profileDescription == "Display P3")
        #expect(doc(s).layers[1].surface!.pixel(x: 8, y: 8) == [1, 0, 0, 1], "assign does not change pixels")
        #expect(throws: EngineError.self, "wrong colour space") { try s.execute("edit.assignProfile", ["profile": "coated-cmyk"]) }
        try s.execute("edit.convertToProfile", ["profile": "srgb", "intent": "relative"])
        let px = doc(s).layers[1].surface!.pixel(x: 8, y: 8)
        #expect(px[0] > 0.99 && px[1] < 0.01, "P3 red clips to sRGB red: \(px)")
        try s.execute("edit.convertToProfile", ["profile": "coated-cmyk", "intent": "perceptual"])
        #expect(doc(s).mode == .cmyk)
        try s.execute("edit.assignProfile", ["profile": "none"])
        #expect(doc(s).iccProfile == nil)
        let info = try s.execute("edit.profileInfo")
        #expect(info["profile"]?["colorSpace"] == "Cmyk")
        #expect((info["builtins"]?.arrayValue?.count ?? 0) >= 10)
        #expect(throws: EngineError.self) { try s.execute("edit.convertToProfile", ["profile": "nope"]) }
    }

    @Test func fillAndEffectColoursFollowTheMode() throws {
        let s = try session("rgb", 8)
        try s.edit("fill layer") { doc, _ in
            var l = Layer(name: "Fill", content: .fill(.solid(.rgb(0, 0, 1))))
            l.effects.items.append(.defaultDropShadow())
            doc.layers.append(l)
        }
        try s.execute("image.mode.cmyk")
        let l = doc(s).layers[1]
        guard case .fill(.solid(let c)) = l.content else { Issue.record("not a fill"); return }
        #expect(c.mode == .cmyk)
        #expect(c.c.x > 0.6, "\(c)")
        guard case .dropShadow(let sh) = l.effects.items[0] else { Issue.record("no shadow"); return }
        #expect(sh.color.mode == .cmyk)
    }

    @Test func proofingStateAndGamutWarning() throws {
        let s = try session("rgb", 8)
        try paintRGB(s)
        #expect(!ColorCommands.proof(s.active!).view.enabled)
        try s.execute("view.proofSetup", ["profile": "coated-cmyk", "intent": "perceptual", "simulatePaper": true])
        let pv = ColorCommands.proof(s.active!)
        #expect(pv.view.intent == .perceptual && pv.view.simulatePaper)
        try s.execute("view.proofColors")
        #expect(ColorCommands.proof(s.active!).view.enabled)
        let t = try ColorCommands.displayTransform(s, s.active!)
        #expect(t.eval([1, 1, 1])[0] < 0.97, "paper simulation")
        let display = try ColorCommands.canvasDisplay(s, s.active!)
        #expect(display.lut?.data.count == 33 * 33 * 33)
        try s.execute("view.proofColors", ["on": false])
        let t2 = try ColorCommands.displayTransform(s, s.active!)
        #expect(t2.eval([1, 1, 1]).allSatisfy { near($0, 1, 1e-3) }, "no proof: identity-ish")
        #expect(try ColorCommands.canvasDisplay(s, s.active!).isIdentity)
        // Saturated sRGB blue is outside coated CMYK; mid gray and white are inside.
        let r = try s.execute("view.gamutWarning", ["on": true])
        #expect(r["on"] == true)
        let d = doc(s)
        let (mask, count) = try ColorCommands.gamutMask(s, d, profile: ColorCommands.proof(s.active!).profile, threshold: 4)
        #expect(r["outOfGamut"] == .int(count))
        let w = d.size.width
        #expect(mask[8 * w + 20] == 255, "blue out of gamut")
        #expect(mask[8 * w + 40] == 0, "gray in gamut")
        #expect(mask[30 * w + 60] == 0, "white in gamut")
    }

    @Test func grayAndCMYKCompositeProfiles() throws {
        let g = try session("gray", 8)
        #expect(ColorCommands.compositeProfile(doc(g)).colorSpace == .gray)
        // sGray displays as sRGB gray: no LUT.
        #expect(try ColorCommands.canvasDisplay(g, g.active!).isIdentity)
        let c = try session("cmyk", 8)
        #expect(ColorCommands.compositeProfile(doc(c)).profileDescription == BuiltinProfile.srgb.profile.profileDescription)
    }

    // MARK: settings_tests

    func tagged(_ spec: String) -> Document {
        var d = Document.withBackground(name: "t", size: PixelSize(width: 8, height: 8), mode: .rgb, depth: .u8, fill: .rgb(0.2, 0.6, 0.9, 1))
        d.iccProfile = [UInt8](BuiltinProfile.from(id: spec)!.profile.data)
        return d
    }

    func desc(_ d: Document) -> String? { d.iccProfile.flatMap { try? ColorCommands.profile(fromBytes: $0) }?.profileDescription }

    @Test func colorSettingsValidateAndReport() throws {
        // Its own renderer: the text gamma it sets is process-wide on a shared one.
        let s = Session(services: EngineServices(renderer: EngineRenderer()))
        let r = try s.execute("edit.colorSettings")
        #expect(r["settings"]?["workingRgb"] == "srgb")
        #expect(throws: EngineError.self) { try s.execute("edit.colorSettings", ["workingRgb": "coated-cmyk"]) }
        #expect(throws: EngineError.self) { try s.execute("edit.colorSettings", ["policyRgb": "sometimes"]) }
        #expect(throws: EngineError.self) { try s.execute("edit.colorSettings", ["intent": "vivid"]) }
        let r2 = try s.execute("edit.colorSettings", ["workingRgb": "adobe-rgb-compat", "intent": "perceptual", "bpc": false])
        #expect(r2["working"]?["rgb"]?.stringValue?.hasPrefix("Adobe RGB") == true)
        #expect(ColorCommands.settings(s).renderingIntent == .perceptual)
        #expect(!ColorCommands.settings(s).bpc)
        // Settings travel with the preferences.
        #expect(s.preferences["colorSettings.workingRgb"] == "adobe-rgb-compat")
        #expect(s.preferences["colorSettings.intent"] == "perceptual")
        let t = Session(preferences: s.preferences)
        #expect(ColorCommands.settings(t).workingRgb == "adobe-rgb-compat")
        #expect(ColorCommands.settings(t).bpc == false)
        // Reset restores photocraft's defaults.
        try s.execute("edit.colorSettings", ["reset": true])
        #expect(ColorCommands.settings(s) == ColorCommands.Settings())
        // blendTextGamma takes a bool or 1…2.2.
        try s.execute("edit.colorSettings", ["blendTextGamma": false])
        #expect(ColorCommands.settings(s).blendTextGamma == 1)
        #expect(s.services.renderer.textGamma == 1, "the compositor blends type without gamma")
        #expect(throws: EngineError.self) { try s.execute("edit.colorSettings", ["blendTextGamma": 3]) }
    }

    @Test func openPolicies() throws {
        let s = Session()
        // Preserve (default): an Adobe RGB file keeps its profile and asks.
        var (_, r) = ColorCommands.openDocument(s, tagged("adobe-rgb-compat"))
        #expect(r["action"] == "kept" && r["mismatch"] == true && r["ask"] == true)
        #expect(desc(doc(s))?.hasPrefix("Adobe RGB") == true)
        // Matching profiles never ask.
        (_, r) = ColorCommands.openDocument(s, tagged("srgb"))
        #expect(r["mismatch"] == false)
        // Convert to working: pixels converted and the document tagged with sRGB.
        try s.execute("edit.colorSettings", ["policyRgb": "convert"])
        (_, r) = ColorCommands.openDocument(s, tagged("adobe-rgb-compat"))
        #expect(r["action"] == "converted")
        #expect(desc(doc(s))?.hasPrefix("sRGB") == true)
        #expect(abs(doc(s).layers[0].surface!.pixel(x: 1, y: 1)[0] - 0.2) > 0.01, "values changed by the conversion")
        // Off: the embedded profile is discarded.
        try s.execute("edit.colorSettings", ["policyRgb": "off"])
        (_, r) = ColorCommands.openDocument(s, tagged("display-p3"))
        #expect(r["action"] == "discarded")
        #expect(doc(s).iccProfile == nil)
        // Untagged files are assumed to be in a non-default working space and tagged with it.
        try s.execute("edit.colorSettings", ["policyRgb": "preserve", "workingRgb": "display-p3"])
        var d = tagged("srgb")
        d.iccProfile = nil
        (_, r) = ColorCommands.openDocument(s, d)
        #expect(r["action"] == "assigned")
        #expect(desc(doc(s)) == "Display P3")
    }

    /// A little-endian EXIF block whose Exif IFD holds ColorSpace = `space`.
    func exifColorSpace(_ space: UInt16) -> [UInt8] {
        var b = Array("Exif\0\0II\u{2a}\0\u{08}\0\0\0".utf8)
        b += [1, 0, 0x69, 0x87, 4, 0, 1, 0, 0, 0, 26, 0, 0, 0, 0, 0, 0, 0]
        b += [1, 0, 0x01, 0xA0, 3, 0, 1, 0, 0, 0]
        b += [UInt8(space & 0xff), UInt8(space >> 8)]
        b += [0, 0, 0, 0, 0, 0]
        return b
    }

    func untaggedCameraFile(_ space: UInt16?) -> Document {
        var d = tagged("srgb")
        d.iccProfile = nil
        d.metadata.exif = space.map(exifColorSpace)
        return d
    }

    /// The tag survives a real JPEG: written without an ICC profile, read back, opened as sRGB.
    @Test func exifSRGBJpegRoundTrip() throws {
        let s = Session()
        try s.execute("edit.colorSettings", ["workingRgb": "display-p3"])
        let r = try EngineIO.export(untaggedCameraFile(1), as: "x.jpg", services: s.services)
        let back = try EngineIO.importFile(name: "x.jpg", bytes: r.bytes, services: s.services).document
        #expect(back.iccProfile == nil, "no ICC profile in the file")
        let (_, report) = ColorCommands.openDocument(s, back)
        #expect(report["action"] == "kept" && report["exif"] == true, "\(report)")
        #expect(desc(doc(s))?.hasPrefix("sRGB") == true)
    }

    /// #204: a camera file with no ICC profile but EXIF ColorSpace = sRGB opens as sRGB; Ignore EXIF
    /// Profile Tag opens it untagged (the working space).
    @Test func exifSRGBTagUnlessIgnored() throws {
        #expect(ColorCommands.exifColorSpace(exifColorSpace(1)) == 1)
        #expect(ColorCommands.exifColorSpace(exifColorSpace(0xFFFF)) == 0xFFFF)
        #expect(ColorCommands.exifColorSpace([1, 2, 3]) == nil)
        let s = Session()
        var (_, r) = ColorCommands.openDocument(s, untaggedCameraFile(1))
        #expect(r["action"] == "kept" && r["exif"] == true && r["ask"] == nil)
        #expect(desc(doc(s))?.hasPrefix("sRGB") == true)
        // Working Display P3, Preserve: it stays sRGB instead of being read as P3.
        try s.execute("edit.colorSettings", ["policyRgb": "preserve", "workingRgb": "display-p3"])
        (_, r) = ColorCommands.openDocument(s, untaggedCameraFile(1))
        #expect(r["action"] == "kept" && r["mismatch"] == true && r["exif"] == true)
        #expect(desc(doc(s))?.hasPrefix("sRGB") == true)
        // Convert: converted from sRGB to P3, so the pixel values change.
        try s.execute("edit.colorSettings", ["policyRgb": "convert"])
        (_, r) = ColorCommands.openDocument(s, untaggedCameraFile(1))
        #expect(r["action"] == "converted")
        #expect(desc(doc(s)) == "Display P3")
        #expect(abs(doc(s).layers[0].surface!.pixel(x: 1, y: 1)[0] - 0.2) > 0.01)
        // Uncalibrated, no EXIF, or Ignore EXIF Profile Tag on: untagged, so the working space.
        try s.execute("edit.colorSettings", ["policyRgb": "preserve"])
        for (space, ignore) in [(UInt16(0xFFFF), false), (nil, false), (1, true)] as [(UInt16?, Bool)] {
            try s.preferences.set("fileHandling.ignoreExifProfileTag", .bool(ignore))
            (_, r) = ColorCommands.openDocument(s, untaggedCameraFile(space))
            #expect(r["action"] == "assigned" && r["exif"] == nil, "\(String(describing: space)), ignore \(ignore)")
            #expect(desc(doc(s)) == "Display P3")
        }
        // An embedded profile always wins over the EXIF tag.
        try s.preferences.set("fileHandling.ignoreExifProfileTag", false)
        var d = tagged("adobe-rgb-compat")
        d.metadata.exif = exifColorSpace(1)
        (_, r) = ColorCommands.openDocument(s, d)
        #expect(r["action"] == "kept" && r["exif"] == nil)
        #expect(desc(doc(s)) == BuiltinProfile.adobeRGB.profile.profileDescription)
    }

    @Test func modeConversionUsesWorkingSpaces() throws {
        let s = Session()
        try s.execute("edit.colorSettings", ["workingRgb": "rec2020"])
        for depth in [8, 16, 32] {
            try s.execute("file.new", ["width": 8, "height": 8, "mode": "gray", "depth": .int(depth)])
            try s.execute("image.mode.rgb")
            #expect(doc(s).mode == .rgb)
            #expect(desc(doc(s))?.contains("2020") == true, "depth \(depth): \(String(describing: desc(doc(s))))")
        }
        // "working" specs follow the settings too.
        #expect(try ColorCommands.resolve(s, "working-rgb", doc: nil, mode: nil).profileDescription.contains("2020"))
    }

    @Test func mismatchResolutionCommand() throws {
        let s = Session()
        ColorCommands.openDocument(s, tagged("adobe-rgb-compat"))
        try s.execute("color.profileMismatch", ["action": "convert"])
        #expect(desc(doc(s))?.hasPrefix("sRGB") == true)
        #expect(s.undo())
        try s.execute("color.profileMismatch", ["action": "discard"])
        #expect(doc(s).iccProfile == nil)
        #expect(throws: EngineError.self) { try s.execute("color.profileMismatch", ["action": "explode"]) }
    }
}
