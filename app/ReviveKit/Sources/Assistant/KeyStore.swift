// The user's API key for their own service (ADR-009): only in the Keychain, never in the
// database, UserDefaults or logs. We ship no key of our own.

import Foundation
import Security

public enum KeyStoreError: Error, Equatable, Sendable {
    /// The Keychain call failed with this status.
    case keychain(Int32)
}

/// Where the API key lives.
public protocol ServiceKeyStoring: Sendable {
    /// Stores the key, replacing an earlier one; an empty key deletes it.
    func save(_ key: String) throws
    /// The stored key, nil when there is none.
    func read() throws -> String?
    /// Removes the key; succeeds when there was none.
    func delete() throws
}

/// Keychain store, readable after first unlock like the bond store (CardService/BondStore.swift),
/// so a summary started before the phone locks can still finish.
public struct KeychainKeyStore: ServiceKeyStoring {
    private let service: String
    private let account: String

    public init(service: String = "revive.assistant", account: String = "api-key") {
        self.service = service
        self.account = account
    }

    public func save(_ key: String) throws {
        guard !key.isEmpty else { return try delete() }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(baseQuery().merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
    }

    public func read() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeyStoreError.keychain(status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyStoreError.keychain(status) }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// In-memory store for tests and previews.
public final class InMemoryKeyStore: ServiceKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    public init(_ key: String? = nil) {
        self.key = key
    }

    public func save(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        self.key = key.isEmpty ? nil : key
    }

    public func read() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return key
    }

    public func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        key = nil
    }
}
