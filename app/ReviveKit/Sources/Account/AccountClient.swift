// The 闻笺 account on our backend (features.md K1; backend/revive_api/routers/auth.py, me.py).
//
// Optional by design (CLAUDE.md rule 3): nothing on the device path calls this module, and
// scripts/check-m1-rules.sh keeps device and offline modules from importing it. Foundation only,
// so its tests also run on Linux (scripts/linux-test.sh).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The signed-in account as the server describes it (`UserOut`).
public struct AccountUser: Codable, Equatable, Sendable {
    public let id: UUID
    /// "+8613812345678" for a phone account.
    public let phone: String?
    public let email: String?
    public let emailVerified: Bool
    public let hasPassword: Bool

    public init(id: UUID, phone: String?, email: String?, emailVerified: Bool, hasPassword: Bool) {
        self.id = id
        self.phone = phone
        self.email = email
        self.emailVerified = emailVerified
        self.hasPassword = hasPassword
    }

    /// What the account page shows: the phone number with its middle hidden, else the email.
    public var displayName: String {
        phone.map(Self.masked(phone:)) ?? email ?? ""
    }
}

/// A sign-in's tokens (`TokenOut`). The access token lives 15 minutes, the refresh token 30 days
/// and is replaced at every refresh (prd.md §7.1).
public struct AccountTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    /// Seconds the access token is valid.
    public let expiresIn: Int
    public let user: AccountUser

    public init(accessToken: String, refreshToken: String, expiresIn: Int, user: AccountUser) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.user = user
    }
}

public enum AccountError: Error, Equatable, Sendable {
    /// The server answered with its error shape (prd.md §7.3). `message` is written for users.
    case server(status: Int, code: String, message: String, retryable: Bool)
    /// No usable connection on this phone (also: 「无线数据」 turned off for the app).
    case offline
    /// The server could not be reached or did not answer.
    case unreachable(String)
    /// An answer that is not what the API returns.
    case badResponse(Int)
    /// The sign-in ended (refresh token spent or revoked); sign in again.
    case signedOut
    /// A server task (transcription, summary) ended in failure; `message` is written for users.
    case taskFailed(code: String, message: String)

    /// The same sentence the AI features use (features.md X11, product-spec.md §7.3a).
    public static let offlineAdvice = "这部手机连不上网，请检查网络或「设置 › 闻笺 › 无线数据」"

    /// What to show the user.
    public var userText: String {
        switch self {
        case .server(_, _, let message, _): message
        case .offline: Self.offlineAdvice
        case .unreachable: "连不上闻笺的服务器，请稍后再试"
        case .badResponse(let status): "服务器的回答不对（\(status)），请稍后再试"
        case .signedOut: "登录已失效，请重新登录"
        case .taskFailed(_, let message): message.isEmpty ? "服务器没能处理这条录音，请稍后再试" : message
        }
    }

    /// The server's stable code, if it answered with one.
    public var code: String? {
        if case .server(_, let code, _, _) = self { return code }
        return nil
    }

    /// A failed request as the user should read it: `.offline` for the URL errors that mean this
    /// phone has no usable connection, otherwise `.unreachable`.
    static func network(_ error: Error) -> AccountError {
        switch (error as? URLError)?.code {
        case .notConnectedToInternet?, .dataNotAllowed?, .internationalRoamingOff?: .offline
        default: .unreachable(error.localizedDescription)
        }
    }
}

/// Sends one request. Tests pass a stub; the app uses `URLSessionTransport`.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// No cookies, no stored credentials, nothing cached on disk: the only credential is the bearer
/// token the session adds.
public struct URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountError.badResponse(0) }
        return (data, http)
    }
}

/// The account endpoints, one call each. Stateless: `AccountSession` keeps the tokens.
public struct AccountClient: Sendable {
    public let baseURL: URL
    private let transport: any HTTPTransport

