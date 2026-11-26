// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "icecap",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "icecap", targets: ["Icecap"]),
        .executable(name: "icecap-spacer", targets: ["IcecapSpacer"]),
        .library(name: "IcecapCore", targets: ["IcecapCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .target(name: "IcecapCore"),
        .executableTarget(
            name: "Icecap",
            dependencies: [
                "IcecapCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // Scripts/build-app.sh copies Sparkle.framework into the bundle's Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "IcecapSpacer",
            dependencies: ["IcecapCore"]
        ),
        .testTarget(
            name: "IcecapCoreTests",
            dependencies: ["IcecapCore"]
        ),
    ]
)
