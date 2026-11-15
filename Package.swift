// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotificationLab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "NotificationLab", path: "Sources/NotificationLab")
    ]
)
