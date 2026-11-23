// 闻笺 account (features.md K1, O1b) against our backend (prd.md §7). This module talks to the
// network, so no device module may depend on it (CLAUDE.md rule 3, scripts/check-m1-rules.sh).
// Nothing here runs unless the user opens the account pages: signed out, the app sends nothing
// to the backend (prd.md §7.1, backend-design.md §4.6).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The signed-in account as the backend describes it (`UserOut`).
public struct AccountUser: Codable, Equatable, Sendable {
    public var id: UUID
    public var phone: String?
    public var email: String?
    public var emailVerified: Bool
    public var hasPassword: Bool

    public init(id: UUID, phone: String? = nil, email: String? = nil, emailVerified: Bool = false,
                hasPassword: Bool = false) {
        self.id = id
        self.phone = phone
        self.email = email
        self.emailVerified = emailVerified
        self.hasPassword = hasPassword
    }

    /// "138****5678" or the email address, for the account page.
    public var displayName: String {
        if let phone {
            let digits = phone.hasPrefix("+86") ? String(phone.dropFirst(3)) : phone
            guard digits.count == 11 else { return digits }
            return String(digits.prefix(3)) + "****" + String(digits.suffix(4))
        }
        return email ?? ""
    }
}

/// What is kept between launches. The refresh token is the secret: it lives in the Keychain only.
public struct AccountSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var user: AccountUser

    public init(accessToken: String, refreshToken: String, user: AccountUser) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.user = user
    }
}

public enum AccountError: Error, Equatable, Sendable {
    /// The backend's error (prd.md §7.3): branch on `code`, show `message`.
    case server(status: Int, code: String, message: String, retryable: Bool)
    /// This phone has no usable connection, or 闻笺's 无线数据 is off in iOS Settings.
    case offline
    /// No answer from the server: DNS, TLS, timeout.
    case unreachable
    /// An answer this build cannot read.
    case badReply
    /// Not signed in, or the sign-in ended (refresh refused): sign in again.
    case signedOut

    /// The backend's code, nil for errors that never reached it.
    public var code: String? {
        if case .server(_, let code, _, _) = self { return code }
        return nil
    }

    /// A failed request as the user should read it: `.offline` for the URL errors that mean this
    /// phone has no usable connection, otherwise `.unreachable`.
    static func network(_ error: Error) -> AccountError {
        switch (error as? URLError)?.code {
        case .notConnectedToInternet?, .dataNotAllowed?, .internationalRoamingOff?: .offline
        default: .unreachable
        }
    }
}

extension AccountError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .server(let status, _, let message, _):
            return message.isEmpty ? "服务暂时出错（\(status)），请稍后再试" : message
        case .offline:
            // Same sentence as AssistantError.offlineAdvice (product-spec.md §7.3a); this module
            // must not depend on Assistant.
            return "这部手机连不上网，请检查网络或「设置 › 闻笺 › 无线数据」"
        case .unreachable:
            return "连不上闻笺的服务器，请稍后再试"
        case .badReply:
            return "服务器的回答看不懂，请稍后再试"
        case .signedOut:
            return "登录已失效，请重新登录"
        }
    }
}

/// Sends one request and returns the body and the status code. Tests pass a stub.
public protocol AccountTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionAccountTransport: AccountTransport {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountError.badReply }
        return (data, http.statusCode)
    }
}

