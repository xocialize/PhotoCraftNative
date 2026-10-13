// Port of photocraft-io (crates/io/tests/heif_unsupported.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// photocraft builds without its `heif` feature say "isn't included in this build"; PCIO always
// reads HEIF through ImageIO, so that message does not apply. What remains: a HEIC header alone,
// under any name, is a clear error, never a trap or a misdetected format.

import Foundation
import PCDocument
import PCIOCore
import Testing
@testable import PCIO

@Suite struct HEIFUnsupportedTests {
    init() { ExportSweep.install() }
    @Test func aHEICHeaderAloneIsAnError() {
        let header: [UInt8] = [0, 0, 0, 0x18] + Array("ftypheic".utf8) + [0, 0, 0, 0] + Array("mif1heic".utf8)
        for name in ["IMG_0001.HEIC", "photo.heif", "noext"] {
            let e = FlatKit.error { try FlatKit.importFile(name, header) }
            #expect(e != nil, "\(name)")
            if case .unknownFormat? = e as? PCIOError { Issue.record("\(name): reported as an unknown format") }
        }
    }
}
