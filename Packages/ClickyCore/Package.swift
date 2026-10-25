// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClickyCore",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "ClickyCore", targets: ["ClickyCore"]),
        .executable(name: "cwb-check", targets: ["cwb-check"])
    ],
    targets: [
        .target(name: "ClickyCore"),
        // Whiteboard parse check for evals: `swift run cwb-check <file>`.
        .executableTarget(name: "cwb-check", dependencies: ["ClickyCore"]),
        .testTarget(name: "ClickyCoreTests", dependencies: ["ClickyCore"])
    ],
    swiftLanguageModes: [.v5]
)
