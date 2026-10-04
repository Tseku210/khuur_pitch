// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "khuur_pitch",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "khuur-pitch", targets: ["khuur_pitch"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "khuur_pitch",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
