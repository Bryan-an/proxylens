// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ProxyLensPersistence",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProxyLensPersistence", targets: ["ProxyLensPersistence"])
    ],
    dependencies: [
        .package(path: "../ProxyLensCore"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")
    ],
    targets: [
        .target(
            name: "ProxyLensPersistence",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ProxyLensCore", package: "ProxyLensCore")
            ]
        ),
        .testTarget(
            name: "ProxyLensPersistenceTests",
            dependencies: [
                "ProxyLensPersistence",
                .product(name: "ProxyLensCore", package: "ProxyLensCore")
            ]
        )
    ]
)
