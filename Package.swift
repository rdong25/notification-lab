// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotificationLab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "NotificationLab", path: "Sources/NotificationLab"),
        // Command-line client; ships inside the app at Contents/Helpers/notiflab.
        .executableTarget(name: "notiflab", path: "Sources/notiflab"),
    ]
)
