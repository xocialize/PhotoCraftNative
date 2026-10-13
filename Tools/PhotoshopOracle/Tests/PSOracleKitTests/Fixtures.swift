// Where the opt-in diagnostics find the oracle's data: the data root `ps-oracle` itself uses
// (`OracleConfig.dataRoot`: `PS_ORACLE_SCRATCH`, else PhotoCraftNative's fixtures root, which is
// `PHOTOCRAFT_FIXTURES` when set, else `<PhotoCraftNative>/../PhotoCraftNative-Fixtures`). A
// diagnostic that reads it runs only when its variable is set and the root exists, and otherwise
// skips with a reason.

import Foundation
import Testing
@testable import PSOracleKit

enum Fixtures {
    /// The data root, or nil when it does not exist.
    static let root: String? = {
        let p = OracleConfig.dataRoot()
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &dir) && dir.boolValue ? p : nil
    }()

    /// The data root for tests enabled by `optIn` ("" when there is none; they are skipped then).
    static var path: String { root ?? "" }

    /// True when the opt-in variable `name` is set and the data root exists.
    static func optIn(_ name: String) -> Bool { ProcessInfo.processInfo.environment[name] != nil && root != nil }

    /// The skip reason for a diagnostic that reads the data root.
    static func reason(_ name: String) -> Comment {
        Comment(rawValue: "opt-in: set \(name); needs the oracle's data root (PHOTOCRAFT_FIXTURES or PS_ORACLE_SCRATCH)")
    }
}
