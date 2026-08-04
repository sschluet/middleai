// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MiddleAI",
  defaultLocalization: "de",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "MiddleAICore", targets: ["MiddleAICore"]),
    .executable(name: "middleai-cli", targets: ["MiddleAICLI"]),
    .executable(name: "MiddleAI", targets: ["MiddleAIApp"]),
    .executable(name: "middleai-tests", targets: ["MiddleAITestRunner"]),
  ],
  dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")
  ],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .target(
      name: "MiddleAICore",
      dependencies: [
        "CSQLite",
        .product(name: "FluidAudio", package: "FluidAudio"),
      ],
      resources: [.process("Resources")],
      linkerSettings: [
        .linkedFramework("AVFoundation"),
        .linkedFramework("NaturalLanguage"),
        .linkedFramework("Security"),
        .linkedFramework("Network"),
        .linkedFramework("ApplicationServices"),
      ]
    ),
    .executableTarget(name: "MiddleAICLI", dependencies: ["MiddleAICore"]),
    .executableTarget(
      name: "MiddleAIApp",
      dependencies: [
        "MiddleAICore",
        .product(name: "FluidAudio", package: "FluidAudio"),
      ],
      resources: [.process("Resources")],
      linkerSettings: [
        .linkedFramework("AudioToolbox"),
        .linkedFramework("CoreAudio"),
      ]
    ),
    .executableTarget(name: "MiddleAITestRunner", dependencies: ["MiddleAICore"]),
    .testTarget(name: "MiddleAICoreTests", dependencies: ["MiddleAICore"]),
  ],
  swiftLanguageModes: [.v6]
)
