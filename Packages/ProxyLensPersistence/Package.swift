// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ProxyLensPersistence",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProxyLensPersistence", targets: ["ProxyLensPersistence"])
    ],
    dependencies: [
        .package(path: "../ProxyLensCore")
    ],
    targets: [
        .target(
            name: "ProxyLensPersistence",
            dependencies: [
                .product(name: "ProxyLensCore", package: "ProxyLensCore")
            ]
        ),
        .testTarget(name: "ProxyLensPersistenceTests", dependencies: ["ProxyLensPersistence"])
    ]
)
