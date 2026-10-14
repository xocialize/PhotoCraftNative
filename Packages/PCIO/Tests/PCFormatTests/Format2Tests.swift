// `.pcraft` format 2 (AB-T-0240): ZIP64 single files, the version each form writes, the v1 → v2
// migration, the package form's type declarations and incremental saves.

import Foundation
@testable import PCFormat
import PCDocument
import PCFoundation
import PCIOCore
import Testing

@Suite struct Format2Tests {
    static func manifestText(_ bytes: [UInt8]) throws -> String {
        String(decoding: try ZipReader(bytes).read(named: "manifest.json", max: .max), as: UTF8.self)
    }

    /// A bundle that fits classic ZIP is photocraft's format 1, byte for byte the layout it reads.
    @Test func classicSingleFilesStayFormat1() throws {
        let bytes = try save(richDoc(.rgb, .u8))
        #expect(try !ZipReader(bytes).isZip64)
        #expect(try Self.manifestText(bytes).contains("\"format_version\": 1,"))
    }

    /// A single file that needs ZIP64 says format 2 and reopens equal (forced here; the real
    /// thing is `Zip64BigTests`).
    @Test func zip64SingleFilesAreFormat2AndRoundTrip() throws {
        let doc = richDoc(.cmyk, .u16)
        let w = PcraftWriter()
        w.forceZip64 = true
        let (bytes, stats) = try w.saveZip(doc)
        #expect(stats.tilesWritten == stats.tilesTotal)
        let zip = try ZipReader(bytes)
        #expect(zip.isZip64)
        #expect(zip.entries.first?.name == "manifest.json")
        #expect(try Self.manifestText(bytes).contains("\"format_version\": 2,"))
        #expect(PcraftFormat.isPcraft(bytes))
        #expect(try load(bytes) == doc)
        #expect(try PcraftFormat.readManifest(bytes).formatVersion == 2)
        // An incremental resave reuses every object (and its CRC) and stays format 2.
        let (again, s2) = try w.saveZip(doc)
        #expect(s2.tilesWritten == 0 && s2.tilesReused == s2.tilesTotal)
        #expect(again == bytes)
    }

