// Where a sign-in survives app restarts: the refresh token and the account it belongs to, in
// the Keychain. The access token is never stored; it lives 15 minutes and is refreshed.

import Foundation
#if canImport(Security)
import Security
#endif

/// What is kept between launches.
public struct SavedSession: Codable, Equatable, Sendable {
    public var refreshToken: String
    public var user: AccountUser
    /// Written before rotating this token so a lost reply can be replayed after relaunch.
    public var pendingRefreshKey: String?

    public init(refreshToken: String, user: AccountUser) {
        self.refreshToken = refreshToken
        self.user = user
    }
}

public protocol SessionStoring: Sendable {
    func load() throws -> SavedSession?
    /// Replaces what is stored; nil removes it.
    func save(_ session: SavedSession?) throws
}

/// For tests and previews.
public final class InMemorySessionStore: SessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var session: SavedSession?

    public init(_ session: SavedSession? = nil) {
        self.session = session
    }

    public func load() throws -> SavedSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    public func save(_ session: SavedSession?) throws {
        lock.lock()
        defer { lock.unlock() }
        self.session = session
    }
}

public enum SessionStoreError: Error, Equatable, Sendable {
    case keychain(Int32)
}

#if canImport(Security)
/// Keychain item readable after first unlock, on this device only: a refresh token is a
/// credential and must not travel to another phone in a backup. A new phone signs in again.
public struct KeychainSessionStore: SessionStoring {
    private let service: String
    private let account: String

    public init(service: String = "revive.account", account: String = "session") {
        self.service = service
        self.account = account
    }

    public func load() throws -> SavedSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            // Unreadable (an older format): treated as signed out rather than an error.
            return try? JSONDecoder().decode(SavedSession.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw SessionStoreError.keychain(status)
        }
    }

    public func save(_ session: SavedSession?) throws {
        guard let session else {
            let status = SecItemDelete(baseQuery() as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SessionStoreError.keychain(status)
            }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(session),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(baseQuery().merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SessionStoreError.keychain(status) }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
#endif
