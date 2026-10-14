// swift-tools-version: 6.2
// PhotoCraftNative — photocraft on Swift and Metal (macOS 26+, Apple Silicon). The one manifest for
// the whole repository: every package under `Packages/`, `Tools/PhotoshopOracle` and `Tools/CameraRawFit` is a group of
// targets here, each exported as a product, so other repos can depend on this one by URL (fleet rule
// AB-D-0023; SwiftPM can't consume a package from a repo's subfolder):
//
//     .package(url: "https://github.com/xocialize/PhotoCraftNative.git", from: "0.1.0")
//     .product(name: "PCPSD", package: "PhotoCraftNative")
//
// Targets keep their sources at `Packages/<package>/{Sources,Tests}/<target>`. Each package's
// `PORT-NOTES.md` has its file map and port status. Ports photocraft (MIT OR Apache-2.0, © ArtCraft
// Team and the PhotoCraft contributors); every ported file names its source and licence.
//
// Fleet packages come by versioned URL only (AB-D-0023). Test data stays outside git, at
// `PHOTOCRAFT_FIXTURES` (default `../PhotoCraftNative-Fixtures`); tests that need it skip without it.
import PackageDescription

/// `Packages/<package>/Sources/<target>`.
func sources(_ package: String, _ target: String) -> String { "Packages/\(package)/Sources/\(target)" }
/// `Packages/<package>/Tests/<target>`.
func tests(_ package: String, _ target: String) -> String { "Packages/\(package)/Tests/\(target)" }

