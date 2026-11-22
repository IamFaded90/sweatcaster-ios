// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "FadedAIPrivateWax",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "FadedAIPrivateWax", targets: ["FadedAIPrivateWax"])],
    dependencies: [
        .package(url: "https://github.com/christopherkarani/Wax.git",
                 revision: "17b211996af3774c2fbc4c676e2e750b04aa3027", traits: [])
    ],
    targets: [
        .target(name: "FadedAIPrivateWax", dependencies: [.product(name: "Wax", package: "Wax")],
                resources: [.copy("Wax-LICENSE.txt")]),
        .testTarget(name: "PrivateWaxTests", dependencies: ["FadedAIPrivateWax"])
    ]
)
