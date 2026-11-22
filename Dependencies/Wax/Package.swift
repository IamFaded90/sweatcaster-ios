// swift-tools-version: 6.2
import PackageDescription

// Wax 17b211996af3774c2fbc4c676e2e750b04aa3027, with iOS platform guards.
// This library graph matches the app's original traits: [] selection.
// Optional embedding providers and desktop executables are not build targets.
let package = Package(
    name: "Wax",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "Wax", targets: ["Wax"])],
    dependencies: [
        .package(url: "https://github.com/christopherkarani/MetalANNS.git", exact: "0.4.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.7.0"),
    ],
    targets: [
        .target(
            name: "WaxCoreCompressionC",
            path: "Sources/WaxCoreCompressionC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("lz4", .when(platforms: [.linux])),
                .linkedLibrary("z", .when(platforms: [.linux])),
            ]
        ),
        .target(
            name: "WaxCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .target(name: "WaxCoreCompressionC", condition: .when(platforms: [.linux])),
            ]
        ),
        .target(
            name: "WaxTextSearch",
            dependencies: [
                "WaxCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "GRDBSQLite", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "WaxVectorSearchC",
            path: "Sources/WaxVectorSearchC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "WaxVectorSearch",
            dependencies: [
                "WaxCore",
                "WaxVectorSearchC",
                .product(name: "MetalANNS", package: "MetalANNS",
                         condition: .when(platforms: [.macOS, .iOS])),
            ],
            resources: [.process("Shaders")]
        ),
        .target(
            name: "Wax",
            dependencies: ["WaxCore", "WaxTextSearch", "WaxVectorSearch"],
            resources: [.process("RAG/Resources")]
        ),
    ]
)
