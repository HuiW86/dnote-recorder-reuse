import Foundation
import GRDB

/// Database and audio files together; the only way SyncEngine and the UI touch the library.
public final class RecordingLibrary: Sendable {
    public let database: AppDatabase
    public let store: AudioStore

    public init(database: AppDatabase, store: AudioStore) {
        self.database = database
        self.store = store
    }

    // MARK: Startup recovery (prd.md §4.3)

    /// After a launch, possibly following a crash: `downloading` goes back to `discovered`,
    /// temporary files are dropped, and OGG files with no Recording row are removed.
    public func recoverAfterLaunch() throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE sync_item SET state = ? WHERE state = ?",
                           arguments: [SyncState.discovered.rawValue, SyncState.downloading.rawValue])
        }
        store.clearTemporary()
        let known = Set(try database.writer.read { try Recording.fetchAll($0) }.map(\.id))
        for id in store.storedAudioIds() where !known.contains(id) {
            store.removeAudio("audio/\(id.uuidString).ogg")
        }
        store.removeDecoded(except: known)
    }

    // MARK: Devices

    /// Inserts or updates the device with this serial.
    @discardableResult
    public func upsertDevice(sn: String, update: (inout Device) -> Void) throws -> Device {
        try database.writer.write { db in
            var device = try Device.filter(Column("sn") == sn).fetchOne(db)
                ?? Device(sn: sn, name: "", firmware: "")
            update(&device)
            try device.save(db)
            return device
        }
    }

    // MARK: Sync items

    public func syncItems(deviceId: UUID) throws -> [SyncItem] {
        try database.writer.read { db in
            try SyncItem.filter(Column("device_id") == deviceId).order(Column("card_file_name")).fetchAll(db)
        }
    }

    /// The item for this card file, inserted as `discovered` if new.
    public func syncItem(deviceId: UUID, name: String, size: Int) throws -> SyncItem {
        try database.writer.write { db in
            if let item = try SyncItem
                .filter(Column("device_id") == deviceId && Column("card_file_name") == name
                        && Column("card_file_size") == size)
                .fetchOne(db) {
                return item
            }
            var item = SyncItem(deviceId: deviceId, cardFileName: name, cardFileSize: size)
            try item.insert(db)
            return item
        }
    }

    public func update(_ item: SyncItem) throws {
        try database.writer.write { db in try item.update(db) }
    }

    /// Inserts the Recording and moves the item to `stored` (or `deletePending`) in one
    /// transaction (prd.md §4.2 step 4).
    public func commitStored(_ recording: Recording, item: SyncItem, deleteAfterSync: Bool) throws -> SyncItem {
        try database.writer.write { db in
            try recording.insert(db)
            var item = item
            item.state = deleteAfterSync ? .deletePending : .stored
            item.recordingId = recording.id
            item.lastError = nil
            try item.update(db)
            return item
        }
    }

    // MARK: Recordings

    public func recordings() throws -> [Recording] {
        try database.writer.read { try Recording.order(Column("started_at")).fetchAll($0) }
    }

    public func recording(id: UUID) throws -> Recording? {
        try database.writer.read { try Recording.fetchOne($0, key: id) }
    }

    /// Recordings newest first, now and after every change (the home list, product-spec.md P05).
    /// The first value arrives immediately; keep the returned observation to keep observing.
    @MainActor
    public func observeRecordings(onError: @escaping @MainActor (Error) -> Void,
                                  onChange: @escaping @MainActor ([Recording]) -> Void) -> LibraryObservation {
        let observation = ValueObservation.tracking { db in
            try Recording.order(Column("started_at").desc).fetchAll(db)
        }
        return LibraryObservation(observation.start(in: database.writer, scheduling: .immediate,
                                                    onError: onError, onChange: onChange))
    }

    /// Failed files of one card that the user should hear about (product-spec.md P05 SyncStatusCard).
    public func failureCounts(deviceId: UUID) throws -> FailureCounts {
        let failed = try database.writer.read { db in
            try SyncItem.filter(Column("device_id") == deviceId && Column("state") == SyncState.failed.rawValue)
                .fetchAll(db)
        }
        // `SyncFailure.decryptFailed`; SyncEngine sits above Library, so the raw value is spelled out.
        let undecryptable = failed.filter { $0.lastError == "decryptFailed" }.count
        return FailureCounts(retryable: failed.count - undecryptable, undecryptable: undecryptable)
    }

    /// When the newest card recording was stored; nil when none was.
    public func lastStoredAt() throws -> Date? {
        try database.writer.read { db in
            try Date.fetchOne(db, sql: "SELECT MAX(created_at) FROM recording WHERE source = ?",
                              arguments: [Recording.Source.card.rawValue])
        }
    }

    // MARK: Devices for the UI

    /// Devices paired from this phone, oldest first. A row without `pairedAt` was only seen
    /// by a sync and does not count as paired (product-spec.md §5.1 `noDevice`).
    public func pairedDevices() throws -> [Device] {
        try database.writer.read { db in
            try Device.filter(Column("paired_at") != nil).order(Column("paired_at")).fetchAll(db)
        }
    }

    public func device(id: UUID) throws -> Device? {
        try database.writer.read { try Device.fetchOne($0, key: id) }
    }

    /// Deletes a recording, its audio and any decoded copy. The SyncItem stays `stored`, so the file is not
    /// synced again, and nothing is sent to the card (prd.md §4.3, T-M1-32).
    public func deleteRecording(id: UUID) throws {
        guard let recording = try database.writer.write({ db -> Recording? in
            guard let r = try Recording.fetchOne(db, key: id) else { return nil }
            try r.delete(db)
            return r
        }) else { return }
        // Row first: a crash before the file is removed leaves an orphan that recovery deletes.
        store.removeAudio(recording.audioPath)
        store.removeDecoded(id)
    }
}

/// Failed sync items: `retryable` are retried automatically, `undecryptable` never are.
public struct FailureCounts: Equatable, Sendable {
    public var retryable: Int
    public var undecryptable: Int

    public init(retryable: Int, undecryptable: Int) {
        self.retryable = retryable
        self.undecryptable = undecryptable
    }
}

/// Keeps a library observation alive; observing stops when this is released or cancelled.
public final class LibraryObservation: @unchecked Sendable {
    private let cancellable: AnyDatabaseCancellable

    init(_ cancellable: AnyDatabaseCancellable) {
        self.cancellable = cancellable
    }

    public func cancel() { cancellable.cancel() }
}
