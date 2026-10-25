// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClickyCore",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "ClickyCore", targets: ["ClickyCore"])
    ],
    targets: [
        .target(name: "ClickyCore"),
        .testTarget(name: "ClickyCoreTests", dependencies: ["ClickyCore"])
    ],
    swiftLanguageModes: [.v5]
)
