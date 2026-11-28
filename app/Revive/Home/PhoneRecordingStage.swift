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
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.onDark.opacity(0.9))
                    }
                    Spacer()
                    // Balances the collapse button so the title stays centred.
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                Spacer(minLength: 16)
                Image(systemName: paused ? "pause.fill" : "mic.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(paused ? Theme.onDark.opacity(0.5) : Theme.record)
                    .symbolEffect(.pulse, isActive: !paused && !reduceMotion)
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
                Text(recorder.interruptionNotice ?? "用手机录音，停止后会保存在这部手机里")
                    .font(.subheadline)
                    .foregroundStyle(Theme.onDark.opacity(recorder.interruptionNotice == nil ? 0.65 : 0.95))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
                Spacer(minLength: 16)
                HStack(spacing: 36) {
                    if !saving { markControl(disabled: paused) }
                    if saving {
                        // Converting to M4A; a long recording takes a few seconds (X18).
                        ProgressView().tint(Theme.onDark).controlSize(.large).frame(height: 66)
                    } else if paused {
                        control("继续", symbol: "play.fill", filled: false) { recorder.resume() }
                    } else {
                        control("暂停", symbol: "pause.fill", filled: false) { recorder.pause() }
                    }
                    if !saving {
                        control("停止", symbol: "stop.fill", filled: true) {
                            // The page closes once stored (below).
                            Task { await recorder.stop() }
                        }
                    }
                }
                .padding(.bottom, 32)
            }
        }
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
                    Image(systemName: "bookmark.fill").font(.title2).foregroundStyle(Theme.onDark)
                }
                .frame(width: 66, height: 66)
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(Theme.onDark.opacity(0.8))
            }
        }
        .buttonStyle(.plain)
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
                }
                .frame(width: 66, height: 66)
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(Theme.onDark.opacity(0.8))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
