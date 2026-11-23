import AppModel
import LinkImport
import SwiftUI

/// 从链接导入 on the Mac (features.md X12): the iPhone's podcast part, on the same
/// `LinkImportModel`. Paste an episode link, a show's RSS address or an audio link; a show lists
/// its episodes to pick one. The download becomes a recording with source 导入. Video sites need a
/// command-line downloader and are not here yet.
struct LinkImportSheet: View {
    @State var model: LinkImportModel
    /// Called with the stored recording; the sheet then closes.
    let imported: (UUID, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("从链接导入").font(.headline)
                TextField("粘贴播客单集链接、RSS 地址或音频地址", text: $model.text, axis: .vertical)
                    .lineLimit(1...3)
                    .autocorrectionDisabled()
                    .focused($fieldFocused)
                    .disabled(model.isBusy)
                    .onSubmit { model.submit() }
                VStack(alignment: .leading, spacing: 4) {
                    Text("支持小宇宙、Apple 播客等播客平台的单集链接，以及节目的 RSS 地址。视频网站的链接暂不支持。")
                    Text(LinkImportModel.rightsNotice)
                    Text(LinkImportModel.privacyNotice)
                }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            stateView
            Divider()
            HStack {
                Spacer()
                Button(model.isBusy ? "取消" : "关闭", role: .cancel) {
                    model.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("导入") { model.submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSubmit)
            }
            .padding(16)
        }
        .frame(width: 520)
        .frame(minHeight: 260)
        .interactiveDismissDisabled(model.isBusy)
        .onAppear { fieldFocused = model.text.isEmpty }
        .onChange(of: model.phase) { _, phase in
            guard case .done(let id, let title) = phase else { return }
            imported(id, title)
            dismiss()
        }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder
    private var stateView: some View {
        switch model.phase {
        case .idle, .done:
            EmptyView()
        case .resolving:
            status { Text("正在读取链接…").foregroundStyle(.secondary) }
        case .choosing(let show, let episodes):
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                Text(show.isEmpty ? "选一期导入" : "\(show) · 选一期导入")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 20).padding(.vertical, 10)
                List(episodes) { episode in
                    Button { model.choose(episode) } label: {
                        EpisodeRow(episode: episode)
                    }
                    .buttonStyle(.plain)
                }
                .frame(minHeight: 240, idealHeight: 320)
            }
        case .downloading(let episode, _, _):
            VStack(alignment: .leading, spacing: 8) {
                Text(episode.title).font(.body.weight(.medium)).lineLimit(2)
                if let fraction = model.progressFraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(model.progressText.map { "正在下载 \($0)" } ?? "正在下载…")
                    .font(.callout).foregroundStyle(.secondary)
                Text("下载时请不要关掉这个窗口，取消或关闭会停止下载。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.bottom, 20)
        case .saving(let episode):
            status { Text("正在存入「\(episode.title)」…").foregroundStyle(.secondary).lineLimit(2) }
        case .failed(let message):
            HStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                Spacer()
                Button("重试") { model.submit() }.disabled(!model.canSubmit)
            }
            .padding(.horizontal, 20).padding(.bottom, 20)
        }
    }

    private func status<Content: View>(@ViewBuilder _ text: () -> Content) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            text()
        }
        .padding(.horizontal, 20).padding(.bottom, 20)
    }
}

/// One episode of a show: title, then date and length when the feed gives them.
private struct EpisodeRow: View {
    let episode: PodcastEpisode

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(episode.title).lineLimit(2)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help("导入这一期")
    }

    private var detail: String {
        var parts: [String] = []
        if let published = episode.published {
            parts.append(published.formatted(.dateTime.year().month().day()))
        }
        if let seconds = episode.durationSeconds, seconds > 0 {
            parts.append(seconds >= 3600 ? "\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分钟" : "\(max(1, seconds / 60)) 分钟")
        }
        return parts.joined(separator: " · ")
    }
}
