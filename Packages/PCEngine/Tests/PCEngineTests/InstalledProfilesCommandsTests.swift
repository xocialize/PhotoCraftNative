// Port of photocraft-engine (crates/engine/src/installed_profiles.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Also checks that every command of the six modules ported here is registered with photocraft's
// label, menu path, shortcut, params notation and module, verbatim.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCPlatform
import Testing

@Suite struct InstalledProfilesCommandsTests {
    func tempDir(_ tag: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pc-installed-\(tag)-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: d)
        try FileManager.default.createDirectory(at: d.appendingPathComponent("vendor"), withIntermediateDirectories: true)
        return d
    }

    @Test func scanListsParsableProfilesByDescriptionAndSkipsJunk() throws {
        let d = try tempDir("scan")
        defer { try? FileManager.default.removeItem(at: d) }
        try BuiltinProfile.srgb.profile.data.write(to: d.appendingPathComponent("b.icc"))
        try BuiltinProfile.coatedCMYK.profile.data.write(to: d.appendingPathComponent("vendor/a.ICM"))
        try Data("not a profile".utf8).write(to: d.appendingPathComponent("broken.icc"))
        try Data().write(to: d.appendingPathComponent("empty.icc"))
        try Data("x".utf8).write(to: d.appendingPathComponent("notes.txt"))
        let found = InstalledProfilesCommands.scan(dirs: [d.path, d.appendingPathComponent("missing").path])
        let names = found.map(\.description)
        #expect(names.count == 2, "\(names)")
        if names.count == 2 { #expect(names[0].lowercased() <= names[1].lowercased()) }
        let cmyk = try #require(found.first { $0.colorSpace == .cmyk })
        #expect(cmyk.path.hasSuffix("a.ICM"))
        #expect(cmyk.isDestination)
        // The listed path is what the profile commands accept.
        #expect((try? ColorCommands.resolveProfile(cmyk.path, doc: nil, mode: nil)) != nil)
    }

    @Test func scanOfNothingIsEmpty() {
        #expect(InstalledProfilesCommands.scan(dirs: []).isEmpty)
        #expect(InstalledProfilesCommands.scan(dirs: ["/definitely/not/a/folder"]).isEmpty)
    }

    @Test func commandFiltersAndRejectsBadParams() throws {
        let s = Session()
        let r = try s.execute("edit.installedProfiles")
        #expect(r["profiles"]?.arrayValue != nil && r["dirs"]?.arrayValue != nil)
        // ColorSync lists the system's profiles.
        #expect((r["profiles"]?.arrayValue?.count ?? 0) > 0)
        let f = try s.execute("edit.installedProfiles", ["class": "output", "colorSpace": "cmyk"])
        for p in f["profiles"]?.arrayValue ?? [] {
            #expect(p["class"] == "output" && p["colorSpace"] == "cmyk")
        }
        for bad: JSONValue in [["class": 3], ["class": "printer"], ["colorSpace": "lab"], ["colorSpace": []]] {
            #expect(throws: EngineError.self, "\(bad)") { try s.execute("edit.installedProfiles", bad) }
        }
    }

    @Test func modulesRegisterPhotocraftsSpecsVerbatim() {
        let r = CommandRegistry.standard()
        let modules: Set<String> = ["image_cmds", "mode_cmds", "trap_cmds", "color_cmds", "proof_sim", "installed_profiles"]
        let mine = PhotocraftCatalog.commands.filter { modules.contains($0.module) }
        #expect(mine.count == 36)
        for c in mine {
            guard let spec = r.spec(c.id) else { Issue.record("\(c.id) not registered"); continue }
            #expect(spec.label == c.label, "\(c.id)")
            #expect(spec.menu == c.menu, "\(c.id)")
            #expect(spec.shortcut == c.shortcut, "\(c.id)")
            #expect(spec.params == c.params, "\(c.id)")
            #expect(spec.module == c.module, "\(c.id)")
        }
        let unavailable = mine.filter { !(r.spec($0.id)?.isAvailable ?? false) }.map(\.id)
        // Image Size and Image Rotation › Arbitrary run PCAlgo's resampler: nothing is left unavailable.
        #expect(unavailable.isEmpty, "\(unavailable)")
    }
}
