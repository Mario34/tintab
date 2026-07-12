// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tintap",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tintap", targets: ["Tintap"])
    ],
    targets: [
        .executableTarget(name: "Tintap"),
        .testTarget(
            name: "TintapTests",
            dependencies: ["Tintap"]
        )
    ]
)
