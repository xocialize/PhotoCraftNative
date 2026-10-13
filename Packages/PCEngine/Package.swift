// swift-tools-version: 6.2
// PCEngine — the façade every PhotoCraft frontend talks to: the `Session` (open documents,
// targeting, history, jobs, events, preferences, view-models), the command registry (photocraft's
// ~860 command ids, dispatched by id with JSON params), and the glue only the engine may hold
// (PCPlatform's text and vector engines as PCRender's rasterizer, PCRender as the export
// compositor, ColorSync display colour, the PCIntelligence registry, PCAlgo's filters and
// geometry, PCIO's file formats). PCAutomation adds the headless JSON control channel and the MCP
// server; `pccli` is the command line.
//
// Port of photocraft-engine (crates/engine), photocraft-automation (crates/automation) and
// photocraft-cli (apps/photocraft-cli), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.
import PackageDescription

let package = Package(
    name: "PCEngine",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PCEngine", targets: ["PCEngine"]),
        .library(name: "PCAutomation", targets: ["PCAutomation"]),
        .executable(name: "pccli", targets: ["pccli"]),
    ],
    dependencies: [
        .package(path: "../PCFoundation"),
        .package(path: "../PCDocument"),
        .package(path: "../PCRender"),
        .package(path: "../PCPaint"),
        .package(path: "../PCPlatform"),
        .package(path: "../PCIntelligence"),
        .package(path: "../PCAlgo"),
        .package(path: "../PCIO"),
        // Photoshop preset codecs PCIO leaves to the engine (`.shc` contours); tests read PSD files.
        .package(path: "../PCPSD"),
        // The Kits whose option enums PCIntelligence's operations take (same versions PCIntelligence pins).
        .package(url: "https://github.com/xocialize/ExtractKit.git", from: "0.1.1"),
        .package(url: "https://github.com/xocialize/EraseKit.git", from: "0.2.0"),
        .package(url: "https://github.com/xocialize/ColorizeKit.git", from: "0.1.1"),
        // The official MCP Swift SDK, at the version the fleet's ML[X] Image Server uses.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
    ],
    targets: [
        .target(
            name: "PCEngine",
            dependencies: [
                .product(name: "PCFoundation", package: "PCFoundation"),
                .product(name: "PCDocument", package: "PCDocument"),
                .product(name: "PCHistory", package: "PCDocument"),
                .product(name: "PCRender", package: "PCRender"),
                .product(name: "PCPaint", package: "PCPaint"),
                .product(name: "PCPlatform", package: "PCPlatform"),
                .product(name: "PCIntelligence", package: "PCIntelligence"),
                .product(name: "PCAlgo", package: "PCAlgo"),
                .product(name: "PCIO", package: "PCIO"),
                .product(name: "PCIOCore", package: "PCIO"),
                .product(name: "PCFormat", package: "PCIO"),
                // SVGImport, EXR layer maps; Linked and SmartMap; PatternMap and DisplaceMap.
                .product(name: "PCIOFormats", package: "PCIO"),
                .product(name: "PCIOSmart", package: "PCIO"),
                .product(name: "PCIOMaps", package: "PCIO"),
                .product(name: "PCPSD", package: "PCPSD"),
                .product(name: "ExtractKit", package: "ExtractKit"),
                .product(name: "EraseKit", package: "EraseKit"),
                .product(name: "ColorizeKit", package: "ColorizeKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "PCAutomation",
            dependencies: [
                "PCEngine",
                .product(name: "PCFoundation", package: "PCFoundation"),
                .product(name: "PCDocument", package: "PCDocument"),
                .product(name: "PCRender", package: "PCRender"),
                .product(name: "PCPlatform", package: "PCPlatform"),
                .product(name: "PCIO", package: "PCIO"),
                .product(name: "PCIOCore", package: "PCIO"),
                .product(name: "PCFormat", package: "PCIO"),
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "pccli",
            dependencies: ["PCAutomation"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PCEngineTests",
            dependencies: [
                "PCEngine",
                .product(name: "PCFoundation", package: "PCFoundation"),
                .product(name: "PCDocument", package: "PCDocument"),
                .product(name: "PCHistory", package: "PCDocument"),
                .product(name: "PCRender", package: "PCRender"),
                .product(name: "PCPaint", package: "PCPaint"),
                .product(name: "PCPlatform", package: "PCPlatform"),
                .product(name: "PCIntelligence", package: "PCIntelligence"),
                .product(name: "PCAlgo", package: "PCAlgo"),
                .product(name: "PCIO", package: "PCIO"),
                .product(name: "PCIOCore", package: "PCIO"),
                .product(name: "PCFormat", package: "PCIO"),
                .product(name: "PCIOSmart", package: "PCIO"),
                .product(name: "PCPSD", package: "PCPSD"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PCAutomationTests",
            dependencies: [
                "PCAutomation", "PCEngine",
                .product(name: "PCFoundation", package: "PCFoundation"),
                .product(name: "PCDocument", package: "PCDocument"),
                .product(name: "PCPlatform", package: "PCPlatform"),
                .product(name: "PCFormat", package: "PCIO"),
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
