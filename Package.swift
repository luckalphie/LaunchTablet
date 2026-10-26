// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LaunchTablet",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LaunchTablet", targets: ["LaunchTablet"])
    ],
    targets: [
        .executableTarget(name: "LaunchTablet", resources: [.process("Resources")]),
        .testTarget(name: "LaunchTabletTests", dependencies: ["LaunchTablet"])
    ]
)
