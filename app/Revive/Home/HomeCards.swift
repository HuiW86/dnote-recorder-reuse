import AppModel
import Library
import SwiftUI

// Home screen components (product-spec.md §0.2, P05, P04).

/// Card name and connection state at the top left: the name opens P07, the chevron P08
/// (product-spec.md §2.1, P05).
struct DeviceChip: View {
    let device: Device?
    let status: DeviceStatus
    let battery: Int?
    let openDevice: () -> Void
    let openSwitcher: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: openDevice) {
                HStack(spacing: 6) {
                    if device != nil {
                        Circle()
                            .fill(isConnected ? Theme.ok : Theme.inkMuted)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "rectangle.portrait")
                            .imageScale(.small)
                    }
                    if let device {
                        Text(device.name).lineLimit(1)
                        trailing
                    } else {
                        Text("添加录音卡")
                    }
                }
                .foregroundStyle(Theme.ink)
                // 44 pt tall to tap; the drawn chip below is shorter.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .disabled(device == nil)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            Button(action: openSwitcher) {
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(Theme.inkMuted)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("切换录音卡")
        }
        .buttonStyle(.plain)
        .font(.subheadline.weight(.medium))
        // The toolbar offers too little width and the name collapses to nothing.
        .fixedSize()
        .padding(.leading, 12)
        // design-spec.md §3 设备条: surface card with a hairline, inset so the tap area stays 44 pt.
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.line, lineWidth: 1))
                .padding(.vertical, 5)
        }
    }

    private var isConnected: Bool {
        switch status {
        case .idle, .recording, .paused: true
        default: false
        }
    }

    @ViewBuilder private var trailing: some View {
        switch status {
        case .connecting:
            ProgressView().controlSize(.mini)
        case .idle, .recording, .paused:
            // design-spec.md §3 设备条: "已连接 · 电量" in words.
            HStack(spacing: 0) {
                Text("已连接").foregroundStyle(Theme.inkMuted)
                if let battery {
                    Text(" · ").foregroundStyle(Theme.inkMuted)
                    Text("\(battery)%")
                        .monospacedDigit()
                        // Low battery keeps the system warning red (design-spec.md §2.1).
                        .foregroundStyle(battery <= 20 ? Color.red : Theme.inkMuted)
                }
            }
            .font(.footnote)
        default:
            Text("未连接").foregroundStyle(Theme.inkMuted)
        }
    }

    private var accessibilityText: String {
        guard let device else { return "添加录音卡" }
        switch status {
        case .connecting: return "\(device.name)，正在连接"
        case .idle, .recording, .paused: return battery.map { "\(device.name)，电量 \($0)%" } ?? device.name
        default: return "\(device.name)，未连接"
        }
    }
}

/// Recording or paused, with the recorded time (product-spec.md P05 RecordingStatusCard).
struct RecordingStatusCard: View {
    let model: HomeModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let paused = model.status == .paused
        HStack(spacing: 12) {
            Image(systemName: paused ? "pause.circle.fill" : "waveform")
                .font(.title2)
                .foregroundStyle(paused ? Theme.inkMuted : Theme.record)
                .symbolEffect(.variableColor.iterative, isActive: !paused && !reduceMotion)
            VStack(alignment: .leading, spacing: 2) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let layout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 8))
                    layout {
                        Text(paused ? "已暂停" : "录音中").font(.headline)
                        // Before the card has reported recd, show the state only.
                        if let seconds = model.recordedSeconds(at: context.date) {
                            Text(RecordingText.clock(seconds: seconds))
                                .font(.headline.monospacedDigit())
                        }
                    }
                }
                if let start = model.recordingStartedAt {
                    Text("开始于 \(RecordingText.time(start))")
                        .font(.caption)
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            Spacer()
        }
        .padding(12)
        .foregroundStyle(Theme.ink)
        .background(paused ? Theme.surface : Theme.accentWash, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.line))
        .accessibilityElement(children: .combine)
    }
}

/// "留着 / 不要" for the recording that just ended (features.md X10). Not answering keeps it.
struct KeepOrDiscardCard: View {
    let finished: FinishedRecording
    let keep: () -> Void
    let discard: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let buttons = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text("不要的话，同步到手机后会移到「最近删除」，并从录音卡上删除")
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
            buttons {
                Button(action: keep) {
                    Text("留着").frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                Button(action: discard) {
                    Text("不要").frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.line))
    }

    private var title: String {
        guard let ms = finished.recordedMs else { return "刚录完一条" }
        return "刚录完一条 · \(RecordingText.clock(seconds: ms / 1000))"
    }
}

