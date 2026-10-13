// swift-tools-version: 6.2
// PCAffinity — a bounded, read-only reader for native Affinity documents (.af, .afdesign, .afphoto,
// .afpub): the archive container, the tagged object stream in doc.dat, the document model and the
// embedded PNG preview. Port of photocraft-affinity (MIT OR Apache-2.0). Standalone: Apple SDK only
// (Compression for zlib; zstd, CRC-32 and XXH64 are implemented here).
// PCAffinitySynth is photocraft's `synth` feature: synthetic containers for tests, never an exporter.
import PackageDescription

let package = Package(
    name: "PCAffinity",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PCAffinity", targets: ["PCAffinity"]),
        .library(name: "PCAffinitySynth", targets: ["PCAffinitySynth"]),
    ],
    targets: [
        .target(name: "PCAffinity"),
        .target(name: "PCAffinitySynth", dependencies: ["PCAffinity"]),
        .testTarget(
            name: "PCAffinityTests",
            dependencies: ["PCAffinity", "PCAffinitySynth"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
