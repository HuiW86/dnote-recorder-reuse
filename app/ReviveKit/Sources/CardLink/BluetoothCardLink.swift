import CardProtocol
@preconcurrency import CoreBluetooth
import Foundation

/// CoreBluetooth implementation of `CardLink`, ported from ios-prototype/Sources/Probe.swift.
///
/// Requires the `bluetooth-central` background mode. With a restore identifier, iOS
/// relaunches the app for a pending connect or a notification after it was terminated
/// in the background; restored or already-connected peripherals are adopted, because a
/// connected card stops advertising and could not be found by scanning.
@MainActor
public final class BluetoothCardLink: NSObject, CardLink {
    public private(set) var state: LinkState = .idle {
        didSet { if state != oldValue { continuation.yield(.state(state)) } }
    }
    public private(set) var peripheralId: UUID?
    public let events: AsyncStream<LinkEvent>

    private let continuation: AsyncStream<LinkEvent>.Continuation
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var discovered: [UUID: CBPeripheral] = [:]
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var connectAttempt = 0
    private var pendingWrites: [CheckedContinuation<Void, Error>] = []
    private var disconnectRequested = false
    /// Peripheral handed over by state restoration; adopted once Bluetooth is powered on,
    /// because CoreBluetooth ignores commands issued before that.
    private var restoredPeripheral: CBPeripheral?

    private static let service = CBUUID(string: CardGATT.service)
    private static let writeUUID = CBUUID(string: CardGATT.writeCharacteristic)
    private static let notifyUUID = CBUUID(string: CardGATT.notifyCharacteristic)

