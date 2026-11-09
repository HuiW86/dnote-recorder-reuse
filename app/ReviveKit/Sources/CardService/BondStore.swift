import Foundation
import Security

/// Where bondIds live, keyed by the card's serial (prd.md §3, §5.1). Never in the database
/// and never logged (CLAUDE.md rule 4).
@MainActor
public protocol BondStore: AnyObject {
    func bondId(serial: String) throws -> Data?
    func save(_ bondId: Data, serial: String) throws
    func remove(serial: String) throws
}

/// Keychain store, readable after first unlock so background reconnects can use it.
@MainActor
public final class KeychainBondStore: BondStore {
    private let service: String

    public init(service: String = "revive.bond") {
        self.service = service
    }

    public func bondId(serial: String) throws -> Data? {
        var query = baseQuery(serial)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw CardServiceError.bondStorageFailed
        }
    }

    public func save(_ bondId: Data, serial: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: bondId,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(baseQuery(serial) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(baseQuery(serial).merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CardServiceError.bondStorageFailed }
    }

    public func remove(serial: String) throws {
        let status = SecItemDelete(baseQuery(serial) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CardServiceError.bondStorageFailed
        }
    }

    private func baseQuery(_ serial: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serial,
        ]
    }
}

/// In-memory store for tests and previews.
@MainActor
public final class InMemoryBondStore: BondStore {
    public private(set) var bonds: [String: Data]

    public init(_ bonds: [String: Data] = [:]) {
        self.bonds = bonds
    }

    public func bondId(serial: String) throws -> Data? { bonds[serial] }
    public func save(_ bondId: Data, serial: String) throws { bonds[serial] = bondId }
    public func remove(serial: String) throws { bonds[serial] = nil }
}
