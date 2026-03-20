// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DisplayBuddy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DisplayBuddy",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
            ]
        )
    ]
)
