// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ProxyLensCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProxyLensCore", targets: ["ProxyLensCore"])
    ],
    targets: [
        .target(name: "ProxyLensCore"),
        .testTarget(name: "ProxyLensCoreTests", dependencies: ["ProxyLensCore"])
    ]
)
