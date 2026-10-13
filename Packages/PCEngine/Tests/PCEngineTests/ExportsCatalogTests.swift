// Port check for photocraft-engine's web_cmds.rs, print_cmds.rs, preset_import_cmds.rs and the PCIO-backed commands of pattern_cmds.rs, swatch_cmds.rs, notes_cmds.rs, comps_cmds.rs, artboard_cmds.rs, variables_cmds.rs, video_cmds.rs, lens_cmds.rs and photo_cmds.rs (`specs()`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Not a photocraft test: every command these modules register is photocraft's, with its id, label,
// menu path, shortcut, params notation and module verbatim (`PhotocraftCatalog.byId`), the module
// registers every id the catalogue lists for it, and none is an `unavailable` stub any more.

import Foundation
@testable import PCEngine
import Testing

@Suite struct ExportsCatalogTests {
    nonisolated(unsafe) static let modules: [any CommandModule.Type] = [
        WebCommands.self, PrintCommands.self, PresetImportCommands.self, PatternCommands.self, SwatchCommands.self, NotesCommands.self,
        CompsCommands.self, ArtboardCommands.self, VariablesCommands.self, VideoCommands.self, LensCommands.self, PhotoCommands.self,
        FiltersExtCommands.self,
    ]

    @Test(arguments: 0..<modules.count) func idsMatchThePhotocraftCatalogue(_ i: Int) {
        let module = Self.modules[i]
        var r = CommandRegistry()
        r.install(module)
        let mine = PhotocraftCatalog.commands.filter { $0.module == module.name }
        #expect(!mine.isEmpty, "\(module.name)")
        #expect(Set(r.specs.map(\.id)) == Set(mine.map(\.id)), "\(module.name)")
        for spec in r.specs {
            guard let c = PhotocraftCatalog.byId[spec.id] else {
                Issue.record("\(spec.id) is not a photocraft command")
                continue
            }
            #expect(spec.isAvailable, "\(spec.id): \(spec.availability.reason ?? "")")
            #expect(spec.label == c.label, "\(spec.id)")
            #expect(spec.menu == c.menu, "\(spec.id)")
            #expect(spec.shortcut == c.shortcut, "\(spec.id)")
            // The catalogue cannot hold notation photocraft assembles at run time.
            if c.params != "{} (see photocraft source)" { #expect(spec.params == c.params, "\(spec.id)") }
            #expect(spec.module == c.module, "\(spec.id)")
        }
    }
}
