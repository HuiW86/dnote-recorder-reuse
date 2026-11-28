import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Account

/// Answers requests from a script and records them.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    enum Answer {
        case json(Int, String)
        case empty(Int)
        /// An empty answer with these headers (an object store's ETag).
        case headers(Int, [String: String])
        case fail(URLError.Code)
    }

    private let lock = NSLock()
    private var answers: [Answer]
    private var _requests: [URLRequest] = []
    /// Held before answering, so tests can start overlapping calls.
    var delay: UInt64 = 0
    let beforeReply: @Sendable (URLRequest) async -> Void

    init(_ answers: [Answer], beforeReply: @escaping @Sendable (URLRequest) async -> Void = { _ in }) {
        self.answers = answers
        self.beforeReply = beforeReply
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func body(_ index: Int) -> [String: String] {
        let data = requests[index].httpBody ?? Data()
        return (try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let answer: Answer = lock.withLock {
            _requests.append(request)
            return answers.isEmpty ? .empty(500) : answers.removeFirst()
        }
        await beforeReply(request)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        let url = request.url!
        switch answer {
        case .json(let status, let text):
            return (Data(text.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case .empty(let status):
            return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case .headers(let status, let fields):
            return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: fields)!)
        case .fail(let code):
            throw URLError(code)
        }
    }
}

let base = URL(string: "https://api.example.com")!
let userJSON = #"{"id":"6f1c2d3e-0000-4000-8000-000000000001","phone":"+8613812345678","email":null,"email_verified":false,"has_password":false}"#

func tokens(_ n: Int, expiresIn: Int = 900) -> String {
    #"{"access_token":"a\#(n)","refresh_token":"r\#(n)","token_type":"bearer","expires_in":\#(expiresIn),"user":\#(userJSON)}"#
}

func error(_ code: String, _ message: String = "提示", retryable: Bool = false) -> String {
    #"{"error":{"code":"\#(code)","message":"\#(message)","retryable":\#(retryable)}}"#
}

/// A clock tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

struct AccountClientTests {
    @Test func requestsHaveTheServersShape() async throws {
        let stub = StubTransport([.json(202, #"{"resend_after_seconds":60}"#), .json(200, tokens(1))])
        let client = AccountClient(baseURL: base, transport: stub)
        let sent = try await client.sendSMSCode(phone: "13812345678")
        #expect(sent.resendAfterSeconds == 60)
        let signedIn = try await client.signIn(phone: "13812345678", code: "123456")
        #expect(signedIn.accessToken == "a1" && signedIn.refreshToken == "r1" && signedIn.expiresIn == 900)
        #expect(signedIn.user.phone == "+8613812345678" && signedIn.user.displayName == "138****5678")

        #expect(stub.requests.map { $0.url!.absoluteString } == [
            "https://api.example.com/v1/auth/sms/send", "https://api.example.com/v1/auth/sms/login",
        ])
        #expect(stub.requests.allSatisfy { $0.httpMethod == "POST" })
        #expect(stub.requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(stub.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(stub.body(1) == ["phone": "13812345678", "code": "123456"])
    }

    @Test func everyEndpointGoesWhereTheServerExpects() async throws {
        let stub = StubTransport([
            .json(202, #"{"resend_after_seconds":60}"#), .json(200, tokens(1)), .json(200, tokens(2)),
            .json(202, #"{"resend_after_seconds":60}"#), .empty(204), .json(200, tokens(3)), .empty(204),
            .json(200, userJSON), .json(200, tokens(4)), .empty(204),
        ])
        let client = AccountClient(baseURL: base, transport: stub)
        _ = try await client.register(email: "a@example.com", password: "correct horse")
        _ = try await client.verify(email: "a@example.com", code: "654321")
        _ = try await client.signIn(email: "a@example.com", password: "correct horse")
        _ = try await client.sendPasswordReset(email: "a@example.com")
        try await client.resetPassword(email: "a@example.com", code: "111111", newPassword: "new password")
        _ = try await client.refresh("r2", idempotencyKey: "k1")
        try await client.signOut("r3")
        _ = try await client.me(accessToken: "a3")
        _ = try await client.changePassword(accessToken: "a3", current: "old password", new: "new password")
        try await client.deleteAccount(accessToken: "a4")

        let calls = stub.requests.map { "\($0.httpMethod!) \($0.url!.path)" }
        #expect(calls == [
            "POST /v1/auth/email/register", "POST /v1/auth/email/verify", "POST /v1/auth/password/login",
            "POST /v1/auth/password/reset/send", "POST /v1/auth/password/reset", "POST /v1/auth/refresh",
            "POST /v1/auth/logout", "GET /v1/me", "POST /v1/me/password", "DELETE /v1/me",
        ])
        #expect(stub.body(4) == ["email": "a@example.com", "code": "111111", "new_password": "new password"])
        #expect(stub.body(5) == ["refresh_token": "r2"])
        #expect(stub.requests[5].value(forHTTPHeaderField: "Idempotency-Key") == "k1")
        #expect(stub.requests[7].value(forHTTPHeaderField: "Authorization") == "Bearer a3")
        #expect(stub.body(8) == ["current_password": "old password", "new_password": "new password"])
        #expect(stub.requests[9].value(forHTTPHeaderField: "Authorization") == "Bearer a4")
    }

    @Test func errorsReadAsAdvice() async throws {
        let stub = StubTransport([
            .json(429, error("code_too_frequent", "验证码发得太频繁，请 42 秒后再试", retryable: true)),
            .fail(.notConnectedToInternet), .fail(.dataNotAllowed), .fail(.timedOut),
            .json(502, "<html>bad gateway</html>"), .json(200, "{}"),
        ])
        let client = AccountClient(baseURL: base, transport: stub)
        await #expect(throws: AccountError.server(status: 429, code: "code_too_frequent",
                                                  message: "验证码发得太频繁，请 42 秒后再试", retryable: true)) {
            _ = try await client.sendSMSCode(phone: "13812345678")
        }
        for expected: AccountError in [.offline, .offline] {
            await #expect(throws: expected) { _ = try await client.sendSMSCode(phone: "1") }
        }
        do {
            _ = try await client.sendSMSCode(phone: "1")
            Issue.record("expected unreachable")
        } catch let error as AccountError {
            guard case .unreachable = error else { Issue.record("got \(error)"); return }
            #expect(error.userText == "连不上闻笺的服务器，请稍后再试")
        }
        await #expect(throws: AccountError.badResponse(502)) { _ = try await client.sendSMSCode(phone: "1") }
        await #expect(throws: AccountError.badResponse(200)) { _ = try await client.sendSMSCode(phone: "1") }
        #expect(AccountError.offline.userText == "这部手机连不上网，请检查网络或「设置 › 闻笺 › 无线数据」")
        #expect(AccountError.server(status: 401, code: "invalid_credentials", message: "邮箱或密码不对",
                                    retryable: false).userText == "邮箱或密码不对")
    }

    @Test func displayNames() {
        let id = UUID()
        #expect(AccountUser(id: id, phone: "+8613900001111", email: nil, emailVerified: false, hasPassword: false)
            .displayName == "139****1111")
        #expect(AccountUser(id: id, phone: nil, email: "a@example.com", emailVerified: true, hasPassword: true)
            .displayName == "a@example.com")
    }
}

