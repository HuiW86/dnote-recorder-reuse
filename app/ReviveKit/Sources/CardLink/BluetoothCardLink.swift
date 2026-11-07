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
                self.central.cancelPeripheralConnection(p)
                self.failConnectWaiter(LinkError.connectTimeout)
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
            break
        }
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
            if case .connecting = state { return }
            // A connection iOS kept stops the card advertising; adopt it instead of scanning.
            if let p = central.retrieveConnectedPeripherals(withServices: [Self.service]).first(where: { $0.state == .connected }) {
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
            if let p = restored { adopt(p) }
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
            p.delegate = self
            p.discoverServices([Self.service])
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { linkDropped() }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral,
                                           error: Error?) {
        MainActor.assumeIsolated { linkDropped() }
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothCardLink: CBPeripheralDelegate {
    nonisolated public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let s = p.services?.first(where: { $0.uuid == Self.service }) else {
                central.cancelPeripheralConnection(p)
                return
            }
            p.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: s)
        }
    }

    nonisolated public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for ch in s.characteristics ?? [] {
                if ch.uuid == Self.writeUUID { writeCharacteristic = ch }
                if ch.uuid == Self.notifyUUID { p.setNotifyValue(true, for: ch) }
            }
        }
    }

    nonisolated public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic,
                                       error: Error?) {
        MainActor.assumeIsolated {
            guard ch.uuid == Self.notifyUUID, ch.isNotifying, writeCharacteristic != nil else { return }
            state = .connected
            connectWaiter?.resume()
            connectWaiter = nil
        }
    }

    nonisolated public func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard !pendingWrites.isEmpty else { return }
            let w = pendingWrites.removeFirst()
            if error != nil { w.resume(throwing: LinkError.writeFailed) } else { w.resume() }
        }
    }

    nonisolated public func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard ch.uuid == Self.notifyUUID, let data = ch.value else { return }
            continuation.yield(.notification(data))
        }
    }
}
