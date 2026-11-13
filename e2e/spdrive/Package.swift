// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "spdrive",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "spdrive", path: "Sources/spdrive")
    ]
)
