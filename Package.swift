// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SDCardImporter",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "SDCardImporterCore",
            path: "Sources/Shared"
        ),
        .testTarget(
            name: "SDCardImporterTests",
            dependencies: ["SDCardImporterCore"],
            path: "Tests/SDCardImporterTests"
        ),
    ]
)