let package = Package(
    name: "PhotoCraftNative",
    platforms: [.macOS(.v26)],
    products: [
        // L0
        .library(name: "PCFoundation", targets: ["PCFoundation"]),
        .library(name: "PCPSD", targets: ["PCPSD"]),
        .library(name: "PCPSDTestSupport", targets: ["PCPSDTestSupport"]),
        .library(name: "PCPlatform", targets: ["PCPlatform"]),
        .library(name: "PCAffinity", targets: ["PCAffinity"]),
        .library(name: "PCAffinitySynth", targets: ["PCAffinitySynth"]),
        // L1–L3
        .library(name: "PCDocument", targets: ["PCDocument"]),
        .library(name: "PCHistory", targets: ["PCHistory"]),
        .library(name: "PCAlgo", targets: ["PCAlgo"]),
        .library(name: "PCPaint", targets: ["PCPaint"]),
        .executable(name: "pcpaint-bench", targets: ["PCPaintBench"]),
        .library(name: "PCRender", targets: ["PCRender"]),
        .executable(name: "PCRenderBench", targets: ["PCRenderBench"]),
        .library(name: "PCIntelligence", targets: ["PCIntelligence"]),
        // L4: files
        .library(name: "PCIO", targets: ["PCIO"]),
        .library(name: "PCIOCore", targets: ["PCIOCore"]),
        .library(name: "PCIOText", targets: ["PCIOText"]),
        .library(name: "PCIOMaps", targets: ["PCIOMaps"]),
        .library(name: "PCIOSmart", targets: ["PCIOSmart"]),
        .library(name: "PCIOFormats", targets: ["PCIOFormats"]),
        .library(name: "PCIOAffinity", targets: ["PCIOAffinity"]),
        .library(name: "PCFormat", targets: ["PCFormat"]),
        // L5: the engine façade, automation and the command line
        .library(name: "PCEngine", targets: ["PCEngine"]),
        .library(name: "PCAutomation", targets: ["PCAutomation"]),
        .executable(name: "pccli", targets: ["pccli"]),
        // The Photoshop acceptance oracle
        .library(name: "PSOracleKit", targets: ["PSOracleKit"]),
        .executable(name: "ps-oracle", targets: ["ps-oracle"]),
        .executable(name: "cr-measure", targets: ["cr-measure"]),
    ],
    dependencies: [
        // Fleet image Kits: PCIntelligence's model-free tiers, and the option enums PCEngine passes on.
        .package(url: "https://github.com/xocialize/MaskKit.git", from: "0.4.1"),
        .package(url: "https://github.com/xocialize/ExtractKit.git", from: "0.1.1"),
        .package(url: "https://github.com/xocialize/EraseKit.git", from: "0.2.0"),
        .package(url: "https://github.com/xocialize/ColorizeKit.git", from: "0.1.1"),
        .package(url: "https://github.com/xocialize/ForgeRestoreKit.git", from: "0.11.0"),
        .package(url: "https://github.com/xocialize/ForgeLightKit.git", from: "0.3.0"),
        // PCPlatform's codecs. webp-swift takes media-bridge by URL too, so a path dependency would
        // collide on package identity.
        .package(url: "https://github.com/xocialize/media-bridge.git", from: "0.40.0"),
        .package(url: "https://github.com/xocialize/webp-swift.git", from: "0.1.0"),
        // The official MCP Swift SDK (PCAutomation), at the version the fleet's ML[X] Image Server uses.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
    ],
    targets: [
        // MARK: PCFoundation — geometry, pixel formats, colour models, blend maths, tiled surfaces,
        // the shared Metal context (photocraft-geom, -color, -raster).
        .target(name: "PCFoundation", path: sources("PCFoundation", "PCFoundation"), resources: [.copy("Shaders")]),
        .testTarget(name: "PCFoundationTests", dependencies: ["PCFoundation"], path: tests("PCFoundation", "PCFoundationTests")),

        // MARK: PCPSD — standalone PSD/PSB reader and writer plus abr/aco/ase/grd/pat/shc
        // (photocraft-psd; PhotoDemon's decode breadth). Depends on no other package of the port.
        .target(name: "PCPSD", path: sources("PCPSD", "PCPSD")),
        // Test support for other targets' tests: `PSDTestGen` and `PSDSeededRandom`.
        .target(name: "PCPSDTestSupport", dependencies: ["PCPSD"], path: sources("PCPSD", "PCPSDTestSupport")),
        .testTarget(name: "PCPSDTests", dependencies: ["PCPSD", "PCPSDTestSupport"], path: tests("PCPSD", "PCPSDTests")),

        // MARK: PCAffinity — bounded read-only reader for native Affinity documents
        // (photocraft-affinity). PCAffinitySynth builds synthetic containers for tests, never an exporter.
        .target(name: "PCAffinity", path: sources("PCAffinity", "PCAffinity")),
        .target(name: "PCAffinitySynth", dependencies: ["PCAffinity"], path: sources("PCAffinity", "PCAffinitySynth")),
        .testTarget(
            name: "PCAffinityTests",
            dependencies: ["PCAffinity", "PCAffinitySynth"],
            path: tests("PCAffinity", "PCAffinityTests"),
            resources: [.copy("Fixtures")]
        ),

        // MARK: PCDocument — the document model and its undo history (photocraft-doc, -ops, the
        // model's part of -geom).
        .target(name: "PCDocument", dependencies: ["PCFoundation"], path: sources("PCDocument", "PCDocument")),
        .target(name: "PCHistory", dependencies: ["PCDocument", "PCFoundation"], path: sources("PCDocument", "PCHistory")),
        .testTarget(name: "PCDocumentTests", dependencies: ["PCDocument", "PCFoundation"], path: tests("PCDocument", "PCDocumentTests")),
        .testTarget(
            name: "PCHistoryTests",
            dependencies: ["PCHistory", "PCDocument", "PCFoundation"],
            path: tests("PCDocument", "PCHistoryTests")
        ),

        // MARK: PCPlatform — photocraft's hand-written subsystems replaced by macOS frameworks:
        // ColorSync, ImageIO (+ webp-swift), CIRAWFilter (+ media-bridge), CoreText, CoreGraphics,
        // NSEvent, Vision, PDFKit. The bundled CMYK profile is CC0-1.0.
        .target(
            name: "PCPlatform",
            dependencies: [
                "PCFoundation", "PCDocument",
                .product(name: "ImageBridge", package: "media-bridge"),
                .product(name: "MediaMeasure", package: "media-bridge"),
                .product(name: "WebPSwift", package: "webp-swift"),
            ],
            path: sources("PCPlatform", "PCPlatform"),
            resources: [.copy("Resources/photocraft-coated-cmyk.icc")]
        ),
        .testTarget(name: "PCPlatformTests", dependencies: ["PCPlatform", "PCDocument"], path: tests("PCPlatform", "PCPlatformTests")),

        // MARK: PCAlgo — the Filter menu: Metal kernels with Swift CPU references (photocraft-algo).
        .target(name: "PCAlgo", dependencies: ["PCFoundation"], path: sources("PCAlgo", "PCAlgo"),
                resources: [.copy("Shaders"), .copy("Tone/CameraRawModel.json")]),
        .testTarget(name: "PCAlgoTests", dependencies: ["PCAlgo", "PCFoundation"], path: tests("PCAlgo", "PCAlgoTests")),

        // MARK: PCPaint — the brush engine: dab generation, CPU reference, Metal dab renderer
        // (photocraft-paint).
        .target(name: "PCPaint", dependencies: ["PCFoundation"], path: sources("PCPaint", "PCPaint"), resources: [.copy("Shaders")]),
        .executableTarget(name: "PCPaintBench", dependencies: ["PCPaint", "PCFoundation"], path: sources("PCPaint", "PCPaintBench")),
        .testTarget(name: "PCPaintTests", dependencies: ["PCPaint", "PCFoundation"], path: tests("PCPaint", "PCPaintTests")),

        // MARK: PCRender — the compositor: CPU reference and Metal on one DrawOp plan, plus the
        // canvas display path (photocraft-compose, -gpu).
        .target(name: "PCRender", dependencies: ["PCFoundation", "PCDocument"], path: sources("PCRender", "PCRender"), resources: [.copy("Shaders")]),
        .executableTarget(
            name: "PCRenderBench",
            dependencies: ["PCRender", "PCFoundation", "PCDocument"],
            path: sources("PCRender", "PCRenderBench")
        ),
        .testTarget(name: "PCRenderTests", dependencies: ["PCRender", "PCFoundation", "PCDocument"], path: tests("PCRender", "PCRenderTests")),

        // MARK: PCIntelligence — the AI tier (photocraft gap G15): the fleet Kits' model-free tiers,
        // with engine-backed providers injected by the host app. No MLX, ForgeCore or weights.
        .target(
            name: "PCIntelligence",
            dependencies: [
                "PCFoundation", "PCDocument", "PCHistory",
                .product(name: "MaskKit", package: "MaskKit"),
                .product(name: "ExtractKit", package: "ExtractKit"),
                .product(name: "EraseKit", package: "EraseKit"),
                .product(name: "ColorizeKit", package: "ColorizeKit"),
                .product(name: "RestoreTier0", package: "ForgeRestoreKit"),
                .product(name: "RestoreTier2", package: "ForgeRestoreKit"),
                .product(name: "LightTier0", package: "ForgeLightKit"),
            ],
            path: sources("PCIntelligence", "PCIntelligence")
        ),
        .testTarget(
            name: "PCIntelligenceTests",
            dependencies: [
                "PCIntelligence", "PCFoundation", "PCDocument", "PCHistory",
                .product(name: "MaskKit", package: "MaskKit"),
                .product(name: "ExtractKit", package: "ExtractKit"),
                .product(name: "EraseKit", package: "EraseKit"),
                .product(name: "ColorizeKit", package: "ColorizeKit"),
                .product(name: "RestoreTier2", package: "ForgeRestoreKit"),
            ],
            path: tests("PCIntelligence", "PCIntelligenceTests")
        ),

        // MARK: PCIO — documents ⇄ files (photocraft-io, -format). The PSD mapping never composites by
        // itself: merged images come from an injected `DocumentCompositor` (default `RenderCompositor`
        // on PCRender), and text/shape/fill rendering from an injected `LayerContentRenderer`.
        //   PCIOCore     big-endian IO, descriptors, colours, gradients, fills, pixels, ZIP/deflate,
        //                the injected protocols
        //   PCIOText     PSD type layers ⇄ TextLayer, Txt2, text styles
        //   PCIOMaps     PSD blocks ⇄ document: adjustments, effects, vectors, patterns, channels,
        //                comps/artboards, slices, notes
        //   PCIOSmart    smart objects: placed-layer data, smart filters, linked files
        //   PCFormat     the native `.pcraft` document
        //   PCIOAffinity Affinity documents → Document, on PCAffinity's reader
        //   PCIOFormats  OpenRaster, Krita, Paint.NET, layered TIFF, multi-part EXR, SVG
        //   PCIO         PSD/PSB import and export, the import/export dispatch
        .target(name: "PCIOCore", dependencies: ["PCFoundation", "PCDocument", "PCPSD"], path: sources("PCIO", "PCIOCore")),
        .target(name: "PCIOText", dependencies: ["PCFoundation", "PCDocument", "PCPSD"], path: sources("PCIO", "PCIOText")),
        .target(name: "PCIOMaps", dependencies: ["PCIOCore", "PCFoundation", "PCDocument", "PCPSD"], path: sources("PCIO", "PCIOMaps")),
        .target(name: "PCIOSmart", dependencies: ["PCIOCore", "PCFoundation", "PCDocument", "PCPSD"], path: sources("PCIO", "PCIOSmart")),
        // PCAffinity also supplies the bounded RFC 8878 zstd decoder `.pcraft` tiles need.
        .target(name: "PCFormat", dependencies: ["PCIOCore", "PCAffinity", "PCFoundation", "PCDocument"], path: sources("PCIO", "PCFormat")),
        .target(name: "PCIOFormats", dependencies: ["PCIOCore", "PCFoundation", "PCDocument", "PCPSD"], path: sources("PCIO", "PCIOFormats")),
        .target(name: "PCIOAffinity", dependencies: ["PCIOCore", "PCAffinity", "PCFoundation", "PCDocument"], path: sources("PCIO", "PCIOAffinity")),
        .target(
            name: "PCIO",
            dependencies: [
                "PCIOCore", "PCIOText", "PCIOMaps", "PCIOSmart", "PCFormat", "PCIOFormats", "PCIOAffinity",
                "PCRender", "PCAffinity", "PCFoundation", "PCDocument", "PCPSD",
            ],
            path: sources("PCIO", "PCIO")
        ),
        .testTarget(name: "PCIOCoreTests", dependencies: ["PCIOCore"], path: tests("PCIO", "PCIOCoreTests")),
        .testTarget(name: "PCIOTextTests", dependencies: ["PCIOText"], path: tests("PCIO", "PCIOTextTests")),
        .testTarget(name: "PCIOMapsTests", dependencies: ["PCIOMaps", "PCIOCore"], path: tests("PCIO", "PCIOMapsTests")),
        .testTarget(name: "PCIOSmartTests", dependencies: ["PCIOSmart", "PCIOCore"], path: tests("PCIO", "PCIOSmartTests")),
        .testTarget(name: "PCFormatTests", dependencies: ["PCFormat", "PCIOCore", "PCAffinitySynth"], path: tests("PCIO", "PCFormatTests")),
        .testTarget(name: "PCIOFormatsTests", dependencies: ["PCIOFormats", "PCIOCore", "PCPSDTestSupport"], path: tests("PCIO", "PCIOFormatsTests")),
        .testTarget(name: "PCIOAffinityTests", dependencies: ["PCIOAffinity", "PCIOCore", "PCAffinitySynth"], path: tests("PCIO", "PCIOAffinityTests")),
        .testTarget(
            name: "PCIOTests",
            dependencies: [
                "PCIO", "PCIOCore", "PCIOText", "PCIOMaps", "PCIOSmart", "PCFormat", "PCIOFormats", "PCIOAffinity",
                "PCRender", "PCAffinitySynth", "PCPSDTestSupport",
            ],
            path: tests("PCIO", "PCIOTests")
        ),

        // MARK: PCEngine — the façade every frontend talks to: the `Session`, the command registry
        // (~860 photocraft command ids), and the glue only the engine may hold. PCAutomation adds the
        // headless JSON control channel and the MCP server; `pccli` is the command line
        // (photocraft-engine, -automation, -cli).
        .target(
            name: "PCEngine",
            dependencies: [
                "PCFoundation", "PCDocument", "PCHistory", "PCRender", "PCPaint", "PCPlatform", "PCIntelligence",
                "PCAlgo", "PCIO", "PCIOCore", "PCFormat",
                // SVGImport, EXR layer maps; Linked and SmartMap; PatternMap and DisplaceMap.
                "PCIOFormats", "PCIOSmart", "PCIOMaps",
                // Photoshop preset codecs PCIO leaves to the engine (`.shc` contours).
                "PCPSD",
                // The Kits whose option enums PCIntelligence's operations take.
                .product(name: "ExtractKit", package: "ExtractKit"),
                .product(name: "EraseKit", package: "EraseKit"),
                .product(name: "ColorizeKit", package: "ColorizeKit"),
            ],
            path: sources("PCEngine", "PCEngine")
        ),
        .target(
            name: "PCAutomation",
            dependencies: [
                "PCEngine", "PCFoundation", "PCDocument", "PCRender", "PCPlatform", "PCIO", "PCIOCore", "PCFormat",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: sources("PCEngine", "PCAutomation")
        ),
        .executableTarget(name: "pccli", dependencies: ["PCAutomation"], path: sources("PCEngine", "pccli")),
        .testTarget(
            name: "PCEngineTests",
            dependencies: [
                "PCEngine", "PCFoundation", "PCDocument", "PCHistory", "PCRender", "PCPaint", "PCPlatform",
                "PCIntelligence", "PCAlgo", "PCIO", "PCIOCore", "PCFormat", "PCIOSmart", "PCPSD",
            ],
            path: tests("PCEngine", "PCEngineTests")
        ),
        .testTarget(
            name: "PCAutomationTests",
            dependencies: [
                "PCAutomation", "PCEngine", "PCFoundation", "PCDocument", "PCPlatform", "PCFormat",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: tests("PCEngine", "PCAutomationTests")
        ),

        // MARK: PhotoshopOracle — drives the real Adobe Photoshop as the acceptance oracle for PSD/PSB
        // files and compares what it reads and renders with PCPSD. `ps-oracle` is the command line.
        .target(name: "PSOracleKit", dependencies: ["PCPSD"], path: "Tools/PhotoshopOracle/Sources/PSOracleKit", resources: [.copy("JSX")]),
        .executableTarget(name: "ps-oracle", dependencies: ["PSOracleKit", "PCPSD"], path: "Tools/PhotoshopOracle/Sources/ps-oracle"),
        .testTarget(name: "PSOracleKitTests", dependencies: ["PSOracleKit", "PCPSD"], path: "Tools/PhotoshopOracle/Tests/PSOracleKitTests"),

        // MARK: CameraRawFit — measures PCAlgo's Camera Raw develop on the grid its sliders were fitted on (AB-T-0241);
        // the fitting scripts are Tools/CameraRawFit/fit.
        .executableTarget(name: "cr-measure", dependencies: ["PCAlgo", "PCFoundation"], path: "Tools/CameraRawFit/Sources/cr-measure"),
    ],
    swiftLanguageModes: [.v6]
)
