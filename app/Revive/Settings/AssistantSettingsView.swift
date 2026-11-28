import AppModel
import Assistant
import SwiftUI

/// 设置 → AI 服务 (features.md X11, ADR-009): the user's own OpenAI-compatible service.
struct AssistantSettingsView: View {
    @State private var model: AssistantSettingsModel
    @State private var confirmingClear = false

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
                Text("兼容 OpenAI 接口的服务都可以用。密钥只保存在这部手机的钥匙串里，不会进入备份，换手机后需要重新填写。")
            }
            .surfaceRows()

            Section {
                TextField("转写模型（可选）", text: $model.transcriptionModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if model.transcriptionModel.isEmpty, let suggested = model.suggestedTranscriptionModel {
                    Button("填入 \(suggested)") { model.transcriptionModel = suggested }
                }
            } header: {
                Text("用这个服务转文字")
            } footer: {
                Text("填了转写模型，录音详情里就能用这个服务把录音转成文字。这时录音音频会上传给它。留空则不会上传任何音频。")
            }
            .surfaceRows()

            Section {
                TextField("比如：产品经理、律师、老师", text: $model.profession)
            } header: {
                Text("你的职业（可选）")
            } footer: {
                Text("填了以后，生成纪要时会侧重这个职业关心的结论、数字和后续动作。职业会随文字稿一起发送给 AI 服务。")
            }
            .surfaceRows()

            Section {
                Button("保存") { model.save() }
                    .disabled(!model.canSave)
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
                // Nothing to clear until a service is stored.
                if model.hasSavedService {
                    Button("清除这个服务", role: .destructive) { confirmingClear = true }
                }
            } footer: {
                Text("用这个服务生成纪要时，录音的文字稿会发送给它；录音音频不会发送。服务怎样处理这些文字，以它自己的隐私政策为准。不填就不会发送任何内容。")
            }
            .surfaceRows()
        }
        .listStyle(.insetGrouped)
        .paperBackground()
        // 测试连接's spinner and its result line, and 清除这个服务 appearing once saved.
        .motion(Motion.standard, value: model.isTesting)
        .motion(Motion.standard, value: model.testResult)
        .motion(Motion.standard, value: model.hasSavedService)
        .navigationTitle("AI 服务")
        .navigationBarTitleDisplayMode(.inline)
        .toast($model.toast)
        // A filled-in form is kept even without 保存; half a service is not stored.
        .onDisappear { model.saveOnLeave() }
        .confirmationDialog("清除 AI 服务？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清除", role: .destructive) { model.clear() }
        } message: {
            Text("会移除已保存的地址、模型和密钥，下次使用需重新填写。已生成的文字稿和纪要会保留。")
        }
    }
}
