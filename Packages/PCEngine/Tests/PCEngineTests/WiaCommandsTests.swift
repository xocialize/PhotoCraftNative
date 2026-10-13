// Port of photocraft-engine (crates/engine/src/wia_cmds.rs, `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import PCDocument
@testable import PCEngine
import Testing

@Suite struct WiaCommandsTests {
    @Test func reportsAvailability() throws {
        let s = Session()
        let r = try s.execute("file.import.wiaSupport")
        #expect(r["devices"]?.arrayValue != nil)
        #if os(Windows)
        #expect(r["available"] == true)
        #else
        #expect(r["available"] == false)
        #endif
    }
}
