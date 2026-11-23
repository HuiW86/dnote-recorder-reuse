import AppModel
import Assistant
import SwiftUI

/// 闻笺 → 设置… on the Mac: the user's own AI service (features.md X11, ADR-009) and 本机转写
/// (X9). The same settings model as the iPhone (`AssistantSettingsModel`); the Mac keeps its
/// own copy, since the two apps do not share settings or keys.
struct MacSettingsView: View {
    @Bindable var preferences: Preferences

    var body: some View {
        TabView {
            AssistantSettingsForm(preferences: preferences)
                .tabItem { Label("AI 服务", systemImage: "sparkles") }
            Form {
                Toggle("本机转写（试验）", isOn: $preferences.onDeviceTranscriptEnabled)
                Text("打开后，可以在这台 Mac 上用系统的离线语音识别把录音转成文字，不联网，不区分说话人；第一次使用时系统会询问语音识别权限。准确度还没有充分验证。打开时优先用它，不会上传音频。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("转文字", systemImage: "text.quote") }
        }
        .frame(width: 560, height: 520)
    }
}

private struct AssistantSettingsForm: View {
    @State private var model: AssistantSettingsModel

    init(preferences: Preferences) {
        _model = State(initialValue: AssistantSettingsModel(preferences: preferences, keyStore: KeychainKeyStore()))
    }

    var body: some View {
        Form {
            Section {
                Picker("服务商", selection: Binding(get: { model.selectedPreset?.id ?? "" },
                                                 set: { id in
                                                     if let preset = model.presets.first(where: { $0.id == id }) {
                                                         model.choose(preset)
                                                     }
                                                 })) {
                    Text("自定义").tag("")
                    ForEach(model.presets) { preset in Text(preset.name).tag(preset.id) }
                }
                TextField("地址", text: $model.baseURL, prompt: Text("例如 https://api.deepseek.com/v1"))
                    .autocorrectionDisabled()
                TextField("模型", text: $model.model).autocorrectionDisabled()
                SecureField("密钥", text: $model.apiKey)
            } footer: {
                Text("兼容 OpenAI 接口的服务都可以用。密钥只保存在这台 Mac 的钥匙串里，不会发给我们。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("转写模型（可选）", text: $model.transcriptionModel).autocorrectionDisabled()
                if model.transcriptionModel.isEmpty, let suggested = model.suggestedTranscriptionModel {
                    Button("填入 \(suggested)") { model.transcriptionModel = suggested }
                }
            } footer: {
                Text("填了转写模型，就能用这个服务把录音转成文字，这时录音音频会上传给它。留空则不会上传任何音频。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("你的职业（可选）", text: $model.profession, prompt: Text("比如：产品经理、律师、老师"))
            } footer: {
                Text("填了以后，生成纪要时会侧重这个职业关心的结论、数字和后续动作；职业会随文字稿一起发给 AI 服务。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("保存") { model.save() }.disabled(!model.isConfigured)
                    Button("测试连接") { model.test() }.disabled(model.isTesting)
                    if model.isTesting { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("清除这个服务", role: .destructive) { model.clear() }
                }
                if let result = model.testResult {
                    Text(result).font(.callout).foregroundStyle(.secondary)
                }
                if let toast = model.toast {
                    Text(toast.text).font(.callout)
                }
            } footer: {
                Text("生成纪要时，录音的文字稿会发送给这个服务。服务怎样处理这些文字，以它自己的隐私政策为准。不填就不会发送任何内容。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
