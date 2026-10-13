// swift-tools-version: 6.2
// PCPSD — standalone, lossless reader and writer for Adobe Photoshop PSD (v1) and PSB (v2) files,
// plus the Adobe asset formats that live beside it (abr, aco, ase, grd, pat, shc).
// Port of photocraft-psd (crates/psd), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors; decode breadth and spec errata cross-checked against PhotoDemon (pdPSD*.cls),
// BSD-2-Clause, © Tanner Helland and contributors.
//
// Like photocraft-psd it depends on no other package of the port: only Apple SDK frameworks
// (Foundation, Compression, CoreGraphics/ImageIO for optional colour conversion).
import PackageDescription

let package = Package(
    name: "PCPSD",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PCPSD", targets: ["PCPSD"]),
        // Test support for other packages' tests: the synthetic PSD/PSB generator (`PSDTestGen`)
        // and the seeded xorshift generator (`PSDSeededRandom`).
        .library(name: "PCPSDTestSupport", targets: ["PCPSDTestSupport"]),
    ],
    targets: [
        .target(name: "PCPSD"),
        .target(name: "PCPSDTestSupport", dependencies: ["PCPSD"]),
        .testTarget(name: "PCPSDTests", dependencies: ["PCPSD", "PCPSDTestSupport"]),
    ]
)
