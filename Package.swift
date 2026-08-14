// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "V2T",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "V2T",
            path: "Sources/V2T"
        )
    ]
)
