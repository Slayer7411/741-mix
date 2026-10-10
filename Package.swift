// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MINOS-741",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "minos741", targets: ["MixApp"]),
        .library(name: "MixCore", targets: ["MixCore"]),
    ],
    targets: [
        .target(name: "MixCore"),
        // Echtzeit-Audiokern (C++, plattformneutral) + CoreAudio-Backend; Signalsmith Stretch (MIT) für Keylock
        .target(name: "MixDSP",
                exclude: ["vendor/signalsmith-stretch/LICENSE.txt", "vendor/signalsmith-linear/LICENSE.txt", "vendor/VERSIONS.txt"],
                cxxSettings: [.headerSearchPath("vendor"), .define("SIGNALSMITH_USE_ACCELERATE"),
                              .unsafeFlags(["-O3"])],
                linkerSettings: [.linkedFramework("Accelerate"), .linkedFramework("AudioToolbox")]),
        // Ableton Link 3.1.5 (GPL-2.0-or-later) über die C-Schnittstelle abl_link
        .target(name: "LinkKit",
                exclude: ["LICENSE-Link.md", "GNU-GPL-v2.0.md", "VERSION.txt", "asio/LICENSE_1_0.txt", "link", "asio"],
                sources: ["abl_link.cpp"],
                cxxSettings: [.headerSearchPath("link/include"), .headerSearchPath("asio/include"),
                              .define("LINK_PLATFORM_MACOSX", to: "1")]),
        // Audio-Thread-Code arbeitet bewusst mit geteiltem Zustand → Swift-5-Modus
        .target(name: "MixEngine", dependencies: ["MixCore", "MixDSP", "LinkKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "MixApp", dependencies: ["MixCore", "MixEngine"],
                          resources: [.copy("Resources")],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MixCoreTests", dependencies: ["MixCore"]),
    ],
    cxxLanguageStandard: .cxx17
)
