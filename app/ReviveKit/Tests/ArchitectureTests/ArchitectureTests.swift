import Testing
import CardProtocol
import CardLink
import CardService
import DeviceSource
import Library
import SyncEngine
import Player
import AppModel

// Every M1 module must build and link together. Dependency direction is fixed in
// Package.swift; the no-networking rule is checked by scripts/check-m1-rules.sh.
struct ArchitectureTests {
    @Test func allModulesLink() {
        let names = [
            String(describing: Command.self), String(describing: LinkState.self), String(describing: CardService.self),
            String(describing: SourceFile.self),
            String(describing: SyncEngine.self), String(describing: RecordingPlayer.self),
            String(describing: CardSession.self),
        ]
        #expect(names.count == Set(names).count)
    }
}
