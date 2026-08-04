// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ProxyLensApplication",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProxyLensApplication", targets: ["ProxyLensApplication"])
    ],
    dependencies: [
        .package(path: "../ProxyLensCore")
    ],
    targets: [
        .target(
            name: "ProxyLensApplication",
            dependencies: [
                .product(name: "ProxyLensCore", package: "ProxyLensCore")
            ]
        ),
        .testTarget(name: "ProxyLensApplicationTests", dependencies: ["ProxyLensApplication"])
    ]
)
