// The two forms of a `.pcraft` bundle and the Uniform Type Identifiers macOS knows them by
// (AB-D-0131, AB-T-0240).
//
// One extension, two forms, two types, as iWork does for `.pages`:
//
//   form         identifier                            conforms to                          declared by
//   package      com.xocialize.pcraft.package          com.apple.package,                   the editor app (exported)
//                                                      public.composite-content
//   single file  ai.storyteller.photocraft.document    public.data, public.image            photocraft (exported);
//                                                                                           the editor app imports it
//
// The package (directory form) is the default Save. Saves are incremental (only new tiles are
// written), there is no size limit, and the manifest is replaced atomically. Finder shows it as one
// file because its type conforms to com.apple.package. The single-file form is one ZIP, kept for
// sharing (Save a Copy). It is rewritten whole on every save and is ZIP64 past 4 GiB. Its type is
// photocraft's, so the app imports photocraft's declaration rather than exporting a rival one: when
// photocraft is installed its declaration wins, and both apps agree on what a `.pcraft` file is.
// Launch Services gives a `.pcraft` folder the package type and a `.pcraft` file the single-file one.
//
// A type's conformance comes from the declaring app's Info.plist: in a process without it (a test, a
// command-line tool), `packageType` names the type but the system knows nothing it conforms to. The
// declarations below are therefore data the app copies into its Info.plist, and
// `declarationProblems(in:)` checks a bundle's copy against them.

import Foundation
import UniformTypeIdentifiers

extension PcraftFormat {
    /// How a `.pcraft` bundle is stored on disk.
    public enum Container: String, Sendable, CaseIterable {
        /// A folder (a macOS document package): the default Save.
        case package
        /// One ZIP file, for sharing.
        case singleFile

        /// The form's Uniform Type Identifier.
        public var typeIdentifier: String {
            switch self {
            case .package: PcraftFormat.packageTypeIdentifier
            case .singleFile: PcraftFormat.singleFileTypeIdentifier
            }
        }

        /// The form's type (its conformance is known only where an Info.plist declares it).
        public var type: UTType {
            switch self {
            case .package: PcraftFormat.packageType
            case .singleFile: PcraftFormat.singleFileType
            }
        }
    }

    /// The package form's identifier, exported by the editor app.
    public static let packageTypeIdentifier = "com.xocialize.pcraft.package"
    /// The single-file form's identifier: photocraft's own, imported.
    public static let singleFileTypeIdentifier = "ai.storyteller.photocraft.document"
    /// What the package type conforms to: a document package, whose content is a composite of
    /// several files.
    public static let packageConformsTo: [UTType] = [.package, .compositeContent]
    /// What the single-file type conforms to, as photocraft declares it.
    public static let singleFileConformsTo: [UTType] = [.data, .image]
    /// The MIME type photocraft gives the single file.
    public static let singleFileMIMEType = "application/x-photocraft"
    /// What Finder shows as the kind of either form.
    public static let typeDescription = "PhotoCraft Document"

    /// The package form's type, as the declaring app sees it.
    public static var packageType: UTType { UTType(exportedAs: packageTypeIdentifier, conformingTo: .package) }
    /// The single-file form's type, as an app that imports photocraft's declaration sees it.
    public static var singleFileType: UTType { UTType(importedAs: singleFileTypeIdentifier, conformingTo: .data) }

    /// The form of the bundle at `url` (following symlinks), or nil when nothing is there.
    public static func container(at url: URL) -> Container? {
        switch FS.kindFollowing(url.path) {
        case .directory?: .package
        case nil: nil
        default: .singleFile
        }
    }

    // MARK: Info.plist declarations

    /// The app's `UTExportedTypeDeclarations` entry for the package form.
    public static var exportedTypeDeclaration: [String: Any] {
        [
            "UTTypeIdentifier": packageTypeIdentifier,
            "UTTypeDescription": typeDescription,
            "UTTypeConformsTo": packageConformsTo.map(\.identifier),
            "UTTypeTagSpecification": ["public.filename-extension": [fileExtension]],
        ]
    }

    /// The app's `UTImportedTypeDeclarations` entry for the single-file form (photocraft's).
    public static var importedTypeDeclaration: [String: Any] {
        [
            "UTTypeIdentifier": singleFileTypeIdentifier,
            "UTTypeDescription": typeDescription,
            "UTTypeConformsTo": singleFileConformsTo.map(\.identifier),
            "UTTypeTagSpecification": ["public.filename-extension": [fileExtension], "public.mime-type": [singleFileMIMEType]],
        ]
    }

    /// The app's `CFBundleDocumentTypes` entries: it edits both forms, owns the package and is a
    /// default handler of photocraft's single file. (Package-ness comes from the type's
    /// conformance, not `LSTypeIsPackage`.) A document-based app adds its own keys, such as
    /// `NSDocumentClass`.
    public static var documentTypeDeclarations: [[String: Any]] {
        [
            ["CFBundleTypeName": typeDescription, "CFBundleTypeRole": "Editor", "LSHandlerRank": "Owner",
             "LSItemContentTypes": [packageTypeIdentifier]],
            ["CFBundleTypeName": "\(typeDescription) (single file)", "CFBundleTypeRole": "Editor", "LSHandlerRank": "Default",
             "LSItemContentTypes": [singleFileTypeIdentifier]],
        ]
    }

    /// What is wrong with an Info.plist's `.pcraft` declarations (empty when they match these):
    /// for the app's own tests, e.g. `declarationProblems(in: Bundle.main.infoDictionary ?? [:])`.
    public static func declarationProblems(in info: [String: Any]) -> [String] {
        var problems: [String] = []
        func check(_ key: String, _ want: [String: Any]) {
            let id = want["UTTypeIdentifier"] as? String ?? ""
            let list = info[key] as? [[String: Any]] ?? []
            guard let got = list.first(where: { $0["UTTypeIdentifier"] as? String == id }) else {
                problems.append("\(key) has no \(id)")
                return
            }
            let conforms = Set(got["UTTypeConformsTo"] as? [String] ?? [])
            for c in want["UTTypeConformsTo"] as? [String] ?? [] where !conforms.contains(c) {
                problems.append("\(id) does not conform to \(c)")
            }
            let tags = got["UTTypeTagSpecification"] as? [String: Any] ?? [:]
            if !(tags["public.filename-extension"] as? [String] ?? []).contains(fileExtension) {
                problems.append("\(id) does not claim the .\(fileExtension) extension")
            }
        }
        check("UTExportedTypeDeclarations", exportedTypeDeclaration)
        check("UTImportedTypeDeclarations", importedTypeDeclaration)
        if (info["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []).contains(where: { $0["UTTypeIdentifier"] as? String == singleFileTypeIdentifier }) {
            problems.append("\(singleFileTypeIdentifier) is photocraft's: import it, don't export it")
        }
        let documents = info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        let handled = Set(documents.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        for id in [packageTypeIdentifier, singleFileTypeIdentifier] where !handled.contains(id) {
            problems.append("CFBundleDocumentTypes doesn't list \(id)")
        }
        return problems
    }
}