/// The account API (prd.md §7.2 账号, 意见反馈). One instance per app; an actor, so a burst of
/// requests that all find the access token expired share a single refresh.
public actor AccountClient {
    public nonisolated let baseURL: URL
    private let transport: any AccountTransport
    private let store: any AccountSessionStoring
    private let newKey: @Sendable () -> String
    private var refreshing: Task<AccountSession, Error>?

    /// `newKey` makes `Idempotency-Key`s; tests pass a counter.
    public init(baseURL: URL, transport: any AccountTransport = URLSessionAccountTransport(),
                store: any AccountSessionStoring, newKey: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.baseURL = baseURL
        self.transport = transport
        self.store = store
        self.newKey = newKey
    }

    /// The stored sign-in, from the Keychain only: never the network.
    public func session() -> AccountSession? {
        try? store.read()
    }

    // MARK: - Signing in (no token)

    /// Returns the seconds before another code may be asked for.
    public func sendSMSCode(phone: String) async throws -> Int {
        let reply: CodeSent = try await decode(post("auth/sms/send", ["phone": phone]))
        return reply.resendAfterSeconds
    }

    /// Signs in, creating the account on first use.
    public func signIn(phone: String, code: String) async throws -> AccountUser {
        try await keep(decode(post("auth/sms/login", ["phone": phone, "code": code])))
    }

    /// Creates an unverified account (or sets a new password on one never verified) and emails a code.
    public func register(email: String, password: String) async throws -> Int {
        let reply: CodeSent = try await decode(post("auth/email/register", ["email": email, "password": password]))
        return reply.resendAfterSeconds
    }

    public func verifyEmail(_ email: String, code: String) async throws -> AccountUser {
        try await keep(decode(post("auth/email/verify", ["email": email, "code": code])))
    }

    public func signIn(email: String, password: String) async throws -> AccountUser {
        try await keep(decode(post("auth/password/login", ["email": email, "password": password])))
    }

    /// The same answer whether or not the address has an account.
    public func sendPasswordReset(email: String) async throws -> Int {
        let reply: CodeSent = try await decode(post("auth/password/reset/send", ["email": email]))
        return reply.resendAfterSeconds
    }

    /// Sets a new password and signs every device out; sign in again afterwards.
    public func resetPassword(email: String, code: String, newPassword: String) async throws {
        _ = try await post("auth/password/reset", ["email": email, "code": code, "new_password": newPassword])
    }

    // MARK: - Signed in

    /// Reads the account again and updates the stored copy.
    public func refreshUser() async throws -> AccountUser {
        let user: AccountUser = try decode(await authorized("GET", "me"))
        if var current = try? store.read() {
            current.user = user
            try? store.save(current)
        }
        return user
    }

    /// Signs every other device out; this one gets new tokens.
    public func changePassword(current: String, new: String) async throws -> AccountUser {
        try await keep(decode(authorized("POST", "me/password",
                                         ["current_password": current, "new_password": new])))
    }

    public func sendFeedback(_ content: String, appVersion: String) async throws {
        _ = try await authorized("POST", "feedback", ["content": content, "app_version": appVersion])
    }

    /// Deletes the account and everything the backend keeps for it (App Store requirement,
    /// backend-design.md §4.7). Recordings on this phone stay. Signed out afterwards.
    public func deleteAccount() async throws {
        _ = try await authorized("DELETE", "me")
        try? store.save(nil)
    }

    /// Signs out on this phone whether or not the server can be told; the server is asked to
    /// revoke the refresh token when it answers.
    public func signOut() async {
        guard let session = try? store.read() else { return }
        try? store.save(nil)
        _ = try? await perform(request("POST", "auth/logout", ["refresh_token": session.refreshToken], key: newKey()))
    }

    // MARK: - Requests

    private struct CodeSent: Decodable {
        let resendAfterSeconds: Int
    }

    private struct Tokens: Decodable {
        let accessToken: String
        let refreshToken: String
        let user: AccountUser
    }

    private func keep(_ tokens: Tokens) throws -> AccountUser {
        let session = AccountSession(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
                                     user: tokens.user)
        do { try store.save(session) } catch { throw AccountError.badReply }
        return tokens.user
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(T.self, from: data) } catch { throw AccountError.badReply }
    }

    /// An unauthenticated write: every one carries an `Idempotency-Key` (prd.md §7.1).
    private func post(_ path: String, _ body: [String: String]) async throws -> Data {
        try await perform(request("POST", path, body, key: newKey()))
    }

    /// With the access token. `token_expired` refreshes once and sends again with a new key (the
    /// first try never reached the handler); a token the server no longer knows signs out.
    private func authorized(_ method: String, _ path: String, _ body: [String: String]? = nil) async throws -> Data {
        guard let session = try? store.read() else { throw AccountError.signedOut }
        let write = method != "GET"
        do {
            return try await perform(request(method, path, body, token: session.accessToken, key: write ? newKey() : nil))
        } catch let error as AccountError {
            switch error.code {
            case "token_expired":
                let fresh = try await refreshed(from: session)
                return try await perform(request(method, path, body, token: fresh.accessToken,
                                                 key: write ? newKey() : nil))
            case "invalid_token", "unauthorized":
                try? store.save(nil)
                throw AccountError.signedOut
            default:
                throw error
            }
        }
    }

    /// One refresh at a time. A caller that finds the token already replaced uses the new one.
    private func refreshed(from stale: AccountSession) async throws -> AccountSession {
        if let current = try? store.read(), current.accessToken != stale.accessToken { return current }
        if let running = refreshing { return try await running.value }
        let task = Task { try await self.refresh(stale.refreshToken) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    /// The refresh token is spent by the first request that reaches the server, so a retry after
    /// a lost connection must carry the same `Idempotency-Key`: the server then returns the same
    /// new tokens instead of treating the spent token as stolen (prd.md §7.1).
    private func refresh(_ refreshToken: String) async throws -> AccountSession {
        let req = try request("POST", "auth/refresh", ["refresh_token": refreshToken], key: newKey())
        var attempt = 0
        while true {
            attempt += 1
            do {
                let tokens: Tokens = try decode(await perform(req))
                _ = try keep(tokens)
                return AccountSession(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
                                      user: tokens.user)
            } catch let error as AccountError {
                switch error {
                case .server(let status, _, _, _) where status == 401:
                    try? store.save(nil)
                    throw AccountError.signedOut
                case .offline, .unreachable:
                    if attempt < 2 { continue }
                    throw error
                default:
                    throw error
                }
            }
        }
    }

    private func request(_ method: String, _ path: String, _ body: [String: String]?, token: String? = nil,
                         key: String?) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1").appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let key { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let status: Int
        do {
            let reply = try await transport.send(request)
            data = reply.0
            status = reply.1
        } catch let error as AccountError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw AccountError.network(error)
        }
        guard (200..<300).contains(status) else { throw Self.serverError(data, status: status) }
        return data
    }

    /// `{"error": {"code", "message", "retryable"}}` (prd.md §7.3); anything else keeps the status.
    static func serverError(_ data: Data, status: Int) -> AccountError {
        struct Reply: Decodable {
            struct Body: Decodable {
                let code: String
                let message: String
                let retryable: Bool?
            }
            let error: Body
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            return .server(status: status, code: "http_\(status)", message: "", retryable: status >= 500)
        }
        return .server(status: status, code: reply.error.code, message: reply.error.message,
                       retryable: reply.error.retryable ?? false)
    }
}
