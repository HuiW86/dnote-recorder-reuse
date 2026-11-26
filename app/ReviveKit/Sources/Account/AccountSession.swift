// The signed-in state and the token dance (prd.md §7.1): the access token is refreshed before it
// runs out or when the server says it has; one refresh at a time, retried with the same
// Idempotency-Key after a lost answer, so the server never sees a spent refresh token twice
// (that would revoke this sign-in's refresh-token family).

import Foundation

public actor AccountSession {
    public nonisolated let client: AccountClient
    private let store: any SessionStoring
    private let now: @Sendable () -> Date

    /// The account, nil when signed out.
    public var user: AccountUser? { saved?.user }
    private var saved: SavedSession?
    private var access: (token: String, expires: Date)?
    private var refreshing: Task<String, Error>?
    /// Changes when a sign-in is replaced or forgotten, including another login by the same user.
    private var signInID = UUID()

    /// Refreshes this long before the access token runs out, against clock drift.
    static let margin: TimeInterval = 60

    public init(client: AccountClient, store: any SessionStoring, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.store = store
        self.now = now
        saved = try? store.load()
    }

    public var isSignedIn: Bool { saved != nil }

    /// Keeps a new sign-in (any sign-in call, a password change).
    public func adopt(_ tokens: AccountTokens) throws {
        try storeTokens(tokens)
        signInID = UUID()
        refreshing = nil
    }

    private func storeTokens(_ tokens: AccountTokens) throws {
        let session = SavedSession(refreshToken: tokens.refreshToken, user: tokens.user)
        try store.save(session)
        saved = session
        access = (tokens.accessToken, now().addingTimeInterval(TimeInterval(tokens.expiresIn) - Self.margin))
    }

    /// Runs `call` with a valid access token. When the server says the token has run out, refreshes
    /// once and tries again. Throws `.signedOut` (and forgets the sign-in) when the sign-in ended.
    public func authorized<T: Sendable>(_ call: @Sendable (String) async throws -> T) async throws -> T {
        try await authorized(for: signInID, call)
    }

    private func authorized<T: Sendable>(for owner: UUID, _ call: @Sendable (String) async throws -> T) async throws -> T {
        try requireCurrent(owner)
        var retried = false
        while true {
            let token = try await accessToken()
            try requireCurrent(owner)
            do {
                let result = try await call(token)
                try requireCurrent(owner)
                return result
            } catch let error as AccountError {
                try requireCurrent(owner)
                if !retried && error.code == "token_expired" {
                    retried = true
                    if access?.token == token { access = nil }
                    continue
                }
                if error.code == "invalid_token" || error.code == "unauthorized" {
                    try? forget()
                    throw AccountError.signedOut
                }
                throw error
            }
        }
    }

    /// The account as the server has it now; also keeps the stored copy current.
    @discardableResult
    public func reloadUser() async throws -> AccountUser {
        let owner = signInID
        let client = client
        let fresh = try await authorized(for: owner) { try await client.me(accessToken: $0) }
        try requireCurrent(owner)
        if var session = saved {
            session.user = fresh
            saved = session
            try? store.save(session)
        }
        return fresh
    }

    public func changePassword(current: String, new: String) async throws {
        let owner = signInID
        let client = client
        let tokens = try await authorized(for: owner) {
            try await client.changePassword(accessToken: $0, current: current, new: new)
        }
        try requireCurrent(owner)
        try adopt(tokens)
    }

    /// Deletes the account on the server, then forgets it here. Recordings on this phone stay.
    public func deleteAccount() async throws {
        let owner = signInID
        let client = client
        try await authorized(for: owner) { try await client.deleteAccount(accessToken: $0) }
        try requireCurrent(owner)
        try forget()
    }

    /// Signs out on the server when it can be reached, and always here.
    public func signOut() async {
        let refreshToken = saved?.refreshToken
        try? forget()
        if let refreshToken {
            try? await client.signOut(refreshToken)
        }
    }

    // MARK: Tokens

    func accessToken() async throws -> String {
        if let access, access.expires > now() { return access.token }
        // Everyone waiting shares one refresh: a second one would spend the token twice.
        if let refreshing { return try await refreshing.value }
        guard var session = saved else { throw AccountError.signedOut }
        let key = session.pendingRefreshKey ?? UUID().uuidString
        if session.pendingRefreshKey == nil {
            session.pendingRefreshKey = key
            try store.save(session)
            saved = session
        }
        let spent = session.refreshToken
        let owner = signInID
        let task = Task { try await self.refresh(spent, key: key, owner: owner) }
        refreshing = task
        defer { if signInID == owner { refreshing = nil } }
        return try await task.value
    }

    private func requireCurrent(_ owner: UUID) throws {
        guard signInID == owner else { throw CancellationError() }
    }

    private func refresh(_ spent: String, key: String, owner: UUID) async throws -> String {
        try requireCurrent(owner)
        do {
            let tokens = try await client.refresh(spent, idempotencyKey: key)
            try requireCurrent(owner)
            try storeTokens(tokens)
            return tokens.accessToken
        } catch let error as AccountError {
            try requireCurrent(owner)
            if case .server(_, let code, _, _) = error, code.hasPrefix("refresh_") {
                try? forget()
                throw AccountError.signedOut
            }
            // Lost answer or server trouble: the pending key stays with the original token.
            throw error
        }
    }

    private func forget() throws {
        signInID = UUID()
        refreshing = nil
        saved = nil
        access = nil
        try store.save(nil)
    }
}
