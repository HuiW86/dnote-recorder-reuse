import AppModel
import Assistant
import SwiftUI

/// 设置 → AI 服务 (features.md X11, ADR-009): the user's own OpenAI-compatible service.
struct AssistantSettingsView: View {
    @State private var model: AssistantSettingsModel

    init(preferences: Preferences) {
        _model = State(initialValue: AssistantSettingsModel(preferences: preferences, keyStore: KeychainKeyStore()))
    }

    var body: some View {
        List {
            Section {
                Menu {
                    ForEach(model.presets) { preset in
                        Button(preset.name) { model.choose(preset) }
                    }
                } label: {
                    LabeledContent("服务商", value: model.selectedPreset?.name ?? "自定义")
                }
                TextField("地址，例如 https://api.deepseek.com/v1", text: $model.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("模型", text: $model.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密钥", text: $model.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("兼容 OpenAI 接口的服务都可以用。密钥只保存在这部手机的钥匙串里。")
            }
            .surfaceRows()

            Section {
                Button("保存") { model.save() }
                    .disabled(!model.isConfigured)
                Button {
                    model.test()
                } label: {
                    HStack {
                        Text("测试连接")
                        Spacer()
                        if model.isTesting { ProgressView() }
                    }
                }
                .disabled(model.isTesting)
                if let result = model.testResult {
                    Text(result)
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .surfaceRows()

            Section {
                Button("清除这个服务", role: .destructive) { model.clear() }
            } footer: {
                Text("用这个服务生成纪要时，录音的文字稿会发送给它；录音音频不会发送。服务怎样处理这些文字，以它自己的隐私政策为准。不填就不会发送任何内容。")
            }
            .surfaceRows()
        }
        .listStyle(.insetGrouped)
        .paperBackground()
        .navigationTitle("AI 服务")
        .navigationBarTitleDisplayMode(.inline)
        .toast($model.toast)
    }
}
