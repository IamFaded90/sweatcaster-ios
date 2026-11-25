// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OfflineSongRuntime",
    platforms: [.iOS("18.0"), .macOS(.v14)],
    // MLX and Draw Things both define metal-cpp globals. Give MLX its own Mach-O image.
    products: [.library(name: "OfflineSongRuntime", type: .dynamic, targets: ["OfflineSongRuntime"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4")
    ],
    targets: [
        .target(name: "OfflineSongRuntime", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXRandom", package: "mlx-swift")
        ], path: "Sources/OfflineSongRuntime", resources: [.copy("License.txt")]),
        .testTarget(name: "OfflineSongRuntimeTests", dependencies: ["OfflineSongRuntime"])
    ],
    swiftLanguageVersions: [.v5]
)
