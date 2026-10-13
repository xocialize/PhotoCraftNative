// Errors, results and cancellation shared by every PCIO module.
// Port of photocraft-io (crates/io/src/lib.rs: IoError, ImportResult, ExportResult,
// unequal_resolution_warning) and photocraft-raster (crates/raster/src/interrupt.rs: Interrupt),
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCPSD

/// Errors from import and export. Like photocraft, malformed files never trap: they fail with one
/// of these, or import with warnings.
public enum PCIOError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Structurally invalid data (photocraft `FormatError::Corrupt`, ZIP and container errors).
    case corrupt(String)
    /// The requested conversion or a feature of the file is not supported.
    case unsupported(String)
    /// A size, count or allocation exceeded a safety limit.
    case limitExceeded(String)
    /// PSD/PSB parse or write failure.
    case psd(String)
    /// A failure in one container format: (format name, message), e.g. ("OpenRaster", "…").
    case format(String, String)
    /// A flat image codec failure.
    case codec(String)
    /// File-system failure.
    case io(String)
    /// The file type could not be determined.
    case unknownFormat(String)
    /// A background import or save was cancelled.
    case cancelled

    public var description: String {
        switch self {
        case let .corrupt(m): "corrupt: \(m)"
        case let .unsupported(m): "unsupported: \(m)"
        case let .limitExceeded(m): "limit exceeded: \(m)"
        case let .psd(m): "PSD: \(m)"
        case let .format(f, m): "\(f): \(m)"
        case let .codec(m): "codec: \(m)"
        case let .io(m): "I/O: \(m)"
        case let .unknownFormat(m): "unknown file format: \(m)"
        case .cancelled: "cancelled"
        }
    }

    /// Wraps any error from PCPSD or elsewhere.
    public static func wrap(_ e: Error) -> PCIOError {
        if let e = e as? PCIOError { return e }
        if let e = e as? PSDError { return .psd(e.description) }
        return .io(String(describing: e))
    }
}

/// Result of an import.
public struct ImportResult: Sendable {
    /// The imported document.
    public var document: Document
    /// Human-readable notes about anything approximated or dropped.
    public var warnings: [String]
    /// Save must not write back to an import-only source, such as Affinity or Paint.NET.
    public var sourceReadOnly: Bool
    /// Only a stand-in picture of the file: Open shows it with its warning; Place and other
    /// auxiliary imports refuse it.
    public var previewOnly: Bool

    public init(document: Document, warnings: [String] = [], sourceReadOnly: Bool = false, previewOnly: Bool = false) {
        self.document = document
        self.warnings = warnings
        self.sourceReadOnly = sourceReadOnly
        self.previewOnly = previewOnly
    }
}

/// Result of an export.
public struct ExportResult: Sendable {
    /// The encoded file.
    public var bytes: [UInt8]
    /// Human-readable notes about anything approximated or dropped.
    public var warnings: [String]

    public init(bytes: [UInt8], warnings: [String] = []) {
        self.bytes = bytes
        self.warnings = warnings
    }
}

/// The import note for a file whose horizontal and vertical resolutions (pixels per inch) differ:
/// a document has one resolution, so it keeps the horizontal one and saves it on both axes
/// (photocraft #1018). Differences under 0.01 ppi are below what the warning can show.
public func unequalResolutionWarning(_ x: Double, _ y: Double) -> String? {
    abs(x - y) >= 0.01
        ? "the vertical resolution (\(String(format: "%.2f", y)) ppi) differs from the horizontal (\(String(format: "%.2f", x)) ppi); the document keeps \(String(format: "%.2f", x)) ppi for both"
        : nil
}

/// Cancellation and progress for background opens and saves (photocraft `Interrupt`).
public struct Interrupt: Sendable {
    private let cancel: @Sendable () -> Bool
    private let report: @Sendable (Float) -> Void

    /// Never cancelled; progress is ignored.
    public static let none = Interrupt(cancel: { false }, progress: { _ in })

    /// An interrupt from a cancellation check and a progress sink (0...1).
    public init(cancel: @escaping @Sendable () -> Bool, progress: @escaping @Sendable (Float) -> Void) {
        self.cancel = cancel
        self.report = progress
    }

    /// Only a cancellation check.
    public static func cancelOnly(_ cancel: @escaping @Sendable () -> Bool) -> Interrupt {
        Interrupt(cancel: cancel, progress: { _ in })
    }

    /// Has the operation been cancelled? Work stops as soon as it sees `true`.
    public var isCancelled: Bool { cancel() }

    /// Throws `PCIOError.cancelled` once cancelled.
    public func check() throws {
        if cancel() { throw PCIOError.cancelled }
    }

    /// Reports progress (0...1).
    public func progress(_ p: Float) { report(p) }

    /// An interrupt whose progress 0...1 fills `lo...hi` of this one (same cancellation)
    /// (photocraft `with_span`).
    public func span(_ lo: Float, _ hi: Float) -> Interrupt {
        let parent = self
        return Interrupt(cancel: { parent.isCancelled }, progress: { p in parent.progress(lo + (hi - lo) * min(max(p, 0), 1)) })
    }
}
