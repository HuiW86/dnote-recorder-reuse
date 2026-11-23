import Account
import AppModel
import SwiftUI

/// 设置 → 账号 (product-spec.md P17, features.md K1): sign in with a phone number or an email, or
/// the signed-in account. Only shown when the build names a server (`AccountService`); nothing
/// on the device path needs it (CLAUDE.md rule 3).
struct AccountView: View {
    @State private var model: AccountModel
    @State private var toast: Toast?

    init(session: AccountSession) {
        _model = State(initialValue: AccountModel(session: session))
    }

    var body: some View {
        Group {
            if let user = model.user {
                SignedInView(model: model, user: user)
            } else {
                SignInView(model: model)
            }
        }
        .navigationTitle("账号")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .onChange(of: model.notice) { _, notice in
            guard let notice else { return }
            toast = Toast(notice)
            model.notice = nil
        }
        .toast($toast)
    }
}

/// Phone number with a code, or email with a password; registering and resetting a password
/// happen in the email form.
private struct SignInView: View {
    @Bindable var model: AccountModel

    var body: some View {
        List {
            Section {
                Picker("登录方式", selection: $model.method) {
                    ForEach(AccountModel.Method.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .surfaceRows()

            switch model.method {
            case .phone: phoneForm
            case .email: emailForm
            }

            if let error = model.errorText {
                Section {
                    Text(error).foregroundStyle(Theme.accent)
                }
                .surfaceRows()
            }
        }
        .listStyle(.insetGrouped)
        .paperBackground()
        .disabled(model.isBusy)
    }

    @ViewBuilder private var phoneForm: some View {
        Section {
            TextField("手机号", text: $model.phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
            HStack {
                TextField("6 位验证码", text: $model.code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                // Counts down the server's resend wait once a second.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let wait = model.resendWait
                    Button(wait > 0 ? "\(wait) 秒后重发" : (model.codeTarget == nil ? "获取验证码" : "重新获取")) {
                        Task { await model.sendPhoneCode() }
                    }
                    .disabled(!model.canSendPhoneCode)
                    .buttonStyle(.borderless)
                }
            }
        } footer: {
            Text("目前只支持中国大陆手机号。第一次用手机号登录会自动创建账号。")
        }
        .surfaceRows()
        Section {
            submitButton("登录", enabled: model.canSignInWithPhone) { await model.signInWithPhone() }
        } footer: {
            purposeNote
        }
        .surfaceRows()
    }

    @ViewBuilder private var emailForm: some View {
        Section {
            TextField("邮箱", text: $model.email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(model.emailStep == .verify || model.emailStep == .reset)
            switch model.emailStep {
            case .signIn:
                SecureField("密码", text: $model.password)
                    .textContentType(.password)
            case .register:
                SecureField("密码（至少 \(AccountModel.passwordMinimum) 位）", text: $model.password)
                    .textContentType(.newPassword)
            case .verify, .reset:
                TextField("邮件里的 6 位验证码", text: $model.code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                if model.emailStep == .reset {
                    SecureField("新密码（至少 \(AccountModel.passwordMinimum) 位）", text: $model.newPassword)
                        .textContentType(.newPassword)
                }
            case .forgot:
                EmptyView()
            }
        } footer: {
            Text(emailFooter)
        }
        .surfaceRows()
        Section {
            submitButton(emailAction, enabled: model.canSubmitEmail) { await model.submitEmail() }
            switch model.emailStep {
            case .signIn:
                Button("注册新账号") { model.show(.register) }
                Button("忘记密码") { model.show(.forgot) }
            case .register, .forgot, .verify, .reset:
                Button("返回登录") { model.show(.signIn) }
            }
        } footer: {
            purposeNote
        }
        .surfaceRows()
    }

    private var emailAction: String {
        switch model.emailStep {
        case .signIn: "登录"
        case .register: "注册"
        case .verify: "完成验证"
        case .forgot: model.resendWait > 0 ? "\(model.resendWait) 秒后可重发" : "发送验证码"
        case .reset: "重设密码"
        }
    }

    private var emailFooter: String {
        switch model.emailStep {
        case .signIn: "用注册时的邮箱和密码登录。"
        case .register: "注册后会给这个邮箱发一封验证码邮件，验证后才能登录。"
        case .verify: "验证码已发到上面的邮箱，10 分钟内有效。没收到可以看看垃圾邮件。"
        case .forgot: "输入注册时的邮箱，我们会发一个验证码用来重设密码。"
        case .reset: "重设后，这个账号在其他设备上的登录都会失效。"
        }
    }

    private var purposeNote: some View {
        Text("账号只用于把录音交给闻笺的服务器转成文字、整理纪要，以及换手机时恢复。录音卡、录音、同步、播放和导出都不需要登录。")
    }

    private func submitButton(_ title: String, enabled: Bool, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                Text(title).fontWeight(.semibold)
                Spacer()
                if model.isBusy { ProgressView() }
            }
        }
        .disabled(!enabled)
    }
}

/// The signed-in account: who, change password, sign out, delete (App Store requires deleting
/// inside the app).
private struct SignedInView: View {
    @Bindable var model: AccountModel
    let user: AccountUser
    @State private var confirmingDelete = false
    @State private var changingPassword = false

    var body: some View {
        List {
            Section {
                LabeledContent(user.phone != nil ? "手机号" : "邮箱", value: user.displayName)
            } footer: {
                Text("录音卡、录音、同步、播放和导出不需要登录；退出登录或注销账号都不影响这部手机上的录音。")
            }
            .surfaceRows()

            Section {
                if user.hasPassword {
                    Button("修改密码") { changingPassword = true }
                }
                Button("退出登录") { Task { await model.signOut() } }
            }
            .surfaceRows()

            Section {
                Button("注销账号", role: .destructive) { confirmingDelete = true }
            } footer: {
                Text("注销后，账号和保存在闻笺服务器上的录音、文字稿、纪要都会删除，不能恢复。")
            }
            .surfaceRows()

            if let error = model.errorText {
                Section {
                    Text(error).foregroundStyle(Theme.accent)
                }
                .surfaceRows()
            }
        }
        .listStyle(.insetGrouped)
        .paperBackground()
        .disabled(model.isBusy)
        .confirmationDialog("注销账号？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("注销账号", role: .destructive) { Task { await model.deleteAccount() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("账号和保存在闻笺服务器上的录音、文字稿、纪要都会删除，不能恢复。这部手机上的录音不受影响。")
        }
        .sheet(isPresented: $changingPassword) {
            ChangePasswordSheet(model: model)
        }
    }
}

private struct ChangePasswordSheet: View {
    let model: AccountModel
    @State private var current = ""
    @State private var new = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SecureField("当前密码", text: $current)
                        .textContentType(.password)
                    SecureField("新密码（至少 \(AccountModel.passwordMinimum) 位）", text: $new)
                        .textContentType(.newPassword)
                } footer: {
                    Text(model.errorText ?? "修改后，这个账号在其他设备上的登录都会失效。")
                }
                .surfaceRows()
            }
            .listStyle(.insetGrouped)
            .paperBackground()
            .navigationTitle("修改密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            if await model.changePassword(current: current, new: new) { dismiss() }
                        }
                    }
                    .disabled(current.isEmpty || new.count < AccountModel.passwordMinimum || model.isBusy)
                }
            }
        }
    }
}
