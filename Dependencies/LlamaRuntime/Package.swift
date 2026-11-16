// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FadedAILlamaRuntime",
    platforms: [.iOS("18.0")],
    products: [.library(name: "FadedAILlamaRuntime", targets: ["FadedAILlamaRuntime"])],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b8668/llama-b8668-xcframework.zip",
            checksum: "639716d1e2fb47f1d4361fea9609fcd7286aff4618b2f9b8a4743c28d8ab41fb"
        ),
        .target(name: "FadedAILlamaRuntime", dependencies: ["llama"], resources: [.copy("LICENSE")])
    ]
)
