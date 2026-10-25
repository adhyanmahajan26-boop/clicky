// swift-tools-version:5.9
// Xcode fixture for Tools/eval/final_eval.py (opened from a temporary copy, never built by the eval).
import PackageDescription

let package = Package(
    name: "EvalFixture",
    targets: [
        .executableTarget(name: "EvalFixture"),
        .testTarget(name: "EvalFixtureTests", dependencies: ["EvalFixture"])
    ]
)
