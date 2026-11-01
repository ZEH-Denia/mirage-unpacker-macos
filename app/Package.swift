// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PKD",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PKD", targets: ["PKDApp"]),
        .library(name: "PKDKit", targets: ["PKDKit"]),
        .executable(name: "pkd-selftest", targets: ["PKDSelfTest"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(
            name: "PKDKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PKDApp",
            dependencies: [
                "PKDKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks"]),
            ]
        ),
        .executableTarget(
            name: "PKDSelfTest",
            dependencies: ["PKDKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