    /// `baseURL` is the API root, e.g. https://api.example.com (paths start with /v1).
    public init(baseURL: URL, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// Seconds before another code may be asked for.
    public struct CodeSent: Decodable, Equatable, Sendable {
        public let resendAfterSeconds: Int
    }

    // MARK: Signing in

    public func sendSMSCode(phone: String) async throws -> CodeSent {
        try await post("/v1/auth/sms/send", ["phone": phone])
    }

    /// Signs in with a phone number; the first sign-in creates the account.
    public func signIn(phone: String, code: String) async throws -> AccountTokens {
        try await post("/v1/auth/sms/login", ["phone": phone, "code": code])
    }

    /// Starts an email account; a code goes to the address. Until verified, registering again
    /// replaces the password.
    public func register(email: String, password: String) async throws -> CodeSent {
        try await post("/v1/auth/email/register", ["email": email, "password": password])
    }

    public func verify(email: String, code: String) async throws -> AccountTokens {
        try await post("/v1/auth/email/verify", ["email": email, "code": code])
    }

    public func signIn(email: String, password: String) async throws -> AccountTokens {
        try await post("/v1/auth/password/login", ["email": email, "password": password])
    }

    /// The server answers the same whether or not the address has an account.
    public func sendPasswordReset(email: String) async throws -> CodeSent {
        try await post("/v1/auth/password/reset/send", ["email": email])
    }

    /// Every sign-in of the account ends; sign in with the new password.
    public func resetPassword(email: String, code: String, newPassword: String) async throws {
        try await postEmpty("/v1/auth/password/reset", ["email": email, "code": code, "new_password": newPassword])
    }

    // MARK: Tokens

    /// A new pair for the refresh token, which is spent. `idempotencyKey` must be reused when the
    /// same refresh is retried after a lost answer: the server then replays the same pair instead
    /// of treating the second use as theft (prd.md §7.1).
    public func refresh(_ refreshToken: String, idempotencyKey: String) async throws -> AccountTokens {
        try await post("/v1/auth/refresh", ["refresh_token": refreshToken], idempotencyKey: idempotencyKey)
    }

    public func signOut(_ refreshToken: String) async throws {
        try await postEmpty("/v1/auth/logout", ["refresh_token": refreshToken])
    }

    // MARK: Signed in

    public func me(accessToken: String) async throws -> AccountUser {
        try await decode(send(request("GET", "/v1/me", body: nil, bearer: accessToken)))
    }

    /// Other sign-ins end; the answer holds fresh tokens for this one.
    public func changePassword(accessToken: String, current: String, new: String) async throws -> AccountTokens {
        try await post("/v1/me/password", ["current_password": current, "new_password": new], bearer: accessToken)
    }

    /// Deletes the account and everything stored with it on the server (App Store requirement).
    public func deleteAccount(accessToken: String) async throws {
        _ = try await send(request("DELETE", "/v1/me", body: nil, bearer: accessToken))
    }

    /// 意见反馈 (features.md O1b). The key makes a send retried after a lost answer land once.
    public func sendFeedback(accessToken: String, content: String, appVersion: String,
                             idempotencyKey: String) async throws {
        _ = try await send(request("POST", "/v1/feedback", body: ["content": content, "app_version": appVersion],
                                   bearer: accessToken, idempotencyKey: idempotencyKey))
    }

    // MARK: Plumbing

    private func post<Out: Decodable>(_ path: String, _ body: [String: String], bearer: String? = nil,
                                      idempotencyKey: String? = nil) async throws -> Out {
        try decode(await send(request("POST", path, body: body, bearer: bearer, idempotencyKey: idempotencyKey)))
    }

    private func postEmpty(_ path: String, _ body: [String: String]) async throws {
        _ = try await send(request("POST", path, body: body, bearer: nil))
    }

    /// `body` is JSON: strings, numbers, booleans and nested objects (`recordings` sends nested audio).
    func request(_ method: String, _ path: String, body: [String: Any]?, bearer: String?,
                 idempotencyKey: String? = nil) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        return request
    }

    func send(_ request: URLRequest) async throws -> Data {
        try await exchange(request).0
    }

    /// Like `send`, with the response for its headers (an uploaded part's ETag).
    func exchange(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as AccountError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AccountError.network(error)
        }
        guard (200..<300).contains(response.statusCode) else {
            if let shape = try? JSONDecoder().decode(ErrorShape.self, from: data) {
                throw AccountError.server(status: response.statusCode, code: shape.error.code,
                                          message: shape.error.message, retryable: shape.error.retryable)
            }
            throw AccountError.badResponse(response.statusCode)
        }
        return (data, response)
    }

    func decode<Out: Decodable>(_ data: Data) throws -> Out {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Out.self, from: data)
        } catch {
            throw AccountError.badResponse(200)
        }
    }

    private struct ErrorShape: Decodable {
        struct Body: Decodable {
            let code: String
            let message: String
            let retryable: Bool
        }

        let error: Body
    }
}
