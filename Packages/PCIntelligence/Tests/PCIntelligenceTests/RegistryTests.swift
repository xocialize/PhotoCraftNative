// The injection seam: default tiers, unavailable capabilities and their reasons, and fake providers
// (stand-ins for ForgeCore's engine adapters, no MLX) switching each capability's tier. Also
// registry thread safety. MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import EraseKit
import PCDocument
import PCFoundation
import PCHistory
import RestoreTier2
import Testing
@testable import PCIntelligence

@Suite struct RegistryTests {

    @Test func defaultsAreTheModelFreeTiers() {
        let r = ProviderRegistry()
        #expect(r.status(of: .subjectMatte) == .available(tier: .vision, engine: BuiltIn.visionMatte, injected: false))
        #expect(r.status(of: .promptMask).tier == .vision)
        #expect(r.status(of: .inpaint) == .available(tier: .classical, engine: BuiltIn.classicalInpaint, injected: false))
        #expect(r.status(of: .restore).tier == .classical)
        #expect(r.status(of: .whiteBalance).tier == .classical)
        #expect(r.status(of: .hdrExpansion).tier == .classical)
        for c in [Capability.colorize, .upscale, .faceRestore, .scratchDetect, .generativeFill] {
            let s = r.status(of: c)
            #expect(!s.isAvailable, "\(c) has no model-free tier")
            #expect((s.reason ?? "").contains("register"), "\(c): the reason says how to enable it")
        }
        #expect(r.status(of: RestoreJob.denoise).tier == .classical)
        #expect(!r.status(of: RestoreJob.motionDeblur).isAvailable && !r.status(of: RestoreJob.defocusDeblur).isAvailable)
        #expect(r.statuses.count == Capability.allCases.count)
        #expect(r.injectedCapabilities.isEmpty)
    }

    @Test func aFakeInpaintProviderSwitchesTheTierAndRuns() async throws {
        let log = CallLog()
        let registry = ProviderRegistry()
        let ai = PCIntelligence(registry: registry)
        var d = FillTests.scene()
        d.selection = Fixture.selection(FillTests.square)
        let classical = try await ai.contentAwareFill(d, layer: d.layers[0].id)
        #expect(classical.receipt.tier == .classical)

        registry.register(inpaint: MagentaInpaint(log: log))
        #expect(ai.status(of: .inpaint) == .available(tier: .model, engine: "FakeLaMa", injected: true))
        let model = try await ai.contentAwareFill(d, layer: d.layers[0].id, options: ContentAwareFillOptions(quality: .fast))
        #expect(model.receipt.tier == .model && model.receipt.engine == "FakeLaMa")
        #expect(log.all == ["inpaint fast"])
        let s = try #require(try Fixture.applied(model.transaction, to: d).layers[0].rasterSurface)
        #expect(s.pixel(x: 120, y: 80) == [1, 0, 1, 1], "the fake's magenta fill landed")
        #expect(s.pixel(x: 10, y: 10) == d.layers[0].rasterSurface!.pixel(x: 10, y: 10))

        // A classical filler (PCAlgo's PatchMatch, say) registers with its own tier.
        registry.register(inpaint: MagentaInpaint(log: log), tier: .classical)
        #expect(ai.status(of: .inpaint).tier == .classical)
        registry.unregister(.inpaint)
        #expect(ai.status(of: .inpaint) == .available(tier: .classical, engine: BuiltIn.classicalInpaint, injected: false))
    }

