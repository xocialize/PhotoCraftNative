// PSD export and the files a linked smart object names. The path comes from the document, so what
// it points at is checked before it is read or embedded.
// Ported from the tests photocraft added after this port's base (crates/io/src/psd_export.rs
// `a_linked_fifo_is_not_read`, crates/engine/src/doc_path/tests.rs), MIT OR Apache-2.0, © ArtCraft
// Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFormat
import PCFoundation
import Testing
@testable import PCIO

@Suite struct LinkedSourceSafetyTests {
    typealias Kit = FlatKit

    static func tempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pcio-linked-\(tag)-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func docLinking(_ path: String) -> Document {
        var d = genDoc(.rgb, .u8, .pixels)
        let so = SmartObject(source: .linked(path: path), transform: .identity, cache: pattern(d.pixelFormat, rect(1, 1, 6, 4), 42, true))
        d.layers.append(Layer(name: "Linked", content: .smart(so)))
        return d
    }

    /// photocraft `712d463f8` `a_linked_fifo_is_not_read`: opening a FIFO for reading blocks until
    /// a writer appears, so the export would never return. It finishes and writes the layer as
    /// pixels, saying why.
    @Test(.timeLimit(.minutes(1))) func aLinkedFifoIsNotRead() throws {
        let dir = try Self.tempDir("fifo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("link.png").path
        #expect(mkfifo(fifo, 0o600) == 0, "mkfifo failed")
        let out = try Kit.export(Self.docLinking(fifo), "x.psd")
        #expect(out.warnings.contains { $0.contains("smart object written as pixels") && $0.contains("not a regular file") }, "\(out.warnings)")
    }

    /// A device that never ends is refused the same way.
    @Test(.timeLimit(.minutes(1))) func aLinkedDeviceIsNotRead() throws {
        let out = try Kit.export(Self.docLinking("/dev/zero"), "x.psd")
        #expect(out.warnings.contains { $0.contains("smart object written as pixels") && $0.contains("not a regular file") }, "\(out.warnings)")
    }

    /// photocraft `5ca6fc776`: a linked file no importer can decode (a text or settings file the
    /// link happened to point at) is not embedded in the export.
    @Test func aLinkedFileThatIsNotAnImageIsNotEmbedded() throws {
        let dir = try Self.tempDir("text")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = "not-an-image-0123456789-do-not-embed"
        let file = dir.appendingPathComponent("notes.txt")
        try Data(secret.utf8).write(to: file)
        let out = try Kit.export(Self.docLinking(file.path), "x.psd")
        #expect(out.warnings.contains { $0.contains("smart object written as pixels") && $0.contains("is not an image") }, "\(out.warnings)")
        #expect(out.bytes.firstRange(of: Array(secret.utf8)) == nil, "the file's bytes are in the export")
    }

    /// The reader itself: regular files only, a directory keeps its own error.
    @Test func readFileRefusesWhatIsNotARegularFile() throws {
        #expect(throws: IOError.self) { try FileRead.readFile(URL(fileURLWithPath: "/dev/null")) }
        #expect(throws: IOError.self) { try FileRead.readFile(FileManager.default.temporaryDirectory) }
        let dir = try Self.tempDir("plain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.bin")
        try Data([1, 2, 3]).write(to: file)
        #expect(try FileRead.readFile(file) == [1, 2, 3])
    }
}