    /// Format 1 bundles (photocraft's, and every earlier save) open, migrated to 2 without a change
    /// to the document; a format newer than 2 is refused.
    @Test func format1OpensAndFormat3IsRefused() throws {
        let doc = richDoc(.rgb, .f32)
        let v1 = try save(doc)
        #expect(try Self.manifestText(v1).contains("\"format_version\": 1,"))
        #expect(try load(v1) == doc)
        let m = try PcraftFormat.readManifest(v1)
        #expect(m.formatVersion == PcraftFormat.formatVersion)
        // The same manifest saying 2, in a classic archive, loads the same: the version describes
        // what the container may be, not the document.
        let v2 = try withManifest(v1) { $0["format_version"] = 2 }
        #expect(try load(v2) == doc)
        #expect(try PcraftFormat.readManifest(v2).document == m.document)
        let v3 = try withManifest(v1) { $0["format_version"] = 3 }
        #expect { try load(v3) } throws: { e in
            if case FormatError.tooNew(found: 3, supported: 2) = e { return true }
            return false
        }
    }

    @Test func v1ToV2MigrationChangesOnlyTheVersion() throws {
        let text = #"{"format_version":1,"generator":"photocraft-format 0.1.0","document":{"id":18446744073709551615,"x":0.30000001192092896}}"#
        var v = try JSONTree.parse(Array(text.utf8))
        let before = v
        #expect(try Migrate.migrate(&v) == 1)
        #expect(v["format_version"] == .number("2"))
        v["format_version"] = .number("1")
        #expect(v == before)
    }

    @Test func packageAndSingleFileFormsSaveAndReopen() throws {
        let doc = richDoc(.rgb, .u16)
        let dir = tempDir("forms")
        defer { remove(dir) }
        let package = dir.appendingPathComponent("a.pcraft"), single = dir.appendingPathComponent("b.pcraft")
        #expect(PcraftFormat.container(at: package) == nil)
        try PcraftWriter().save(doc, to: package, as: .package)
        try PcraftWriter().save(doc, to: single, as: .singleFile)
        #expect(PcraftFormat.container(at: package) == .package)
        #expect(PcraftFormat.container(at: single) == .singleFile)
        #expect(try PcraftFormat.load(contentsOf: package) == doc)
        #expect(try PcraftFormat.load(contentsOf: single) == doc)
        // A package is photocraft's format 1 too.
        let manifest = try String(contentsOf: package.appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(manifest.contains("\"format_version\": 1,"))
    }

    /// A package save writes only the tiles that changed: every other object file keeps its inode
    /// and modification time, also for a fresh writer (the document reopened later).
    @Test func packageSavesWriteOnlyNewTiles() throws {
        var doc = richDoc(.rgb, .u8)
        let dir = tempDir("incremental").appendingPathComponent("doc.pcraft")
        defer { remove(dir.deletingLastPathComponent()) }
        let first = try PcraftWriter().save(doc, to: dir, as: .package)
        let tiles = dir.appendingPathComponent("tiles")
        func snapshot() throws -> [String: [String]] {
            var out: [String: [String]] = [:]
            for name in try FS.list(tiles.path) {
                let a = try FileManager.default.attributesOfItem(atPath: tiles.appendingPathComponent(name).path)
                out[name] = ["\(a[.systemFileNumber] ?? "")", "\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"]
            }
            return out
        }
        let before = try snapshot()
        #expect(before.count == first.tilesTotal)
        let id = doc.layers[1].id
        doc.withRaster(of: id) { $0.setPixel(x: 3, y: 3, [0.5, 0.25, 0.75, 1]) }
        let stats = try PcraftWriter().save(doc, to: dir, as: .package)
        #expect(stats.tilesWritten == 1)
        #expect(stats.tilesReused == stats.tilesTotal - 1)
        #expect(stats.objectsRemoved == 1, "the edited tile's old version is collected")
        let after = try snapshot()
        let added = Set(after.keys).subtracting(before.keys), removed = Set(before.keys).subtracting(after.keys)
        #expect(added.count == 1 && removed.count == 1)
        for (name, sig) in after where !added.contains(name) { #expect(before[name] == sig, "\(name) was rewritten") }
        #expect(try PcraftFormat.load(contentsOf: dir) == doc)
    }
}

@Suite struct PcraftTypeTests {
    /// The Info.plist a correctly declared app carries.
    static var goodInfo: [String: Any] {
        [
            "UTExportedTypeDeclarations": [PcraftFormat.exportedTypeDeclaration],
            "UTImportedTypeDeclarations": [PcraftFormat.importedTypeDeclaration],
            "CFBundleDocumentTypes": PcraftFormat.documentTypeDeclarations,
        ]
    }

    @Test func thePackageTypeIsADocumentPackage() throws {
        #expect(PcraftFormat.Container.package.typeIdentifier == "com.xocialize.pcraft.package")
        #expect(PcraftFormat.packageType.identifier == PcraftFormat.packageTypeIdentifier)
        #expect(PcraftFormat.packageConformsTo.map(\.identifier) == ["com.apple.package", "public.composite-content"])
        #expect(PcraftFormat.exportedTypeDeclaration["UTTypeConformsTo"] as? [String] == ["com.apple.package", "public.composite-content"])
        // The single file is photocraft's type, declared as photocraft declares it.
        #expect(PcraftFormat.Container.singleFile.typeIdentifier == "ai.storyteller.photocraft.document")
        #expect(PcraftFormat.importedTypeDeclaration["UTTypeConformsTo"] as? [String] == ["public.data", "public.image"])
        // Both claim the extension, and the declarations are valid property lists.
        for d in [PcraftFormat.exportedTypeDeclaration, PcraftFormat.importedTypeDeclaration] {
            #expect((d["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"] as? [String] == ["pcraft"])
        }
        let data = try PropertyListSerialization.data(fromPropertyList: Self.goodInfo, format: .xml, options: 0)
        let back = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        #expect(PcraftFormat.declarationProblems(in: back ?? [:]).isEmpty)
    }

    @Test func declarationProblemsNameWhatIsWrong() {
        #expect(PcraftFormat.declarationProblems(in: [:]).count == 4)
        var flat = PcraftFormat.exportedTypeDeclaration
        flat["UTTypeConformsTo"] = ["public.data"]
        var info = Self.goodInfo
        info["UTExportedTypeDeclarations"] = [flat, PcraftFormat.importedTypeDeclaration]
        #expect(PcraftFormat.declarationProblems(in: info) == [
            "com.xocialize.pcraft.package does not conform to com.apple.package",
            "com.xocialize.pcraft.package does not conform to public.composite-content",
            "ai.storyteller.photocraft.document is photocraft's: import it, don't export it",
        ])
    }
}
