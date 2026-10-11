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
        // Cloud-Library (File Provider): Prüfen lokal / nur online, Download-Planer, FSEvents, Anheft-Status.
        // Ohne Abhängigkeiten, später Teil des Datei-Dienstes
        .target(name: "LibraryCloud"),
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
        // Dekodieren, Wellenform-Analyse, Übersicht, Phrasen-Anker, Cover – ohne Audiogerät, auch im Datei-Dienst
        .target(name: "MixMedia", dependencies: ["MixCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // Audio-Thread-Code arbeitet bewusst mit geteiltem Zustand → Swift-5-Modus
        .target(name: "MixEngine", dependencies: ["MixCore", "MixMedia", "MixDSP", "LinkKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "MixApp", dependencies: ["MixCore", "MixEngine", "LibraryCloud"],
                          resources: [.copy("Resources")],
                          swiftSettings: [.swiftLanguageMode(.v5)],
                          linkerSettings: [.linkedFramework("CoreAudioKit")]),   // Plugin-Fenster (AUGenericView)
        .testTarget(name: "MixCoreTests", dependencies: ["MixCore"]),
        .testTarget(name: "LibraryCloudTests", dependencies: ["LibraryCloud"]),
        // .mtrk: Rundreise gegen Dekodieren im Prozess, kaputte Köpfe, Löschen während eingeblendet
        .testTarget(name: "MixMediaTests", dependencies: ["MixMedia", "MixCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // Kern offline rendern (kein Audiogerät): Transport, Loop, Keylock, FX-Fahnen, Übergabe
        .testTarget(name: "MixEngineTests", dependencies: ["MixDSP", "MixMedia", "MixEngine"]),
        // Controller-Ereignisse offline (ohne Gerät, ohne Audio) durch den Kern schicken
        .testTarget(name: "MixAppTests", dependencies: ["MixApp", "MixCore", "MixEngine"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ],
    cxxLanguageStandard: .cxx17
)
