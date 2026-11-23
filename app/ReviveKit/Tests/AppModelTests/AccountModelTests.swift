import Account
@testable import AppModel
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

// 闻笺账号 pages (product-spec.md P17～P19; test-spec.md T-M2-51): input checks, the login
// flows, and that nothing is sent before the user acts.

/// Answers with what `handler` returns; records each request's path.
private final class AccountStub: AccountTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (String) -> (Int, String)
    private var recorded: [String] = []

    init(_ handler: @escaping @Sendable (String) -> (Int, String)) {
        self.handler = handler
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let path = request.url?.path ?? ""
        lock.lock()
        recorded.append(path)
        lock.unlock()
        let (status, body) = handler(path)
        return (Data(body.utf8), status)
    }
}

private let id = UUID(uuidString: "6f9619ff-8b86-d011-b42d-00c04fc964ff")!
private let tokens = #"{"access_token":"a","refresh_token":"r","token_type":"bearer","expires_in":900,"user":{"id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","phone":null,"email":"a@b.cn","email_verified":true,"has_password":true}}"#
private let sent = #"{"resend_after_seconds":60}"#

private func client(_ stub: AccountStub, store: InMemoryAccountSessionStore = InMemoryAccountSessionStore())
    -> AccountClient {
    AccountClient(baseURL: URL(string: "https://api.example.com")!, transport: stub, store: store)
}

@MainActor
struct AccountModelTests {
    @Test func inputChecks() {
        #expect(AccountInput.phone("138 0013 8000") == "13800138000")
        #expect(AccountInput.phone("+86 138-0013-8000") == "13800138000")
        #expect(AccountInput.phone("0086 13800138000") == "13800138000")
        #expect(AccountInput.phone("12800138000") == nil)
        #expect(AccountInput.phone("1380013800") == nil)
        #expect(AccountInput.phone("+1 415 555 0100") == nil)
        #expect(AccountInput.email(" a@b.cn ") == "a@b.cn")
        #expect(AccountInput.email("a@b") == nil)
        #expect(AccountInput.email("a b@c.cn") == nil)
        #expect(AccountInput.email("@b.cn") == nil)
        #expect(AccountInput.code(" 123456 ") == "123456")
        #expect(AccountInput.code("12a456") == nil)
        #expect(AccountInput.code("123") == nil)
        #expect(AccountInput.isPassword("12345678"))
        #expect(!AccountInput.isPassword("1234567"))
    }

