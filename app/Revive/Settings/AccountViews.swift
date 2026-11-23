import Account
import AppModel
import SwiftUI

// 闻笺账号 (product-spec.md P17～P19; features.md K1, O1b). Reachable only when the build has a
// server address (`AppEnvironment.account`); the card and recordings never need it.

/// P17 闻笺账号.
struct AccountView: View {
    @Bindable var model: AccountModel
    @State private var showsLogin = false
    @State private var showsPassword = false
    @State private var confirmsSignOut = false
    @State private var confirmsDelete = false

    var body: some View {
        List {
            if let user = model.user {
                Section {
                    LabeledContent("账号", value: user.displayName)
                }
                .surfaceRows()
                Section {
                    if user.hasPassword {
                        Button("修改密码") { showsPassword = true }
                    }
                    NavigationLink("意见反馈", value: Route.feedback)
                }
                .surfaceRows()
                Section {
                    Button("退出登录") { confirmsSignOut = true }
                }
                .surfaceRows()
                Section {
                    Button("注销账号", role: .destructive) { confirmsDelete = true }
                } footer: {
                    Text("注销会删除服务器上这个账号的全部数据。这部手机上的录音不受影响。")
                }
                .surfaceRows()
            } else {
                Section {
                    Button("登录或注册") { showsLogin = true }
                } footer: {
                    Text("登录后可以使用闻笺的服务。录音卡、录音和你自己设置的 AI 服务都不需要登录。")
                }
                .surfaceRows()
            }
        }
        .listStyle(.insetGrouped)
        .paperBackground()
        .disabled(model.isBusy)
        .overlay { if model.isBusy { ProgressView() } }
        .navigationTitle("闻笺账号")
        .navigationBarTitleDisplayMode(.inline)
        // Reads the Keychain; only a signed-in account asks the server for its latest details.
        .task {
            await model.load()
            await model.refresh()
        }
        .sheet(isPresented: $showsLogin) {
            LoginSheet(client: model.client) { model.signedIn($0) }
        }
        .sheet(isPresented: $showsPassword) {
            ChangePasswordSheet(model: model)
        }
        .confirmationDialog("退出登录？", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { Task { await model.signOut() } }
        } message: {
            Text("退出后，这部手机上的录音不受影响。")
        }
        .alert("注销账号？", isPresented: $confirmsDelete) {
            Button("注销", role: .destructive) { Task { _ = await model.deleteAccount() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("注销后，服务器上这个账号的数据（账号、登记的录音卡、意见反馈）会全部删除，不能恢复。这部手机上的录音不受影响。")
        }
        .toast($model.toast)
    }
}

/// P18 登录: phone and code, or email; email sign-up and password reset in the same sheet.
struct LoginSheet: View {
    @State private var model: LoginModel
    private let onSignedIn: (AccountUser) -> Void
    @Environment(\.dismiss) private var dismiss

    init(client: AccountClient, onSignedIn: @escaping (AccountUser) -> Void) {
        _model = State(initialValue: LoginModel(client: client))
        self.onSignedIn = onSignedIn
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("登录方式", selection: methodBinding) {
                        Text("手机号").tag(false)
                        Text("邮箱").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .listRowBackground(Color.clear)
                switch model.mode {
                case .phone: phoneSection
                case .emailSignIn: emailSignInSection
                case .emailSignUp: signUpSection
                case .passwordReset: resetSection
                }
                if let error = model.error {
                    Section {
                        Text(error).foregroundStyle(Theme.accent)
                    }
                    .surfaceRows()
                } else if let notice = model.notice {
                    Section {
                        Text(notice).foregroundStyle(Theme.inkMuted)
                    }
                    .surfaceRows()
                }
            }
            .listStyle(.insetGrouped)
            .paperBackground()
            .disabled(model.isBusy)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                if model.isBusy {
                    ToolbarItem(placement: .confirmationAction) { ProgressView() }
                }
            }
            .onChange(of: model.signedIn) { _, user in
                guard let user else { return }
                onSignedIn(user)
                dismiss()
            }
        }
    }

