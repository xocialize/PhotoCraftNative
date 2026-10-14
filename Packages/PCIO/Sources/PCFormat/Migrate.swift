// Manifest migrations. Each step upgrades the raw JSON from version `n` to `n + 1`, so old
// bundles keep loading as the schema evolves.
// Port of photocraft-format (crates/format/src/migrate.rs), MIT OR Apache-2.0, © ArtCraft Team
// and the PhotoCraft contributors.

enum Migrate {
    typealias Step = @Sendable (inout JSONTree) throws(FormatError) -> Void

    /// `steps[i]` upgrades version `i + 1` to `i + 2`.
    static let steps: [Step] = [v1ToV2, v2ToV3]

    /// 1 → 2: format 2 changes the single-file container (ZIP64 when needed), not the document
    /// schema, so a version 1 manifest is already a valid version 2 one.
    static let v1ToV2: Step = { (_: inout JSONTree) throws(FormatError) in }

    /// 2 → 3: format 3 adds an adjustment kind (filter adjustment layers), so a version 2 manifest
    /// is already a valid version 3 one.
    static let v2ToV3: Step = { (_: inout JSONTree) throws(FormatError) in }

    /// Upgrades `v` in place to `target` using `steps`; returns the version found.
    @discardableResult
    static func migrateWith(_ v: inout JSONTree, _ steps: [Step], target: UInt32) throws(FormatError) -> UInt32 {
        guard let raw = v.get("format_version")?.asU64 else { throw .corrupt("manifest has no format_version") }
        guard let found = UInt32(exactly: raw) else { throw .corrupt("format_version out of range") }
        if found == 0 { throw .corrupt("format_version 0 is invalid") }
        if found > target { throw .tooNew(found: found, supported: target) }
        var ver = found
        while ver < target {
            let i = Int(ver) - 1
            guard i < steps.count else { throw .unsupported("no migration from format \(ver)") }
            try steps[i](&v)
            v["format_version"] = .number(String(ver + 1))
            ver += 1
        }
        return found
    }

    @discardableResult
    static func migrate(_ v: inout JSONTree) throws(FormatError) -> UInt32 {
        try migrateWith(&v, steps, target: pcraftFormatVersion)
    }
}
