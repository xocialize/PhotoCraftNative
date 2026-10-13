// Port of photocraft-io (crates/io/tests/tiff_pages.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Multi-page TIFF and BigTIFF through `DocumentIO.importFile`: the default page is the first
// full-resolution one (like Photoshop), and a BigTIFF's orientation is applied (#693).
// photocraft's `import_tiff_page` (any page by index) and `codecs::tiff_info` have no PCIO
// counterpart; those assertions are left out.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Testing
@testable import PCIO

@Suite struct TIFFPagesTests {
    init() { ExportSweep.install() }
    typealias Kit = FlatKit

    /// A little-endian TIFF (classic or BigTIFF) with one 8-bit gray page per `(w, h, level,
    /// NewSubfileType, orientation)`, chained in order.
    static func tiff(big: Bool, _ pages: [(Int, Int, UInt8, UInt32, UInt16)]) -> [UInt8] {
        func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0 ..< n).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }
        var f: [UInt8] = Array("II".utf8)
        if big {
            f += le(43, 2) + le(8, 2) + le(0, 2) + le(0, 8)
        } else {
            f += le(42, 2) + le(0, 4)
        }
        var nextField = big ? 8 : 4
        let width = big ? 8 : 4
        for (w, h, level, kind, orientation) in pages {
            let pixelsAt = UInt64(f.count)
            f += [UInt8](repeating: level, count: w * h)
            if f.count % 2 == 1 { f.append(0) }
            let ifdAt = UInt64(f.count)
            f.replaceSubrange(nextField ..< nextField + width, with: le(ifdAt, width))
            let entries: [(UInt16, UInt16, UInt64)] = [
                (254, 4, UInt64(kind)), (256, 4, UInt64(w)), (257, 4, UInt64(h)), (258, 3, 8), (259, 3, 1), (262, 3, 1),
                (273, 4, pixelsAt), (274, 3, UInt64(orientation)), (277, 3, 1), (278, 4, UInt64(h)), (279, 4, UInt64(w * h)),
            ]
            f += big ? le(UInt64(entries.count), 8) : le(UInt64(entries.count), 2)
            for (tag, type, v) in entries {
                f += le(UInt64(tag), 2) + le(UInt64(type), 2)
                f += big ? le(1, 8) + le(v, 8) : le(1, 4) + le(v, 4)
            }
            nextField = f.count
            f += [UInt8](repeating: 0, count: width)
        }
        return f
    }

    @Test(arguments: [false, true]) func theFirstFullResolutionPageOpens(_ big: Bool) throws {
        // A thumbnail, then two pages.
        let bytes = Self.tiff(big: big, [(2, 2, 9, 1, 1), (6, 4, 50, 0, 1), (3, 5, 90, 2, 1)])
        let r = try Kit.importFile("pages.tif", bytes)
        withKnownIssue("PCIO gap: ImageIOCodec.decode opens image 0 (here the reduced-resolution thumbnail) and reports no pages left out; photocraft opens the first full-resolution page") {
            #expect(r.document.size == PixelSize(width: 6, height: 4), "big \(big)")
            #expect(r.warnings.contains("only the first of 2 pages was imported"), "\(r.warnings)")
        }
    }

    @Test(arguments: [false, true]) func bigTIFFOrientationIsAppliedOnOpen(_ big: Bool) throws {
        // #693: Orientation 6 turns the stored 6×4 landscape into a 4×6 portrait, in both containers.
        let bytes = Self.tiff(big: big, [(6, 4, 50, 0, 6)])
        let r = try Kit.importFile("turned.tif", bytes)
        withKnownIssue("PCIO gap: ImageIO reports no orientation for a BigTIFF, and ImageIOCodec reads it only from ImageIO's properties (photocraft reads tag 274 itself)") {
            #expect(r.document.size == PixelSize(width: 4, height: 6), "big \(big)")
        } when: { big }
    }
}
