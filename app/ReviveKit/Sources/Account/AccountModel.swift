// 设置 → 账号 (features.md K1; product-spec.md P17): the screen state for signing in with a phone
// number or an email, registering, resetting a password, and the signed-in account page.
//
// Kept in this module rather than AppModel so it builds and is tested with the rest of the
// account code on Linux too (AppModel needs AVFoundation). No view code here.

import Foundation
import Observation

@MainActor
@Observable
public final class AccountModel {
    public enum Method: String, CaseIterable, Identifiable, Sendable {
        case phone, email
        public var id: String { rawValue }
        public var title: String { self == .phone ? "手机号" : "邮箱" }
    }

    /// Where the email form is.
    public enum EmailStep: Equatable, Sendable {
        case signIn, register
        /// A code went to the address after registering (or signing in before verifying).
        case verify
        case forgot
        /// A reset code went to the address.
        case reset
    }

    public var method: Method = .phone
    public var emailStep: EmailStep = .signIn
    public var phone = ""
    public var email = ""
    public var password = ""
    public var code = ""
    public var newPassword = ""

    /// The account, nil when signed out.
    public private(set) var user: AccountUser?
    public private(set) var isBusy = false
    /// Why the last action failed, shown under the form.
    public private(set) var errorText: String?
    /// A passing message ("已登录"); the view clears it after showing it.
    public var notice: String?

    /// Where the last code went (normalised), and when another may be asked for.
    public private(set) var codeTarget: String?
    private var resendAt: Date?

    @ObservationIgnored public let session: AccountSession
    @ObservationIgnored private let now: () -> Date

    public static let passwordMinimum = 8

    public init(session: AccountSession, now: @escaping () -> Date = { Date() }) {
        self.session = session
        self.now = now
    }

    /// Shows the stored account at once, then checks it with the server. A sign-in that has
    /// ended there shows as signed out; no connection keeps what is stored.
    public func load() async {
        user = await session.user
        guard user != nil else { return }
        do {
            user = try await session.reloadUser()
        } catch AccountError.signedOut {
            user = nil
        } catch {
            // Offline or server trouble: the stored account stays on screen.
        }
    }

    // MARK: Input checks

