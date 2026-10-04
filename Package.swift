// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GlanceBar",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Tests only (snapshot tests need XCTest, i.e. Xcode: run them with scripts/test.sh). NFR-6.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.19.6"),
    ],
    targets: [
        .executableTarget(
            name: "GlanceBar",
            path: "Sources/GlanceBar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GlanceBarTests",
            dependencies: ["GlanceBar", .product(name: "SnapshotTesting", package: "swift-snapshot-testing")],
            path: "Tests/GlanceBarTests",
            exclude: ["__Snapshots__"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
