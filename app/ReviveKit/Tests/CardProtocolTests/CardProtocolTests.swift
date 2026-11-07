import Testing
@testable import CardProtocol

// Placeholder until #37 ports the protocol layer and its fixtures (T-M1-01..07).
struct CardProtocolTests {
    @Test func moduleLinks() {
        #expect(CardProtocolModule.name == "CardProtocol")
    }
}
