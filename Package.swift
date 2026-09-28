// swift-tools-version: 6.0

import PackageDescription

/// Unpacks zip archives with Apple's Compression framework, so the app needs no third-party zip library.
let package = Package(
    name: "CompressionKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .visionOS(.v2)
    ],
    products: [
        .library(name: "CompressionKit", targets: ["CompressionKit"])
    ],
    targets: [
        .target(name: "CompressionKit")
    ]
)
