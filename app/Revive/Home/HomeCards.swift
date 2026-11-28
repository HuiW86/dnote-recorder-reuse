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
                            // Only the dot's colour moves: the chip sits in the toolbar, where a
                            // width animation would jitter.
                            .motion(Motion.standard, value: isConnected)
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
            // With no card the words "添加录音卡" lead to the 录音卡 tab and its add button.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            // Nothing to switch between without a card; the words already add one.
            if device != nil {
                Button(action: openSwitcher) {
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(Theme.inkMuted)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("切换录音卡")
            } else {
                Spacer().frame(width: 12)
            }
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
            // design-spec.md §3 设备条: "已连接 · 电量" in words (#85).
            HStack(spacing: 0) {
                Text("已连接").foregroundStyle(Theme.inkMuted)
                if let battery {
                    Text(" · ").foregroundStyle(Theme.inkMuted)
                    Text("\(battery)%")
                        .monospacedDigit()
                        .motionNumber(Double(battery))
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
                .motionSymbolReplace()
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
        .motion(Motion.standard, value: paused)
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
                // The card leaves by itself after 10 s; this says what that means.
                Text("不选就留着。不要的话，同步到手机后会移到「最近删除」，并从录音卡上删除")
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
                        .contentTransition(.opacity)
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
                        .motionNumber(fraction)
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
        // design-spec.md §3 同步状态: a card only while a pass runs; otherwise a line (#85).
        .padding(.horizontal, expanded ? 12 : 4)
        .padding(.vertical, expanded ? 12 : 0)
        .background {
            if expanded {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.line))
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

    /// The spinner gives way to the outcome: the check (or the warning) grows where it spun.
    @ViewBuilder private var icon: some View {
        Group {
            switch card {
            case .checking, .syncing:
                ProgressView().motionTransition(.fade)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok).motionTransition(.pop)
            case .waitingForRecording:
                Image(systemName: "clock").foregroundStyle(Theme.inkMuted).motionTransition(.fade)
            case .disconnected:
                Image(systemName: "bolt.horizontal.circle").foregroundStyle(Theme.inkMuted).motionTransition(.fade)
            default:
                // A sync problem is a warning: system orange, not the brand red (design-spec.md §2.1).
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).motionTransition(.pop)
            }
        }
        .frame(minWidth: 20)
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
                withMotion(Motion.tap) { agreed.toggle() }
            } label: {
                Label("我已征得对方同意", systemImage: agreed ? "checkmark.square.fill" : "square")
                    .motionSymbolReplace()
            }
            .foregroundStyle(Theme.ink)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
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
