import AppModel
import LinkImport
import SwiftUI

/// 从链接导入 (features.md X12, product-spec.md P05 导入): paste a podcast episode link, a show's
/// RSS address or an audio link; a show lists its episodes to pick one. The download becomes a
/// recording with source 导入. Opened from the import menu on 录音.
struct LinkImportSheet: View {
    @State var model: LinkImportModel
    /// Called with the title once stored; the sheet then closes.
    let imported: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                linkSection
                stateSection
            }
            .listStyle(.insetGrouped)
            .paperBackground()
            // Reading → choosing → downloading → saving: each step replaces the last in place.
            // Keyed on the step, not on the bytes received, so the list is not re-animated on
            // every progress tick; the bar itself glides.
            .motion(Motion.standard, value: step)
            .navigationTitle("从链接导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.isBusy ? "取消" : "关闭") {
                        model.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        fieldFocused = false
                        model.submit()
                    }
                    .disabled(!model.canSubmit)
                }
            }
        }
        .tint(Theme.accent)
        .interactiveDismissDisabled(model.isBusy)
        .onAppear { fieldFocused = model.text.isEmpty }
        .onChange(of: model.phase) { _, phase in
            guard case .done(_, let title) = phase else { return }
            imported(title)
            dismiss()
        }
        .onDisappear { model.cancel() }
    }

    /// Which step the import is at, without its progress.
    private var step: Int {
        switch model.phase {
        case .idle: 0
        case .resolving: 1
        case .choosing: 2
        case .downloading: 3
        case .saving: 4
        case .done: 5
        case .failed: 6
        }
    }

    private var linkSection: some View {
        // Captured on its own: PasteButton may call back off the main thread, so its closure is
        // @Sendable and only touches the (main-actor) model through a hop to the main actor.
        let target = model
        return Section {
            TextField("粘贴播客单集链接、RSS 地址或音频地址", text: $model.text, axis: .vertical)
                .lineLimit(1...4)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .disabled(model.isBusy)
                .submitLabel(.go)
                .onSubmit { model.submit() }
            // PasteButton reads the clipboard only when tapped, so iOS shows no paste prompt.
            PasteButton(payloadType: String.self) { @Sendable strings in
                guard let text = strings.first else { return }
                Task { @MainActor in
                    target.text = text
                    target.submit()
                }
            }
            .disabled(model.isBusy)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("支持小宇宙、Apple 播客等播客平台的单集链接，以及节目的 RSS 地址。视频网站的链接暂不支持。")
                Text(LinkImportModel.rightsNotice)
                Text(LinkImportModel.privacyNotice)
            }
            .foregroundStyle(Theme.inkMuted)
        }
        .surfaceRows()
    }

    @ViewBuilder
    private var stateSection: some View {
        switch model.phase {
        case .idle, .done:
            EmptyView()
        case .resolving:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在读取链接…").foregroundStyle(Theme.inkMuted)
                }
            }
            .surfaceRows()
        case .choosing(let show, let episodes):
            Section {
                ForEach(episodes) { episode in
                    Button { model.choose(episode) } label: {
                        EpisodeRow(episode: episode)
                    }
                    .foregroundStyle(Theme.ink)
                }
            } header: {
                Text(show.isEmpty ? "选一期导入" : "\(show) · 选一期导入")
            }
            .surfaceRows()
        case .downloading(let episode, _, _):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(episode.title).font(.body.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(2)
                    if let fraction = model.progressFraction {
                        ProgressView(value: fraction)
                            .motion(Motion.standard, value: fraction)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(model.progressText.map { "正在下载 \($0)" } ?? "正在下载…")
                        .monospacedDigit()
                        .font(.footnote).foregroundStyle(Theme.inkMuted)
                }
                .accessibilityElement(children: .combine)
            } footer: {
                Text("下载时请留在这一页，取消或关闭会停止下载。").foregroundStyle(Theme.inkMuted)
            }
            .surfaceRows()
        case .saving(let episode):
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在存入「\(episode.title)」…").foregroundStyle(Theme.inkMuted).lineLimit(2)
                }
            }
            .surfaceRows()
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("重试") { model.submit() }
                    .disabled(!model.canSubmit)
            }
            .surfaceRows()
        }
    }
}

/// One episode of a show: title, then date and length when the feed gives them.
private struct EpisodeRow: View {
    let episode: PodcastEpisode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(episode.title).foregroundStyle(Theme.ink).lineLimit(2)
            if !detail.isEmpty {
                Text(detail).font(.footnote).foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(.vertical, 2)
        .accessibilityHint("导入这一期")
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
