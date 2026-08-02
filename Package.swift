// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiddleAI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MiddleAICore", targets: ["MiddleAICore"]),
        .executable(name: "middleai-cli", targets: ["MiddleAICLI"]),
        .executable(name: "MiddleAI", targets: ["MiddleAIApp"]),
        .executable(name: "middleai-tests", targets: ["MiddleAITestRunner"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            revision: "4266f988d170a83017d1e82e2e4654602f277f1d"
        )
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(
            name: "MiddleAICore",
            dependencies: [
                "CSQLite",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift")
            ],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("Security"),
                .linkedFramework("Network")
            ]
        ),
        .executableTarget(name: "MiddleAICLI", dependencies: ["MiddleAICore"]),
        .executableTarget(
            name: "MiddleAIApp",
            dependencies: [
                "MiddleAICore",
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        ),
        .executableTarget(name: "MiddleAITestRunner", dependencies: ["MiddleAICore"])
    ],
    swiftLanguageModes: [.v5]
)
