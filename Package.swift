// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "Luma",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(
            name: "Luma",
            targets: ["Luma"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Luma"
        )
    ]
)