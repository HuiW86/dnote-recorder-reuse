import Account
import Foundation
import Observation

// 闻笺账号 (features.md K1, O1b; product-spec.md P17～P19). Only the account pages use this: the
// card, recordings, on-device transcription and the user's own AI service never need it
// (CLAUDE.md rule 3, ADR-009). Signed out, nothing is sent to the backend (prd.md §7.1).

/// Where the backend is. Until it is deployed the address is empty and the app shows no account
/// pages at all (product-spec.md P09).
public enum AccountServer {
    /// Info.plist key, set from `app/project.yml`.
    public static let infoKey = "ReviveAPIBaseURL"

    /// An https address; anything else (empty, a typo) means no account features. Plain http is
    /// accepted only for a local test server.
    public static func baseURL(_ info: [String: Any]?) -> URL? {
        guard let text = (info?[infoKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, let url = URL(string: text), let host = url.host, !host.isEmpty
        else { return nil }
        switch url.scheme?.lowercased() {
        case "https": return url
        case "http" where host == "localhost" || host == "127.0.0.1": return url
        default: return nil
        }
    }
}

/// Checks the forms do before anything is sent; the backend checks again.
public enum AccountInput {
    /// 11 digits of a mainland China mobile number, from "+86 138-0013-8000" and the like; nil
    /// otherwise (the backend accepts nothing else yet, ADR-003).
    public static func phone(_ text: String) -> String? {
        var digits = text.filter { !" -()\u{00A0}".contains($0) }
        if digits.hasPrefix("+86") { digits.removeFirst(3) } else if digits.hasPrefix("0086") { digits.removeFirst(4) }
        guard digits.count == 11, digits.first == "1", let second = digits.dropFirst().first,
              ("3"..."9").contains(second), digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber)
        else { return nil }
        return digits
    }

    public static func email(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."),
              !parts[1].hasSuffix("."), !trimmed.contains(" ")
        else { return nil }
        return trimmed
    }

    public static func code(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...8).contains(trimmed.count), trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber)
        else { return nil }
        return trimmed
    }

    /// 8 to 128 characters, the backend's rule.
    public static func isPassword(_ text: String) -> Bool {
        (8...128).contains(text.count)
    }

    static let badPhone = "请输入中国大陆手机号"
    static let badEmail = "请输入正确的邮箱地址"
    static let badCode = "请输入收到的验证码"
    static let shortPassword = "密码至少 8 位"
    static let noPassword = "请输入密码"
}

/// "登录" (product-spec.md P18): phone and code, email and password, email sign-up, password reset.
@MainActor
@Observable
public final class LoginModel {
    public enum Mode: Equatable, Sendable {
        /// Phone and SMS code; the first sign-in creates the account.
        case phone
        case emailSignIn
        /// Email, password, then the emailed code.
        case emailSignUp
        /// Email, then the emailed code and a new password.
        case passwordReset
    }

    public private(set) var mode: Mode = .phone
    public var phone = ""
    public var email = ""
    public var password = ""
    public var code = ""
    public var newPassword = ""
    /// A code was sent in this mode: the code field shows.
    public private(set) var codeSent = false
    public private(set) var isBusy = false
    /// Why the last step failed, under the form.
    public private(set) var error: String?
    /// What happened, under the form ("验证码已发送", "密码已重设…").
    public private(set) var notice: String?
    /// Set when signed in: the page closes.
    public private(set) var signedIn: AccountUser?

    @ObservationIgnored private let client: AccountClient
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var resendAt: Date?

    public init(client: AccountClient, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.now = now
    }

    public func switchTo(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        code = ""
        newPassword = ""
        codeSent = false
        resendAt = nil
        error = nil
        notice = nil
    }

    /// Seconds before "获取验证码" works again; 0 when it does.
    public func secondsUntilResend() -> Int {
        guard let resendAt else { return 0 }
        return max(0, Int(resendAt.timeIntervalSince(now()).rounded(.up)))
    }

    /// "获取验证码" (phone), "发送验证码" (sign-up, reset).
    public func sendCode() async {
        guard !isBusy, secondsUntilResend() == 0 else { return }
        error = nil
        notice = nil
        switch mode {
        case .phone:
            guard let phone = AccountInput.phone(self.phone) else { return fail(AccountInput.badPhone) }
            await run { try await $0.sendSMSCode(phone: phone) }
        case .emailSignUp:
            guard let email = AccountInput.email(self.email) else { return fail(AccountInput.badEmail) }
            guard AccountInput.isPassword(self.password) else { return fail(AccountInput.shortPassword) }
            let secret = self.password
            await run { try await $0.register(email: email, password: secret) }
        case .passwordReset:
            guard let email = AccountInput.email(self.email) else { return fail(AccountInput.badEmail) }
            await run { try await $0.sendPasswordReset(email: email) }
        case .emailSignIn:
            return
        }
    }

