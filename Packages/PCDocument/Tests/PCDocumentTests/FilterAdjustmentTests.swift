// Filter adjustment layers (AB-T-0258): the model's coding, defaults and ranges. New; no
// photocraft counterpart.

import Foundation
import Testing
@testable import PCDocument

@Suite struct FilterAdjustmentModelTests {
    static let all: [FilterAdjustment] = [
        .grain(.init(amount: 40, size: 3.5, roughness: 20, seed: 0xfeed_beef)),
        .addNoise(.init(amount: 250, gaussian: true, monochromatic: true, seed: 12)),
        .gaussianBlur(.init(radius: 7.25)),
        .motionBlur(.init(angle: -45, distance: 120)),
    ]

    /// serde's externally tagged form, nested: `{"Filter":{"GaussianBlur":{"radius":7.25}}}`.
    @Test func codesAsTaggedVariants() throws {
        for f in Self.all {
            let a = Adjustment.filter(f)
            let data = try JSONEncoder().encode(a)
            #expect(try JSONDecoder().decode(Adjustment.self, from: data) == a)
            let text = String(decoding: data, as: UTF8.self)
            #expect(text.hasPrefix("{\"Filter\":{\""), "\(text)")
        }
        let blur = try JSONDecoder().decode(Adjustment.self, from: Data(#"{"Filter":{"GaussianBlur":{"radius":7.25}}}"#.utf8))
        #expect(blur == .filter(.gaussianBlur(.init(radius: 7.25))))
        // Missing settings take Compositor's defaults; an unknown kind is an error.
        let bare = try JSONDecoder().decode(Adjustment.self, from: Data(#"{"Filter":{"Grain":{}}}"#.utf8))
        #expect(bare == .filter(.grain(.init(amount: 25, size: 1.5, roughness: 50, seed: 0))))
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Adjustment.self, from: Data(#"{"Filter":{"Swirl":{}}}"#.utf8)) }
    }

    @Test func defaultsKindsAndRanges() {
        #expect(FilterAdjustment.Kind.allCases.map { FilterAdjustment.defaults($0, seed: 5).kind } == FilterAdjustment.Kind.allCases)
        #expect(FilterAdjustment.defaults(.motionBlur) == .motionBlur(.init(angle: 0, distance: 10)))
        #expect(FilterAdjustment.defaults(.gaussianBlur) == .gaussianBlur(.init(radius: 10)))
        #expect(FilterAdjustment.defaults(.addNoise, seed: 5) == .addNoise(.init(amount: 10, gaussian: false, monochromatic: false, seed: 5)))
        #expect(Adjustment.filter(.addNoise(.init())).label == "Add Noise")
        #expect(FilterAdjustment.Kind.allCases.filter(\.samplesNeighbours) == [.gaussianBlur, .motionBlur])
        #expect(FilterAdjustment.gaussianBlur(.init(radius: 900)).clamped == .gaussianBlur(.init(radius: 250)))
        #expect(FilterAdjustment.motionBlur(.init(angle: .nan, distance: 0)).clamped == .motionBlur(.init(angle: 0, distance: 1)))
        #expect(FilterAdjustment.grain(.init(amount: -3, size: 40, roughness: 101, seed: 9)).clamped
            == .grain(.init(amount: 0, size: 20, roughness: 100, seed: 9)))
        #expect(Adjustment.invert.asFilter == nil && Adjustment.filter(.gaussianBlur(.init())).asFilter == .gaussianBlur(.init()))
    }
}