struct AccountSessionTests {
    private func session(_ stub: StubTransport, clock: TestClock = TestClock(),
                         store: InMemorySessionStore = InMemorySessionStore()) -> AccountSession {
        AccountSession(client: AccountClient(baseURL: base, transport: stub), store: store, now: { clock.now })
    }

    private func signedIn(_ stub: StubTransport, clock: TestClock = TestClock(),
                          store: InMemorySessionStore = InMemorySessionStore()) async throws -> AccountSession {
        let session = session(stub, clock: clock, store: store)
        let data = Data(tokens(1).utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        try await session.adopt(try decoder.decode(AccountTokens.self, from: data))
        return session
    }

    @Test func aSignInSurvivesARestartWithoutTheAccessToken() async throws {
        let store = InMemorySessionStore()
        _ = try await signedIn(StubTransport([]), store: store)
        let saved = try #require(try store.load())
        #expect(saved.refreshToken == "r1" && saved.user.phone == "+8613812345678")
        // A new launch knows the account but must refresh before calling.
        let stub = StubTransport([.json(200, tokens(2)), .json(200, userJSON)])
        let restarted = session(stub, store: store)
        let known = await restarted.isSignedIn
        let phone = await restarted.user?.phone
        #expect(known && phone == "+8613812345678")
        _ = try await restarted.reloadUser()
        #expect(stub.requests.map(\.url!.path) == ["/v1/auth/refresh", "/v1/me"])
        #expect(stub.body(0) == ["refresh_token": "r1"])
        #expect(stub.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer a2")
        #expect(try store.load()?.refreshToken == "r2")
    }

    @Test func theAccessTokenIsRefreshedBeforeItRunsOut() async throws {
        let clock = TestClock()
        let stub = StubTransport([.json(200, userJSON), .json(200, tokens(2)), .json(200, userJSON)])
        let session = try await signedIn(stub, clock: clock)
        _ = try await session.reloadUser()
        clock.advance(900 - 59)  // within the last 60 s: refreshed early
        _ = try await session.reloadUser()
        #expect(stub.requests.map(\.url!.path) == ["/v1/me", "/v1/auth/refresh", "/v1/me"])
        #expect(stub.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer a1")
        #expect(stub.requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer a2")
    }

    /// The feedback retried after refreshing an expired token carries the same key; the server
    /// keeps no answer for `token_expired`, so the retry runs (prd.md §7.1).
    @Test func feedbackKeepsItsKeyAcrossARefresh() async throws {
        let stub = StubTransport([
            .json(401, error("token_expired", "登录已过期", retryable: true)), .json(200, tokens(2)),
            .json(201, #"{"id":"6f1c2d3e-0000-4000-8000-000000000009"}"#),
        ])
        let session = try await signedIn(stub)
        try await session.sendFeedback("好用", appVersion: "0.1.0 (110)", idempotencyKey: "fb-1")
        #expect(stub.requests.map(\.url!.path) == ["/v1/feedback", "/v1/auth/refresh", "/v1/feedback"])
        #expect(stub.body(0) == ["content": "好用", "app_version": "0.1.0 (110)"])
        #expect(stub.requests[0].value(forHTTPHeaderField: "Idempotency-Key") == "fb-1")
        #expect(stub.requests[2].value(forHTTPHeaderField: "Idempotency-Key") == "fb-1")
        #expect(stub.requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer a2")
    }

    @Test func anExpiredTokenIsRefreshedOnceAndTheCallRetried() async throws {
        let stub = StubTransport([
            .json(401, error("token_expired", "登录已过期", retryable: true)), .json(200, tokens(2)),
            .json(200, userJSON),
        ])
        let session = try await signedIn(stub)
        _ = try await session.reloadUser()
        #expect(stub.requests.map(\.url!.path) == ["/v1/me", "/v1/auth/refresh", "/v1/me"])
    }

    @Test func overlappingCallsShareOneRefresh() async throws {
        let clock = TestClock()
        let stub = StubTransport([.json(200, tokens(2)), .json(200, userJSON), .json(200, userJSON)])
        let session = try await signedIn(stub, clock: clock)
        clock.advance(3600)
        stub.delay = 50_000_000
        async let one = session.reloadUser()
        async let two = session.reloadUser()
        _ = try await (one, two)
        let paths = stub.requests.map(\.url!.path)
        #expect(paths.filter { $0 == "/v1/auth/refresh" }.count == 1)
        #expect(paths.filter { $0 == "/v1/me" }.count == 2)
    }

    @Test func aLostRefreshAnswerIsRetriedWithTheSameKey() async throws {
        let clock = TestClock()
        let stub = StubTransport([.fail(.networkConnectionLost), .json(200, tokens(2)), .json(200, userJSON),
                                  .json(200, tokens(3)), .json(200, userJSON)])
        let session = try await signedIn(stub, clock: clock)
        clock.advance(3600)
        await #expect(throws: AccountError.self) { _ = try await session.reloadUser() }
        let still = await session.isSignedIn
        #expect(still)  // a lost answer does not end the sign-in
        _ = try await session.reloadUser()
        let first = stub.requests[0].value(forHTTPHeaderField: "Idempotency-Key")
        #expect(first != nil && stub.requests[1].value(forHTTPHeaderField: "Idempotency-Key") == first)
        #expect(stub.body(0) == ["refresh_token": "r1"] && stub.body(1) == ["refresh_token": "r1"])
        // The next refresh is a new request with a new key.
        clock.advance(3600)
        _ = try await session.reloadUser()
        #expect(stub.body(3) == ["refresh_token": "r2"])
        #expect(stub.requests[3].value(forHTTPHeaderField: "Idempotency-Key") != first)
    }

    @Test func pendingRefreshSurvivesRelaunchAfterALostResponse() async throws {
        let store = InMemorySessionStore()
        let clock = TestClock()
        let first = StubTransport([.fail(.networkConnectionLost)])
        let original = try await signedIn(first, clock: clock, store: store)
        clock.advance(3600)
        await #expect(throws: AccountError.self) { _ = try await original.reloadUser() }
        let key = try #require(first.requests.first?.value(forHTTPHeaderField: "Idempotency-Key"))
        let pending = try #require(try store.load())
        #expect(pending.refreshToken == "r1" && pending.pendingRefreshKey == key)

        // Round-trip the same JSON that the Keychain persists and create a fresh actor.
        let restored = try JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(pending))
        let newStore = InMemorySessionStore(restored)
        let second = StubTransport([.json(200, tokens(2)), .json(200, userJSON)])
        _ = try await session(second, store: newStore).reloadUser()
        #expect(second.requests.first?.value(forHTTPHeaderField: "Idempotency-Key") == key)
        #expect(second.body(0) == first.body(0))
        let rotated = try #require(try newStore.load())
        #expect(rotated.refreshToken == "r2" && rotated.pendingRefreshKey == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func aRefreshCannotRestoreOrClearASupersededSignIn(signOut: Bool, oldRefreshFails: Bool) async throws {
        let (entered, started) = AsyncStream<Void>.makeStream()
        let (hold, release) = AsyncStream<Void>.makeStream()
        let oldReply: StubTransport.Answer = oldRefreshFails ? .json(401, error("refresh_reused")) : .json(200, tokens(2))
        let stub = StubTransport([oldReply, signOut ? .empty(204) : .json(200, tokens(6))]) { request in
            guard request.url?.lastPathComponent == "refresh", let body = request.httpBody,
                  let args = try? JSONDecoder().decode([String: String].self, from: body),
                  args["refresh_token"] == "r1" else { return }
            started.finish()
            for await _ in hold {}
        }
        let store = InMemorySessionStore()
        let clock = TestClock()
        let session = try await signedIn(stub, clock: clock, store: store)
        clock.advance(3600)
        let oldRefresh = Task { try await session.accessToken() }
        for await _ in entered {}
        // Prevent an implementation that joins the old task from hanging the suite.
        let timeout = Task {
            try await Task.sleep(for: .seconds(5))
            release.finish()
        }
        defer { timeout.cancel(); release.finish() }

        if signOut {
            await session.signOut()
        } else {
            let user = try #require(await session.user)
            try await session.adopt(AccountTokens(accessToken: "a5", refreshToken: "r5", expiresIn: 0, user: user))
            #expect(try await session.accessToken() == "a6")
            try #require(stub.requests.count == 2)
            #expect(stub.body(1) == ["refresh_token": "r5"])
        }
        release.finish()
        await #expect(throws: CancellationError.self) { try await oldRefresh.value }
        #expect(try store.load()?.refreshToken == (signOut ? nil : "r6"))
    }

    @Test func oldSessionCanLoadAndALockedStoreDoesNotSpendItsToken() async throws {
        let oldRecord = """
            {"refreshToken":"r1","user":{"id":"6f1c2d3e-0000-4000-8000-000000000001",
             "emailVerified":false,"hasPassword":false}}
            """
        let old = try JSONDecoder().decode(SavedSession.self, from: Data(oldRecord.utf8))
        #expect(old.refreshToken == "r1" && old.pendingRefreshKey == nil)
        struct ReadOnlyStore: SessionStoring {
            let old: SavedSession
            func load() throws -> SavedSession? { old }
            func save(_ session: SavedSession?) throws { throw SessionStoreError.keychain(-1) }
        }
        let stub = StubTransport([])
        let session = AccountSession(client: AccountClient(baseURL: base, transport: stub), store: ReadOnlyStore(old: old))
        await #expect(throws: SessionStoreError.keychain(-1)) { _ = try await session.accessToken() }
        #expect(stub.requests.isEmpty)
    }

    @Test func aSpentOrRevokedSignInSignsOut() async throws {
        for code in ["refresh_reused", "refresh_invalid"] {
            let clock = TestClock()
            let store = InMemorySessionStore()
            let stub = StubTransport([.json(401, error(code, "登录已失效，请重新登录"))])
            let session = try await signedIn(stub, clock: clock, store: store)
            clock.advance(3600)
            await #expect(throws: AccountError.signedOut) { _ = try await session.reloadUser() }
            let still = await session.isSignedIn
            let user = await session.user
            #expect(!still && user == nil)
            #expect(try store.load() == nil)
        }
        let store = InMemorySessionStore()
        let stub = StubTransport([.json(401, error("invalid_token"))])
        let session = try await signedIn(stub, store: store)
        await #expect(throws: AccountError.signedOut) { _ = try await session.reloadUser() }
        #expect(try store.load() == nil)
    }

    @Test func signingOutForgetsEvenWithoutTheServer() async throws {
        let store = InMemorySessionStore()
        let stub = StubTransport([.fail(.notConnectedToInternet)])
        let session = try await signedIn(stub, store: store)
        await session.signOut()
        #expect(stub.requests.map(\.url!.path) == ["/v1/auth/logout"])
        #expect(stub.body(0) == ["refresh_token": "r1"])
        let still = await session.isSignedIn
        let stored = try store.load()
        #expect(!still && stored == nil)
        await #expect(throws: AccountError.signedOut) { _ = try await session.reloadUser() }
    }

    @Test func changingThePasswordKeepsTheNewTokensAndDeletingForgets() async throws {
        let store = InMemorySessionStore()
        let stub = StubTransport([
            .json(401, error("invalid_credentials", "当前密码不对")), .json(200, tokens(5)), .empty(204),
        ])
        let session = try await signedIn(stub, store: store)
        await #expect(throws: AccountError.self) { try await session.changePassword(current: "x", new: "new password") }
        #expect(try store.load()?.refreshToken == "r1")
        try await session.changePassword(current: "old password", new: "new password")
        #expect(try store.load()?.refreshToken == "r5")
        try await session.deleteAccount()
        #expect(stub.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer a5")
        let still = await session.isSignedIn
        let stored = try store.load()
        #expect(!still && stored == nil)
    }
}
