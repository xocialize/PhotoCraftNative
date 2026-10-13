// swift-tools-version: 6.2
// PCAlgo — the Filter menu of the PhotoCraft native port: every filter as a Metal compute kernel
// with a Swift CPU reference on `FloatImage` that the GPU must match.
// Port of photocraft-algo (crates/algo/src), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
import PackageDescription

let package = Package(
    name: "PCAlgo",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PCAlgo", targets: ["PCAlgo"]),
    ],
    dependencies: [
        .package(path: "../PCFoundation"),
    ],
    targets: [
        .target(
            name: "PCAlgo",
            dependencies: ["PCFoundation"],
            resources: [.copy("Shaders")]
        ),
        .testTarget(name: "PCAlgoTests", dependencies: ["PCAlgo", "PCFoundation"]),
    ]
)
