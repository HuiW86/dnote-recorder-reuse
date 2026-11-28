import AppKit
import AppModel
import SwiftUI

/// A rewrite or an answer on the Mac (features.md X15, G3): it opens at once and fills in as the
/// reply arrives; closing it stops the request, as on the iPhone.
struct AssistantOutputSheet: View {
    let output: AssistantOutput
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var dismissTitle: String {
        if output.isStreaming { return "停止" }
        return output.isCutOff ? "关闭" : "完成"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(output.title).font(.headline).lineLimit(1)
                Spacer()
                if output.isStreaming { ProgressView().controlSize(.small) }
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if output.text.isEmpty, output.isStreaming {
                        Text("正在等你的 AI 服务回复").foregroundStyle(.secondary)
                    } else {
                        Text(RichText.attributed(output.text)).textSelection(.enabled)
                    }
                    if output.isCutOff {
                        Label("回答没有收完整，可以关掉后再试一次。", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            Divider()
            HStack {
                Button(copied ? "已拷贝" : "拷贝") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output.text, forType: .string)
                    copied = true
                }
                .disabled(output.isStreaming || output.text.isEmpty)
                Spacer()
                Button(dismissTitle) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 420, idealHeight: 560)
    }
}

/// 问一问 on the Mac: one question about this recording, answered by the user's service.
struct AskSheet: View {
    let onAsk: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("问一问这条录音").font(.headline)
            TextField("比如：最后定下来的上线时间是哪天？", text: $question, axis: .vertical)
                .lineLimit(2...5)
            Text("问题会和这条录音的文字稿、纪要一起发给你在设置里填的 AI 服务。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("提问") {
                    onAsk(question)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
