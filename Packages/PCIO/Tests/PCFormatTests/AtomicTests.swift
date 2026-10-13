// Crash-safe file replacement with injected failures.
// Port of photocraft-format (crates/format/src/atomic/tests.rs), MIT OR Apache-2.0, © ArtCraft Team
// and the PhotoCraft contributors.

import Foundation
@testable import PCFormat
import Synchronization
import Testing

@Suite struct AtomicTests {
    static let original = Array("the user's precious original document".utf8)
    static let noRetry = RenameRetry(attempts: 0, firstDelayMs: 0)

    /// Only the target remains: no temporary file was left behind.
    static func assertNoTemp(_ dir: URL) {
        let leftovers = ((try? FS.list(dir.path)) ?? []).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty, "temporary files left behind: \(leftovers)")
    }

    static func read(_ url: URL) -> [UInt8] { (try? FS.read(url.path)) ?? [] }

    /// The real file system with failures injected at chosen steps.
    final class Faulty: AtomicFS, @unchecked Sendable {
        /// Write this many bytes, then fail like a full disk.
        var failWriteAfter: Int?
        /// Fail every rename with this error.
        var failRename: IOError?
        /// Fail the first N renames with "permission denied" (a transient lock), then succeed.
        var lockedRenames = 0
        var renames = 0

        func writeNew(_ tmp: String, _ bytes: [UInt8]) throws(IOError) {
            if let n = failWriteAfter {
                let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o666)
                if fd < 0 { throw IOError.last(tmp) }
                defer { close(fd) }
                try AtomicSave.writeAll(fd, bytes, 0, min(n, bytes.count), tmp)
                throw IOError(.storageFull, "injected: no space left on device", code: ENOSPC)
            }
            try RealFS().writeNew(tmp, bytes)
        }

        func rename(_ from: String, _ to: String) throws(IOError) {
            renames += 1
            if let e = failRename { throw e }
            if lockedRenames > 0 {
                lockedRenames -= 1
                throw IOError(.permissionDenied, "injected: sharing violation", code: EACCES)
            }
            try RealFS().rename(from, to)
        }

        func remove(_ path: String) throws(IOError) { try RealFS().remove(path) }
        func syncDir(_ dir: String) throws(IOError) { try RealFS().syncDir(dir) }
        func copyPermissions(_ from: String, _ to: String) throws(IOError) { try RealFS().copyPermissions(from, to) }
    }

    @Test func replacesAndCreates() throws {
        let d = tempDir("atomic-ok")
        let p = d.appendingPathComponent("doc.psd")
        try AtomicSave.atomicWrite(p, Array("first".utf8))
        #expect(AtomicTests.read(p) == Array("first".utf8))
        try AtomicSave.atomicWrite(p, Array("second, longer".utf8))
        #expect(AtomicTests.read(p) == Array("second, longer".utf8))
        AtomicTests.assertNoTemp(d)
        remove(d)
    }

    /// A large write reports how far it has got, chunk by chunk, up to 1.0, and writes the same
    /// bytes as a plain atomic write.
    @Test func reportsWriteProgress() throws {
        let d = tempDir("atomic-progress")
        let p = d.appendingPathComponent("big.psd")
        let bytes = (0 ..< RealFS.writeChunk * 2 + 123).map { UInt8($0 % 251) }
        var seen: [Float] = []
        try AtomicSave.atomicWriteProgress(p, bytes) { seen.append($0) }
        #expect(seen.count == 3, "one report per chunk: \(seen)")
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 < $1 }, "monotonic: \(seen)")
        #expect(seen[0] > 0 && seen[0] < 0.6, "\(seen)")
        #expect(seen.last == 1)
        #expect(AtomicTests.read(p) == bytes, "the file holds the bytes")
        AtomicTests.assertNoTemp(d)
        remove(d)
    }

    @Test func createsMissingParentFolders() throws {
        let d = tempDir("atomic-parent")
        let p = d.appendingPathComponent("a/b/out.png")
        try AtomicSave.atomicWrite(p, Array("x".utf8))
        #expect(AtomicTests.read(p) == Array("x".utf8))
        remove(d)
    }

    @Test func writeFailureHalfwayKeepsOriginal() throws {
        let d = tempDir("atomic-write")
        let p = d.appendingPathComponent("doc.psd")
        try Data(AtomicTests.original).write(to: p)
        let fs = Faulty()
        fs.failWriteAfter = 5
        do throws(IOError) {
            try AtomicSave.atomicWriteWith(fs, AtomicTests.noRetry, p.path, [UInt8](repeating: 7, count: 4096))
            Issue.record("the write must fail")
        } catch {
            #expect(error.kind == .storageFull)
            #expect(error.message.contains("not changed"), "\(error)")
        }
        #expect(AtomicTests.read(p) == AtomicTests.original)
        #expect(fs.renames == 0, "never renames after a failed write")
        AtomicTests.assertNoTemp(d)
        remove(d)
    }

    @Test func renameFailureKeepsOriginal() throws {
        let d = tempDir("atomic-rename")
        let p = d.appendingPathComponent("doc.psd")
        try Data(AtomicTests.original).write(to: p)
        let fs = Faulty()
        fs.failRename = IOError(.other, "injected rename failure")
        #expect(throws: IOError.self) { try AtomicSave.atomicWriteWith(fs, AtomicTests.noRetry, p.path, Array("new".utf8)) }
        #expect(AtomicTests.read(p) == AtomicTests.original)
        AtomicTests.assertNoTemp(d)
        remove(d)
    }

    @Test func crossDeviceRenameErrorsClearlyAndNeverWritesInPlace() throws {
        let d = tempDir("atomic-exdev")
        let p = d.appendingPathComponent("doc.psd")
        try Data(AtomicTests.original).write(to: p)
        let fs = Faulty()
        fs.failRename = IOError(errno: EXDEV, "rename")
        do throws(IOError) {
            try AtomicSave.atomicWriteWith(fs, AtomicTests.noRetry, p.path, Array("new".utf8))
            Issue.record("the rename must fail")
        } catch {
            #expect(error.message.contains("different volume"), "\(error)")
        }
        #expect(AtomicTests.read(p) == AtomicTests.original)
        AtomicTests.assertNoTemp(d)
        remove(d)
    }

    @Test func lockedTargetRenameIsRetried() throws {
        let d = tempDir("atomic-locked")
        let p = d.appendingPathComponent("doc.psd")
        try Data(AtomicTests.original).write(to: p)
        let fs = Faulty()
        fs.lockedRenames = 2
        try AtomicSave.atomicWriteWith(fs, RenameRetry(attempts: 3, firstDelayMs: 1), p.path, Array("new".utf8))
        #expect(AtomicTests.read(p) == Array("new".utf8))
        #expect(fs.renames == 3)
        AtomicTests.assertNoTemp(d)
        remove(d)
    }

    @Test func lockThatOutlastsTheRetriesKeepsOriginal() throws {
        let d = tempDir("atomic-locked2")
        let p = d.appendingPathComponent("doc.psd")
        try Data(AtomicTests.original).write(to: p)
        let fs = Faulty()
        fs.lockedRenames = 10
        do throws(IOError) {
            try AtomicSave.atomicWriteWith(fs, RenameRetry(attempts: 2, firstDelayMs: 1), p.path, Array("new".utf8))
            Issue.record("the rename must fail")
        } catch {
            #expect(error.kind == .permissionDenied)
            #expect(error.message.contains("locked"), "\(error)")
        }
        #expect(fs.renames == 3)
        #expect(AtomicTests.read(p) == AtomicTests.original)
        AtomicTests.assertNoTemp(d)
        remove(d)
    }

    @Test func readOnlyFolderErrorsClearlyAndNeverWritesInPlace() throws {
        let d = tempDir("atomic-ro")
        let p = d.appendingPathComponent("doc.psd")
        try Data(AtomicTests.original).write(to: p)
        // The file itself stays writable: an in-place fallback would succeed and must not happen.
        chmod(d.path, 0o555)
        defer {
            chmod(d.path, 0o755)
            remove(d)
        }
        if FileManager.default.createFile(atPath: d.appendingPathComponent("probe").path, contents: nil) {
            return // running as root: permissions aren't enforced
        }
        do throws(IOError) {
            try AtomicSave.atomicWrite(p, Array("new".utf8))
            Issue.record("the save must fail")
        } catch {
            #expect(error.kind == .permissionDenied)
            #expect(error.message.contains("not writable"), "\(error)")
        }
        #expect(AtomicTests.read(p) == AtomicTests.original)
        AtomicTests.assertNoTemp(d)
    }

    @Test func keepsTheOriginalFileMode() throws {
        let d = tempDir("atomic-mode")
        let p = d.appendingPathComponent("doc.psd")
        try Data(AtomicTests.original).write(to: p)
        chmod(p.path, 0o600)
        try AtomicSave.atomicWrite(p, Array("new".utf8))
        var st = stat()
        stat(p.path, &st)
        #expect(st.st_mode & 0o777 == 0o600)
        remove(d)
    }

    @Test func writesThroughASymlink() throws {
        let d = tempDir("atomic-link")
        let real = d.appendingPathComponent("real.psd")
        let link = d.appendingPathComponent("link.psd")
        try Data(AtomicTests.original).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try AtomicSave.atomicWrite(link, Array("new".utf8))
        #expect(try FS.lkind(link.path) == .symlink)
        #expect(AtomicTests.read(real) == Array("new".utf8))
        remove(d)
    }

    @Test func directoryTargetOrBareRootIsAnErrorNotATrap() throws {
        let d = tempDir("atomic-dir")
        #expect(throws: IOError.self) { try AtomicSave.atomicWrite(d, Array("x".utf8)) }
        #expect(throws: IOError.self) { try AtomicSave.atomicWriteWith(RealFS(), .platform, "/", Array("x".utf8)) }
        #expect(throws: IOError.self) { try AtomicSave.atomicWriteWith(RealFS(), .platform, "", Array("x".utf8)) }
        remove(d)
    }

    /// A share that refuses the full flush (`F_FULLFSYNC`) still saves through a plain fsync;
    /// every other sync error still fails the save.
    @Test func aRefusedFullFlushFallsBackToAPlainFsync() throws {
        func refused(_ errno: Int32) -> Result<Void, IOError> { .failure(IOError(errno: errno, "F_FULLFSYNC")) }
        for (errno, name) in [(ENOTSUP, "ENOTSUP, SMB"), (ENOTTY, "ENOTTY")] {
            var fsynced = false
            let r = Result { () throws(IOError) in try AtomicSave.orPlainFsync(refused(errno)) { () throws(IOError) in fsynced = true } }
            #expect((try? r.get()) != nil, "\(name)")
            #expect(fsynced, "\(name): the plain fsync runs")
        }
        // The plain fsync's own failure is reported.
        let failed = Result { () throws(IOError) in try AtomicSave.orPlainFsync(refused(ENOTSUP)) { () throws(IOError) in throw IOError(errno: EIO, "fsync") } }
        if case .failure(let e) = failed { #expect(e.code == EIO) } else { Issue.record("the fsync failure was lost") }
        // Real errors (EIO, ENOSPC, EACCES) never fall back, and success needs no fallback.
        for errno in [EIO, ENOSPC, EACCES] {
            let r = Result { () throws(IOError) in
                try AtomicSave.orPlainFsync(refused(errno)) { () throws(IOError) in Issue.record("no fallback for errno \(errno)") }
            }
            if case .failure(let e) = r { #expect(e.code == errno) } else { Issue.record("errno \(errno) passed") }
        }
        try AtomicSave.orPlainFsync(.success(())) { () throws(IOError) in Issue.record("no fallback after a full flush") }
    }

    @Test func syncFileFlushesALocalFile() throws {
        let d = tempDir("atomic-sync")
        let path = d.appendingPathComponent("f.bin").path
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        #expect(fd >= 0)
        defer { close(fd) }
        try AtomicSave.syncFile(fd)
        remove(d)
    }

    @Test func tempNamesAreUniqueHiddenAndShort() {
        let a = AtomicSave.tempName(String(repeating: "n", count: 300)), b = AtomicSave.tempName("doc.psd")
        #expect(a.hasPrefix(".") && a.hasSuffix(".pcsave.tmp") && a.count < 100)
        #expect(b.hasPrefix(".doc.psd.\(getpid())-"))
        #expect(AtomicSave.tempName("x") != AtomicSave.tempName("x"))
    }
}
