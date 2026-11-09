import SwiftUI

/// P02 connect guide (product-spec.md §4.2). Official app instruction, with "press" made
/// "press and hold": a short press does not wake a card that has powered off
/// (evidence/v38-card-link 03c). The card drawing is our own line art, not the product photo.
struct ConnectGuideView: View {
    let onContinue: () -> Void

    var body: some View {
        ScrollingPage {
            VStack(spacing: 32) {
                CardSketch()
                    .frame(width: 140, height: 200)
                    .accessibilityHidden(true)
                Text("把录音卡靠近手机，按住**录音键**，等**白灯闪烁**后松手")
                    .font(.title3)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 24)
        } footer: {
            Button(action: onContinue) {
                Text("继续").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .navigationTitle("唤醒录音卡")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Outline of a card with its record button and a blinking white light.
private struct CardSketch: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.primary, lineWidth: 2)
            VStack(spacing: 16) {
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(.secondary, lineWidth: 1))
                    .frame(width: 10, height: 10)
                    .shadow(color: .white, radius: lit ? 6 : 0)
                    .opacity(lit ? 1 : 0.25)
                Circle()
                    .stroke(.tint, lineWidth: 3)
                    .frame(width: 44, height: 44)
                    .overlay(Circle().fill(.tint.opacity(0.25)).padding(8))
                Text("录音键")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { lit = false }
        }
    }
}
