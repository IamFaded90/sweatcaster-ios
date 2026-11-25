// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "ClonedVoiceRuntime", platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "FadedAICloneRuntime", targets: ["FadedAICloneRuntime"])],
    dependencies: [
        .package(url: "https://github.com/iliasaz/chatterbox-coreml", revision: "b8288834e783f3a6210757fbaf62f9014220bff9"),
        .package(url: "https://github.com/iliasaz/perth-coreml.git", branch: "main"),
        // Match Wax and the existing pinned Draw Things engine's shared Crypto major.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.7.1")
    ], targets: [.target(name: "FadedAICloneRuntime", dependencies: [
        .product(name: "ChatterboxCoreML", package: "chatterbox-coreml"),
        .product(name: "PerthCoreML", package: "perth-coreml")
    ])], swiftLanguageModes: [.v5])
