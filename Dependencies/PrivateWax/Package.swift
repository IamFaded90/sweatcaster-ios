// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "FadedAIPrivateWax",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "FadedAIPrivateWax", targets: ["FadedAIPrivateWax"])],
    dependencies: [
        .package(path: "../Wax")
    ],
    targets: [
        .target(name: "FadedAIPrivateWax", dependencies: [.product(name: "Wax", package: "Wax")],
                resources: [.copy("Wax-LICENSE.txt")]),
        .testTarget(name: "PrivateWaxTests", dependencies: ["FadedAIPrivateWax"])
    ]
)
