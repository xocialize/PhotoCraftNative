// Port of photocraft-automation (crates/automation/src/budgets.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Fixed ceilings for automation previews and outbound JSON. They bound individual outputs, not
// total document memory or the duration of an engine command: a reply is encoded whole before
// anything is written, and one that is too large is replaced by a small error naming its id.

import Foundation
import PCDocument
import PCEngine

public enum Budgets {
    /// Maximum encoded JSON reply, including its newline for JSON-lines transports.
    public static let maxResponseBytes = 8 << 20
    /// Maximum PNG bytes before base64 expansion (leaves room for JSON/MCP metadata).
    public static let maxPNGBytes = 5 << 20
    /// Maximum requested preview edge. Zero still requests full size, within this ceiling.
    public static let maxPreviewSide = 2048
    /// Maximum source pixels processed by a headless automation preview.
    public static let maxRenderSourcePixels: UInt64 = 64 << 20

    /// Checked before the compositor runs: an oversized request fails rather than silently
    /// downscaling (photocraft `check_preview`).
    public static func checkPreview(width: Int, height: Int, maxSide: Int) throws {
        if width <= 0 || height <= 0 {
            throw AutomationError.badRequest("automation preview requires nonzero document dimensions")
        }
        let (pixels, overflow) = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
        if overflow || pixels > maxRenderSourcePixels {
            throw AutomationError.badRequest("automation preview source exceeds \(maxRenderSourcePixels) pixels")
        }
        let side = maxSide == 0 ? max(width, height) : maxSide
        if side > maxPreviewSide { throw AutomationError.badRequest("automation preview side exceeds \(maxPreviewSide) pixels") }
    }

    /// Checked before base64 encoding or writing a rendered PNG.
    public static func checkPNG(_ bytes: Int) throws {
        if bytes > maxPNGBytes { throw AutomationError.badRequest("automation PNG exceeds \(maxPNGBytes) bytes") }
    }

    /// The compact encoding of `value` when it fits `maximum` bytes (photocraft
    /// `encode_with_limit`).
    static func encodeWithLimit(_ value: JSONValue, _ maximum: Int) throws -> Data {
        let data = Data(value.serialized().utf8)
        if data.count > maximum {
            throw AutomationError.badRequest("response encoding failed: response exceeds \(maximum) bytes")
        }
        return data
    }

    /// `value` encoded within the reply ceiling (one byte is kept for the newline).
    public static func jsonBytes(_ value: JSONValue) throws -> Data {
        try encodeWithLimit(value, maxResponseBytes - 1)
    }

    /// One reply line, newline included. A reply over the ceiling becomes one small error with
    /// the original id; the operation may already have completed (photocraft `write_reply`).
    public static func replyLine(_ reply: JSONValue) -> Data {
        var encoded: Data
        do {
            encoded = try jsonBytes(reply)
        } catch {
            encoded = (try? jsonBytes(oversizedReply(reply))) ?? Data(#"{"id":null,"ok":false,"error":"response budget exceeded"}"#.utf8)
        }
        encoded.append(0x0A)
        return encoded
    }

    /// The error that replaces an oversized reply.
    static func oversizedReply(_ reply: JSONValue) -> JSONValue {
        ["id": reply["id"] ?? .null, "ok": false, "error": .string("response exceeds \(maxResponseBytes) bytes; operation may have completed")]
    }

    /// `reply` itself, or the error that replaces it when it exceeds the ceiling.
    public static func bounded(_ reply: JSONValue) -> JSONValue {
        (try? jsonBytes(reply)) != nil ? reply : oversizedReply(reply)
    }

    /// Reserves envelope and id space and bounds retained batch results incrementally, so many
    /// individually valid replies can't accumulate into an enormous batch (photocraft
    /// `BatchReplyBudget`).
    public struct BatchReplyBudget: Sendable {
        public internal(set) var remaining: Int
        /// Charge each result as it costs inside a JSON string (MCP text content).
        public let escaped: Bool

        public init() {
            remaining = maxResponseBytes - ControlSecurity.maxRequestBytes - 4096
            escaped = false
        }

        init(remaining: Int, escaped: Bool) {
            self.remaining = remaining
            self.escaped = escaped
        }

        /// For a batch reply sent as MCP text content: the encoded reply is embedded in a JSON
        /// string, which escapes every quote and backslash again.
        public static func escapedBudget() -> BatchReplyBudget { BatchReplyBudget(remaining: BatchReplyBudget().remaining, escaped: true) }

        /// Must be called before retaining the result or dispatching the next step.
        public mutating func charge(_ result: JSONValue) throws {
            let limit = max(0, remaining - 1)
            let bytes = try encodeWithLimit(result, limit)
            // Compact JSON has no raw control characters, so only `"` and `\` grow when escaped.
            let size = escaped ? bytes.count + bytes.reduce(0) { $0 + ($1 == 0x22 || $1 == 0x5C ? 1 : 0) } : bytes.count
            if size > limit { throw AutomationError.badRequest("response exceeds \(limit) bytes once escaped") }
            remaining = max(0, remaining - (size + 1))
        }
    }
}
