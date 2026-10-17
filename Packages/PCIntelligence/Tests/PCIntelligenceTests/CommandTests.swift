// The AI commands as data: ids (photocraft's reused where the feature exists), menus, params,
// enabled predicates evaluated against a document and the registry, and their Codable form.
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import Testing
@testable import PCIntelligence

@Suite struct CommandTests {
    /// Ids photocraft-engine already defines for these features (crates/engine/src at 184c226a).
    static let photocraftIds: Set<String> = ["select.subject", "select.object", "layer.removeBackground", "paint.remove", "edit.contentAwareFill"]

    @Test func idsAreUniqueAndReusePhotocraft() {
        let ids = IntelligenceCommands.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for c in IntelligenceCommands.all {
            #expect((c.photocraftSource != nil) == CommandTests.photocraftIds.contains(c.id), "\(c.id)")
            #expect(c.id.split(separator: ".").count >= 2 && !c.label.isEmpty && c.params.hasPrefix("{"))
        }
        #expect(CommandTests.photocraftIds.isSubset(of: Set(ids)))
        // Every capability has a command; the enlarger is PCEngine's `image.imageSize` with "enlarger".
        #expect(Set(IntelligenceCommands.all.map(\.capability)).isSuperset(of: Set(Capability.allCases).subtracting([.scratchDetect, .enlarge])))
        #expect(IntelligenceCommands.command("select.subject")?.menu == ["Select"])
        #expect(IntelligenceCommands.command("select.objectFinder")?.journal == false, "the hover preview is a query")
    }

    @Test func enabledPredicatesFollowTheDocumentAndRegistry() {
        let registry = ProviderRegistry()
        let none = CommandContext(document: nil, activeLayer: nil, registry: registry)
        for c in IntelligenceCommands.all { #expect(IntelligenceCommands.disabledReason(c, in: none) == "no document open") }

        var d = FillTests.scene()
        let bg = d.layers[0].id
        let ctx = CommandContext(document: d, activeLayer: bg, registry: registry)
        func reason(_ id: String, _ c: CommandContext) -> String? { IntelligenceCommands.disabledReason(IntelligenceCommands.command(id)!, in: c) }
        #expect(reason("select.subject", ctx) == nil)
        #expect(reason("layer.removeBackground", ctx) == nil)
        #expect(reason("edit.contentAwareFill", ctx) == "make a selection first")
        #expect(reason("filter.neuralFilters.jpegArtifactsRemoval", ctx) == nil)
        #expect(reason("image.autoWhiteBalance", ctx) == nil)
        #expect(reason("filter.neuralFilters.colorize", ctx)?.contains("colorizer") == true)
        #expect(reason("image.superResolution", ctx)?.contains("UpscaleProvider") == true)
        #expect(reason("edit.generativeFill", ctx) == "make a selection first")

        d.selection = Fixture.selection(FillTests.square)
        let withSel = CommandContext(document: d, activeLayer: bg, registry: registry)
        #expect(reason("edit.contentAwareFill", withSel) == nil)
        #expect(reason("edit.generativeFill", withSel)?.contains("Generative Fill needs") == true)

        registry.register(colorize: SepiaColorize())
        registry.register(inpaint: MagentaInpaint(log: CallLog()))
        #expect(reason("filter.neuralFilters.colorize", withSel) == nil)
        #expect(reason("edit.generativeFill", withSel) == nil, "the inpaint model stands in")

        // Not a pixel layer, locked pixels, grayscale.
        var adj = d
        let aid = adj.insertAbove(nil, Layer(name: "Invert", content: .adjustment(.invert)))
        #expect(reason("paint.remove", CommandContext(document: adj, activeLayer: aid, registry: registry))?.contains("not a pixel layer") == true)
        var locked = d
        locked.updateLayer(bg) { $0.locks.pixels = true }
        #expect(reason("layer.removeBackground", CommandContext(document: locked, activeLayer: bg, registry: registry))?.contains("is locked") == true)
        var gray = d
        gray.mode = .grayscale
        #expect(reason("image.autoWhiteBalance", CommandContext(document: gray, activeLayer: bg, registry: registry)) == "needs an RGB, CMYK or Lab document")
        #expect(reason("select.subject", CommandContext(document: d, activeLayer: nil, registry: registry)) == nil, "Select Subject needs no layer")
        #expect(reason("paint.remove", CommandContext(document: d, activeLayer: nil, registry: registry)) == "no active layer")
    }

    @Test func descriptorsRoundTripThroughJSON() throws {
        let data = try JSONEncoder().encode(IntelligenceCommands.all)
        let back = try JSONDecoder().decode([CommandDescriptor].self, from: data)
        #expect(back == IntelligenceCommands.all)
    }
}
