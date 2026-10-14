// New: PCAlgo's cross-run texture cache sized from a host's memory budget (AB-T-0261).

import Foundation
import Metal
import Testing
@testable import PCAlgo
import PCFoundation

/// Sets the process-wide `AlgoGPU.memoryBudget`, so these run one at a time (no other suite sets it).
@Suite(.serialized) struct AlgoCacheBudgetTests {
    /// The engine's budget on an emulated 16 GB Mac, as AB-T-0253's drill measured it.
    static let sixteenGBTier = 12_713_000_000

    /// Filter ▸ Gaussian Blur over a `side`² RGBA layer on the GPU, as PixelAgencyEditor's drill runs it: it leaves its
    /// textures and staging buffers for the next run. The layer comes padded by the blur's halo, as `FilterEngine` would
    /// pad it (the same textures, without a copy that takes seconds in a debug build).
    static func blur(_ side: Int) throws {
        let layer = PixelRect(x: 0, y: 0, width: side, height: side), filter = GaussianBlur(radius: 8)
        guard case .radius(let halo) = filter.halo(bounds: layer) else { return }
        let padded = FloatImage(rect: layer.outset(by: halo), channels: 4)
        _ = try FilterEngine.apply(filter, to: padded, output: layer, context: .inferred(channels: 4, bounds: layer), on: .gpu)
    }

    @Test func withoutABudgetTheCapIsTodays() throws {
        guard AlgoGPU.isAvailable else { return }
        let gpu = try AlgoGPU.shared()
        let today = min(4 << 30, Int(gpu.device.recommendedMaxWorkingSetSize / 4))
        #expect(AlgoGPU.memoryBudget == nil)
        #expect(gpu.cacheLimit == today)
        AlgoGPU.memoryBudget = Self.sixteenGBTier
        defer { AlgoGPU.memoryBudget = nil }
        #expect(gpu.cacheLimit == Int(Double(Self.sixteenGBTier) * AlgoGPU.cacheShare))
        AlgoGPU.memoryBudget = nil
        #expect(gpu.cacheLimit == today)
    }

    /// AB-T-0253's drill filled the cache to 1,557 MiB with one 4096² blur, 1,951.5 MiB with another of 2048², and
    /// 2,928.4 MiB with blurs from 4096² down to 1024². Each 4096² run alone hands back more than the cap: its source,
    /// destination and two staging buffers are 256 MiB each.
    @Test func aSixteenGBBudgetHoldsTheCacheToItsCapThroughTheDrillsBlurs() throws {
        guard AlgoGPU.isAvailable else { return }
        let gpu = try AlgoGPU.shared()
        AlgoGPU.memoryBudget = Self.sixteenGBTier
        defer { AlgoGPU.memoryBudget = nil }
        let cap = gpu.cacheLimit
        #expect(cap == 635_650_000)
        #expect(gpu.cachedBytes <= cap, "setting the budget trims a fuller cache")
        for side in [4096, 2048] + Array(stride(from: 4096, through: 1024, by: -512)) {
            try Self.blur(side)
            #expect(gpu.cachedBytes <= cap, "after a \(side)² blur")
        }
        // An admission's shrink lets go of the textures on a utility queue: the call itself is short.
        let start = ContinuousClock.now
        let freed = gpu.trimCaches(.critical)
        let elapsed = ContinuousClock.now - start
        #expect(freed <= cap)
        #expect(elapsed < .milliseconds(50), "trimCaches(.critical) took \(elapsed)")
        AlgoGPU.waitForReleases()
    }

    @Test func whatTheCapDropsIsLetGoOf() throws {
        guard AlgoGPU.isAvailable else { return }
        let gpu = try AlgoGPU.shared()
        weak var cached: (any MTLTexture)?
        try autoreleasepool {
            // A size no filter run asks for, so a parallel test can't take it back first.
            let t = try gpu.privateTexture(width: 3001, height: 7)
            cached = t
            gpu.releaseTextures([t])
        }
        #expect(cached != nil, "kept for reuse")
        AlgoGPU.memoryBudget = 1   // a cap of 0 bytes
        defer { AlgoGPU.memoryBudget = nil }
        #expect(gpu.cachedBytes == 0)
        AlgoGPU.waitForReleases()
        #expect(cached == nil, "released once dropped")
        // Whatever comes back meanwhile is dropped too.
        let t = try gpu.privateTexture(width: 3001, height: 7)
        gpu.releaseTextures([t])
        #expect(gpu.cachedBytes == 0)
    }
}
