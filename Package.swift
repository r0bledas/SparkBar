// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SparkBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "SparkBar",
            targets: ["SparkBar"]
        )
    ],
    targets: [
        .executableTarget(
            name: "SparkBar",
            path: "Sources/SparkBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Security"),
                .linkedFramework("WebKit"),
                .linkedFramework("PDFKit")
            ]
        ),
        .testTarget(
            name: "SparkBarTests",
            dependencies: ["SparkBar"],
            path: "Tests/SparkBarTests"
        )
    ]
)