    /// "登录", "完成注册", "重设密码".
    public func submit() async {
        guard !isBusy else { return }
        error = nil
        switch mode {
        case .phone:
            guard let phone = AccountInput.phone(self.phone) else { return fail(AccountInput.badPhone) }
            guard let code = AccountInput.code(self.code) else { return fail(AccountInput.badCode) }
            await signIn { try await $0.signIn(phone: phone, code: code) }
        case .emailSignIn:
            guard let email = AccountInput.email(self.email) else { return fail(AccountInput.badEmail) }
            guard !self.password.isEmpty else { return fail(AccountInput.noPassword) }
            let secret = self.password
            await signIn { try await $0.signIn(email: email, password: secret) }
        case .emailSignUp:
            guard let email = AccountInput.email(self.email) else { return fail(AccountInput.badEmail) }
            guard let code = AccountInput.code(self.code) else { return fail(AccountInput.badCode) }
            await signIn { try await $0.verifyEmail(email, code: code) }
        case .passwordReset:
            guard let email = AccountInput.email(self.email) else { return fail(AccountInput.badEmail) }
            guard let code = AccountInput.code(self.code) else { return fail(AccountInput.badCode) }
            guard AccountInput.isPassword(self.newPassword) else { return fail(AccountInput.shortPassword) }
            let secret = self.newPassword
            isBusy = true
            defer { isBusy = false }
            do {
                try await client.resetPassword(email: email, code: code, newPassword: secret)
                switchTo(.emailSignIn)
                password = ""
                notice = "密码已重设，请用新密码登录"
            } catch {
                fail(error)
            }
        }
    }

    /// Sends a code and starts the resend countdown.
    private func run(_ send: @Sendable (AccountClient) async throws -> Int) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let wait = try await send(client)
            codeSent = true
            resendAt = now().addingTimeInterval(TimeInterval(wait))
            notice = "验证码已发送"
        } catch {
            fail(error)
        }
    }

    private func signIn(_ request: @Sendable (AccountClient) async throws -> AccountUser) async {
        isBusy = true
        defer { isBusy = false }
        do {
            signedIn = try await request(client)
        } catch AccountError.server(_, "email_not_verified", _, _) {
            // Registered but never verified: signing up again with the same password sends a code.
            switchTo(.emailSignUp)
            error = "这个邮箱还没有验证。点「发送验证码」，输入邮件里的验证码完成注册"
        } catch {
            fail(error)
        }
    }

    private func fail(_ message: String) {
        error = message
    }

    private func fail(_ error: Error) {
        if error is CancellationError { return }
        self.error = (error as? LocalizedError)?.errorDescription ?? "出错了，请稍后再试"
    }
}

/// "闻笺账号" (product-spec.md P17) and "意见反馈" (P19).
@MainActor
@Observable
public final class AccountModel {
    /// nil when signed out.
    public private(set) var user: AccountUser?
    public private(set) var isBusy = false
    public var toast: Toast?

    @ObservationIgnored public let client: AccountClient

    public init(client: AccountClient) {
        self.client = client
    }

    /// Reads the stored sign-in; no request (prd.md §7.1).
    public func load() async {
        user = await client.session()?.user
    }

    /// After the login page closed with a user.
    public func signedIn(_ user: AccountUser) {
        self.user = user
    }

    /// Updates the account from the backend while the page is open; a sign-in the server no
    /// longer accepts signs out here too.
    public func refresh() async {
        guard user != nil else { return }
        do {
            user = try await client.refreshUser()
        } catch AccountError.signedOut {
            user = nil
            toast = Toast(AccountError.signedOut.errorDescription ?? "")
        } catch {
            // Offline or the server is down: keep showing what is stored.
        }
    }

    public func signOut() async {
        await client.signOut()
        user = nil
        toast = Toast("已退出登录")
    }

    /// Returns true when the account is gone. Recordings on this phone are untouched.
    public func deleteAccount() async -> Bool {
        await perform { try await $0.deleteAccount() } success: {
            self.user = nil
            self.toast = Toast("账号已注销，服务器上的账号数据已删除")
        }
    }

    public func changePassword(current: String, new: String) async -> Bool {
        guard !current.isEmpty else {
            toast = Toast(AccountInput.noPassword)
            return false
        }
        guard AccountInput.isPassword(new) else {
            toast = Toast(AccountInput.shortPassword)
            return false
        }
        var changed: AccountUser?
        let ok = await perform { changed = try await $0.changePassword(current: current, new: new) } success: {
            self.toast = Toast("密码已修改，其他设备需要重新登录")
        }
        if let changed { user = changed }
        return ok
    }

    /// At most 5000 characters, like the backend.
    public static let feedbackLimit = 5000

    public func sendFeedback(_ text: String, appVersion: String) async -> Bool {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            toast = Toast("请先写下想说的话")
            return false
        }
        guard content.count <= Self.feedbackLimit else {
            toast = Toast("最多 \(Self.feedbackLimit) 个字")
            return false
        }
        return await perform { try await $0.sendFeedback(content, appVersion: appVersion) } success: {
            self.toast = Toast("已收到，谢谢你的反馈")
        }
    }

    private func perform(_ request: (AccountClient) async throws -> Void, success: () -> Void) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            try await request(client)
            success()
            return true
        } catch is CancellationError {
            return false
        } catch {
            if case AccountError.signedOut = error { user = nil }
            toast = Toast((error as? LocalizedError)?.errorDescription ?? "出错了，请稍后再试")
            return false
        }
    }
}
