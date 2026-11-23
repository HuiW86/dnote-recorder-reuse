@testable import Account
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

// The account client against a stub server (test-spec.md T-M2-50): request shapes, the refresh
// rules of prd.md §7.1, signing out, and how errors read.

/// Answers each request with what `handler` returns, and records the requests.
final class StubServer: AccountTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: (URLRequest) throws -> (Int, String)
    private var recorded: [URLRequest] = []

    init(_ handler: @escaping (URLRequest) throws -> (Int, String)) {
        self.handler = handler
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lock.lock()
        recorded.append(request)
        let handler = self.handler
        lock.unlock()
        let (status, body) = try handler(request)
        return (Data(body.utf8), status)
    }
}

extension URLRequest {
    var path: String { url?.path ?? "" }
    var json: [String: String] {
        guard let httpBody, let object = try? JSONSerialization.jsonObject(with: httpBody) as? [String: String]
        else { return [:] }
        return object
    }
    var bearer: String? {
        value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) }
    }
    var key: String? { value(forHTTPHeaderField: "Idempotency-Key") }
}

let userId = "6f9619ff-8b86-d011-b42d-00c04fc964ff"

func userJSON(phone: String = "+8613800138000") -> String {
    #"{"id":"\#(userId)","phone":"\#(phone)","email":null,"email_verified":false,"has_password":false}"#
}

func tokensJSON(access: String, refresh: String) -> String {
    #"{"access_token":"\#(access)","refresh_token":"\#(refresh)","token_type":"bearer","expires_in":900,"user":\#(userJSON())}"#
}

func errorJSON(_ code: String, _ message: String = "msg", retryable: Bool = false) -> String {
    #"{"error":{"code":"\#(code)","message":"\#(message)","retryable":\#(retryable)}}"#
}

private let base = URL(string: "https://api.example.com")!
private let user = AccountUser(id: UUID(uuidString: userId)!, phone: "+8613800138000")

/// Counts across threads.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        n += 1
        return n
    }
}

/// Keys "k1", "k2", … in order.
private func counter() -> @Sendable () -> String {
    let count = Counter()
    return { "k\(count.next())" }
}

private func signedIn(access: String = "old", refresh: String = "r1") -> InMemoryAccountSessionStore {
    InMemoryAccountSessionStore(AccountSession(accessToken: access, refreshToken: refresh, user: user))
}

struct AccountClientTests {
    @Test func phoneSignInStoresTheSession() async throws {
        let server = StubServer { _ in (200, tokensJSON(access: "a1", refresh: "r1")) }
        let store = InMemoryAccountSessionStore()
        let client = AccountClient(baseURL: base, transport: server, store: store, newKey: counter())

        let signedInUser = try await client.signIn(phone: "13800138000", code: "123456")

        #expect(signedInUser == user)
        #expect(signedInUser.displayName == "138****8000")
        #expect(try store.read() == AccountSession(accessToken: "a1", refreshToken: "r1", user: user))
        let request = try #require(server.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.path == "/v1/auth/sms/login")
        #expect(request.json == ["phone": "13800138000", "code": "123456"])
        #expect(request.key == "k1")
        #expect(request.bearer == nil)
    }

    @Test func codeRequestsReturnTheResendWait() async throws {
        let server = StubServer { _ in (202, #"{"resend_after_seconds":60}"#) }
        let client = AccountClient(baseURL: base, transport: server, store: InMemoryAccountSessionStore())
        #expect(try await client.sendSMSCode(phone: "13800138000") == 60)
        #expect(try await client.register(email: "a@b.cn", password: "12345678") == 60)
        #expect(try await client.sendPasswordReset(email: "a@b.cn") == 60)
        #expect(server.requests.map(\.path) == ["/v1/auth/sms/send", "/v1/auth/email/register",
                                                "/v1/auth/password/reset/send"])
        #expect(server.requests.allSatisfy { $0.key != nil })
    }

