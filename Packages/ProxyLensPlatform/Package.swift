// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ProxyLensPlatform",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProxyLensPlatform", targets: ["ProxyLensPlatform"])
    ],
    dependencies: [
        .package(path: "../ProxyLensCore")
    ],
    targets: [
        .target(
            name: "ProxyLensPlatform",
            dependencies: [
                .product(name: "ProxyLensCore", package: "ProxyLensCore")
            ]
        ),
        .testTarget(name: "ProxyLensPlatformTests", dependencies: ["ProxyLensPlatform"])
    ]
)
