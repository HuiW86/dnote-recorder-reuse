// swift-tools-version:6.0
// Module layout follows docs/prd.md §1. M1 modules must not depend on any
// networking library; scripts/check-m1-rules.sh enforces this in CI.

import PackageDescription

let package = Package(
    name: "ReviveKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReviveKit", targets: [
            "CardProtocol", "CardLink", "CardService", "DeviceSource", "Library", "SyncEngine", "Player",
            "Transcription", "AppModel", "Assistant",
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
        // What SyncEngine needs from any recording device (ADR-010). Foundation only: no D·NOTE
        // frames, commands, encryption or file names.
        .target(name: "DeviceSource"),
        // Device operations, pairing, unsolicited events; `CardSyncSource` makes the card a DeviceSource.
        .target(name: "CardService", dependencies: ["CardProtocol", "CardLink", "DeviceSource"]),
        // Local database and audio files.
        .target(name: "Library", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        // Device files -> local library, per the sync state machine. Knows devices only through
        // DeviceSource, never the D·NOTE modules (ADR-010; scripts/check-m1-rules.sh).
        .target(name: "SyncEngine", dependencies: ["DeviceSource", "Library"]),
        // Playback and export of stored OGG files.
        .target(name: "Player", dependencies: ["Library"]),
        // Screen state for the SwiftUI app (no views): one session over the device stack,
        // onboarding, pairing, home and recording detail (product-spec.md). Tested against the fake card.
        // On-device speech recognition of stored recordings (features.md X9). Offline: no
        // networking, enforced by scripts/check-m1-rules.sh like the M1 modules.
        .target(name: "Transcription", dependencies: ["Library", "Player"]),
        .target(name: "AppModel", dependencies: ["CardLink", "CardService", "Library", "SyncEngine", "Player",
                                                 "Transcription", "Assistant"]),
        // Summaries through a service the user configures (features.md X11, G1; ADR-009). The one
        // module allowed to use the network: no device module may depend on it (CLAUDE.md rule 3).
        .target(name: "Assistant", dependencies: ["Library", "Player", "Transcription"]),

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
            "CardProtocol", "CardLink", "CardService", "CardTestSupport", "DeviceSource",
        ]),
        .testTarget(name: "LibraryTests", dependencies: ["Library"]),
        .testTarget(name: "TranscriptionTests", dependencies: ["Library", "Transcription"]),
        .testTarget(name: "AssistantTests", dependencies: [
            "Library", "Assistant", "Transcription", "Player", "CardProtocol", "CardTestSupport",
        ]),
        .testTarget(name: "PlayerTests", dependencies: ["CardProtocol", "Library", "Player", "CardTestSupport"]),
        .testTarget(name: "SyncEngineTests", dependencies: [
            "CardProtocol", "CardLink", "CardService", "DeviceSource", "Library", "SyncEngine", "CardTestSupport",
        ]),
        .testTarget(name: "AppModelTests", dependencies: [
            "AppModel", "CardProtocol", "CardLink", "CardService", "Library", "SyncEngine", "Player", "CardTestSupport",
            "Assistant",
        ]),
        .testTarget(name: "ArchitectureTests", dependencies: [
            "CardProtocol", "CardLink", "CardService", "DeviceSource", "Library", "SyncEngine", "Player", "AppModel",
        ]),
    ]
)
