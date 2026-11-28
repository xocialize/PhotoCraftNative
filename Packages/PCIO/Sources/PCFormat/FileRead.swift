// Reading a whole file to open it: the read side of `AtomicSave`.
//
// What it adds over reading in one go for multi-gigabyte PSB files:
// - Bounded reads: each read asks for at most `readChunk` bytes (some file systems reject very
//   large single reads).
// - A clear out-of-memory error: a file larger than the memory available says how much it needed
//   instead of trapping in the allocator.
// Port of photocraft-format (crates/format/src/read.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.

import Foundation

/// A source of bytes read in chunks (Rust's `Read`): `read` returns at most `maxCount` bytes, and
/// an empty array at the end.
public protocol ChunkReader {
    mutating func read(_ maxCount: Int) throws(IOError) -> [UInt8]
}

/// Reads an open file descriptor (not closed by the reader).
public struct FileDescriptorReader: ChunkReader {
    public let fd: Int32
    public init(fd: Int32) { self.fd = fd }

    public mutating func read(_ maxCount: Int) throws(IOError) -> [UInt8] {
        let n = max(0, min(maxCount, FileRead.readChunk))
        if n == 0 { return [] }
        var buf = [UInt8](repeating: 0, count: n)
        while true {
            let got = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, n) }
            if got < 0 {
                if errno == EINTR { continue }
                throw IOError.last("read")
            }
            buf.removeLast(n - got)
            return buf
        }
    }
}

/// Reads bytes in memory.
public struct MemoryChunkReader: ChunkReader {
    public var bytes: [UInt8]
    public var position = 0
    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public mutating func read(_ maxCount: Int) throws(IOError) -> [UInt8] {
        let n = min(max(0, maxCount), bytes.count - position)
        defer { position += n }
        return Array(bytes[position ..< position + n])
    }
}

public enum FileRead {
    /// Largest single read: big enough that a 5 GB file takes under a hundred reads.
    public static let readChunk = 64 << 20

    /// The most any one open reads (photocraft `MAX_OPEN_BYTES`), so a file that keeps growing
    /// while it is read still ends.
    public static let maxOpenBytes: UInt64 = 1 << 38

    /// Reads all of the file at `url`, in reads of at most `readChunk` bytes and `maxOpenBytes`
    /// in all. Anything but a regular file is refused without being read: opening a FIFO for
    /// reading would wait for a writer, and a device such as `/dev/zero` never ends (photocraft
    /// `712d463f8`).
    public static func readFile(_ url: URL) throws(IOError) -> [UInt8] {
        try readFile(url, chunk: readChunk)
    }

    /// `readFile` with a chosen read size (tests use small ones to exercise the loop).
    public static func readFile(_ url: URL, chunk: Int) throws(IOError) -> [UInt8] {
        // Non-blocking, so the open itself cannot wait on a FIFO; what was opened is then checked,
        // not the name.
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 { throw IOError.last(url.path) }
        defer { close(fd) }
        var st = stat()
        if fstat(fd, &st) != 0 { throw IOError.last(url.path) }
        if st.st_mode & S_IFMT == S_IFDIR { throw IOError(errno: EISDIR, url.path) }
        if st.st_mode & S_IFMT != S_IFREG { throw IOError(.invalidInput, "\(url.path): not a regular file") }
        // It is a regular file: back to ordinary blocking reads, as photocraft's `read_path` does.
        _ = fcntl(fd, F_SETFL, 0)
        let len = UInt64(max(0, st.st_size))
        var r = FileDescriptorReader(fd: fd)
        return try readAll(&r, sizeHint: min(len, maxOpenBytes), chunk: chunk, limit: maxOpenBytes)
    }

    /// Reads `reader` to its end in reads of at most `readChunk` bytes. `sizeHint` (the file's
    /// length) sizes the buffer up front; a file that grows or shrinks while being read is still
    /// read to its end.
    public static func readAll<R: ChunkReader>(_ reader: inout R, sizeHint: UInt64) throws(IOError) -> [UInt8] {
        try readAll(&reader, sizeHint: sizeHint, chunk: readChunk)
    }

    static func readAll<R: ChunkReader>(_ reader: inout R, sizeHint: UInt64, chunk: Int, limit: UInt64 = .max) throws(IOError) -> [UInt8] {
        var buf = try bufferFor(sizeHint)
        let chunk = max(chunk, 1)
        while UInt64(buf.count) < limit {
            let want = Int(min(UInt64(chunk), limit - UInt64(buf.count)))
            let part = try reader.read(want)
            if part.isEmpty { break }
            buf += part
        }
        return buf
    }

    /// An empty buffer with room for `len` bytes, or an out-of-memory error saying how much was
    /// needed (Swift cannot recover from a failed allocation, so sizes beyond physical memory are
    /// refused up front).
    public static func bufferFor(_ len: UInt64) throws(IOError) -> [UInt8] {
        guard len <= ProcessInfo.processInfo.physicalMemory, let n = Int(exactly: len) else {
            throw IOError(.outOfMemory, "not enough memory to read the whole file (\(sizeText(len)))")
        }
        var buf = [UInt8]()
        buf.reserveCapacity(n)
        return buf
    }

    /// `len` bytes for people: "4.75 GB", "759.00 MB", "12 bytes".
    static func sizeText(_ len: UInt64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var v = Double(len)
        var unit = 0
        while v >= 1000 && unit + 1 < units.count {
            v /= 1000
            unit += 1
        }
        return unit > 0 ? String(format: "%.2f %@", v, units[unit]) : "\(len) bytes"
    }

    /// Reads one opened bundle entry under its `max` budget. The stat `len` is a buffer hint only
    /// (files can change while open, and a FIFO reports 0), so the bound is enforced on the read
    /// itself, never on the hint (photocraft `store::read_entry`).
    public static func readEntry<R: ChunkReader>(_ reader: inout R, len: UInt64, max: Int, path: String) throws(FormatError) -> [UInt8] {
        let limit = UInt64(max).addingReportingOverflow(1).overflow ? UInt64.max : UInt64(max) + 1
        let hint = min(len, limit)
        let bytes: [UInt8]
        do throws(IOError) {
            bytes = try readAll(&reader, sizeHint: hint, chunk: readChunk, limit: limit)
        } catch {
            throw .io(error)
        }
        if bytes.count > max { throw .limitExceeded("`\(path)` exceeds \(max) bytes") }
        return bytes
    }
}
