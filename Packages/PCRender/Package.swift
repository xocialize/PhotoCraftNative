// swift-tools-version: 6.2
// PCRender — the compositor of the PhotoCraft native port: a Swift CPU reference (the correctness
// oracle) and a Metal compositor that run the same DrawOp plan, plus the canvas display path.
// Port of photocraft-compose and photocraft-gpu (MIT OR Apache-2.0), © ArtCraft Team and the
// PhotoCraft contributors.
import PackageDescription

let package = Package(
    name: "PCRender",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PCRender", targets: ["PCRender"]),
        .executable(name: "PCRenderBench", targets: ["PCRenderBench"]),
    ],
    dependencies: [
        .package(path: "../PCFoundation"),
        .package(path: "../PCDocument"),
    ],
    targets: [
        .target(
            name: "PCRender",
            dependencies: ["PCFoundation", .product(name: "PCDocument", package: "PCDocument")],
            resources: [.copy("Shaders")]
        ),
        .executableTarget(name: "PCRenderBench", dependencies: ["PCRender", "PCFoundation", .product(name: "PCDocument", package: "PCDocument")]),
        .testTarget(name: "PCRenderTests", dependencies: ["PCRender", "PCFoundation", .product(name: "PCDocument", package: "PCDocument")]),
    ]
)
