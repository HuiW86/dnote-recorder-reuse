import AppModel
import SwiftUI

/// Full-screen recording page (design-spec.md §3): state, recorded time and the two controls.
/// Dark in both colour schemes. Closing it leaves the recording running; the home screen keeps
/// its own status card and controls.
struct RecordingStage: View {
    @Bindable var model: HomeModel
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let paused = model.status == .paused
        ZStack {
            Theme.stage.ignoresSafeArea()
            VStack(spacing: 0) {
                header(paused: paused)
                Spacer(minLength: 16)
                Image(systemName: paused ? "pause.fill" : "waveform")
                    .font(.system(size: 44))
                    .foregroundStyle(paused ? Theme.onDark.opacity(0.5) : Theme.record)
                    .symbolEffect(.variableColor.iterative, isActive: !paused && !reduceMotion)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(clock(at: context.date))
                        .font(.system(size: 76, weight: .thin, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .foregroundStyle(Theme.onDark.opacity(paused ? 0.5 : 1))
                }
                .padding(.top, 20)
                .padding(.horizontal, 24)
                Text("录音结束后自动同步到手机；存好之前，卡上的录音不会被删除")
                    .font(.subheadline)
                    .foregroundStyle(Theme.onDark.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
                Spacer(minLength: 16)
                HStack(spacing: 36) {
                    markControl(disabled: paused)
                    // One key that turns from 暂停 into 继续, so its icon morphs in place.
                    control(paused ? "继续" : "暂停", symbol: paused ? "play.fill" : "pause.fill",
                            command: paused ? .resume : .pause, filled: false) {
                        if paused { model.resume() } else { model.pause() }
                    }
                    control("停止", symbol: "stop.fill", command: .stop, filled: true) { model.stopRecording() }
                }
                .padding(.bottom, 32)
            }
        }
        // Pausing dims the page and swaps its icons together, in one move.
        .motion(Motion.standard, value: paused)
        .motion(Motion.tap, value: model.pendingCommand)
        .toast($model.toast)
        .preferredColorScheme(.dark)
    }

    private func header(paused: Bool) -> some View {
        HStack {
            Button(action: close) {
                Image(systemName: "chevron.down")
                    .font(.headline)
                    .foregroundStyle(Theme.onDark.opacity(0.8))
                    .frame(width: 44, height: 44)
                    .background(Theme.onDark.opacity(0.1), in: Circle())
            }
            .accessibilityLabel("收起，录音继续")
            Spacer()
            HStack(spacing: 8) {
                Circle()
                    .fill(paused ? Theme.onDark.opacity(0.4) : Theme.record)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                Text(title(paused: paused))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.onDark.opacity(0.9))
                    .lineLimit(1)
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func title(paused: Bool) -> String {
        let state = paused ? "已暂停" : "录音中"
        guard let name = model.currentDevice?.name, !name.isEmpty else { return state }
        return "\(state) · \(name)"
    }

    /// "00:12:48"; "--:--:--" until the card has reported the recorded time.
    private func clock(at date: Date) -> String {
        model.recordedSeconds(at: date).map { RecordingText.clock(seconds: $0) } ?? "--:--:--"
    }

    /// "标重点", with the number of marks set so far (features.md X7).
    private func markControl(disabled: Bool) -> some View {
        let count = model.markCount
        let title = count == 0 ? "标重点" : "标重点 · \(count)"
        return Button { model.markNow() } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(Theme.onDark.opacity(0.14))
                    // Each mark set nods the bookmark once: the tap was taken.
                    Image(systemName: "bookmark.fill").font(.title2).foregroundStyle(Theme.onDark)
                        .symbolEffect(.bounce, value: count)
                }
                .frame(width: 66, height: 66)
                Text(title)
                    .font(.footnote)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(count)))
                    .foregroundStyle(Theme.onDark.opacity(0.8))
            }
        }
        .buttonStyle(.pressable)
        .motion(Motion.tap, value: count)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .sensoryFeedback(.impact, trigger: count)
        .accessibilityLabel(count == 0 ? "标重点" : "标重点，已标 \(count) 处")
    }

    private func control(_ title: String, symbol: String, command: HomeModel.Command, filled: Bool,
                         action: @escaping () -> Void) -> some View {
        let running = model.pendingCommand == command
        return Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(filled ? Theme.record : Theme.onDark.opacity(0.14))
                    if running {
                        ProgressView().tint(Theme.onDark)
                            .motionTransition(.fade)
                    } else {
                        Image(systemName: symbol).font(.title2).foregroundStyle(Theme.onDark)
                            .contentTransition(.symbolEffect(.replace))
                            .motionTransition(.fade)
                    }
                }
                .frame(width: 66, height: 66)
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(Theme.onDark.opacity(0.8))
                    .contentTransition(.opacity)
            }
        }
        .buttonStyle(.pressable)
        .disabled(model.pendingCommand != nil)
        .accessibilityLabel(title)
    }
}
