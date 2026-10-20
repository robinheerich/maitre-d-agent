// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MaitreDAgent",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MaitreDAgent", path: "Sources/MaitreDAgent")
    ]
)
