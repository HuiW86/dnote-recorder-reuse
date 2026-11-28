// swift-tools-version:6.0
// Linux-only manifest for scripts/linux-test.sh: the ReviveKit modules that need nothing but
// Foundation (plus GRDB and swift-crypto in place of CryptoKit). The `revive` executable builds
// without Player (no add-audio on Linux). CoreBluetooth, AVFoundation,
// Speech, Security and SwiftUI code is left out and is tested on macOS CI only. Never used by
// the app; the real manifest is app/ReviveKit/Package.swift.
import PackageDescription

let crypto = Target.Dependency.product(name: "Crypto", package: "swift-crypto")

let package = Package(
    name: "ReviveKitLinux",
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(name: "os", path: "Shim/os"),
        .target(name: "ThreadingShim", path: "Shim/ThreadingShim"),
        .target(name: "CardProtocol", dependencies: [crypto]),
        .target(name: "CardLink", dependencies: ["CardProtocol"], exclude: ["BluetoothCardLink.swift"]),
        .target(name: "DeviceSource"),
        .target(name: "CardService", dependencies: ["CardProtocol", "CardLink", "DeviceSource", "os"]),
        .target(name: "Library", dependencies: [.product(name: "GRDB", package: "GRDB.swift"), crypto]),
        .target(name: "SyncEngine", dependencies: ["DeviceSource", "Library", "os", "ThreadingShim", crypto]),
        .target(name: "LinkImport"),
        .target(name: "Account"),
        .target(name: "AIRoute"),
        .target(name: "LibraryTools", dependencies: ["Library", "ThreadingShim"]),
        .executableTarget(name: "revive", dependencies: ["Library", "LibraryTools"]),
        .target(name: "CardTestSupport", dependencies: ["CardProtocol", "CardLink"], path: "Tests/CardTestSupport",
                exclude: ["SyntheticOpus.swift"]),
        .testTarget(name: "CardProtocolTests", dependencies: ["CardProtocol", "CardTestSupport"],
                    exclude: ["OggOpusTests.swift"], resources: [.copy("Fixtures")]),
        .testTarget(name: "CardLinkTests", dependencies: ["CardProtocol", "CardLink", "CardTestSupport"]),
        .testTarget(name: "CardServiceTests", dependencies: [
            "CardProtocol", "CardLink", "CardService", "CardTestSupport", "DeviceSource",
        ]),
        .testTarget(name: "LibraryTests", dependencies: ["Library"]),
        .testTarget(name: "LinkImportTests", dependencies: ["LinkImport"]),
        .testTarget(name: "AccountTests", dependencies: ["Account"]),
        .testTarget(name: "AIRouteTests", dependencies: ["AIRoute"]),
        .testTarget(name: "LibraryToolsTests", dependencies: ["Library", "LibraryTools"]),
        .testTarget(name: "SyncEngineTests", dependencies: [
            "CardProtocol", "CardLink", "CardService", "DeviceSource", "Library", "SyncEngine", "CardTestSupport",
        ]),
    ]
)
