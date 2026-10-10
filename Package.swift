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
        // Echtzeit-Audiokern (C++, plattformneutral) + CoreAudio-Backend; Time-Stretch-Bibliothek (MIT) für Keylock
        // VST 3 SDK 3.8.1 (MIT, Steinberg): nur Laden und Betreiben von Plugins (Module, Fabrik, Parameter, Verbindung)
        .target(name: "VST3SDK",
                exclude: ["LICENSE.txt", "VERSION.txt", "pluginterfaces/LICENSE.txt", "public.sdk/LICENSE.txt"],
                cxxSettings: [.headerSearchPath("."), .define("RELEASE", to: "1")],
                linkerSettings: [.linkedFramework("Cocoa")]),
        .target(name: "MixDSP",
                dependencies: ["VST3SDK"],
                exclude: ["vendor/signalsmith-stretch/LICENSE.txt", "vendor/signalsmith-linear/LICENSE.txt", "vendor/VERSIONS.txt"],
                cxxSettings: [.headerSearchPath("vendor"), .headerSearchPath("../VST3SDK"), .define("SIGNALSMITH_USE_ACCELERATE"),
                              .define("RELEASE", to: "1"), .unsafeFlags(["-O3"])],
                linkerSettings: [.linkedFramework("Accelerate"), .linkedFramework("AudioToolbox")]),
        // Link 3.1.5 (Netzwerk-Tempo-Sync, GPL-2.0-or-later) über die C-Schnittstelle abl_link
        .target(name: "LinkKit",
                exclude: ["LICENSE-Link.md", "GNU-GPL-v2.0.md", "VERSION.txt", "asio/LICENSE_1_0.txt", "link", "asio"],
                sources: ["abl_link.cpp"],
                cxxSettings: [.headerSearchPath("link/include"), .headerSearchPath("asio/include"),
                              .define("LINK_PLATFORM_MACOSX", to: "1")]),
        // Audio-Thread-Code arbeitet bewusst mit geteiltem Zustand → Swift-5-Modus
        .target(name: "MixEngine", dependencies: ["MixCore", "MixDSP", "LinkKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "MixApp", dependencies: ["MixCore", "MixEngine"],
                          resources: [.copy("Resources")],
                          swiftSettings: [.swiftLanguageMode(.v5)],
                          linkerSettings: [.linkedFramework("CoreAudioKit")]),   // Plugin-Fenster (AUGenericView)
        .testTarget(name: "MixCoreTests", dependencies: ["MixCore"]),
        // Kern offline rendern (kein Audiogerät): Transport, Loop, Keylock, FX-Fahnen, Übergabe
        .testTarget(name: "MixEngineTests", dependencies: ["MixDSP", "MixEngine"]),
    ],
    cxxLanguageStandard: .cxx17
)
