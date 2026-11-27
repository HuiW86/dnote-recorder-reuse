import Foundation
import Testing
@testable import Account

/// 设置 → 账号: the forms, their checks and what each step leads to.
@MainActor
struct AccountModelTests {
    private let clock = TestClock()

    private func model(_ stub: StubTransport, store: InMemorySessionStore = InMemorySessionStore()) -> AccountModel {
        let clock = clock
        let session = AccountSession(client: AccountClient(baseURL: base, transport: stub), store: store,
                                     now: { clock.now })
        return AccountModel(session: session, now: { clock.now })
    }

    @Test func phoneNumbersAndEmailsAreChecked() {
        #expect(AccountModel.normalizedPhone("138 1234 5678") == "+8613812345678")
        #expect(AccountModel.normalizedPhone("+86 138-1234-5678") == "+8613812345678")
        #expect(AccountModel.normalizedPhone("008613812345678") == "+8613812345678")
        for bad in ["", "1381234567", "12812345678", "138123456789", "１３８１２３４５６７８", "+1 415 555 0100"] {
            #expect(AccountModel.normalizedPhone(bad) == nil, "\(bad)")
        }
        #expect(AccountModel.looksLikeEmail("a@example.com"))
        for bad in ["", "a@", "@example.com", "a@example", "a@.com", "a@b.", "a b@example.com", "a@b@c.com"] {
            #expect(!AccountModel.looksLikeEmail(bad), "\(bad)")
        }
    }