    /// Content-Aware Fill's options reach a provider that takes them through the seam (no
    /// task-local); the Remove tool and plain `InpaintProvider` calls get the defaults.
    @Test func inpaintOptionsReachAnOptionsProvider() async throws {
        let registry = ProviderRegistry()
        let box = OptionsRecordingInpaint()
        registry.register(inpaint: box, tier: .classical)
        let ai = PCIntelligence(registry: registry)
        var d = FillTests.scene()
        d.selection = Fixture.selection(FillTests.square)
        let window = PCIntelligence.samplingWindow(hole: FillTests.square, canvas: d.bounds)
        let source = [Bool](repeating: true, count: window.area)
        let opts = InpaintOptions(sampling: .mask(source), colorAdaptation: .veryHigh, rotationAdaptation: .full, scale: true, mirror: true, seed: 9)
        let out = try await ai.contentAwareFill(d, layer: d.layers[0].id, options: ContentAwareFillOptions(inpaint: opts))
        #expect(box.seen == [opts])
        #expect(out.receipt.engine == "FakePatchMatch")
        let s = try #require(try Fixture.applied(out.transaction, to: d).layers[0].rasterSurface)
        #expect(s.pixel(x: 120, y: 80) == [0, 1, 0, 1], "the mirrored (green) fill: the options were used")
        // Defaults: Content-Aware Fill without options, and the Remove tool.
        _ = try await ai.contentAwareFill(d, layer: d.layers[0].id)
        var hole = Surface(format: .gray8)
        hole.fill(FillTests.square, with: [1])
        _ = try await ai.remove(d, layer: d.layers[0].id, hole: hole)
        #expect(box.seen.dropFirst() == [InpaintOptions(), InpaintOptions()])
        // The plain Kit requirement runs the options form with the defaults.
        let img = try KitBridge.image(fromRGBA: [SIMD4(0, 0, 0, 1)], width: 1, height: 1, sample: .u8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let mask = try KitBridge.maskImage([1], width: 1, height: 1)
        _ = try await (box as any InpaintProvider).inpaint(img, mask: mask, quality: .best)
        #expect(box.seen.last == InpaintOptions())
        // A provider without options still runs, unchanged.
        let log = CallLog()
        registry.register(inpaint: MagentaInpaint(log: log))
        _ = try await ai.contentAwareFill(d, layer: d.layers[0].id, options: ContentAwareFillOptions(inpaint: opts))
        #expect(log.all == ["inpaint best"])
    }

    /// A built-in tier under the inpaint slot (PCEngine's PatchMatch) runs while the slot is empty, gives way to a
    /// registered model, and stays when a host empties the slot or every slot (AB-T-0304: PixelAgencyEditor's models
    /// module empties the slot when LaMa isn't ready, and the fills became EraseKit's diffusion).
    @Test func aBuiltInInpaintTierOutlivesTheSlot() async throws {
        let log = CallLog()
        let registry = ProviderRegistry()
        let ai = PCIntelligence(registry: registry)
        var d = FillTests.scene()
        d.selection = Fixture.selection(FillTests.square)
        let builtIn = OptionsRecordingInpaint()
        registry.setBuiltIn(inpaint: builtIn)
        let atBuiltIn = CapabilityStatus.available(tier: .classical, engine: "FakePatchMatch", injected: false)
        #expect(registry.status(of: .inpaint) == atBuiltIn)
        #expect(registry.builtInName(.inpaint) == "FakePatchMatch" && registry.injectedCapabilities.isEmpty)
        #expect(registry.status(of: .generativeFill).isAvailable == false, "a classical built-in is no generative stand-in")
        var out = try await ai.contentAwareFill(d, layer: d.layers[0].id)
        #expect(out.receipt.tier == .classical && out.receipt.engine == "FakePatchMatch")

        registry.register(inpaint: MagentaInpaint(log: log))
        out = try await ai.contentAwareFill(d, layer: d.layers[0].id)
        #expect(out.receipt.engine == "FakeLaMa" && log.all == ["inpaint best"], "a registered model overrides it")

        registry.unregister(.inpaint)
        #expect(registry.status(of: .inpaint) == atBuiltIn)
        out = try await ai.contentAwareFill(d, layer: d.layers[0].id)
        #expect(out.receipt.engine == "FakePatchMatch" && builtIn.seen.count == 2)

        registry.removeAll()
        #expect(registry.status(of: .inpaint) == atBuiltIn)
        out = try await ai.contentAwareFill(d, layer: d.layers[0].id)
        #expect(out.receipt.engine == "FakePatchMatch" && builtIn.seen.count == 3)
    }

    @Test func generativeFillUsesItsProviderOrTheInpaintStandIn() async throws {
        let log = CallLog()
        let registry = ProviderRegistry()
        let ai = PCIntelligence(registry: registry)
        var d = FillTests.scene()
        d.selection = Fixture.selection(FillTests.square)
        #expect(!ai.status(of: .generativeFill).isAvailable)

        registry.register(inpaint: MagentaInpaint(log: log))
        let standIn = try await ai.generativeFill(d, above: d.layers[0].id, prompt: "a cat")
        #expect(standIn.receipt.tier == .model && standIn.receipt.capability == .generativeFill)
        #expect(standIn.receipt.notes.contains { $0.contains("prompt ignored") })
        let a = try Fixture.applied(standIn.transaction, to: d)
        let gen = try #require(a.layer(standIn.layer))
        #expect(gen.name == "Generative Layer 1" && a.layers.last?.id == gen.id)
        #expect(gen.mask != nil, "masked by the selection")
        #expect(gen.rasterSurface?.pixel(x: 120, y: 80) == [1, 0, 1, 1])
        #expect(a.layers[0] == d.layers[0], "the source layer is untouched")

        let prompts = CallLog()
        registry.register(generativeFill: GenerativeFillClosure("FakeFlux") { image, mask, prompt in
            prompts.add(prompt)
            return image
        })
        let real = try await ai.generativeFill(d, above: nil, prompt: "a cat")
        #expect(real.receipt.engine == "FakeFlux" && real.receipt.notes.isEmpty)
        #expect(prompts.all == ["a cat"])
    }

    @Test func fakeMatteAndPromptProvidersReplaceVision() async throws {
        let registry = ProviderRegistry()
        registry.register(matte: HalfMatte())
        let squares = SquarePromptMask()
        registry.register(promptMask: squares)
        let ai = PCIntelligence(registry: registry)
        // A flat image: Vision would find nothing, the fake matte selects the top half.
        let d = Fixture.document(width: 64, height: 48) { _, _ in SIMD4(0.5, 0.5, 0.5, 1) }
        let subject = try await ai.selectSubject(d, options: SubjectOptions(quality: .best))
        #expect(subject.receipt == TierReceipt(capability: .subjectMatte, tier: .model, engine: "FakeBiRefNet", notes: ["quality: best"]))
        #expect(subject.selection?.contentBounds == PixelRect(x: 0, y: 0, width: 64, height: 24))
        let obj = try await ai.selectObject(d, prompt: .click(x: 30, y: 20))
        #expect(obj.receipt.engine == "FakeEdgeTAM" && obj.receipt.tier == .model)
        #expect(obj.selection?.contentBounds == PixelRect(x: 20, y: 10, width: 20, height: 20))
        let click = try #require(squares.last?.points.first)
        #expect(click.x == 30 && click.y == 20, "document coordinates reach the provider in image pixels")
        let bg = try await ai.removeBackground(d, layer: d.layers[0].id)
        #expect(bg.receipt.tier == .model && bg.bounds == PixelRect(x: 0, y: 0, width: 64, height: 24))
    }

    @Test func colorizeAndUpscaleLightUpWhenRegistered() async throws {
        let registry = ProviderRegistry()
        let ai = PCIntelligence(registry: registry)
        let d = Fixture.document(width: 32, height: 24) { x, _ in
            let v = Float(x) / 31
            return SIMD4(v, v, v, 1)
        }
        await #expect(throws: IntelligenceError.self) { try await ai.colorize(d, layer: d.layers[0].id) }
        await #expect(throws: IntelligenceError.self) { try await ai.superResolution(d) }

        registry.register(colorize: SepiaColorize())
        let c = try await ai.colorize(d, layer: d.layers[0].id)
        #expect(c.receipt.tier == .model && c.receipt.engine == "FakeDDColor")
        let px = try #require(try Fixture.applied(c.transaction, to: d).layers[0].rasterSurface).readRGBA(PixelRect(x: 20, y: 5, width: 1, height: 1))[0]
        #expect(px.x > px.z + 0.1, "sepia: red above blue")
        // A grayscale document can't show colour.
        var gray = d
        gray.mode = .grayscale
        await #expect(throws: IntelligenceError.self) { try await ai.colorize(gray, layer: gray.layers[0].id) }

        registry.register(upscale: NearestUpscale())
        let sr = try await ai.superResolution(d, factor: 2)
        #expect(sr.document.size == PixelSize(width: 64, height: 48))
        #expect(sr.document.resolutionDpi == d.resolutionDpi * 2)
        #expect(sr.receipt.metrics["appliedScale"] == 2 && sr.receipt.engine == "FakeRealPLKSR")
        #expect(sr.document.layers.count == 1 && sr.document.layers[0].name == "Background")
        let up = sr.document.layers[0].rasterSurface!
        #expect(up.pixel(x: 41, y: 9) == d.layers[0].rasterSurface!.pixel(x: 20, y: 4))
    }

    @Test func restoreJobsFollowTheProviderReport() async throws {
        let registry = ProviderRegistry()
        registry.register(restore: InvertingRestore())
        #expect(registry.status(of: RestoreJob.denoise) == .available(tier: .model, engine: "FakeNAFNet", injected: true))
        #expect(!registry.status(of: RestoreJob.motionDeblur).isAvailable, "a job whose backer is unregistered stays unavailable")
        let ai = PCIntelligence(registry: registry)
        let d = Fixture.document(width: 16, height: 16) { _, _ in SIMD4(0.2, 0.3, 0.4, 1) }
        let out = try await ai.jpegArtifactsRemoval(d, layer: d.layers[0].id, strength: .high)
        #expect(out.receipt.engine == "FakeNAFNet" && out.receipt.notes == ["the backer has no strength dial"])
        let p = try #require(try Fixture.applied(out.transaction, to: d).layers[0].rasterSurface).readRGBA(PixelRect(x: 3, y: 3, width: 1, height: 1))[0]
        #expect(abs(p.x - 0.8) < 0.01 && abs(p.z - 0.6) < 0.01, "the provider's (inverting) result came back")
    }

    @Test func photoRestorationRunsEveryRegisteredStage() async throws {
        let registry = ProviderRegistry()
        let ai = PCIntelligence(registry: registry)
        let d = Fixture.document(width: 48, height: 32) { x, y in SIMD4(0.5, 0.45, 0.4, 1) + (x == 20 ? SIMD4(0.4, 0.4, 0.4, 0) : .zero) }
        // No models: noise reduction runs classically, the other stages are named as skipped.
        let plain = try await ai.photoRestoration(d, layer: d.layers[0].id)
        #expect(plain.stages.map(\.capability) == [.restore])
        #expect(plain.receipt.tier == .classical)
        #expect(plain.receipt.notes.contains { $0.contains("scratch reduction skipped") })
        #expect(plain.receipt.notes.contains { $0.contains("Enhance Face skipped") })
        await #expect(throws: IntelligenceError.self) {
            try await ai.photoRestoration(d, layer: d.layers[0].id, options: PhotoRestorationOptions(scratchReduction: 1, noiseReduction: 0, enhanceFace: 1))
        }
        // Scratch detector (the bright column) + inpaint + face.
        let faces = CallLog()
        registry.register(scratchDetect: DefectMaskClosure("FakeBOPBTL") { image in
            let w = image.width, h = image.height
            var v = [Float](repeating: 0, count: w * h)
            for y in 0..<h { v[y * w + 20] = 1 }
            return try KitBridge.maskImage(v, width: w, height: h)
        })
        registry.register(faceRestore: FaceRestoreClosure("FakeGFPGAN") { image, s in faces.add("\(s)"); return image })
        let full = try await ai.photoRestoration(d, layer: d.layers[0].id, options: PhotoRestorationOptions(scratchReduction: 1, noiseReduction: 0.2, enhanceFace: 0.7))
        #expect(full.stages.map(\.capability) == [.scratchDetect, .inpaint, .restore, .faceRestore])
        #expect(full.stages.map(\.tier) == [.model, .classical, .classical, .model])
        #expect(full.receipt.tier == .model)
        #expect(faces.all == ["0.7"])
        let s = try #require(try Fixture.applied(full.transaction, to: d).layers[0].rasterSurface)
        #expect(abs(s.readRGBA(PixelRect(x: 20, y: 16, width: 1, height: 1))[0].x - 0.5) < 0.05, "the scratch column was filled")
        // Smart Portrait.
        let portrait = try await ai.restoreFaces(d, layer: d.layers[0].id, strength: 2)
        #expect(portrait.receipt.engine == "FakeGFPGAN" && portrait.receipt.metrics["strength"] == 1)
    }

    @Test func registryIsSafeUnderConcurrentUse() async {
        let registry = ProviderRegistry()
        let log = CallLog()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    switch i % 4 {
                    case 0: registry.register(inpaint: MagentaInpaint(log: log))
                    case 1: registry.unregister(.inpaint)
                    case 2: registry.register(upscale: NearestUpscale())
                    default: _ = registry.statuses
                    }
                }
            }
        }
        registry.register(inpaint: MagentaInpaint(log: log))
        #expect(registry.status(of: .inpaint).engine == "FakeLaMa")
        #expect(registry.status(of: .upscale).isAvailable)
        registry.removeAll()
        #expect(registry.injectedCapabilities.isEmpty)
    }
}
