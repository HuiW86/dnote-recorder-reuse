import Testing
import CardProtocol
import CardLink
import CardService
import Library
import SyncEngine
import Player

// Every M1 module must build and link together. Dependency direction is fixed in
// Package.swift; the no-networking rule is checked by scripts/check-m1-rules.sh.
struct ArchitectureTests {
    @Test func allModulesLink() {
        let names = [
            String(describing: Command.self), String(describing: LinkState.self), CardServiceModule.name,
            SyncEngineModule.name, PlayerModule.name,
        ]
        #expect(names.count == Set(names).count)
    }
}