    @Test func readsCarryTheTokenButNoKey() async throws {
        let server = StubServer { _ in (200, userJSON(phone: "+8613900139000")) }
        let store = signedIn()
        let client = AccountClient(baseURL: base, transport: server, store: store)

        let fresh = try await client.refreshUser()

        #expect(fresh.phone == "+8613900139000")
        #expect(try store.read()?.user.phone == "+8613900139000")
        let request = try #require(server.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.path == "/v1/me")
        #expect(request.bearer == "old")
        #expect(request.key == nil)
    }

    /// prd.md §7.3: `token_expired` refreshes once and sends again; the retry gets a new key.
    @Test func expiredTokenIsRefreshedOnce() async throws {
        let server = StubServer { request in
            switch (request.path, request.bearer) {
            case ("/v1/feedback", "old"): (401, errorJSON("token_expired", retryable: true))
            case ("/v1/auth/refresh", _): (200, tokensJSON(access: "new", refresh: "r2"))
            case ("/v1/feedback", "new"): (201, #"{"id":"\#(userId)"}"#)
            default: (500, "unexpected")
            }
        }
        let store = signedIn()
        let client = AccountClient(baseURL: base, transport: server, store: store, newKey: counter())

        try await client.sendFeedback("好用", appVersion: "0.1.0 (9)")

        let requests = server.requests
        #expect(requests.map(\.path) == ["/v1/feedback", "/v1/auth/refresh", "/v1/feedback"])
        #expect(requests[0].json == ["content": "好用", "app_version": "0.1.0 (9)"])
        #expect(requests[1].json == ["refresh_token": "r1"])
        #expect(requests[1].bearer == nil)
        #expect(Set(requests.compactMap(\.key)).count == 3)
        #expect(try store.read()?.refreshToken == "r2")
        #expect(try store.read()?.accessToken == "new")
    }

    @Test func concurrentRequestsShareOneRefresh() async throws {
        let server = StubServer { request in
            switch (request.path, request.bearer) {
            case ("/v1/me", "old"): (401, errorJSON("token_expired", retryable: true))
            case ("/v1/auth/refresh", _): (200, tokensJSON(access: "new", refresh: "r2"))
            case ("/v1/me", "new"): (200, userJSON())
            default: (500, "unexpected")
            }
        }
        let client = AccountClient(baseURL: base, transport: server, store: signedIn())

        async let first = client.refreshUser()
        async let second = client.refreshUser()
        _ = try await (first, second)

        #expect(server.requests.filter { $0.path == "/v1/auth/refresh" }.count == 1)
    }

    /// A refresh lost on the way back is sent again with the same key, so the server returns the
    /// same tokens instead of treating the spent refresh token as stolen (prd.md §7.1).
    @Test func lostRefreshIsRetriedWithTheSameKey() async throws {
        let refreshes = Counter()
        let server = StubServer { request in
            switch (request.path, request.bearer) {
            case ("/v1/me", "old"): return (401, errorJSON("token_expired"))
            case ("/v1/auth/refresh", _):
                if refreshes.next() == 1 { throw URLError(.timedOut) }
                return (200, tokensJSON(access: "new", refresh: "r2"))
            case ("/v1/me", "new"): return (200, userJSON())
            default: return (500, "unexpected")
            }
        }
        let client = AccountClient(baseURL: base, transport: server, store: signedIn(), newKey: counter())

        _ = try await client.refreshUser()

        let keys = server.requests.filter { $0.path == "/v1/auth/refresh" }.map(\.key)
        #expect(keys.count == 2)
        #expect(keys[0] != nil && keys[0] == keys[1])
    }

    @Test func refusedRefreshSignsOut() async throws {
        let server = StubServer { request in
            request.path == "/v1/auth/refresh" ? (401, errorJSON("refresh_reused")) : (401, errorJSON("token_expired"))
        }
        let store = signedIn()
        let client = AccountClient(baseURL: base, transport: server, store: store)

        await #expect(throws: AccountError.signedOut) { try await client.refreshUser() }
        #expect(try store.read() == nil)
    }

    @Test func unknownTokenSignsOut() async throws {
        let server = StubServer { _ in (401, errorJSON("invalid_token")) }
        let store = signedIn()
        let client = AccountClient(baseURL: base, transport: server, store: store)

        await #expect(throws: AccountError.signedOut) { try await client.refreshUser() }
        #expect(try store.read() == nil)
        #expect(server.requests.count == 1)
    }

    @Test func signedOutSendsNothing() async throws {
        let server = StubServer { _ in (200, "{}") }
        let client = AccountClient(baseURL: base, transport: server, store: InMemoryAccountSessionStore())

        await #expect(throws: AccountError.signedOut) { try await client.sendFeedback("x", appVersion: "") }
        await #expect(throws: AccountError.signedOut) { try await client.deleteAccount() }
        await client.signOut()
        #expect(server.requests.isEmpty)
    }

    /// Signing out works without a connection; the server is told when it can be.
    @Test func signOutWorksOffline() async throws {
        let server = StubServer { _ in throw URLError(.notConnectedToInternet) }
        let store = signedIn()
        let client = AccountClient(baseURL: base, transport: server, store: store)

        await client.signOut()

        #expect(try store.read() == nil)
        let request = try #require(server.requests.first)
        #expect(request.path == "/v1/auth/logout")
        #expect(request.json == ["refresh_token": "r1"])
    }

    @Test func deletingTheAccountSignsOut() async throws {
        let server = StubServer { _ in (204, "") }
        let store = signedIn()
        let client = AccountClient(baseURL: base, transport: server, store: store)

        try await client.deleteAccount()

        #expect(try store.read() == nil)
        let request = try #require(server.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.path == "/v1/me")
        #expect(request.bearer == "old")
        #expect(request.key != nil)
    }

    @Test func failedDeleteKeepsTheSignIn() async throws {
        let server = StubServer { _ in (500, errorJSON("internal", "服务暂时出错，请稍后再试", retryable: true)) }
        let store = signedIn()
        let client = AccountClient(baseURL: base, transport: server, store: store)

        await #expect(throws: AccountError.server(status: 500, code: "internal", message: "服务暂时出错，请稍后再试",
                                                  retryable: true)) { try await client.deleteAccount() }
        #expect(try store.read() != nil)
    }

    @Test func errorsReadAsTheServerSaysOrAsAdvice() async throws {
        let tooSoon = AccountClient.serverError(Data(errorJSON("code_too_frequent", "验证码发得太频繁，请 42 秒后再试",
                                                               retryable: true).utf8), status: 429)
        #expect(tooSoon == .server(status: 429, code: "code_too_frequent", message: "验证码发得太频繁，请 42 秒后再试",
                                   retryable: true))
        #expect(tooSoon.errorDescription == "验证码发得太频繁，请 42 秒后再试")

        let gateway = AccountClient.serverError(Data("<html>bad gateway</html>".utf8), status: 502)
        #expect(gateway.code == "http_502")
        #expect(gateway.errorDescription == "服务暂时出错（502），请稍后再试")

        #expect(AccountError.network(URLError(.notConnectedToInternet)) == .offline)
        #expect(AccountError.network(URLError(.dataNotAllowed)) == .offline)
        #expect(AccountError.network(URLError(.timedOut)) == .unreachable)
        #expect(AccountError.offline.errorDescription == "这部手机连不上网，请检查网络或「设置 › 闻笺 › 无线数据」")

        let offline = StubServer { _ in throw URLError(.notConnectedToInternet) }
        let client = AccountClient(baseURL: base, transport: offline, store: InMemoryAccountSessionStore())
        await #expect(throws: AccountError.offline) { _ = try await client.sendSMSCode(phone: "13800138000") }
    }

    @Test func emailNamesAnAccountWithoutAPhone() {
        let byEmail = AccountUser(id: UUID(), email: "a@b.cn", emailVerified: true, hasPassword: true)
        #expect(byEmail.displayName == "a@b.cn")
    }
}
