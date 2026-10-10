// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "741-mix",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "741mix", targets: ["MixApp"]),
        .library(name: "MixCore", targets: ["MixCore"]),
    ],
    targets: [
        .target(name: "MixCore"),
        // Audio-Thread-Code arbeitet bewusst mit geteiltem Zustand → Swift-5-Modus
        .target(name: "MixEngine", dependencies: ["MixCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "MixApp", dependencies: ["MixCore", "MixEngine"],
                          resources: [.copy("Resources")],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MixCoreTests", dependencies: ["MixCore"]),
    ]
)
