// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ChiboardTelemetry",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "ChiboardTelemetry",
            type: .static,
            targets: ["ChiboardTelemetry"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/microsoft/plcrashreporter.git",
            exact: "1.12.2"
        ),
    ],
    targets: [
        .target(
            name: "ChiboardTelemetry",
            dependencies: [
                .product(name: "CrashReporter", package: "plcrashreporter"),
            ],
            resources: [
                .process("Resources/PrivacyInfo.xcprivacy"),
                .process("Resources/en.lproj/PrivacyNotice.txt"),
                .process("Resources/zh-Hans.lproj/PrivacyNotice.txt"),
            ]
        ),
        .testTarget(
            name: "ChiboardTelemetryTests",
            dependencies: ["ChiboardTelemetry"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
