// swift-tools-version: 6.2
// PCIO — L4 of the PhotoCraft native port: the bridge between the document model and files.
//
//   PCIOCore     shared helpers: big-endian IO, descriptors, colours, gradients, fills, pixels,
//                ZIP/deflate, the injected compositor/renderer/codec protocols (io blocks.rs,
//                pixels.rs, gradient_bake.rs; format zip.rs)
//   PCIOText     PSD type layers ⇄ TextLayer, Txt2, text styles (text psd.rs, psd_styles.rs;
//                io text_styles_map.rs)
//   PCIOMaps     PSD block ⇄ document mappings: adjustments, effects, vectors, patterns,
//                channels, comps/artboards, slices, notes (io *_map.rs)
//   PCIOSmart    smart objects: placed-layer data, smart filters, linked files (io smart_map.rs,
//                linked.rs, displace_map.rs, camera_raw_map.rs)
//   PCFormat     the native `.pcraft` document (photocraft-format)
//   PCIOAffinity Affinity documents → Document (io affinity.rs, on PCAffinity's reader)
//   PCIOFormats  other layered formats: OpenRaster, Krita, Paint.NET, layered TIFF transcoding,
//                multi-part EXR, SVG (io ora.rs, kra.rs, pdn*, tiff_layers.rs + psd tiff.rs,
//                exr_parts.rs, svg.rs)
//   PCIO         PSD/PSB import and export, the import/export dispatch (io psd_import.rs,
//                psd_export.rs, lib.rs, …), and the default compositor conformance on PCRender
//
// Port of photocraft-io (crates/io) and photocraft-format (crates/format), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.
//
// Like photocraft's psd/io split, the PSD mapping never composites by itself: the merged image of
// an export comes from an injected `DocumentCompositor` (default: `RenderCompositor`, backed by
// PCRender's CPU or Metal compositor), and text/shape/fill rendering from an injected
// `LayerContentRenderer` / PCRender `LayerRasterizer`. Only Apple SDK frameworks plus the local
// packages are used (no URL dependencies).
import PackageDescription

let swiftSettings: [SwiftSetting] = []

let package = Package(
    name: "PCIO",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PCIO", targets: ["PCIO"]),
        .library(name: "PCFormat", targets: ["PCFormat"]),
        .library(name: "PCIOCore", targets: ["PCIOCore"]),
        // Used by the engine directly (`SVGImport`, `Linked`, `SmartMap`, `PatternMap`, `DisplaceMap`).
        .library(name: "PCIOFormats", targets: ["PCIOFormats"]),
        .library(name: "PCIOSmart", targets: ["PCIOSmart"]),
        .library(name: "PCIOMaps", targets: ["PCIOMaps"]),
    ],
    dependencies: [
        .package(path: "../PCFoundation"),
        .package(path: "../PCDocument"),
        .package(path: "../PCPSD"),
        // The compositor: export merged images, previews and the composite oracle (in photocraft,
        // io depends on compose too).
        .package(path: "../PCRender"),
        // Affinity documents (io affinity.rs) and the bounded RFC 8878 zstd decoder `.pcraft`
        // tiles need (`ZstdDecoder`).
        .package(path: "../PCAffinity"),
    ],
    targets: [
        .target(
            name: "PCIOCore",
            dependencies: [
                .product(name: "PCFoundation", package: "PCFoundation"),
                .product(name: "PCDocument", package: "PCDocument"),
                .product(name: "PCPSD", package: "PCPSD"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "PCIOText",
            dependencies: [
                .product(name: "PCFoundation", package: "PCFoundation"),
                .product(name: "PCDocument", package: "PCDocument"),
                .product(name: "PCPSD", package: "PCPSD"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "PCIOMaps",
            dependencies: [
                "PCIOCore",
                .product(name: "PCFoundation", package: "PCFoundation"),
                .product(name: "PCDocument", package: "PCDocument"),
                .product(name: "PCPSD", package: "PCPSD"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "PCIOSmart",
            dependencies: [
                "PCIOCore",
                .product(name: "PCFoundation", package: "PCFoundation"),
                .product(name: "PCDocument", package: "PCDocument"),
                .product(name: "PCPSD", package: "PCPSD"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "PCFormat",
            dependencies: [
                "PCIOCore",
                .product(name: "PCAffinity", package: "PCAffinity"),
                .product(name: "PCFoundation", package: "PCFoundation"),
                .product(name: "PCDocument", package: "PCDocument"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "PCIOFormats",
            dependencies: [
                "PCIOCore",
                .product(name: "PCFoundation", package: "PCFoundation"),
                .product(name: "PCDocument", package: "PCDocument"),
                .product(name: "PCPSD", package: "PCPSD"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "PCIOAffinity",
            dependencies: [
                "PCIOCore",
                .product(name: "PCAffinity", package: "PCAffinity"),
                .product(name: "PCFoundation", package: "PCFoundation"),
                .product(name: "PCDocument", package: "PCDocument"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "PCIO",
            dependencies: [
                "PCIOCore", "PCIOText", "PCIOMaps", "PCIOSmart", "PCFormat", "PCIOFormats", "PCIOAffinity",
                .product(name: "PCRender", package: "PCRender"),
                .product(name: "PCAffinity", package: "PCAffinity"),
                .product(name: "PCFoundation", package: "PCFoundation"),
                .product(name: "PCDocument", package: "PCDocument"),
                .product(name: "PCPSD", package: "PCPSD"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(name: "PCIOCoreTests", dependencies: ["PCIOCore"]),
        .testTarget(name: "PCIOTextTests", dependencies: ["PCIOText"]),
        .testTarget(name: "PCIOMapsTests", dependencies: ["PCIOMaps", "PCIOCore"]),
        .testTarget(name: "PCIOSmartTests", dependencies: ["PCIOSmart", "PCIOCore"]),
        .testTarget(name: "PCFormatTests", dependencies: ["PCFormat", "PCIOCore", .product(name: "PCAffinitySynth", package: "PCAffinity")]),
        .testTarget(name: "PCIOFormatsTests", dependencies: ["PCIOFormats", "PCIOCore", .product(name: "PCPSDTestSupport", package: "PCPSD")]),
        .testTarget(name: "PCIOAffinityTests", dependencies: ["PCIOAffinity", "PCIOCore", .product(name: "PCAffinitySynth", package: "PCAffinity")]),
        .testTarget(name: "PCIOTests", dependencies: ["PCIO", "PCIOCore", "PCIOText", "PCIOMaps", "PCIOSmart", "PCFormat", "PCIOFormats", "PCIOAffinity",
                                                      .product(name: "PCRender", package: "PCRender"),
                                                      .product(name: "PCAffinitySynth", package: "PCAffinity"),
                                                      .product(name: "PCPSDTestSupport", package: "PCPSD")]),
    ]
)
