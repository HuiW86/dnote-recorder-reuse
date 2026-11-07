import AppModel
import SwiftUI

/// First use: P01 → P02 → P03 in one stack (product-spec.md §2.1, §3.1).
struct OnboardingFlow: View {
    enum Route: Hashable {
        case connectGuide, pairing, privacy, permissions
    }

    let env: AppEnvironment
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView(env: env, path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .connectGuide: ConnectGuideView { path.append(.pairing) }
                    case .pairing: PairingView(env: env) { env.refreshDevices() }
                    case .privacy: PrivacyView()
                    case .permissions: PermissionsView()
                    }
                }
        }
    }
}
