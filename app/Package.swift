// swift-tools-version:5.9
// Symphony Control: build with `make app` (or open this folder in Xcode).
import PackageDescription

let package = Package(
    name: "SymphonyControl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SymphonyControl", path: "Sources"),
    ]
)
