// swift-tools-version:6.0
// Module layout follows docs/prd.md §1. M1 modules must not depend on any
// networking library; scripts/check-m1-rules.sh enforces this in CI.

import PackageDescription

let package = Package(
    name: "ReviveKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReviveKit", targets: [
            "CardProtocol", "CardLink", "CardService", "Library", "SyncEngine", "Player",
        ]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
    ],
    targets: [
        // Frame codec, command whitelist, decryption, OGG muxing, firmware table.
        .target(name: "CardProtocol"),
        // CoreBluetooth transport: scan, connect, notify, pending reconnect.
        .target(name: "CardLink", dependencies: ["CardProtocol"]),
        // Device operations, pairing, unsolicited events.
        .target(name: "CardService", dependencies: ["CardProtocol", "CardLink"]),
        // Local database and audio files.
        .target(name: "Library", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        // Card files -> local library, per the sync state machine.
        .target(name: "SyncEngine", dependencies: ["CardService", "Library"]),
        // Playback and export of stored OGG files.
        .target(name: "Player", dependencies: ["Library"]),

        // Fake card and evidence replay for integration tests (test-spec.md §2). Lives under
        // Tests/ and is not part of the product, so it never ships in the app.
        .target(name: "CardTestSupport", dependencies: ["CardProtocol", "CardLink"], path: "Tests/CardTestSupport"),

        .testTarget(
            name: "CardProtocolTests",
            dependencies: ["CardProtocol", "CardTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "CardLinkTests", dependencies: ["CardProtocol", "CardLink", "CardTestSupport"]),
        .testTarget(name: "CardServiceTests", dependencies: [
            "CardProtocol", "CardLink", "CardService", "CardTestSupport",
        ]),
        .testTarget(name: "LibraryTests", dependencies: ["Library"]),
        .testTarget(name: "SyncEngineTests", dependencies: [
            "CardProtocol", "CardLink", "CardService", "Library", "SyncEngine", "CardTestSupport",
        ]),
        .testTarget(name: "ArchitectureTests", dependencies: [
            "CardProtocol", "CardLink", "CardService", "Library", "SyncEngine", "Player",
        ]),
    ]
)
