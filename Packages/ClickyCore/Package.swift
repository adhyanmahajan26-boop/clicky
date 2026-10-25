// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClickyCore",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "ClickyCore", targets: ["ClickyCore"]),
        .executable(name: "cwb-check", targets: ["cwb-check"]),
        .executable(name: "code-agent-args", targets: ["code-agent-args"])
    ],
    dependencies: [
        // Whiteboard math rendering (MTMathImage). Pinned; see docs/v2/PENDING_LIVE_TESTS.md (P4).
        .package(url: "https://github.com/mgriebling/SwiftMath", exact: "1.7.3")
    ],
    targets: [
        .target(name: "ClickyCore", dependencies: [.product(name: "SwiftMath", package: "SwiftMath")]),
        // Whiteboard parse check for evals: `swift run cwb-check <file>`.
        .executableTarget(name: "cwb-check", dependencies: ["ClickyCore"]),
        // The Code-mode agent's exact argv/settings as JSON, for Tools/codeprobe.sh.
        .executableTarget(name: "code-agent-args", dependencies: ["ClickyCore"]),
        .testTarget(name: "ClickyCoreTests", dependencies: ["ClickyCore"], exclude: ["Fixtures", "Goldens"])
    ],
    swiftLanguageModes: [.v5]
)
