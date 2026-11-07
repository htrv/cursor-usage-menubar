// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CursorUsageMenubar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CursorUsageMenubar",
            path: "Sources"
        )
    ]
)
