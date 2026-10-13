// Errors shared by every PCPlatform module.
// Replaces the per-crate error enums of photocraft-cms (`CmsError`), photocraft-codecs (`CodecError`),
// photocraft-raw (`RawError`) and photocraft-tablet (`Error`) with one native error type. Port of
// their API shape, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation

/// Why a platform call failed.
public enum PlatformError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The framework cannot do this on this OS (a format with no writer, a camera with no decoder…).
    case unsupported(String)
    /// The bytes could not be decoded.
    case decodeFailed(String)
    /// The pixels could not be encoded.
    case encodeFailed(String)
    /// Not a usable ICC profile (photocraft `CmsError::BadSignature` / `Invalid`).
    case invalidProfile(String)
    /// A caller-supplied value is out of range.
    case invalidArgument(String)
    /// A decoder's size guard refused the image (photocraft `CodecError::LimitExceeded`).
    case limitExceeded(String)
    /// A system framework call failed for a reason it did not explain.
    case frameworkFailure(String)

    public var description: String {
        switch self {
        case .unsupported(let m): "unsupported: \(m)"
        case .decodeFailed(let m): "decode failed: \(m)"
        case .encodeFailed(let m): "encode failed: \(m)"
        case .invalidProfile(let m): "invalid ICC profile: \(m)"
        case .invalidArgument(let m): "invalid argument: \(m)"
        case .limitExceeded(let m): "limit exceeded: \(m)"
        case .frameworkFailure(let m): "framework failure: \(m)"
        }
    }
}
