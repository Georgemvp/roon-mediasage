// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RoonSage",
    defaultLocalization: "nl",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RoonSageCore", targets: ["RoonSageCore"]),
        .library(name: "RoonSageUI", targets: ["RoonSageUI"]),
        .library(name: "AudioAnalysis", targets: ["AudioAnalysis"]),
        .library(name: "CLAPEngine", targets: ["CLAPEngine"]),
        .library(name: "AnalyzerCore", targets: ["AnalyzerCore"]),
        .executable(name: "RoonSage", targets: ["RoonSage"]),
        .executable(name: "roonsage-mcp", targets: ["RoonSageMCP"]),
        .executable(name: "roonsage-analyzer", targets: ["RoonSageAnalyzer"]),
        .executable(name: "RoonSageAnalyzerApp", targets: ["RoonSageAnalyzerApp"]),
    ],
    dependencies: [
        .package(path: "../RoonProtocol"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "RoonSageCore",
            dependencies: [
                "AudioAnalysis",
                .product(name: "RoonProtocol", package: "RoonProtocol"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "RoonSageUI",
            dependencies: ["RoonSageCore"],
            path: "Sources/RoonSageUI",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "RoonSage",
            dependencies: ["RoonSageCore", "RoonSageUI"],
            path: "Sources/RoonSage",
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "RoonSageMCP",
            dependencies: ["RoonSageCore"],
            path: "Sources/RoonSageMCP"
        ),
        // Light, resource-free half: identity, Camelot, tempo, FFT, LRC, the
        // provider gates. Everything a *client* needs. Depended on by
        // RoonSageCore, so it must never carry a model — see CLAPEngine.
        .target(
            name: "AudioAnalysis",
            path: "Sources/AudioAnalysis"
        ),
        // Heavy half: the CLAP CoreML models (746 MB of .mlpackage) plus the
        // decode/analysis code that runs them.
        //
        // This target exists purely so those 746 MB stay OUT of the client apps.
        // While the models sat in AudioAnalysis, RoonSageCore's dependency on it
        // dragged the whole bundle into RoonSage.app on both macOS and iOS: a
        // measured 793 MB iOS bundle of which 746 MB was a model the client
        // never runs (CLAP inference happens in the analyser). Only the analyser
        // products may depend on this target — adding it to RoonSageCore or
        // RoonSageUI silently re-inflates every client by ~746 MB.
        .target(
            name: "CLAPEngine",
            dependencies: ["AudioAnalysis"],
            path: "Sources/CLAPEngine",
            resources: [.copy("Resources")]
        ),
        .target(
            name: "AnalyzerCore",
            dependencies: [
                "AudioAnalysis",
                "CLAPEngine",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/AnalyzerCore"
        ),
        .executableTarget(
            name: "RoonSageAnalyzer",
            dependencies: ["AnalyzerCore", "AudioAnalysis", "CLAPEngine"],
            path: "Sources/RoonSageAnalyzer"
        ),
        .executableTarget(
            name: "RoonSageAnalyzerApp",
            dependencies: ["AnalyzerCore", "AudioAnalysis", "CLAPEngine", "RoonSageCore", "RoonSageUI"],
            path: "Sources/RoonSageAnalyzerApp",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "RoonSageCoreTests",
            dependencies: ["RoonSageCore", "AudioAnalysis", "CLAPEngine", "AnalyzerCore"]
        ),
    ]
)
