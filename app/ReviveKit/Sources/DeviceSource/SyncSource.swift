import Foundation

// What SyncEngine needs from a recording device (ADR-010). The types here say nothing about
// D·NOTE: no frames, command bytes, encryption or file-name format. The D·NOTE card is the
// first implementation (`CardSyncSource` in CardService); another device joins by implementing
// `SyncSource`, and the sync state machine, the library and CLAUDE.md rule 2 (store before
// delete) stay shared.

/// A file on the device. Name and size together identify it (prd.md §4.3).
public struct SourceFile: Hashable, Sendable {
    public var name: String
    /// Bytes as downloaded; a resumed download continues at an offset into these.
    public var size: Int

    public init(name: String, size: Int) {
        self.name = name
        self.size = size
    }
}

/// What the library keeps about a device (prd.md §5.1 `device`).
public struct SourceInfo: Equatable, Sendable {
    /// Stable per device: the library's key for it (`device.sn`).
    public var serial: String
    public var firmware: String
    public var battery: Int?
    public var freeMb: Int?
    public var totalMb: Int?

    public init(serial: String, firmware: String, battery: Int? = nil, freeMb: Int? = nil, totalMb: Int? = nil) {
        self.serial = serial
        self.firmware = firmware
        self.battery = battery
        self.freeMb = freeMb
        self.totalMb = totalMb
    }
}

/// The device errors SyncEngine tells apart (prd.md §6). An implementation maps its own errors
/// to these; anything else it throws ends the pass as `storeFailed`.
public enum SourceError: Error, Equatable, Sendable {
    /// No link, the link dropped, or Bluetooth is unusable.
    case disconnected
    /// The device is not paired with this phone: nothing is taken from it.
    case notPaired
    /// The device is recording, so its file list says nothing about its files.
    case busyRecording
    /// The device refuses every transfer until it is restarted.
    case busy
    case fileNotFound
    /// Bytes arrived malformed or out of order: what was received cannot be trusted.
    case transferFailed
    /// No reply in time; what was received so far is still good.
    case requestTimeout
    /// A reply the device's protocol does not allow.
    case unexpectedReply
    case other
}

/// Device events that start a sync pass (prd.md §4.4).
public enum SourceEvent: Equatable, Sendable {
    case connected
    case recordingStopped
}

/// A device's own event type, as seen by SyncEngine: nil for events it ignores.
public protocol SourceEventConvertible {
    var sourceEvent: SourceEvent? { get }
}

extension SourceEvent: SourceEventConvertible {
    public var sourceEvent: SourceEvent? { self }
}

/// A downloaded file as the library stores it.
public struct SourceAudio: Sendable {
    /// OGG Opus, which the library and the player expect.
    public var ogg: Data
    public var durationMs: Int

    public init(ogg: Data, durationMs: Int) {
        self.ogg = ogg
        self.durationMs = durationMs
    }
}

/// Turns the bytes of one downloaded file into `SourceAudio`. Runs off the main actor.
public protocol SourceAudioConverter: Sendable {
    func convert(_ raw: Data) throws -> SourceAudio
}

@MainActor
public protocol SyncSource: AnyObject {
    var isConnected: Bool { get }
    /// The connected (or pending) device's link id: a pass stops when it changes.
    var connectionId: UUID? { get }
    /// Name of a device the library has not named yet, such as "录音卡". Never a brand
    /// (CLAUDE.md rule 5).
    var defaultDeviceName: String { get }
    var audioConverter: any SourceAudioConverter { get }
    /// The latest info seen on this link, or asks the device.
    func deviceInfo() async throws -> SourceInfo
    /// Files are only taken from a device paired with this phone.
    func isPairedWithThisPhone() async throws -> Bool
    /// Recording or paused: no file is synced meanwhile (H5).
    func isRecording() async throws -> Bool
    /// Throws `SourceError.busyRecording` rather than return a list that means nothing.
    func listFiles() async throws -> [SourceFile]
    /// Downloads `file` from byte `offset`, handing each chunk to `onData` as it arrives.
    /// Chunks handed over before a failure stay valid.
    func download(_ file: SourceFile, from offset: Int, onData: @escaping (Data) -> Void) async throws
    /// Only called after the file is stored on the phone (CLAUDE.md rule 2). The outcome is
    /// confirmed with `listFiles`, so returning does not have to mean the file is gone.
    func delete(_ name: String) async throws
    /// When the recording started, from what the device says about the file; nil when unknown.
    func startDate(of file: SourceFile) -> Date?
}
