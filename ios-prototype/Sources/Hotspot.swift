import Foundation
import Network
import NetworkExtension

// FastUpload hotspot reachability, following the official app (FastTransferWifi / FAST_TRANSFER):
// 0x88 {ap:1, ssid:"FastUpload", psk} -> wait 3 s -> join Wi-Fi -> TCP 192.168.88.1:6718
// (6 attempts, 2 s apart) -> 0x88 {ap:0}. The TCP protocol itself is #6, not tested here.

enum FastTransfer {
    static let ssid = "FastUpload"
    static let host = "192.168.88.1"
    static let port: UInt16 = 6718
    static let tcpAttempts = 6
}

/// Same shape as the official generateWifiPassword(12): letters and digits without look-alikes.
func generateWifiPassword(length: Int = 12) -> String {
    let sets = ["ABCDEFGHJKLMNPQRSTUVWXYZ", "abcdefghijkmnpqrstuvwxyz", "0123456789"]
    let all = sets.joined()
    var chars = sets.map { $0.randomElement()! }
    chars += (chars.count..<length).map { _ in all.randomElement()! }
    return String(chars.shuffled())
}

extension Probe {
    /// Manual check: leave the AP on with a fixed password so it can be joined from Settings.
    func hotspotHold(_ on: Bool) throws {
        let psk = "dnote1234"
        try sendRaw(buildFrame(Cmd.setWifiAp, json: ["ap": on ? 1 : 0, "ssid": FastTransfer.ssid, "psk": psk]))
        log.add("hotspot: manual \(on ? "ON" : "OFF") ssid=\(FastTransfer.ssid) psk=\(psk)")
    }

    /// fixedPsk: reuse one password and let the AP settle 10 s, to separate AP restart timing
    /// from NEHotspotConfiguration behaviour.
    func hotspotProbe(fixedPsk: Bool = false, joinOnce: Bool = true) async throws {
        let psk = fixedPsk ? "dnote1234" : generateWifiPassword()
        // Reset first: an AP left on from an earlier run may still use the old password.
        try sendRaw(buildFrame(Cmd.setWifiAp, json: ["ap": 0, "ssid": FastTransfer.ssid, "psk": psk]))
        try await Task.sleep(for: .seconds(2))
        try sendRaw(buildFrame(Cmd.setWifiAp, json: ["ap": 1, "ssid": FastTransfer.ssid, "psk": psk]))
        log.add("hotspot: 0x88 ap=0 then ap=1 ssid=\(FastTransfer.ssid) psk=\(psk) fixed=\(fixedPsk) joinOnce=\(joinOnce)")
        if fixedPsk { try await Task.sleep(for: .seconds(4)) }
        defer {
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: FastTransfer.ssid)
            try? sendRaw(buildFrame(Cmd.setWifiAp, json: ["ap": 0, "ssid": FastTransfer.ssid, "psk": psk]))
            log.add("hotspot: cleanup (removed Wi-Fi config, 0x88 ap=0)")
        }
        // Official app waits 3 s; V7 saw joins fail at 3 s, so give the AP longer to come up.
        try await Task.sleep(for: .seconds(6))

