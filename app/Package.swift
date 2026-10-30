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
    targets: [
        .target(
            name: "PKDKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PKDApp",
            dependencies: ["PKDKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PKDSelfTest",
            dependencies: ["PKDKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
