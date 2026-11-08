import Foundation
import Observation

/// Bluetooth permission as the system reports it, before any CoreBluetooth manager exists.
public enum BluetoothAuthorization: Equatable, Sendable {
    case notDetermined, allowed, denied
}

/// P01 welcome and permission (product-spec.md §3.1, §4.2). The permission prompt is only
/// triggered by "继续", after the page has said what Bluetooth is for: creating the
/// Bluetooth stack is what makes iOS ask.
@MainActor
@Observable
public final class OnboardingModel {
    public enum Phase: Equatable, Sendable {
        case intro
        /// The system prompt is up.
        case requesting
        /// Permission refused: ErrorState with "去设置".
        case denied
        /// Allowed: go on to P02.
        case proceed
    }

    public private(set) var phase: Phase = .intro

    private let authorization: () -> BluetoothAuthorization
    private let startBluetooth: () -> CardSession?
    @ObservationIgnored private var listener: (session: CardSession, token: UUID)?
    @ObservationIgnored private var poll: Task<Void, Never>?

    /// - Parameters:
    ///   - authorization: current permission, read again on every check.
    ///   - startBluetooth: creates (once) and returns the app's session; nil if it could not be built.
    public init(authorization: @escaping () -> BluetoothAuthorization,
                startBluetooth: @escaping () -> CardSession?) {
        self.authorization = authorization
        self.startBluetooth = startBluetooth
    }

    /// "继续".
    public func continueTapped() {
        switch authorization() {
        case .allowed:
            _ = startBluetooth()
            finish(.proceed)
        case .denied:
            phase = .denied
        case .notDetermined:
            phase = .requesting
            guard let session = startBluetooth() else { return }
            // CoreBluetooth reports its first state once the user has answered the prompt.
            let token = session.addListener { [weak self] event in
                if case .stateChanged = event { self?.refresh() }
                if case .disconnected = event { self?.refresh() }
            }
            listener = (session, token)
            // With Bluetooth on, the first report after "允许" may not change the link state
            // (it starts as idle), so also poll the permission while the prompt is up.
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let self, self.phase == .requesting else { return }
                    self.refresh()
                }
            }
            refresh()
        }
    }

    /// Re-checks the permission; also called when the app returns from Settings.
    public func refresh() {
        guard phase == .requesting || phase == .denied else { return }
        switch authorization() {
        case .allowed:
            _ = startBluetooth()
            finish(.proceed)
        case .denied: phase = .denied
        case .notDetermined: break
        }
    }

    private func finish(_ next: Phase) {
        if let listener { listener.session.removeListener(listener.token) }
        listener = nil
        poll?.cancel()
        poll = nil
        phase = next
    }
}
