// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ProxyLensCapture",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProxyLensCapture", targets: ["ProxyLensCapture"])
    ],
    dependencies: [
        .package(path: "../ProxyLensCore")
    ],
    targets: [
        .target(
            name: "ProxyLensCapture",
            dependencies: [
                .product(name: "ProxyLensCore", package: "ProxyLensCore")
            ]
        ),
        .testTarget(name: "ProxyLensCaptureTests", dependencies: ["ProxyLensCapture"])
    ]
)