    /// No address, no account pages (product-spec.md P09).
    @Test func serverAddressComesFromInfoPlist() {
        #expect(AccountServer.baseURL(nil) == nil)
        #expect(AccountServer.baseURL([AccountServer.infoKey: ""]) == nil)
        #expect(AccountServer.baseURL([AccountServer.infoKey: "  "]) == nil)
        #expect(AccountServer.baseURL([AccountServer.infoKey: "api.example.com"]) == nil)
        #expect(AccountServer.baseURL([AccountServer.infoKey: "http://api.example.com"]) == nil)
        #expect(AccountServer.baseURL([AccountServer.infoKey: "https://api.example.com"])
            == URL(string: "https://api.example.com"))
        #expect(AccountServer.baseURL([AccountServer.infoKey: "http://127.0.0.1:8000"])
            == URL(string: "http://127.0.0.1:8000"))
    }

    @Test func phoneSignIn() async throws {
        let stub = AccountStub { path in path == "/v1/auth/sms/send" ? (202, sent) : (200, tokens) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var clock = start
        let model = LoginModel(client: client(stub), now: { clock })

        model.phone = "1380013800"
        await model.sendCode()
        #expect(model.error == "请输入中国大陆手机号")
        #expect(stub.paths.isEmpty)

        model.phone = "138 0013 8000"
        await model.sendCode()
        #expect(model.codeSent)
        #expect(model.notice == "验证码已发送")
        #expect(model.secondsUntilResend() == 60)

        // The countdown holds back a second request.
        clock = start.addingTimeInterval(30)
        #expect(model.secondsUntilResend() == 30)
        await model.sendCode()
        #expect(stub.paths == ["/v1/auth/sms/send"])

        model.code = "12"
        await model.submit()
        #expect(model.error == "请输入收到的验证码")
        model.code = "123456"
        await model.submit()
        #expect(model.signedIn?.email == "a@b.cn")
        #expect(model.error == nil)
        #expect(stub.paths == ["/v1/auth/sms/send", "/v1/auth/sms/login"])
    }

    /// Registered but never verified: the page turns into sign-up with the email and password kept.
    @Test func unverifiedEmailOffersTheCode() async throws {
        let stub = AccountStub { path in
            switch path {
            case "/v1/auth/password/login":
                (403, #"{"error":{"code":"email_not_verified","message":"邮箱还没有验证，请先完成验证","retryable":false}}"#)
            case "/v1/auth/email/register": (202, sent)
            default: (200, tokens)
            }
        }
        let model = LoginModel(client: client(stub))
        model.switchTo(.emailSignIn)
        model.email = "a@b.cn"
        model.password = "12345678"

        await model.submit()

        #expect(model.mode == .emailSignUp)
        #expect(model.email == "a@b.cn")
        #expect(model.password == "12345678")
        #expect(model.error?.contains("还没有验证") == true)
        await model.sendCode()
        model.code = "654321"
        await model.submit()
        #expect(model.signedIn != nil)
        #expect(stub.paths == ["/v1/auth/password/login", "/v1/auth/email/register", "/v1/auth/email/verify"])
    }

    @Test func passwordResetReturnsToSignIn() async throws {
        let stub = AccountStub { path in path == "/v1/auth/password/reset" ? (204, "") : (202, sent) }
        let model = LoginModel(client: client(stub))
        model.switchTo(.passwordReset)
        model.email = "a@b.cn"
        await model.sendCode()
        model.code = "123456"
        model.newPassword = "short"
        await model.submit()
        #expect(model.error == "密码至少 8 位")

        model.newPassword = "a new password"
        await model.submit()

        #expect(model.mode == .emailSignIn)
        #expect(model.notice == "密码已重设，请用新密码登录")
        #expect(model.signedIn == nil)
        #expect(stub.paths == ["/v1/auth/password/reset/send", "/v1/auth/password/reset"])
    }

    @Test func serverMessageIsShown() async throws {
        let stub = AccountStub { _ in
            (429, #"{"error":{"code":"code_too_frequent","message":"验证码发得太频繁，请 42 秒后再试","retryable":true}}"#)
        }
        let model = LoginModel(client: client(stub))
        model.phone = "13800138000"
        await model.sendCode()
        #expect(model.error == "验证码发得太频繁，请 42 秒后再试")
        #expect(!model.codeSent)
    }

    /// Opening the account page reads the Keychain only (prd.md §7.1).
    @Test func loadSendsNothing() async throws {
        let stub = AccountStub { _ in (200, tokens) }
        let user = AccountUser(id: id, phone: "+8613800138000")
        let store = InMemoryAccountSessionStore(AccountSession(accessToken: "a", refreshToken: "r", user: user))
        let model = AccountModel(client: client(stub, store: store))

        await model.load()

        #expect(model.user == user)
        #expect(stub.paths.isEmpty)
    }

    @Test func feedbackNeedsWords() async throws {
        let stub = AccountStub { _ in (201, #"{"id":"6f9619ff-8b86-d011-b42d-00c04fc964ff"}"#) }
        let user = AccountUser(id: id, phone: "+8613800138000")
        let store = InMemoryAccountSessionStore(AccountSession(accessToken: "a", refreshToken: "r", user: user))
        let model = AccountModel(client: client(stub, store: store))
        await model.load()

        #expect(await model.sendFeedback("  \n ", appVersion: "0.1.0") == false)
        #expect(model.toast?.text == "请先写下想说的话")
        #expect(await model.sendFeedback(String(repeating: "长", count: 5001), appVersion: "0.1.0") == false)
        #expect(stub.paths.isEmpty)

        #expect(await model.sendFeedback("同步很快", appVersion: "0.1.0") == true)
        #expect(model.toast?.text == "已收到，谢谢你的反馈")
        #expect(stub.paths == ["/v1/feedback"])
    }

    @Test func deletedAccountLeavesThePage() async throws {
        let stub = AccountStub { _ in (204, "") }
        let user = AccountUser(id: id, phone: "+8613800138000")
        let store = InMemoryAccountSessionStore(AccountSession(accessToken: "a", refreshToken: "r", user: user))
        let model = AccountModel(client: client(stub, store: store))
        await model.load()

        #expect(await model.deleteAccount())

        #expect(model.user == nil)
        #expect(try store.read() == nil)
        #expect(stub.paths == ["/v1/me"])
    }

    @Test func refusedSignInSignsOutHere() async throws {
        let stub = AccountStub { _ in
            (401, #"{"error":{"code":"invalid_token","message":"登录信息无效，请重新登录","retryable":false}}"#)
        }
        let user = AccountUser(id: id, phone: "+8613800138000")
        let store = InMemoryAccountSessionStore(AccountSession(accessToken: "a", refreshToken: "r", user: user))
        let model = AccountModel(client: client(stub, store: store))
        await model.load()

        await model.refresh()

        #expect(model.user == nil)
        #expect(model.toast?.text == "登录已失效，请重新登录")
    }
}
