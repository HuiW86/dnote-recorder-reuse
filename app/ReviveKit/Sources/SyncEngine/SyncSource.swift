import CardLink
import CardProtocol
import CardService
import Foundation

/// What SyncEngine needs from a recording device (ADR-010): link state, device info, the pairing
/// check, the file list, the recording state, download and delete. The D·NOTE card's
/// `CardService` is the first implementation; another device joins by implementing this, and
/// the sync state machine, the library and CLAUDE.md rule 2 (store before delete) stay shared.
///
/// The value types are still the card's (`CardFile`, `DeviceInfo`, `RecordingStatus`) and errors
/// are `CardServiceError`; they become device-neutral when a second device needs it (M6, #73).
@MainActor
public protocol SyncSource: AnyObject {
    var linkState: LinkState { get }
    /// The connected (or pending) device's link id.
    var peripheralId: UUID? { get }
    /// The latest device info seen on this link, if any.
    var lastInfo: DeviceInfo? { get }
    func info() async throws -> DeviceInfo
    /// Paired with this phone; files are only taken from a paired device.
    func isPairedWithThisPhone() async throws -> Bool
    /// Throws `CardServiceError.cardBusyRecording` while the device records.
    func listFiles() async throws -> [CardFile]
    func recordingStatus() async throws -> RecordingStatus
    /// Downloads `file` from byte `offset`, handing each chunk to `onData` as it arrives.
    func download(_ file: CardFile, from offset: Int, onData: @escaping (Data) -> Void) async throws
    /// Only called after the file is stored on the phone (CLAUDE.md rule 2).
    func delete(_ name: String) async throws
}

extension CardService: SyncSource {}
