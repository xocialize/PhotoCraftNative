// Filter adjustment layers through the engine (AB-T-0258): `layer.newAdjustmentLayer.grain`,
// `.addNoise`, `.gaussianBlur` and `.motionBlur` create them, `layer.setAdjustment` edits them,
// `.pcraft` keeps them, and a PSD save bakes them to pixels with a warning (AB-D-0143). New; no
// photocraft counterpart.

import Foundation
@testable import PCEngine
import PCDocument
import PCFoundation
import Testing

@Suite struct FilterAdjustmentCommandTests {
    /// 64×48: black on the left half, white on the right.
    func session() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 64, "height": 48])
        try adjustTestPaint(s, SIMD4(1, 1, 1, 1))
        try adjustTestPaint(s, SIMD4(0, 0, 0, 1), PixelRect(x: 0, y: 0, width: 32, height: 48))
        return s
    }

    func filter(_ s: Session, _ r: JSONValue) throws -> (LayerId, FilterAdjustment) {
        let id = try layerResult(r)
        let l = try #require(s.active?.doc.layer(id))
        guard case .adjustment(.filter(let f)) = l.content else { throw EngineError.other("\(l.name) is not a filter adjustment layer") }
        return (id, f)
    }

    @Test func commandsCreateTheFourKinds() throws {
        let s = try session()
        let (_, blur) = try filter(s, try s.execute("layer.newAdjustmentLayer.gaussianBlur", ["radius": 4]))
        #expect(blur == .gaussianBlur(.init(radius: 4)))
        #expect(s.active?.doc.layers.last?.name.hasPrefix("Gaussian Blur") == true)
        let (_, motion) = try filter(s, try s.execute("layer.newAdjustmentLayer.motionBlur", ["angle": 120, "distance": 30]))
        #expect(motion == .motionBlur(.init(angle: 90, distance: 30)), "angle clamped to Photoshop's −90…90")
        let (_, noise) = try filter(s, try s.execute("layer.newAdjustmentLayer.addNoise",
                                                      ["amount": 40, "distribution": "gaussian", "monochromatic": true, "seed": 42]))
        #expect(noise == .addNoise(.init(amount: 40, gaussian: true, monochromatic: true, seed: 42)))
        // Without a seed, a pattern of the layer's own.
        let (gid, grain) = try filter(s, try s.execute("layer.newAdjustmentLayer.grain", ["amount": 60]))
        #expect(grain == .grain(.init(amount: 60, size: 1.5, roughness: 50, seed: AdjustParams.seed(for: gid))))
        let (gid2, grain2) = try filter(s, try s.execute("layer.newAdjustmentLayer.grain"))
        if case .grain(let a) = grain, case .grain(let b) = grain2 { #expect(gid != gid2 && a.seed != b.seed) }
        for (kind, p): (String, JSONValue) in [("gaussianBlur", ["radius": "wide"]), ("addNoise", ["distribution": "pink"]), ("grain", ["seed": -1]),
                                               ("grain", ["seed": 1.5]), ("motionBlur", ["distance": "far"])] {
            #expect(throws: EngineError.self, "\(kind) \(p)") { try s.execute("layer.newAdjustmentLayer.\(kind)", p) }
        }
    }

    @Test func setAdjustmentEditsAndResetKeepsThePattern() throws {
        let s = try session()
        let (id, _) = try filter(s, try s.execute("layer.newAdjustmentLayer.grain", ["seed": 7, "size": 4]))
        try s.execute("layer.setAdjustment", ["layer": .id(id), "amount": 80])
        #expect(s.active?.doc.layer(id)?.content == .adjustment(.filter(.grain(.init(amount: 80, size: 4, roughness: 50, seed: 7)))))
        try s.execute("layer.setAdjustment", ["layer": .id(id)])
        #expect(s.active?.doc.layer(id)?.content == .adjustment(.filter(.grain(.init(amount: 25, size: 1.5, roughness: 50, seed: 7)))))
        // `toParams` is `fromParams`'s inverse for every kind.
        for f in [FilterAdjustment.grain(.init(amount: 10, size: 3, roughness: 90, seed: 123_456)),
                  .addNoise(.init(amount: 300, gaussian: true, monochromatic: false, seed: 4_000_000_000)),
                  .gaussianBlur(.init(radius: 0.5)), .motionBlur(.init(angle: -30, distance: 1500))] {
            let a = Adjustment.filter(f)
            #expect(try AdjustParams.fromParams(AdjustParams.kind(of: a), AdjustParams.toParams(a), base: nil, mode: .rgb) == a)
        }
        #expect(AdjustParams.filterKinds == ["grain", "addNoise", "gaussianBlur", "motionBlur"])
    }

    /// The blur softens the black/white edge in the composite.
    @Test func filtersShowInTheComposite() throws {
        let s = try session()
        #expect(try adjustTestPixel(s, 31, 20) == [0, 0, 0, 1])
        try s.execute("layer.newAdjustmentLayer.gaussianBlur", ["radius": 3])
        let edge = try adjustTestPixel(s, 31, 20)
        #expect(edge[0] > 0.2 && edge[0] < 0.6, "\(edge)")
        _ = s.undo()
        try s.execute("layer.newAdjustmentLayer.motionBlur", ["angle": 90, "distance": 30])
        // A vertical streak leaves the vertical edge black (thinning towards the canvas's top and
        // bottom, past which the backdrop is clear).
        let streak = try adjustTestPixel(s, 31, 20)
        #expect(streak.prefix(3) == [0, 0, 0] && streak[3] > 0.8 && streak[3] < 1, "\(streak)")
    }

    @Test func pcraftKeepsThemAndPSDBakesThem() throws {
        let dir = try ioDir("filters")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try session()
        try s.execute("layer.newAdjustmentLayer.gaussianBlur", ["radius": 2])
        try s.execute("layer.newAdjustmentLayer.grain", ["seed": 99])
        let saved = try #require(s.active?.doc)
        let path = dir.appendingPathComponent("filters.pcraft").path
        try s.execute("file.saveAs", ["path": .string(path)])
        let (i, warnings, _) = try s.openFile(path)
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(s.documents[i].doc.layers.map(\.content).suffix(2) == saved.layers.map(\.content).suffix(2))
        let psd = dir.appendingPathComponent("filters.psd").path
        let r = try s.execute("file.saveACopy", ["path": .string(psd)])
        let w = r["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(w.filter { $0.contains("baked to pixels") }.count == 2, "\(w)")
        // The engine's renderer bakes them: the layers come back holding pixels that draw the live
        // composite, away from the canvas edge (where the live blur thins it and a pixel layer can't).
        let (j, _, _) = try s.openFile(psd)
        let back = s.documents[j].doc
        #expect(back.layers.suffix(2).allSatisfy { if case .raster(let p) = $0.content { !p.contentBounds.isEmpty } else { false } })
        let inner = saved.bounds.inset(by: 8)
        let live = try s.services.renderer.renderCPU(saved, region: inner), layers = try s.services.renderer.renderCPU(back, region: inner)
        let m = zip(live.px, layers.px).map { p, q in (0..<4).map { abs(p[$0] - q[$0]) }.max() ?? 0 }.max() ?? 0
        #expect(m * 255 <= 2, "\(m * 255) levels")
        dropForOracle(URL(fileURLWithPath: psd), as: "filter-bake.psd")
    }

    /// A fill beneath a blur damages its own rect grown by the blur's reach, and nothing outside
    /// that changes.
    @Test func damageUnderABlurGrowsByItsReach() throws {
        func render(_ s: Session) throws -> [SIMD4<Float>] {
            let doc = try #require(s.active?.doc)
            return try s.services.renderer.renderCPU(doc, region: doc.bounds).px
        }
        let s = try session()
        let bg = try #require(s.active?.doc.layers.first?.id)
        try s.execute("layer.newAdjustmentLayer.gaussianBlur", ["radius": 3])
        try s.selectLayer(bg)
        let shown = try render(s)
        try s.execute("select.rect", ["x": 40, "y": 10, "width": 6, "height": 5])
        try s.execute("edit.fill", ["color": "#ff0000"])
        let damage = try #require(s.active?.lastDamage)
        #expect(damage.contains(PixelRect(x0: 40 - 9, y0: 10 - 9, x1: 46 + 9, y1: 15 + 9)), "\(damage)")
        let now = try render(s)
        #expect(now != shown)
        for (i, (a, b)) in zip(shown, now).enumerated() where !damage.contains(x: Int32(i % 64), y: Int32(i / 64)) {
            #expect(a == b, "pixel \(i) outside the damage changed")
        }
    }

    @Test func registeredUnderNewAdjustmentLayer() {
        let s = Session()
        for kind in AdjustParams.filterKinds {
            let spec = s.registry.specs.first { $0.id == "layer.newAdjustmentLayer.\(kind)" }
            #expect(spec?.menu == ["Layer", "New Adjustment Layer"], "\(kind)")
            #expect(s.registry.specs.first { $0.id == "image.adjustments.\(kind)" } == nil, "\(kind) has no destructive twin")
        }
    }
}
