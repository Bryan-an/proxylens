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
        .package(path: "../ProxyLensApplication"),
        .package(path: "../ProxyLensPlatform"),
        .package(path: "../ProxyLensPersistence"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.3"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", exact: "1.45.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.36.1")
    ],
    targets: [
        .target(
            name: "ProxyLensCapture",
            dependencies: [
                .product(name: "ProxyLensCore", package: "ProxyLensCore"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ],
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),
        .testTarget(
            name: "ProxyLensCaptureTests",
            dependencies: [
                "ProxyLensCapture",
                .product(name: "ProxyLensApplication", package: "ProxyLensApplication"),
                .product(name: "ProxyLensPersistence", package: "ProxyLensPersistence"),
                .product(name: "ProxyLensPlatform", package: "ProxyLensPlatform"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ]
        )
    ]
)
