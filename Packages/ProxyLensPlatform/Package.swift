// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ProxyLensPlatform",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProxyLensPlatform", targets: ["ProxyLensPlatform"])
    ],
    dependencies: [
        .package(path: "../ProxyLensCore"),
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.18.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.6.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1")
    ],
    targets: [
        .target(
            name: "ProxyLensPlatform",
            dependencies: [
                .product(name: "ProxyLensCore", package: "ProxyLensCore"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "X509", package: "swift-certificates")
            ],
            linkerSettings: [
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .testTarget(
            name: "ProxyLensPlatformTests",
            dependencies: [
                "ProxyLensPlatform",
                .product(name: "X509", package: "swift-certificates")
            ]
        )
    ]
)
