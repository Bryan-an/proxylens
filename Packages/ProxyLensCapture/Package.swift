// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ProxyLensCapture",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProxyLensCapture", targets: ["ProxyLensCapture"])
    ],
    dependencies: [
        .package(path: "../ProxyLensCore"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.3")
    ],
    targets: [
        .target(
            name: "ProxyLensCapture",
            dependencies: [
                .product(name: "ProxyLensCore", package: "ProxyLensCore"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ]
        ),
        .testTarget(
            name: "ProxyLensCaptureTests",
            dependencies: [
                "ProxyLensCapture",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ]
        )
    ]
)
