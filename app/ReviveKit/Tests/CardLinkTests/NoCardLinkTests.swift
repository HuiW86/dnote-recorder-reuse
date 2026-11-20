import Foundation
import Testing
import CardLink
import CardProtocol

// 先不连卡 (product-spec.md P01): the link the tabs use before Bluetooth was ever asked about.
@MainActor
struct NoCardLinkTests {
    @Test func neverConnectsNorWrites() async {
        let link = NoCardLink()
        #expect(link.state == .idle)
        #expect(link.peripheralId == nil)
        link.startScan()
        link.stopScan()
        link.disconnect()
        await #expect(throws: LinkError.connectFailed) { try await link.connect(UUID()) }
        await #expect(throws: LinkError.notConnected) { try await link.send(.deviceInfo) }
    }
}
