// A public face on the bounded Zstandard decoder (Zstd.swift), so other packages can read zstd data
// without a second decoder: photocraft's `.pcraft` stores its tiles zstd-compressed, and Apple's
// Compression framework has no zstd. Same limits as the archive path: output stops at the declared
// size, the window is capped, and damaged input throws instead of trapping.

public enum ZstdDecoder {
    public enum Failure: Error, Equatable {
        /// The data is not valid Zstandard (or uses dictionaries / skippable frames).
        case corrupt
        /// The frames decode to a different size than declared.
        case sizeMismatch
    }

    /// Decodes every concatenated frame in `data` when the decoded size isn't stored (`.pcraft`
    /// blobs): output may be any length up to `maxSize`; decoding past it throws `.sizeMismatch`.
    public static func decompress(_ data: [UInt8], maxSize: Int, maxWindow: UInt64 = 64 << 20) throws(Failure) -> [UInt8] {
        do {
            return try Zstd.decompress(data[...], size: maxSize, maxWindow: maxWindow)
        } catch AffinityError.malformed(let m) where m.contains("size mismatch") {
            throw .sizeMismatch
        } catch {
            throw .corrupt
        }
    }

    /// Decodes every concatenated frame in `data` into exactly `expectedSize` bytes.
    public static func decompress(_ data: [UInt8], expectedSize: Int, maxWindow: UInt64 = 64 << 20) throws(Failure) -> [UInt8] {
        do {
            let out = try Zstd.decompress(data[...], size: expectedSize, maxWindow: maxWindow)
            guard out.count == expectedSize else { throw Failure.sizeMismatch }
            return out
        } catch let e as Failure {
            throw e
        } catch AffinityError.malformed(let m) where m.contains("size mismatch") {
            throw .sizeMismatch
        } catch {
            throw .corrupt
        }
    }
}
