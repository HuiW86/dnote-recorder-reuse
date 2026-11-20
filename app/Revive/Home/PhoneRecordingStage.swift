import AppModel
import SwiftUI
import UIKit

/// Recording with the phone's microphone (features.md X18): same look as the card's recording
/// page, dark in both schemes. Stopping keeps the recording in the list.
struct PhoneRecordingStage: View {
    @Bindable var recorder: PhoneRecorder
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let paused = recorder.state == .paused
        ZStack {
            Theme.stage.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(paused ? Theme.onDark.opacity(0.4) : Theme.record)
                        .frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                    Text(paused ? "已暂停 · 这部手机" : "录音中 · 这部手机")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.onDark.opacity(0.9))
                }
                .padding(.top, 20)
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
                Text(recorder.interruptionNotice ?? "用手机的麦克风录音，录音只保存在这部手机上")
                    .font(.subheadline)
                    .foregroundStyle(Theme.onDark.opacity(recorder.interruptionNotice == nil ? 0.65 : 0.95))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
                Spacer(minLength: 16)
                HStack(spacing: 48) {
                    if paused {
                        control("继续", symbol: "play.fill", filled: false) { recorder.resume() }
                    } else {
                        control("暂停", symbol: "pause.fill", filled: false) { recorder.pause() }
                    }
                    control("停止", symbol: "stop.fill", filled: true) {
                        recorder.stop()
                        close()
                    }
                }
                .padding(.bottom, 32)
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .onChange(of: recorder.interruptionNotice) { _, notice in
            if let notice { UIAccessibility.post(notification: .announcement, argument: notice) }
        }
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
