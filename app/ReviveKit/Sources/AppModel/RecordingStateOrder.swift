import Foundation

/// The ordering rule for the recording state of the card on the link (prd.md §2.5, #53).
///
/// The state reaches the app three ways over one Bluetooth link: command replies (`0x50`–`0x53`),
/// pushes from the card (`0x54`, `0x55`, `0x56 {rec:0}`, the periodic `0x80`) and the app's own
/// `0x56` reads. Their events are handled by different tasks, so an answer can be handled after
/// something newer. Rather than one counter per case, every observation advances one sequence:
///
/// - command replies and pushes are applied as they come: nothing handled before them is newer;
/// - a `0x56` answer is applied only if nothing was observed since its read was sent (a push, any
///   `0x80`, even one that agrees with the screen, a command starting, the link dropping). An
///   overtaken answer may still refine the shown state (recorded time, file name) when it names
///   the same state of the same recording on the same card, but never change it;
/// - a later `0x80` that disagrees is not applied itself: it starts a `0x56` read, and is applied
///   only if that read gets no answer and nothing was observed since that `0x80`;
/// - while a recording command waits for its reply (or for the `0x56` after its timeout), a
///   disagreeing `0x80` starts nothing: the command settles the state.
struct RecordingStateOrder {
    /// A point in the sequence, taken when a read is sent or a fallback is held back.
    struct Ticket: Equatable, Sendable {
        fileprivate let sequence: Int
        /// The card on the link when the ticket was taken.
        let deviceId: UUID?
    }

    private var sequence = 0
    /// A recording command is waiting for its reply or for the `0x56` read after a timeout.
    private(set) var commandRunning = false

    /// Something told the state, or may have changed it: an applied state, any `0x80`, a link drop.
    mutating func observed() { sequence += 1 }

    /// A recording command was sent. Its reply is newer than any answer still on its way.
    mutating func commandStarted() {
        commandRunning = true
        sequence += 1
    }

    mutating func commandEnded() { commandRunning = false }

    func ticket(for deviceId: UUID?) -> Ticket { Ticket(sequence: sequence, deviceId: deviceId) }

    /// Nothing was observed since `ticket` was taken.
    func isCurrent(_ ticket: Ticket) -> Bool { ticket.sequence == sequence }
}
