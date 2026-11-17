// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FadedAICastBrowser",
    platforms: [.iOS("18.0")],
    products: [.library(name: "CastBrowserFeature", targets: ["CastBrowserFeature"])],
    dependencies: [.package(url: "https://github.com/googlecast/google-cast-ios-sdk", exact: "4.8.6")],
    targets: [
        .target(name: "CastBrowserFeature", dependencies: [
            .product(name: "GoogleCastDynamic", package: "google-cast-ios-sdk")
        ], resources: [.process("Assets.xcassets"), .copy("AdBlockingRules.json")])
    ]
)
