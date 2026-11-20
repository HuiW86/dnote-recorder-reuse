import Foundation
import Testing
@testable import AppModel

// prd.md §2.5 (#53): the ordering rule on its own. The session-level cases with the fake card
// are in HomeModelTests and DeviceStatusTests.
struct RecordingStateOrderTests {
    @Test func ticketStaysCurrentUntilSomethingIsObserved() {
        var order = RecordingStateOrder()
        let card = UUID()
        let ticket = order.ticket(for: card)
        #expect(order.isCurrent(ticket))
        #expect(ticket.deviceId == card)
        order.observed()
        #expect(!order.isCurrent(ticket))
        #expect(order.isCurrent(order.ticket(for: card)))
    }

    @Test func commandStartOvertakesEarlierTickets() {
        var order = RecordingStateOrder()
        let before = order.ticket(for: nil)
        order.commandStarted()
        #expect(order.commandRunning)
        #expect(!order.isCurrent(before))
        // The command's own read, sent after it started, is not overtaken by the start.
        let during = order.ticket(for: nil)
        #expect(order.isCurrent(during))
        order.commandEnded()
        #expect(!order.commandRunning)
        #expect(order.isCurrent(during))
    }
}