/// Sync state (product-spec.md P05 SyncStatusCard).
struct SyncStatusCard: View {
    let card: SyncCard
    let diagnostics: DiagnosticLog?
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).font(expanded ? Font.subheadline.weight(.medium) : Font.footnote)
                    if case .done(let at) = card {
                        Text(RecordingText.dateTime(at))
                            .font(.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
                Spacer()
                if case .syncing(_, _, let fraction) = card {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.inkMuted)
                }
                switch card.action {
                case .retry?:
                    Button("立即重试", action: retry).font(.subheadline)
                case .exportDiagnostics?:
                    if let diagnostics {
                        DiagnosticShareLink(log: diagnostics).font(.subheadline)
                    }
                case nil:
                    EmptyView()
                }
            }
            if case .syncing(_, _, let fraction) = card {
                ProgressView(value: fraction)
            }
            if let detail = card.detail {
                Text(detail).font(.caption).foregroundStyle(Theme.inkMuted)
            }
        }
        // design-spec.md §3 同步状态: a card only while a pass runs; otherwise a line under the title.
        .padding(.horizontal, expanded ? 12 : 4)
        .padding(.vertical, expanded ? 12 : 0)
        .background {
            if expanded {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                    RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.line)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var expanded: Bool {
        switch card {
        case .checking, .syncing: true
        default: false
        }
    }

    @ViewBuilder private var icon: some View {
        switch card {
        case .checking, .syncing:
            ProgressView()
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
        case .waitingForRecording:
            Image(systemName: "clock").foregroundStyle(Theme.inkMuted)
        case .disconnected:
            Image(systemName: "bolt.horizontal.circle").foregroundStyle(Theme.inkMuted)
        default:
            // A sync problem is a warning: system orange, not the brand red (design-spec.md §2.1).
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

/// Bottom recording controls (product-spec.md P05 RecordControlBar).
struct RecordControlBar: View {
    let model: HomeModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if model.status == .recording || model.status == .paused {
            controls
        } else {
            floatingStart
        }
    }

    /// Pause / resume and stop, while a recording runs (also on the recording page).
    private var controls: some View {
        // Accessibility text sizes stack the two buttons; side by side their titles wrap per character (#49).
        let buttons = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        return buttons {
            if model.status == .paused {
                button("继续", symbol: "play.fill", command: .resume) { model.resume() }
            } else {
                button("暂停", symbol: "pause.fill", command: .pause) { model.pause() }
            }
            button("停止", symbol: "stop.fill", command: .stop, tint: Theme.record) { model.stopRecording() }
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    /// The round record button floating at the bottom right (design-spec.md §3), with the
    /// connection hint beside it.
    private var floatingStart: some View {
        let enabled = model.status == .idle && model.pendingCommand == nil
        let busy = model.pendingCommand == .start || model.status == .connecting
        return HStack(alignment: .center, spacing: 12) {
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.line))
            }
            Spacer(minLength: 0)
            Button { model.startTapped() } label: {
                ZStack {
                    Circle().fill(enabled ? Theme.record : Theme.inkMuted.opacity(0.35))
                    if busy {
                        ProgressView().tint(Theme.onDark)
                    } else {
                        Circle().fill(Theme.onDark).frame(width: 22, height: 22)
                    }
                }
                .frame(width: 64, height: 64)
                .shadow(color: Theme.record.opacity(enabled ? 0.28 : 0), radius: 8, y: 6)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityLabel("开始录音")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var hint: String? {
        switch model.status {
        case .waiting: "按住卡上的录音键，白灯闪烁后松手"
        case .connecting: "正在连接录音卡…"
        default: nil
        }
    }

    private func button(_ title: String, symbol: String, command: HomeModel.Command, tint: Color = Theme.accent,
                        enabled: Bool = true, action: @escaping () -> Void) -> some View {
        let running = model.pendingCommand == command
        return Button(action: action) {
            HStack(spacing: 6) {
                if running || (command == .start && model.status == .connecting) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                }
                Text(title)
            }
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .disabled(!enabled || model.pendingCommand != nil)
    }
}

/// P04: asked once before the first recording started from the app (product-spec.md P04).
struct ConsentSheet: View {
    let onStart: () -> Void
    @State private var agreed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("录音前请确认").font(.title2.bold()).foregroundStyle(Theme.ink)
            Text("请先征得对方同意再开始录音，并避免录制敏感信息。")
                .foregroundStyle(Theme.inkMuted)
            Button {
                agreed.toggle()
            } label: {
                Label("我已征得对方同意", systemImage: agreed ? "checkmark.square.fill" : "square")
            }
            .foregroundStyle(Theme.ink)
            .accessibilityAddTraits(agreed ? .isSelected : [])
            Spacer()
            Button(action: onStart) {
                Text("开始录音").frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!agreed)
            Button("取消") { dismiss() }
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .tint(Theme.accent)
        .paperPage()
        .presentationDetents([.medium])
    }
}