    @Test func signingInWithAPhoneNumber() async throws {
        let store = InMemorySessionStore()
        let stub = StubTransport([.json(202, #"{"resend_after_seconds":60}"#), .json(200, tokens(1))])
        let model = model(stub, store: store)
        #expect(!model.canSendPhoneCode)
        model.phone = "138 1234 5678"
        #expect(model.canSendPhoneCode && !model.canSignInWithPhone)
        await model.sendPhoneCode()
        #expect(model.notice == "验证码已发到 138****5678")
        #expect(stub.body(0) == ["phone": "+8613812345678"])
        // The resend button waits out the server's minute.
        #expect(model.resendWait == 60 && !model.canSendPhoneCode)
        clock.advance(59.5)
        #expect(model.resendWait == 1)
        clock.advance(0.5)
        #expect(model.resendWait == 0 && model.canSendPhoneCode)
        model.code = "12345"
        #expect(!model.canSignInWithPhone)
        model.code = "123456"
        #expect(model.canSignInWithPhone)
        // Another number needs its own code.
        model.phone = "13900000000"
        #expect(!model.canSignInWithPhone)
        model.phone = "13812345678"
        await model.signInWithPhone()
        #expect(model.user?.displayName == "138****5678" && model.notice == "已登录")
        #expect(model.code.isEmpty && model.errorText == nil)
        #expect(try store.load()?.refreshToken == "r1")
    }

    @Test func aWrongCodeSaysSoAndKeepsTheForm() async {
        let stub = StubTransport([
            .json(202, #"{"resend_after_seconds":60}"#),
            .json(400, error("code_invalid", "验证码不对或已失效，请重新获取")),
        ])
        let model = model(stub)
        model.phone = "13812345678"
        await model.sendPhoneCode()
        model.code = "000000"
        await model.signInWithPhone()
        #expect(model.user == nil && model.errorText == "验证码不对或已失效，请重新获取")
        #expect(model.phone == "13812345678" && !model.isBusy)
    }

    @Test func registeringVerifyingAndSigningInWithEmail() async {
        let stub = StubTransport([.json(202, #"{"resend_after_seconds":60}"#), .json(200, tokens(1))])
        let model = model(stub)
        model.method = .email
        model.show(.register)
        model.email = " A@Example.com "
        model.password = "short"
        #expect(!model.canSubmitEmail)
        model.password = "correct horse"
        await model.submitEmail()
        #expect(model.emailStep == .verify && model.notice == "验证码已发到 a@example.com")
        #expect(stub.body(0) == ["email": "a@example.com", "password": "correct horse"])
        model.code = "654321"
        await model.submitEmail()
        #expect(stub.body(1) == ["email": "a@example.com", "code": "654321"])
        #expect(model.user != nil && model.emailStep == .signIn && model.password.isEmpty)
    }

    @Test func signingInBeforeVerifyingSendsANewCode() async {
        let stub = StubTransport([
            .json(403, error("email_not_verified", "邮箱还没有验证，请先完成验证")),
            .json(202, #"{"resend_after_seconds":60}"#),
        ])
        let model = model(stub)
        model.method = .email
        model.email = "a@example.com"
        model.password = "correct horse"
        await model.submitEmail()
        #expect(model.emailStep == .verify && model.errorText == nil)
        #expect(model.notice == "这个邮箱还没有验证，验证码已发到 a@example.com")
        #expect(stub.requests.map(\.url!.path) == ["/v1/auth/password/login", "/v1/auth/email/register"])
    }

    @Test func resettingAForgottenPassword() async {
        let stub = StubTransport([.json(202, #"{"resend_after_seconds":60}"#), .empty(204)])
        let model = model(stub)
        model.method = .email
        model.show(.forgot)
        model.email = "a@example.com"
        await model.submitEmail()
        #expect(model.emailStep == .reset && model.notice == "如果这个邮箱注册过，验证码已发到 a@example.com")
        model.code = "111111"
        model.newPassword = "1234567"
        #expect(!model.canSubmitEmail)
        model.newPassword = "new password"
        await model.submitEmail()
        #expect(stub.body(1) == ["email": "a@example.com", "code": "111111", "new_password": "new password"])
        #expect(model.emailStep == .signIn && model.notice == "密码已重设，请用新密码登录" && model.newPassword.isEmpty)
    }

    @Test func noConnectionUsesTheSameAdviceAsTheAIFeatures() async {
        let model = model(StubTransport([.fail(.notConnectedToInternet)]))
        model.phone = "13812345678"
        await model.sendPhoneCode()
        #expect(model.errorText == "这部手机连不上网，请检查网络或「设置 › 闻笺 › 无线数据」")
        #expect(model.codeTarget == nil && model.canSendPhoneCode)
    }

    @Test func theStoredAccountShowsAtOnceAndIsChecked() async throws {
        let saved = SavedSession(refreshToken: "r1", user: AccountUser(
            id: UUID(), phone: "+8613812345678", email: nil, emailVerified: false, hasPassword: false))
        // Offline: what is stored stays on screen.
        let offline = model(StubTransport([.fail(.notConnectedToInternet)]), store: InMemorySessionStore(saved))
        await offline.load()
        #expect(offline.user?.displayName == "138****5678")
        // Revoked elsewhere: shows as signed out.
        let revoked = model(StubTransport([.json(401, error("refresh_reused"))]), store: InMemorySessionStore(saved))
        await revoked.load()
        #expect(revoked.user == nil)
        // Never signed in: nothing is asked of the server.
        let stub = StubTransport([])
        let fresh = model(stub)
        await fresh.load()
        #expect(fresh.user == nil && stub.requests.isEmpty)
    }

    @Test func signingOutAndDeletingTheAccount() async throws {
        let store = InMemorySessionStore()
        let stub = StubTransport([
            .json(202, #"{"resend_after_seconds":60}"#), .json(200, tokens(1)), .empty(204),
            .json(202, #"{"resend_after_seconds":60}"#), .json(200, tokens(2)), .empty(204),
        ])
        let model = model(stub, store: store)
        model.phone = "13812345678"
        await model.sendPhoneCode()
        model.code = "123456"
        await model.signInWithPhone()
        await model.signOut()
        let afterSignOut = try store.load()
        #expect(model.user == nil && model.notice == "已退出登录" && afterSignOut == nil)

        clock.advance(61)
        await model.sendPhoneCode()
        model.code = "123456"
        await model.signInWithPhone()
        await model.deleteAccount()
        #expect(stub.requests.last.map { "\($0.httpMethod!) \($0.url!.path)" } == "DELETE /v1/me")
        #expect(model.user == nil && model.notice == "账号已注销。这部手机上的录音不受影响。")
        #expect(try store.load() == nil)
    }

    @Test func changingThePassword() async throws {
        let store = InMemorySessionStore()
        let stub = StubTransport([
            .json(202, #"{"resend_after_seconds":60}"#), .json(200, tokens(1)),
            .json(401, error("invalid_credentials", "当前密码不对")), .json(200, tokens(3)),
        ])
        let model = model(stub, store: store)
        model.phone = "13812345678"
        await model.sendPhoneCode()
        model.code = "123456"
        await model.signInWithPhone()
        #expect(await model.changePassword(current: "x", new: "short") == false)
        #expect(model.errorText == "新密码至少 8 位" && stub.requests.count == 2)
        #expect(await model.changePassword(current: "x", new: "new password") == false)
        #expect(model.errorText == "当前密码不对")
        #expect(await model.changePassword(current: "old password", new: "new password"))
        let stored = try store.load()
        #expect(model.notice == "密码已修改，其他设备需要重新登录" && stored?.refreshToken == "r3")
    }

    /// 意见反馈 (P19): checks before sending, and one key per text until the server answers, so a
    /// send retried after a lost answer is stored once (T-M2-31).
    @Test func sendingFeedback() async throws {
        let stub = StubTransport([
            .json(202, #"{"resend_after_seconds":60}"#), .json(200, tokens(1)),
            .fail(.timedOut), .json(201, #"{"id":"6f1c2d3e-0000-4000-8000-000000000009"}"#),
            .json(422, error("invalid_request", "请求不完整或格式不对：content")),
            .json(201, #"{"id":"6f1c2d3e-0000-4000-8000-00000000000a"}"#),
        ])
        let model = model(stub)
        model.phone = "13812345678"
        await model.sendPhoneCode()
        model.code = "123456"
        await model.signInWithPhone()

        model.feedbackText = "  \n "
        #expect(!model.canSendFeedback)
        #expect(await model.sendFeedback(appVersion: "0.1.0 (110)") == false)
        #expect(model.errorText == "请先写下想说的话")
        model.feedbackText = String(repeating: "长", count: AccountModel.feedbackLimit + 1)
        #expect(!model.canSendFeedback)
        #expect(await model.sendFeedback(appVersion: "0.1.0 (110)") == false)
        #expect(model.errorText == "最多 5000 个字" && stub.requests.count == 2)

        // The answer is lost: the text stays, and sending it again reuses the key.
        model.feedbackText = " 同步很快 "
        #expect(await model.sendFeedback(appVersion: "0.1.0 (110)") == false)
        #expect(model.feedbackText == " 同步很快 " && model.errorText == "连不上闻笺的服务器，请稍后再试")
        #expect(await model.sendFeedback(appVersion: "0.1.0 (110)"))
        #expect(model.feedbackText.isEmpty && model.notice == "已收到，谢谢你的反馈")
        let first = stub.requests[2], retry = stub.requests[3]
        #expect(first.url!.path == "/v1/feedback" && first.value(forHTTPHeaderField: "Authorization") == "Bearer a1")
        #expect(stub.body(2) == ["content": "同步很快", "app_version": "0.1.0 (110)"])
        let key = try #require(first.value(forHTTPHeaderField: "Idempotency-Key"))
        #expect(retry.value(forHTTPHeaderField: "Idempotency-Key") == key)

        // An answer, even a refusal, ends the key: the next send has a new one.
        model.feedbackText = "再来一条"
        #expect(await model.sendFeedback(appVersion: "0.1.0 (110)") == false)
        #expect(model.errorText == "请求不完整或格式不对：content")
        #expect(await model.sendFeedback(appVersion: "0.1.0 (110)"))
        let refused = stub.requests[4].value(forHTTPHeaderField: "Idempotency-Key")
        let resent = stub.requests[5].value(forHTTPHeaderField: "Idempotency-Key")
        #expect(refused != nil && resent != nil && refused != resent && refused != key)
    }
}
