// swift-tools-version: 6.0
import PackageDescription

/// The SimpleDataLogs Swift SDK: one library, no dependencies, Swift 6 strict concurrency.
let package = Package(
    name: "SimpleDataLogs",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "SimpleDataLogs", targets: ["SimpleDataLogs"]),
    ],
    targets: [
        // The privacy manifest ships inside the SDK bundle, as App Store review expects.
        .target(name: "SimpleDataLogs", resources: [.copy("Resources/PrivacyInfo.xcprivacy")]),
        .testTarget(name: "SimpleDataLogsTests", dependencies: ["SimpleDataLogs"]),
    ],
    swiftLanguageModes: [.v6]
)
