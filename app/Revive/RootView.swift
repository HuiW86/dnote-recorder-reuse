import SwiftUI

/// First use until a card is paired, then the home screen (product-spec.md §2.1).
struct RootView: View {
    let env: AppEnvironment

    var body: some View {
        Group {
            if let error = env.libraryError {
                ContentUnavailableView {
                    Label("无法读取录音", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("本机录音库打不开，卡上的录音不受影响。请重启 App 后再试。")
                } actions: {
                    ShareLink(item: error) { Text("导出诊断信息") }
                }
            } else if env.hasPairedDevice {
                HomePlaceholderView(env: env)
            } else {
                OnboardingFlow(env: env)
            }
        }
        .debugEntry(env)
    }
}

/// Stand-in for P05 until batch 2 of #41.
struct HomePlaceholderView: View {
    let env: AppEnvironment

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("录音卡已配对", systemImage: "checkmark.circle")
            } description: {
                Text("首页在 #41 第 2 批实现")
            }
            .navigationTitle("全部录音")
        }
    }
}

extension View {
    /// DEBUG builds keep the #38/#40 card debug screen reachable, on the app's own Bluetooth stack.
    func debugEntry(_ env: AppEnvironment) -> some View {
        #if DEBUG
        modifier(DebugEntry(env: env))
        #else
        self
        #endif
    }
}

#if DEBUG
private struct DebugEntry: ViewModifier {
    let env: AppEnvironment
    @State private var model: CardDebugModel?
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                Button {
                    guard let session = env.startBluetooth() else { return }
                    model = model ?? CardDebugModel(session: session, log: env.debugLog)
                    showing = true
                } label: {
                    Image(systemName: "ladybug").padding(8)
                }
                .accessibilityLabel("调试")
                .padding(.trailing, 4)
            }
            .sheet(isPresented: $showing, onDismiss: { env.session?.autoSyncEnabled = true }) {
                if let model { CardDebugView(model: model) }
            }
            .onChange(of: showing) { _, shown in
                // Keep #38 evidence logs to the requests the debug screen sends.
                if shown { env.session?.autoSyncEnabled = false }
            }
    }
}
#endif