    private var title: String {
        switch model.mode {
        case .phone, .emailSignIn: "登录"
        case .emailSignUp: "注册"
        case .passwordReset: "找回密码"
        }
    }

    /// 手机号 / 邮箱; sign-up and reset count as 邮箱.
    private var methodBinding: Binding<Bool> {
        Binding(get: { model.mode != .phone }, set: { email in model.switchTo(email ? .emailSignIn : .phone) })
    }

    private var phoneSection: some View {
        Section {
            TextField("手机号", text: $model.phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
            codeRow(sendTitle: "获取验证码")
            Button("登录") { Task { await model.submit() } }
                .fontWeight(.semibold)
        } footer: {
            Text("第一次登录会自动注册。目前只支持中国大陆手机号。")
        }
        .surfaceRows()
    }

    private var emailSignInSection: some View {
        Section {
            emailField
            SecureField("密码", text: $model.password)
                .textContentType(.password)
            Button("登录") { Task { await model.submit() } }
                .fontWeight(.semibold)
            Button("注册新账号") { model.switchTo(.emailSignUp) }
            Button("忘记密码") { model.switchTo(.passwordReset) }
        }
        .surfaceRows()
    }

    private var signUpSection: some View {
        Section {
            emailField
            SecureField("密码（至少 8 位）", text: $model.password)
                .textContentType(.newPassword)
            codeRow(sendTitle: "发送验证码")
            Button("完成注册") { Task { await model.submit() } }
                .fontWeight(.semibold)
            Button("已有账号，去登录") { model.switchTo(.emailSignIn) }
        } footer: {
            Text("验证码会发到这个邮箱，10 分钟内有效。")
        }
        .surfaceRows()
    }

    private var resetSection: some View {
        Section {
            emailField
            codeRow(sendTitle: "发送验证码")
            SecureField("新密码（至少 8 位）", text: $model.newPassword)
                .textContentType(.newPassword)
            Button("重设密码") { Task { await model.submit() } }
                .fontWeight(.semibold)
            Button("返回登录") { model.switchTo(.emailSignIn) }
        } footer: {
            Text("重设后，其他设备上的登录都会失效。")
        }
        .surfaceRows()
    }

    private var emailField: some View {
        TextField("邮箱", text: $model.email)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    /// The code field with its send button, which counts down until another code may be asked for.
    private func codeRow(sendTitle: String) -> some View {
        HStack {
            TextField("验证码", text: $model.code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let wait = model.secondsUntilResend()
                Button(wait > 0 ? "\(wait) 秒后重新获取" : sendTitle) { Task { await model.sendCode() } }
                    .buttonStyle(.borderless)
                    .disabled(wait > 0)
            }
        }
    }
}

/// 修改密码, from P17.
struct ChangePasswordSheet: View {
    @Bindable var model: AccountModel
    @State private var current = ""
    @State private var fresh = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SecureField("当前密码", text: $current)
                        .textContentType(.password)
                    SecureField("新密码（至少 8 位）", text: $fresh)
                        .textContentType(.newPassword)
                } footer: {
                    Text("修改后，其他设备上的登录会失效。")
                }
                .surfaceRows()
            }
            .listStyle(.insetGrouped)
            .paperBackground()
            .disabled(model.isBusy)
            .navigationTitle("修改密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task { if await model.changePassword(current: current, new: fresh) { dismiss() } }
                    }
                }
            }
            .toast($model.toast)
        }
    }
}

/// P19 意见反馈.
struct FeedbackView: View {
    @Bindable var model: AccountModel
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 180)
            } footer: {
                Text("会和 App 版本号一起发送，不含录音和日志。需要诊断信息时，请在设置里「导出诊断信息」后发给我们。")
            }
            .surfaceRows()
        }
        .listStyle(.insetGrouped)
        .paperBackground()
        .disabled(model.isBusy)
        .navigationTitle("意见反馈")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("发送") {
                    Task { if await model.sendFeedback(text, appVersion: AboutView.version) { dismiss() } }
                }
            }
        }
        .toast($model.toast)
    }
}
