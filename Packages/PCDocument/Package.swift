// swift-tools-version: 6.2
// PCDocument — L1/L2 of the PhotoCraft native port: the pure-data document model (layers, masks,
// adjustments, effects, smart objects, text, vectors, comps, slices…) and its undo history.
// Ports photocraft-doc, the parts of photocraft-geom the model needs (affine maths, warps) and
// photocraft-ops (MIT OR Apache-2.0).
import PackageDescription

let package = Package(
    name: "PCDocument",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PCDocument", targets: ["PCDocument"]),
        .library(name: "PCHistory", targets: ["PCHistory"]),
    ],
    dependencies: [
        .package(path: "../PCFoundation"),
    ],
    targets: [
        .target(name: "PCDocument", dependencies: ["PCFoundation"]),
        .target(name: "PCHistory", dependencies: ["PCDocument", "PCFoundation"]),
        .testTarget(name: "PCDocumentTests", dependencies: ["PCDocument", "PCFoundation"]),
        .testTarget(name: "PCHistoryTests", dependencies: ["PCHistory", "PCDocument", "PCFoundation"]),
    ]
)
