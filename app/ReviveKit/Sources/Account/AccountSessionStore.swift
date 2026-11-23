import Foundation
#if canImport(Security)
import Security
#endif

/// Where the sign-in is kept between launches.
public protocol AccountSessionStoring: Sendable {
    func read() throws -> AccountSession?
    /// nil deletes; deleting when there is nothing succeeds.
    func save(_ session: AccountSession?) throws
}

public enum AccountStoreError: Error, Equatable, Sendable {
    /// The Keychain call failed with this status.
    case keychain(Int32)
}

#if canImport(Security)
/// Keychain store, readable after first unlock and kept to this phone like the AI service key
/// (Assistant/KeyStore.swift): a restored backup on a new phone starts signed out.
public struct KeychainAccountSessionStore: AccountSessionStoring {
    private let service: String
    private let account: String

    public init(service: String = "revive.account", account: String = "session") {
        self.service = service
        self.account = account
    }

    public func read() throws -> AccountSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return try? JSONDecoder().decode(AccountSession.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw AccountStoreError.keychain(status)
        }
    }

    public func save(_ session: AccountSession?) throws {
        guard let session else {
            let status = SecItemDelete(baseQuery() as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AccountStoreError.keychain(status)
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
        guard status == errSecSuccess else { throw AccountStoreError.keychain(status) }
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

/// In-memory store for tests and previews.
public final class InMemoryAccountSessionStore: AccountSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var session: AccountSession?

    public init(_ session: AccountSession? = nil) {
        self.session = session
    }

    public func read() throws -> AccountSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    public func save(_ session: AccountSession?) throws {
        lock.lock()
        defer { lock.unlock() }
        self.session = session
    }
}