    /// "+8613812345678" for a mainland mobile number typed with or without +86, spaces or dashes.
    public static func normalizedPhone(_ text: String) -> String? {
        var digits = text.filter { !" -()".contains($0) }
        if digits.hasPrefix("+86") { digits.removeFirst(3) } else if digits.hasPrefix("0086") { digits.removeFirst(4) }
        guard digits.count == 11, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), digits.hasPrefix("1"),
              let second = digits.dropFirst().first, "3456789".contains(second) else { return nil }
        return "+86" + digits
    }

    /// Spaces around the address are ignored (they are trimmed before sending); none inside.
    public static func looksLikeEmail(_ text: String) -> Bool {
        let address = text.trimmingCharacters(in: .whitespaces)
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasPrefix(".")
            && !parts[1].hasSuffix(".") && !address.contains(" ")
    }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces).lowercased() }
    private var trimmedCode: String { code.trimmingCharacters(in: .whitespaces) }

    /// Seconds until another code may be asked for (the view refreshes it every second).
    public var resendWait: Int {
        guard let resendAt else { return 0 }
        return max(0, Int((resendAt.timeIntervalSince(now())).rounded(.up)))
    }

    public var canSendPhoneCode: Bool {
        !isBusy && Self.normalizedPhone(phone) != nil && resendWait == 0
    }

    /// A 6-digit code for the number it was sent to.
    public var canSignInWithPhone: Bool {
        !isBusy && trimmedCode.count == 6 && trimmedCode.allSatisfy(\.isNumber)
            && codeTarget != nil && codeTarget == Self.normalizedPhone(phone)
    }

    public var canSubmitEmail: Bool {
        guard !isBusy, Self.looksLikeEmail(email) else { return false }
        switch emailStep {
        case .signIn: return !password.isEmpty
        case .register: return password.count >= Self.passwordMinimum
        case .verify: return trimmedCode.count == 6
        case .forgot: return resendWait == 0
        case .reset: return trimmedCode.count == 6 && newPassword.count >= Self.passwordMinimum
        }
    }

    // MARK: Phone

    public func sendPhoneCode() async {
        guard canSendPhoneCode, let target = Self.normalizedPhone(phone) else { return }
        await run {
            let sent = try await self.session.client.sendSMSCode(phone: target)
            self.codeSent(to: target, wait: sent.resendAfterSeconds)
            self.notice = "验证码已发到 \(AccountUser.masked(phone: target))"
        }
    }

    public func signInWithPhone() async {
        guard canSignInWithPhone, let target = Self.normalizedPhone(phone) else { return }
        await run {
            try await self.adopt(try await self.session.client.signIn(phone: target, code: self.trimmedCode))
        }
    }

    // MARK: Email

    /// The button under the email form does what the current step needs.
    public func submitEmail() async {
        guard canSubmitEmail else { return }
        switch emailStep {
        case .signIn: await signInWithEmail()
        case .register: await register()
        case .verify: await verify()
        case .forgot: await sendReset()
        case .reset: await resetPassword()
        }
    }

    public func show(_ step: EmailStep) {
        emailStep = step
        errorText = nil
        code = ""
    }

    private func signInWithEmail() async {
        let address = trimmedEmail
        await run {
            do {
                try await self.adopt(try await self.session.client.signIn(email: address, password: self.password))
            } catch let error as AccountError where error.code == "email_not_verified" {
                // Registered but never verified: send a fresh code (this keeps the password just typed).
                let sent = try await self.session.client.register(email: address, password: self.password)
                self.codeSent(to: address, wait: sent.resendAfterSeconds)
                self.emailStep = .verify
                self.notice = "这个邮箱还没有验证，验证码已发到 \(address)"
            }
        }
    }

    private func register() async {
        let address = trimmedEmail
        await run {
            let sent = try await self.session.client.register(email: address, password: self.password)
            self.codeSent(to: address, wait: sent.resendAfterSeconds)
            self.emailStep = .verify
            self.notice = "验证码已发到 \(address)"
        }
    }

    private func verify() async {
        let address = trimmedEmail
        await run {
            try await self.adopt(try await self.session.client.verify(email: address, code: self.trimmedCode))
        }
    }

    private func sendReset() async {
        let address = trimmedEmail
        await run {
            let sent = try await self.session.client.sendPasswordReset(email: address)
            self.codeSent(to: address, wait: sent.resendAfterSeconds)
            self.emailStep = .reset
            // The server answers the same for unknown addresses; so does this text.
            self.notice = "如果这个邮箱注册过，验证码已发到 \(address)"
        }
    }

    private func resetPassword() async {
        let address = trimmedEmail
        await run {
            try await self.session.client.resetPassword(email: address, code: self.trimmedCode,
                                                        newPassword: self.newPassword)
            self.password = ""
            self.newPassword = ""
            self.show(.signIn)
            self.notice = "密码已重设，请用新密码登录"
        }
    }

    // MARK: Signed in

    public func signOut() async {
        isBusy = true
        await session.signOut()
        isBusy = false
        user = nil
        clearForm()
        notice = "已退出登录"
    }

    /// Deletes the account on the server (the view asks first). Recordings on this phone stay.
    public func deleteAccount() async {
        await run {
            try await self.session.deleteAccount()
            self.user = nil
            self.clearForm()
            self.notice = "账号已注销。这部手机上的录音不受影响。"
        }
    }

    /// True when it worked; other sign-ins of the account end.
    @discardableResult
    public func changePassword(current: String, new: String) async -> Bool {
        guard new.count >= Self.passwordMinimum else {
            errorText = "新密码至少 \(Self.passwordMinimum) 位"
            return false
        }
        var changed = false
        await run {
            try await self.session.changePassword(current: current, new: new)
            changed = true
            self.notice = "密码已修改，其他设备需要重新登录"
        }
        return changed
    }

    // MARK: 意见反馈 (product-spec.md P19)

    /// What the user is writing; kept when sending fails.
    public var feedbackText = ""
    /// The key of a send whose answer never came, with the text it was for: sending the same
    /// text again reuses it, so the server keeps one copy. Any answer, or other text, starts anew.
    @ObservationIgnored private var unansweredFeedback: (text: String, key: String)?

    /// The backend's limit.
    public static let feedbackLimit = 5000

    public var canSendFeedback: Bool {
        let text = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.count <= Self.feedbackLimit && !isBusy
    }

    /// True when the server has it; the text is then cleared.
    @discardableResult
    public func sendFeedback(appVersion: String) async -> Bool {
        let text = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorText = "请先写下想说的话"
            return false
        }
        guard text.count <= Self.feedbackLimit else {
            errorText = "最多 \(Self.feedbackLimit) 个字"
            return false
        }
        let key = unansweredFeedback.flatMap { $0.text == text ? $0.key : nil } ?? UUID().uuidString
        unansweredFeedback = (text, key)
        var sent = false
        await run {
            do {
                try await self.session.sendFeedback(text, appVersion: appVersion, idempotencyKey: key)
            } catch let error as AccountError {
                // Only a request that got no answer may be sent again under the same key.
                if case .server = error { self.unansweredFeedback = nil }
                if error == .signedOut { self.unansweredFeedback = nil }
                throw error
            }
            self.unansweredFeedback = nil
            self.feedbackText = ""
            sent = true
            self.notice = "已收到，谢谢你的反馈"
        }
        return sent
    }

    // MARK: Plumbing

    private func adopt(_ tokens: AccountTokens) async throws {
        try await session.adopt(tokens)
        user = tokens.user
        clearForm()
        notice = "已登录"
    }

    private func codeSent(to target: String, wait: Int) {
        codeTarget = target
        resendAt = now().addingTimeInterval(TimeInterval(wait))
        code = ""
    }

    private func clearForm() {
        feedbackText = ""
        unansweredFeedback = nil
        password = ""
        code = ""
        newPassword = ""
        codeTarget = nil
        resendAt = nil
        emailStep = .signIn
        errorText = nil
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        isBusy = true
        errorText = nil
        defer { isBusy = false }
        do {
            try await work()
        } catch let error as AccountError {
            if error == .signedOut { user = nil }
            errorText = error.userText
        } catch is CancellationError {
            // Left the page.
        } catch {
            errorText = "出错了，请稍后再试"
        }
    }
}

extension AccountUser {
    /// "138****5678" for "+8613812345678".
    public static func masked(phone: String) -> String {
        let digits = phone.hasPrefix("+86") ? String(phone.dropFirst(3)) : phone
        guard digits.count == 11 else { return digits }
        return digits.prefix(3) + "****" + digits.suffix(4)
    }
}
