// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "icecap",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "icecap", targets: ["Icecap"]),
        .library(name: "IcecapCore", targets: ["IcecapCore"]),
    ],
    targets: [
        .target(name: "IcecapCore"),
        .executableTarget(
            name: "Icecap",
            dependencies: ["IcecapCore"]
        ),
        .testTarget(
            name: "IcecapCoreTests",
            dependencies: ["IcecapCore"]
        ),
    ]
)