    public init(restoreIdentifier: String = "revive.central") {
        (events, continuation) = AsyncStream.makeStream(of: LinkEvent.self)
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier,
        ])
    }

    // MARK: - CardLink

    public func startScan() {
        guard central.state == .poweredOn else { return }
        // No service filter: the card advertises only manufacturer data (PROTOCOL.md §2.2).
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        central.stopScan()
    }

    public func connect(_ id: UUID) async throws {
        try checkPoweredOn()
        let p = try knownPeripheral(id)
        stopScan()
        failConnectWaiter(LinkError.connectFailed)
        connectAttempt += 1
        let attempt = connectAttempt
        begin(p)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connectWaiter = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: CardLinkTiming.connectTimeout)
                guard let self, self.connectAttempt == attempt, self.connectWaiter != nil else { return }
                // A timeout is final: mark it requested so the cancel does not register a pending connect.
                self.disconnectRequested = true
                self.central.cancelPeripheralConnection(p)
                self.failConnectWaiter(LinkError.connectTimeout)
                if self.state == .connecting { self.state = .disconnected(.requested) }
            }
        }
    }

    public func connectWhenSeen(_ id: UUID) throws {
        try checkPoweredOn()
        begin(try knownPeripheral(id))
    }

    public func disconnect() {
        disconnectRequested = true
        failConnectWaiter(LinkError.connectFailed)
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        // A pending connect never calls back, so settle the state here.
        if state == .connecting { state = .disconnected(.requested) }
    }

    public func send(_ request: CardRequest) async throws {
        let frame = try request.encode()
        guard state == .connected, let p = peripheral, let ch = writeCharacteristic else {
            throw LinkError.notConnected
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            // CoreBluetooth confirms writes in order, so a FIFO is enough.
            pendingWrites.append(c)
            p.writeValue(frame, for: ch, type: .withResponse)
        }
    }

    // MARK: - Internals

    private func checkPoweredOn() throws {
        switch central.state {
        case .poweredOn: return
        case .unauthorized: throw LinkError.bluetoothUnauthorized
        case .poweredOff: throw LinkError.bluetoothOff
        default: throw LinkError.bluetoothUnsupported
        }
    }

    private func knownPeripheral(_ id: UUID) throws -> CBPeripheral {
        if let p = discovered[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first { return p }
        throw LinkError.unknownPeripheral
    }

    private func begin(_ p: CBPeripheral) {
        // Only one card at a time: drop the previous one so its callbacks cannot touch this link.
        if let old = peripheral, old.identifier != p.identifier {
            old.delegate = nil
            central.cancelPeripheralConnection(old)
            writeCharacteristic = nil
        }
        disconnectRequested = false
        peripheral = p
        peripheralId = p.identifier
        p.delegate = self
        state = .connecting
        // No timeout on the system side: a connect stays pending until the card advertises.
        central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    /// Takes over a peripheral iOS already holds (state restoration or a previous run).
    private func adopt(_ p: CBPeripheral) {
        peripheral = p
        peripheralId = p.identifier
        p.delegate = self
        switch p.state {
        case .connected:
            state = .connecting
            p.discoverServices([Self.service])
        case .connecting:
            state = .connecting
        default:
            // Restored without a live connection: register the pending connect again.
            begin(p)
        }
    }

    /// GATT setup failed on a connected card. Treated as final, like a timeout, so a card
    /// with a broken GATT table does not loop through reconnects; CardService may retry.
    private func setupFailed(_ p: CBPeripheral) {
        disconnectRequested = true
        failConnectWaiter(LinkError.connectFailed)
        central.cancelPeripheralConnection(p)
    }

    /// Callbacks for a peripheral other than the current one (e.g. after switching cards) are ignored.
    private func isCurrent(_ p: CBPeripheral) -> Bool {
        p.identifier == peripheral?.identifier
    }

    private func failConnectWaiter(_ error: Error) {
        connectWaiter?.resume(throwing: error)
        connectWaiter = nil
    }

    private func linkDropped() {
        writeCharacteristic = nil
        let writes = pendingWrites
        pendingWrites = []
        writes.forEach { $0.resume(throwing: LinkError.notConnected) }
        failConnectWaiter(LinkError.connectFailed)
        if disconnectRequested || peripheral == nil {
            state = .disconnected(.requested)
            return
        }
        state = .disconnected(.lost)
        // iOS cannot find the card by background scanning, so reconnect via a pending connect.
        if let p = peripheral, central.state == .poweredOn {
            p.delegate = self
            central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
            state = .connecting
        }
    }

    private static func linkState(_ s: CBManagerState) -> LinkState? {
        switch s {
        case .poweredOff: .poweredOff
        case .unauthorized: .unauthorized
        case .unsupported, .resetting, .unknown: .unsupported
        case .poweredOn: nil
        @unknown default: .unsupported
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothCardLink: CBCentralManagerDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if let s = Self.linkState(central.state) {
                writeCharacteristic = nil
                let writes = pendingWrites
                pendingWrites = []
                writes.forEach { $0.resume(throwing: LinkError.notConnected) }
                failConnectWaiter(s == .poweredOff ? LinkError.bluetoothOff : LinkError.connectFailed)
                state = s
                return
            }
            if let p = restoredPeripheral {
                restoredPeripheral = nil
                adopt(p)
            } else if !disconnectRequested,
                      let p = central.retrieveConnectedPeripherals(withServices: [Self.service])
                          .first(where: { $0.state == .connected && (peripheral == nil || isCurrent($0)) }) {
                // A connection iOS kept stops the card advertising; adopt it instead of scanning.
                adopt(p)
            } else if let p = peripheral, !disconnectRequested {
                // Bluetooth was toggled: the system dropped our pending connect, so register it again.
                begin(p)
            } else {
                state = .idle
            }
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Delegate callbacks arrive on the main queue (see init), so this never crosses threads.
        nonisolated(unsafe) let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first
        MainActor.assumeIsolated {
            if let p = restored {
                restoredPeripheral = p
                peripheral = p
                peripheralId = p.identifier
                p.delegate = self
            }
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                                           advertisementData ad: [String: Any], rssi: NSNumber) {
        let md = ad[CBAdvertisementDataManufacturerDataKey] as? Data
        MainActor.assumeIsolated {
            guard let md, let adv = Advertisement(manufacturerData: md) else { return }
            discovered[p.identifier] = p
            continuation.yield(.discovered(DiscoveredCard(id: p.identifier, name: p.name, advertisement: adv,
                                                          rssi: rssi.intValue)))
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated {
            guard isCurrent(p) else { return }
            p.delegate = self
            p.discoverServices([Self.service])
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard isCurrent(p) else { return }
            linkDropped()
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral,
                                           error: Error?) {
        MainActor.assumeIsolated {
            guard isCurrent(p) else { return }
            linkDropped()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothCardLink: CBPeripheralDelegate {
    nonisolated public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard isCurrent(p) else { return }
            guard error == nil, let s = p.services?.first(where: { $0.uuid == Self.service }) else {
                setupFailed(p)
                return
            }
            p.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: s)
        }
    }

    nonisolated public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard isCurrent(p) else { return }
            let chars = s.characteristics ?? []
            guard error == nil,
                  let write = chars.first(where: { $0.uuid == Self.writeUUID }),
                  let notify = chars.first(where: { $0.uuid == Self.notifyUUID }) else {
                setupFailed(p)
                return
            }
            writeCharacteristic = write
            p.setNotifyValue(true, for: notify)
        }
    }

    nonisolated public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic,
                                       error: Error?) {
        MainActor.assumeIsolated {
            guard isCurrent(p), ch.uuid == Self.notifyUUID else { return }
            guard error == nil, ch.isNotifying, writeCharacteristic != nil else {
                setupFailed(p)
                return
            }
            state = .connected
            connectWaiter?.resume()
            connectWaiter = nil
        }
    }

    nonisolated public func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard isCurrent(p), !pendingWrites.isEmpty else { return }
            let w = pendingWrites.removeFirst()
            if error != nil { w.resume(throwing: LinkError.writeFailed) } else { w.resume() }
        }
    }

    nonisolated public func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard isCurrent(p), ch.uuid == Self.notifyUUID, let data = ch.value else { return }
            continuation.yield(.notification(data))
        }
    }
}
