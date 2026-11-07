import CardLink
import CardProtocol
import Foundation

/// Reads a link's event stream in tests. The fake card queues replies synchronously,
/// so a test can send, then read exactly what came back.
@MainActor
public final class LinkEventReader {
    private var buffer: [LinkEvent] = []
    private var waiter: CheckedContinuation<LinkEvent?, Never>?
    private var finished = false

    public init(_ link: some CardLink) {
        let events = link.events
        Task { [weak self] in
            for await event in events { self?.deliver(event) }
            self?.finish()
        }
    }

    public func next() async -> LinkEvent? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if finished { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }

    private func deliver(_ event: LinkEvent) {
        if let w = waiter {
            waiter = nil
            w.resume(returning: event)
        } else {
            buffer.append(event)
        }
    }

    private func finish() {
        finished = true
        waiter?.resume(returning: nil)
        waiter = nil
    }

    /// Next notification parsed as a frame, skipping state and discovery events.
    /// Returns nil for an unparsable notification.
    public func nextFrame() async -> Frame? {
        while let event = await next() {
            if case .notification(let data) = event { return Frame.parse(data) }
        }
        return nil
    }

    /// Like `nextFrame`, but throws when the stream ends or the notification is unparsable.
    public func frame() async throws -> Frame {
        guard let f = await nextFrame() else { throw ReaderError.noFrame }
        return f
    }

    public enum ReaderError: Error { case noFrame }

    /// Next state change, skipping other events.
    public func nextState() async -> LinkState? {
        while let event = await next() {
            if case .state(let s) = event { return s }
        }
        return nil
    }

    /// Download chunks up to and including the first non-data chunk; nil marks a truncated chunk.
    public func chunks() async -> [FileChunk?] {
        var out: [FileChunk?] = []
        while let frame = await nextFrame(), frame.command == .fileData {
            let chunk = FileChunk.parse(frame)
            out.append(chunk)
            if chunk?.status != .data { break }
        }
        return out
    }
}
