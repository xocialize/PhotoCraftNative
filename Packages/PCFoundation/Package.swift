// swift-tools-version: 6.2
// PCFoundation — L0 of the PhotoCraft native port: geometry, pixel formats, colour models,
// blend-mode math, tiled copy-on-write surfaces, float image regions and the shared Metal context.
// Ports photocraft-geom, photocraft-color and photocraft-raster (MIT OR Apache-2.0).
import PackageDescription

let package = Package(
    name: "PCFoundation",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PCFoundation", targets: ["PCFoundation"]),
    ],
    targets: [
        .target(
            name: "PCFoundation",
            resources: [.copy("Shaders")]
        ),
        .testTarget(name: "PCFoundationTests", dependencies: ["PCFoundation"]),
    ]
)
