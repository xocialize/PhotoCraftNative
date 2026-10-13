// swift-tools-version: 6.2
// PCPaint — the brush engine of the PhotoCraft native port: Photoshop-grade brushes (computed and
// sampled tips, every Brush Settings section), deterministic dab generation, the CPU reference
// rasteriser and compositor, a Metal dab renderer, and the retouch/mixer/replace/background-eraser
// dab machinery. Port of photocraft-paint (crates/paint), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.
import PackageDescription

let package = Package(
    name: "PCPaint",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PCPaint", targets: ["PCPaint"]),
        .executable(name: "pcpaint-bench", targets: ["PCPaintBench"]),
    ],
    dependencies: [
        .package(path: "../PCFoundation"),
    ],
    targets: [
        .target(
            name: "PCPaint",
            dependencies: [.product(name: "PCFoundation", package: "PCFoundation")],
            resources: [.copy("Shaders")]
        ),
        .executableTarget(
            name: "PCPaintBench",
            dependencies: ["PCPaint", .product(name: "PCFoundation", package: "PCFoundation")]
        ),
        .testTarget(
            name: "PCPaintTests",
            dependencies: ["PCPaint", .product(name: "PCFoundation", package: "PCFoundation")]
        ),
    ]
)