        // apply() can report success even when iOS fails to join and falls back to the previous
        // network, so verify the Wi-Fi address is on the card's subnet and retry the join.
        // The SSID is checked alongside it to tell the two failures apart (#21):
        //   A: iOS never switched network        -> SSID is not FastUpload
        //   B: switched but no route to the card -> SSID matches, no 192.168.88.x address
        var joined = false
        var sawCardSSID = false
        var ssidReadable = false
        for join in 1...3 where !joined {
            let config = NEHotspotConfiguration(ssid: FastTransfer.ssid, passphrase: psk, isWEP: false)
            // joinOnce=false like a manual join; joinOnce=true failed repeatedly in V7.
            config.joinOnce = joinOnce
            let t0 = Date()
            do {
                try await NEHotspotConfigurationManager.shared.apply(config)
            } catch let e as NSError where e.domain == NEHotspotConfigurationErrorDomain
                        && e.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                log.add("hotspot: already associated")
            } catch {
                log.add("hotspot: join \(join) apply error \(error)")
            }
            // Give DHCP up to 8 s to hand out a 192.168.88.x address.
            var lastSSID: String?
            for _ in 0..<16 where !joined {
                lastSSID = await currentSSID()
                if let ssid = lastSSID {
                    ssidReadable = true
                    if ssid == FastTransfer.ssid { sawCardSSID = true }
                }
                joined = wifiIPv4().contains { $0.hasPrefix("192.168.88.") }
                if !joined { try await Task.sleep(for: .milliseconds(500)) }
            }
            log.add(String(format: "hotspot: join %d %@ after %.1fs ssid=%@ en0=%@", join,
                           joined ? "OK" : "NOT on card subnet", Date().timeIntervalSince(t0),
                           lastSSID ?? "unavailable", "\(wifiIPv4())"))
            if !joined {
                NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: FastTransfer.ssid)
                try await Task.sleep(for: .seconds(2))
            }
        }
        guard joined else {
            let why: String
            if !ssidReadable {
                why = "inconclusive, SSID unreadable (entitlement or Location permission)"
            } else if sawCardSSID {
                why = "B: associated with FastUpload but never got a 192.168.88.x address"
            } else {
                why = "A: iOS never switched to FastUpload"
            }
            log.add("hotspot: could not join FastUpload — \(why) [FAIL]")
            return
        }

        for attempt in 1...FastTransfer.tcpAttempts {
            let t = Date()
            do {
                let banner = try await tcpConnect()
                log.add("hotspot: TCP \(FastTransfer.host):\(FastTransfer.port) connected on attempt \(attempt) "
                        + "first bytes=\(banner.isEmpty ? "(none in 3s)" : banner.hex) [PASS]")
                return
            } catch {
                log.add(String(format: "hotspot: TCP attempt %d failed after %.1fs: %@ | %@", attempt,
                               Date().timeIntervalSince(t), "\(error)", "en0=\(wifiIPv4())"))
            }
            try await Task.sleep(for: .seconds(2))
        }
        log.add("hotspot: TCP never connected [FAIL]")
    }

    /// SSID iOS reports for the current Wi-Fi network. The same check @capgo/capacitor-wifi
    /// 8.5.x added to confirm a join; 8.3.1 (the version the official app ships) has none.
    /// nil means "could not read" — needs the HotspotConfiguration entitlement or a network
    /// this app configured — not "not connected".
    private func currentSSID() async -> String? {
        await withCheckedContinuation { c in
            NEHotspotNetwork.fetchCurrent { c.resume(returning: $0?.ssid) }
        }
    }

    /// IPv4 addresses currently on the Wi-Fi interface (en0).
    private func wifiIPv4() -> [String] {
        var addrs: [String] = []
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0 else { return [] }
        defer { freeifaddrs(ifa) }
        var p = ifa
        while let cur = p {
            let i = cur.pointee
            if String(cString: i.ifa_name) == "en0", let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                addrs.append(String(cString: host))
            }
            p = i.ifa_next
        }
        return addrs
    }

    /// Connect over Wi-Fi, then read whatever the card sends within 3 s.
    private func tcpConnect() async throws -> Data {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .wifi
        let conn = NWConnection(host: .init(FastTransfer.host), port: .init(rawValue: FastTransfer.port)!, using: params)
        defer { conn.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var done = false
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: if !done { done = true; c.resume() }
                case .failed(let e), .waiting(let e): if !done { done = true; c.resume(throwing: e) }
                default: break
                }
            }
            conn.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if !done { done = true; c.resume(throwing: ProbeError.timeout("tcp connect")) }
            }
        }
        return await withCheckedContinuation { c in
            var done = false
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, _ in
                if !done { done = true; c.resume(returning: data ?? Data()) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if !done { done = true; c.resume(returning: Data()) }
            }
        }
    }
}
