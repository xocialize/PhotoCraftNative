// New: PCRender's CPU caches answer memory pressure (PCFoundation's MemoryPressureRelay).

import Foundation
import PCDocument
import PCFoundation
import Testing
@testable import PCRender

@Suite struct CPUCachePressureTests {
    @Test func theRelayRunsEveryRegisteredTrim() {
        let relay = MemoryPressureRelay()
        final class Box: @unchecked Sendable { var levels: [MemoryPressureRelay.Level] = []; let lock = NSLock() }
        let box = Box()
        var a: MemoryPressureRegistration? = relay.register("a") { l in box.lock.lock(); box.levels.append(l); box.lock.unlock(); return 10 }
        let b = relay.register("b") { $0 == .critical ? 7 : 3 }
        #expect(relay.relay(.warning) == [.init(name: "a", freed: 10), .init(name: "b", freed: 3)])
        #expect(relay.relay(.critical).map(\.freed) == [10, 7])
        a = nil
        #expect(relay.registered == ["b"])
        #expect(relay.relay(.warning).map(\.name) == ["b"])
        #expect(box.levels == [.warning, .critical] && a == nil)
        #expect(!relay.isListening)
        relay.start(); relay.start()
        #expect(relay.isListening)
        relay.stop()
        #expect(!relay.isListening)
        _ = b
    }

    @Test func cpuCachesTrimToHalfThenEmpty() throws {
        let doc = BenchmarkDocuments.realistic20(size: 256)
        let c = DocumentCompositor(rasterizer: DT.rasterizer, backend: .cpu, metal: nil)
        _ = try c.render(doc, region: doc.bounds)
        let held = c.cpu.cacheBytes
        #expect(held > 0)
        let warned = c.cpu.trim(.warning)
        #expect(warned >= held / 2 && c.cpu.cacheBytes <= held / 2 && warned == held - c.cpu.cacheBytes)
        _ = c.cpu.trim(.critical)
        #expect(c.cpu.cacheBytes == 0)
        _ = try c.render(doc, region: doc.bounds)
        let leaves = c.cache.bytes
        #expect(c.cache.trim(.warning) == leaves - c.cache.bytes && c.cache.bytes <= leaves / 2)
        #expect(c.trimCPUCaches(.critical) >= 0 && c.cache.bytes == 0 && c.cpu.cacheBytes == 0)
        #expect(MemoryPressureRelay.shared.registered.contains("PCRender CPU caches"))
        // The trimmed caches rebuild: the composite is unchanged.
        let again = try c.render(doc, region: doc.bounds)
        #expect(again == (try DocumentCompositor(rasterizer: DT.rasterizer, backend: .cpu, metal: nil).render(doc, region: doc.bounds)))
    }
}
