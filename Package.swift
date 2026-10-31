// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Morrow",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.executable(name: "Morrow", targets: ["MorrowApp"]), .library(name: "MorrowCore", targets: ["MorrowCore"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "f5b0677f6b52b81d068871611cfcb82d1e7a0005", traits: []),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0")
    ],
    targets: [
        .target(name: "CMail", linkerSettings: [.linkedLibrary("curl", .when(platforms: [.macOS])), .linkedLibrary("sqlite3"), .linkedLibrary("z"), .linkedFramework("Security")]),
        .target(name: "MorrowCore", dependencies: ["CMail", .product(name: "MLXEmbedders", package: "mlx-swift-lm"), .product(name: "Tokenizers", package: "swift-transformers")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "MorrowApp", dependencies: ["MorrowCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MorrowCoreTests", dependencies: ["MorrowCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MorrowAppTests", dependencies: ["MorrowApp"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
