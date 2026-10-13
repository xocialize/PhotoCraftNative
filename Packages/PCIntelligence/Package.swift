// swift-tools-version: 6.2
// PCIntelligence — the PhotoCraft native port's AI tier (photocraft gap G15). photocraft planned an
// `ml` crate (SAM2, matting, depth, sky, inpainting; docs/architecture.md §2) and never built it.
// This package fills the gap by slotting in the fleet's finished image Kits instead of developing
// models: their model-free tiers run by default, and the host app injects the engine-backed
// (ForgeCore, MLX) providers into one registry slot per capability. Command shapes after
// photocraft-engine (MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors).
//
// Category A: no MLX, no ForgeCore, no weights. The Kits come by versioned URL (fleet decision
// AB-D-0023: a path and a URL to the same package collide on identity).
import PackageDescription

let package = Package(
    name: "PCIntelligence",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PCIntelligence", targets: ["PCIntelligence"]),
    ],
    dependencies: [
        .package(path: "../PCFoundation"),
        .package(path: "../PCDocument"),
        .package(url: "https://github.com/xocialize/MaskKit.git", from: "0.4.1"),
        .package(url: "https://github.com/xocialize/ExtractKit.git", from: "0.1.1"),
        .package(url: "https://github.com/xocialize/EraseKit.git", from: "0.2.0"),
        .package(url: "https://github.com/xocialize/ColorizeKit.git", from: "0.1.1"),
        .package(url: "https://github.com/xocialize/ForgeRestoreKit.git", from: "0.11.0"),
        .package(url: "https://github.com/xocialize/ForgeLightKit.git", from: "0.3.0"),
    ],
    targets: [
        .target(
            name: "PCIntelligence",
            dependencies: [
                .product(name: "PCFoundation", package: "PCFoundation"),
                .product(name: "PCDocument", package: "PCDocument"),
                .product(name: "PCHistory", package: "PCDocument"),
                .product(name: "MaskKit", package: "MaskKit"),
                .product(name: "ExtractKit", package: "ExtractKit"),
                .product(name: "EraseKit", package: "EraseKit"),
                .product(name: "ColorizeKit", package: "ColorizeKit"),
                .product(name: "RestoreTier0", package: "ForgeRestoreKit"),
                .product(name: "RestoreTier2", package: "ForgeRestoreKit"),
                .product(name: "LightTier0", package: "ForgeLightKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PCIntelligenceTests",
            dependencies: [
                "PCIntelligence",
                .product(name: "PCFoundation", package: "PCFoundation"),
                .product(name: "PCDocument", package: "PCDocument"),
                .product(name: "PCHistory", package: "PCDocument"),
                .product(name: "MaskKit", package: "MaskKit"),
                .product(name: "ExtractKit", package: "ExtractKit"),
                .product(name: "EraseKit", package: "EraseKit"),
                .product(name: "ColorizeKit", package: "ColorizeKit"),
                .product(name: "RestoreTier2", package: "ForgeRestoreKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
