// swift-tools-version: 5.9
import PackageDescription

// The iOS device and simulator binaries are unmodified slices from Microsoft's
// Microsoft.ML.OnnxRuntime 1.20.0 NuGet package. The SHA-256 of its inner
// runtimes/ios/native/onnxruntime.xcframework.zip before removing Catalyst was
// d92cacf2ec95cddff5b4b87695b7772563cba0de6cfa28c81627ed2a8f9c399c.
// The matching Objective-C bindings use Microsoft's commit 12ce7374c86944e1f68f3a866d10105d8357f074.
let package = Package(
    name: "OfflineVoiceRuntime",
    platforms: [.iOS(.v17)],
    products: [.library(name: "OfflineVoiceRuntime", targets: ["OfflineVoiceRuntime"])],
    targets: [
        .binaryTarget(name: "onnxruntime", path: "onnxruntime.xcframework"),
        .target(name: "OnnxRuntimeBindings", dependencies: ["onnxruntime"], path: "objectivec",
                cxxSettings: [.define("SPM_BUILD")],
                linkerSettings: [.linkedFramework("CoreML"), .linkedFramework("Accelerate")]),
        .target(name: "OfflineVoiceRuntime", dependencies: ["OnnxRuntimeBindings"],
                resources: [.copy("LICENSE"), .copy("ONNX-LICENSE.txt"), .copy("ThirdPartyNotices.txt")])
    ],
    cxxLanguageStandard: .cxx17
)
