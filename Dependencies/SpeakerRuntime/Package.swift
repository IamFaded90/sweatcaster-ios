// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "SpeakerRuntime", platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "FadedAISpeakerRuntime", targets: ["FadedAISpeakerRuntime"])],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio", revision: "e2ea498dafd6db9b3f18f0f644bc35312b3a7679", traits: ["Diarizer"])],
    targets: [.target(name: "FadedAISpeakerRuntime", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")])],
    swiftLanguageModes: [.v5])
