// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TermTint",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "TermTint", path: "Sources/TermTint")
    ]
)
