// Files that crashed or hung Photoshop. Every crash costs the operator a crash-report dialog, so a
// quarantined file is never opened again unless the caller states a hypothesis to test
// (`--allow-quarantined "<hypothesis>"`, logged). Entries match by content (SHA-256) and by name.

import CryptoKit
import Foundation

public struct QuarantineEntry: Codable, Sendable {
    public var name: String
    public var sha256: String
    public var reason: String
    public var date: String
}

public struct Quarantine: Sendable {
    public let url: URL
    public private(set) var entries: [QuarantineEntry]

    public init(scratch: URL) {
        url = scratch.appendingPathComponent("ps-oracle/quarantine.json")
        entries = (try? JSONDecoder().decode([QuarantineEntry].self, from: Data(contentsOf: url))) ?? []
    }

    public static func digest(_ file: URL) -> String {
        guard let d = try? Data(contentsOf: file, options: .alwaysMapped) else { return "" }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    public func entry(for file: URL) -> QuarantineEntry? {
        let name = file.lastPathComponent
        if let e = entries.first(where: { $0.name == name }) { return e }
        let h = Self.digest(file)
        return h.isEmpty ? nil : entries.first { $0.sha256 == h }
    }

    public mutating func add(_ file: URL, reason: String) throws {
        guard entry(for: file) == nil else { return }
        entries.append(QuarantineEntry(name: file.lastPathComponent, sha256: Self.digest(file), reason: reason,
                                       date: ISO8601DateFormatter().string(from: Date())))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(entries).write(to: url)
    }
}
