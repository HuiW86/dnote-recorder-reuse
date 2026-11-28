import AppModel
import SwiftUI
import UIKit

/// Recording with the phone's microphone (features.md X18): same look as the card's recording
/// page, dark in both schemes. Stopping keeps the recording in the list.
struct PhoneRecordingStage: View {
    @Bindable var recorder: PhoneRecorder
    /// Hides the page; recording goes on and the record key shows the time (as on P13).
    let collapse: () -> Void
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let saving = recorder.isSaving
        let paused = recorder.state == .paused || saving
        ZStack {
            Theme.stage.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button(action: collapse) {
                        Image(systemName: "chevron.down")
                            .font(.headline)
                            .foregroundStyle(Theme.onDark.opacity(0.8))
                            .frame(width: 44, height: 44)
                            .background(Theme.onDark.opacity(0.1), in: Circle())
                    }
                    .accessibilityLabel("收起，录音继续")
                    .opacity(saving ? 0 : 1)
                    .disabled(saving)
                    Spacer()
                    HStack(spacing: 8) {
                        Circle()
                            .fill(paused ? Theme.onDark.opacity(0.4) : Theme.record)
                            .frame(width: 9, height: 9)
                            .accessibilityHidden(true)
                        Text(saving ? "正在保存 · 这部手机" : paused ? "已暂停 · 这部手机" : "录音中 · 这部手机")
                            .contentTransition(.opacity)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.onDark.opacity(0.9))
                    }
                    Spacer()
                    // Balances the collapse button so the title stays centred.
                    Color.clear.frame(width: 44, height: 44)
                }
                // Same place as on the card's recording page, so the collapse key does not shift.
                .padding(.horizontal, 12)
                .padding(.top, 8)
                Spacer(minLength: 16)
                Image(systemName: paused ? "pause.fill" : "mic.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(paused ? Theme.onDark.opacity(0.5) : Theme.record)
                    .symbolEffect(.pulse, isActive: !paused && !reduceMotion)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(RecordingText.clock(seconds: Int(recorder.elapsed)))
                        .font(.system(size: 76, weight: .thin, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .foregroundStyle(Theme.onDark.opacity(paused ? 0.5 : 1))
                }
                .padding(.top, 20)
                .padding(.horizontal, 24)
                // A call or another app paused the recording (X18); otherwise where it is kept.
                Text(saving ? "正在保存到这部手机，长录音要几秒钟"
                     : recorder.interruptionNotice ?? "用手机录音，停止后会保存在这部手机里")
                    .contentTransition(.opacity)
                    .font(.subheadline)
                    .foregroundStyle(Theme.onDark.opacity(recorder.interruptionNotice == nil ? 0.65 : 0.95))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
                Spacer(minLength: 16)
                HStack(spacing: 36) {
                    if !saving { markControl(disabled: paused).motionTransition(.fade) }
                    if saving {
                        // Converting to M4A; a long recording takes a few seconds (X18). The keys
                        // fade out around it, so the spinner reads as what 停止 started.
                        ProgressView().tint(Theme.onDark).controlSize(.large).frame(height: 66)
                            .motionTransition(.fade)
                    } else {
                        // One key that turns from 暂停 into 继续, so its icon morphs in place.
                        control(paused ? "继续" : "暂停", symbol: paused ? "play.fill" : "pause.fill", filled: false) {
                            if paused { recorder.resume() } else { recorder.pause() }
                        }
                        .motionTransition(.fade)
                    }
                    if !saving {
                        control("停止", symbol: "stop.fill", filled: true) {
                            // The page closes once stored (below).
                            Task { await recorder.stop() }
                        }
                        .motionTransition(.fade)
                    }
                }
                .padding(.bottom, 32)
            }
        }
        // Pausing, an interruption and saving each dim or swap the page in one move.
        .motion(Motion.standard, value: paused)
        .motion(Motion.standard, value: saving)
        .motion(Motion.standard, value: recorder.interruptionNotice)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        // Stored, after 停止 or after running out of space: close, so the tabs show the toast.
        .onChange(of: recorder.isSaving) { wasSaving, saving in
            if wasSaving, !saving, recorder.state == .idle { close() }
        }
        .onChange(of: recorder.interruptionNotice) { _, notice in
            if let notice { UIAccessibility.post(notification: .announcement, argument: notice) }
        }
    }

    /// "标重点", with the number of marks so far, as on the card's recording page (features.md X7).
    private func markControl(disabled: Bool) -> some View {
        let count = recorder.marksMs.count
        let title = count == 0 ? "标重点" : "标重点 · \(count)"
        return Button { recorder.markNow() } label: {
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

    private func control(_ title: String, symbol: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(filled ? Theme.record : Theme.onDark.opacity(0.14))
                    Image(systemName: symbol).font(.title2).foregroundStyle(Theme.onDark)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 66, height: 66)
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(Theme.onDark.opacity(0.8))
                    .contentTransition(.opacity)
            }
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(title)
    }
}
