// New: PCAlgo's reusable GPU textures answer memory pressure (PCFoundation's MemoryPressureRelay).

import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct AlgoMemoryPressureTests {
    @Test func reusableTexturesTrimAndRegister() throws {
        guard AlgoGPU.isAvailable else { return }
        let gpu = try AlgoGPU.shared()
        #expect(MemoryPressureRelay.shared.registered.contains("PCAlgo reusable textures"))
        // A size no filter run asks for, so a parallel test can't take it back first.
        let t = try gpu.privateTexture(width: 37, height: 41)
        gpu.releaseTextures([t])
        #expect(gpu.cachedBytes >= 37 * 41 * 16)
        #expect(gpu.trimCaches(.critical) >= 37 * 41 * 16)
    }
}
