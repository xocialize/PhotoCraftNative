// swift-tools-version: 6.2
// PCPlatform — the PhotoCraft native port's platform layer: photocraft's hand-written pure-Rust
// subsystems replaced by the macOS frameworks that already do the job.
//
//   Color     photocraft-cms (crates/cms)            → ColorSync / CGColorSpace / vImage
//   Codecs    photocraft-codecs + photocraft-heif     → ImageIO (+ webp-swift for WebP write)
//   Raw       photocraft-raw (crates/raw)             → Core Image CIRAWFilter (+ media-bridge ImageBridge)
//   Text      photocraft-text (crates/text)           → CoreText, over PCDocument's TextLayer
//   Vector    photocraft-vector (crates/vector)       → CoreGraphics, over PCDocument's VectorPath/ShapeLayer
//   Input     photocraft-tablet (crates/tablet)       → AppKit NSEvent
//   Vision    photocraft gap G15 (no ML runtime)      → Vision (geometry/text helpers only)
//   PDF       photocraft gap #2541                    → CoreGraphics PDF / PDFKit
//
// Ports the API shape of photocraft (MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors). The bundled `photocraft-coated-cmyk.icc` is photocraft-cms's generated profile,
// dedicated to the public domain (CC0-1.0).
import PackageDescription

let package = Package(
    name: "PCPlatform",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PCPlatform", targets: ["PCPlatform"]),
    ],
    dependencies: [
        .package(path: "../PCFoundation"),
        // The document model: text and vector render PCDocument's own types (in photocraft,
        // `text` and `vector` depend on `doc`).
        .package(path: "../PCDocument"),
        // Fleet image packages, by versioned URL (AB-D-0023: webp-swift takes media-bridge by URL,
        // so a path dependency here would collide on package identity).
        .package(url: "https://github.com/xocialize/media-bridge.git", from: "0.40.0"),
        .package(url: "https://github.com/xocialize/webp-swift.git", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "PCPlatform",
            dependencies: [
                .product(name: "PCFoundation", package: "PCFoundation"),
                .product(name: "PCDocument", package: "PCDocument"),
                .product(name: "ImageBridge", package: "media-bridge"),
                .product(name: "MediaMeasure", package: "media-bridge"),
                .product(name: "WebPSwift", package: "webp-swift"),
            ],
            resources: [.copy("Resources/photocraft-coated-cmyk.icc")]
        ),
        .testTarget(name: "PCPlatformTests", dependencies: ["PCPlatform", .product(name: "PCDocument", package: "PCDocument")]),
    ]
)
