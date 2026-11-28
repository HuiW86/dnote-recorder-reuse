import CardLink
import CardProtocol
import DeviceSource
import Foundation

/// The D·NOTE card as SyncEngine's device (ADR-010): `CardService` behind the device-neutral
/// `SyncSource`. Everything that is particular to this card stays on this side: the `0x80`
/// info, the `0xA1` pairing check, decryption and OGG wrapping, and the file-name clock.
@MainActor
public final class CardSyncSource: SyncSource {
    public let service: CardService

    public init(_ service: CardService) {
        self.service = service
    }

    public var isConnected: Bool { service.linkState == .connected }
    public var connectionId: UUID? { service.peripheralId }
    /// Pairing names the card first; the card's own Bluetooth name is the brand (ADR-005).
    public var defaultDeviceName: String { "录音卡" }
    public var audioConverter: any SourceAudioConverter { CardAudioConverter() }

    public func deviceInfo() async throws -> SourceInfo {
        let info: DeviceInfo
        if let last = service.lastInfo {
            info = last
        } else {
            info = try await mapErrors { try await service.info() }
        }
        return SourceInfo(serial: info.serial, firmware: info.firmware, battery: info.battery,
                          freeMb: info.freeSpace, totalMb: info.totalSpace)
    }

    public func isPairedWithThisPhone() async throws -> Bool {
        try await mapErrors { try await service.isPairedWithThisPhone() }
    }

    public func isRecording() async throws -> Bool {
        try await mapErrors { try await service.recordingStatus().state != .idle }
    }

    public func listFiles() async throws -> [SourceFile] {
        try await mapErrors { try await service.listFiles() }.map { SourceFile(name: $0.name, size: $0.size) }
    }

    public func download(_ file: SourceFile, from offset: Int, onData: @escaping (Data) -> Void) async throws {
        try await mapErrors {
            try await service.download(CardFile(name: file.name, size: file.size), from: offset, onData: onData)
        }
    }

    public func delete(_ name: String) async throws {
        try await mapErrors { try await service.delete(name) }
    }

    public func startDate(of file: SourceFile) -> Date? {
        CardFile.startDate(fileName: file.name)
    }

    private func mapErrors<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as CardServiceError {
            throw SourceError(error)
        }
    }
}

extension SourceError {
    /// Card error codes as SyncEngine tells them apart (prd.md §6).
    init(_ error: CardServiceError) {
        switch error {
        case .notPaired: self = .notPaired
        case .cardBusyRecording: self = .busyRecording
        case .cardBusy: self = .busy
        case .fileNotFound: self = .fileNotFound
        case .transferFailed: self = .transferFailed
        case .requestTimeout: self = .requestTimeout
        case .unexpectedReply: self = .unexpectedReply
        case .disconnected, .bluetoothOff, .bluetoothUnauthorized, .bluetoothUnsupported,
             .connectTimeout, .connectFailed, .unknownCard: self = .disconnected
        case .pairVerifyFailed, .pairCancelled, .invalidArgument, .bondStorageFailed: self = .other
        }
    }
}

extension CardEvent: SourceEventConvertible {
    /// A connect or a stop on the card starts a sync pass (prd.md §4.4).
    public var sourceEvent: SourceEvent? {
        switch self {
        case .stateChanged(.connected): .connected
        case .recordingStopped: .recordingStopped
        default: nil
        }
    }
}

/// Raw card bytes -> OGG (prd.md §4.2 step 2): decrypt when encrypted, split into 40-byte
/// frames of 20 ms each, wrap in OGG.
public struct CardAudioConverter: SourceAudioConverter {
    public init() {}

    public func convert(_ raw: Data) throws -> SourceAudio {
        let opus = AudioCrypto.isEncrypted(raw) ? try AudioCrypto.decrypt(raw) : raw
        let frames = OggOpus.splitFrames(opus)
        guard !frames.isEmpty else { throw AudioError.tooShort }
        return SourceAudio(ogg: OggOpus.wrap(frames), durationMs: frames.count * 20)
    }
}
