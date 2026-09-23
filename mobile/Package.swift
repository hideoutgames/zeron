// swift-tools-version: 6.1
// This is a Skip (https://skip.dev) package.
import PackageDescription

let skipstone = [Target.PluginUsage.plugin(name: "skipstone", package: "skip")]

let package = Package(
    name: "mobile",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ZeronMobile", type: .dynamic, targets: ["ZeronMobile"]),
        .library(name: "ZeronClient", type: .dynamic, targets: ["ZeronClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/skiptools/skip.git", from: "1.9.11"),
        .package(url: "https://github.com/skiptools/skip-fuse-ui.git", from: "1.0.0"),
        .package(url: "https://github.com/skiptools/skip-fuse.git", from: "1.0.0"),
        .package(url: "https://github.com/skiptools/skip-model.git", from: "1.0.0"),
        .package(url: "https://github.com/skiptools/skip-keychain.git", "0.0.0"..<"2.0.0"),
    ],
    targets: [
        .target(
            name: "ZeronMobile",
            dependencies: [
                "ZeronClient",
                .product(name: "SkipFuseUI", package: "skip-fuse-ui"),
            ],
            path: "App",
            resources: [.process("Resources")],
            plugins: skipstone
        ),
        .target(
            name: "ZeronClient",
            dependencies: [
                "ZeronGenerated",
                "ZeronPlatform",
                .product(name: "SkipFuse", package: "skip-fuse"),
                .product(name: "SkipModel", package: "skip-model"),
            ],
            path: "Client",
            plugins: skipstone
        ),
        .target(
            name: "ZeronPlatform",
            dependencies: [
                .product(name: "SkipFuse", package: "skip-fuse"),
                .product(name: "SkipKeychain", package: "skip-keychain"),
            ],
            path: "Platform",
            plugins: skipstone
        ),
        .target(
            name: "ZeronGenerated",
            dependencies: [
                .product(name: "SkipFuse", package: "skip-fuse"),
            ],
            path: "Generated",
            plugins: skipstone
        ),
        .testTarget(
            name: "ZeronClientTests",
            dependencies: [
                "ZeronClient",
                .product(name: "SkipTest", package: "skip"),
            ],
            path: "Tests",
            resources: [.copy("Fixtures")],
            plugins: skipstone
        ),
    ]
)
