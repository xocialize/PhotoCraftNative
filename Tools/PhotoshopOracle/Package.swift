// swift-tools-version: 6.2
// PhotoshopOracle — drives the real Adobe Photoshop (ExtendScript over Apple events) as the
// acceptance oracle for the PhotoCraft native port's PSD/PSB files, and compares what Photoshop
// reads and renders with what PCPSD reads.
//
// `ps-oracle` is the command-line front end; `PSOracleKit` holds the Photoshop bridge (lock file,
// osascript runner with timeouts and recovery, the ExtendScript sources), an uncompressed TIFF /
// Photoshop Raw reader, and the comparisons against PCPSD (by path, read-only).
import PackageDescription

let package = Package(
    name: "PhotoshopOracle",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "ps-oracle", targets: ["ps-oracle"]),
        .library(name: "PSOracleKit", targets: ["PSOracleKit"]),
    ],
    dependencies: [
        .package(path: "../../Packages/PCPSD"),
    ],
    targets: [
        .target(
            name: "PSOracleKit",
            dependencies: [.product(name: "PCPSD", package: "PCPSD")],
            resources: [.copy("JSX")]
        ),
        .executableTarget(name: "ps-oracle", dependencies: ["PSOracleKit", .product(name: "PCPSD", package: "PCPSD")]),
        .testTarget(name: "PSOracleKitTests", dependencies: ["PSOracleKit", .product(name: "PCPSD", package: "PCPSD")]),
    ],
    swiftLanguageModes: [.v6]
)
