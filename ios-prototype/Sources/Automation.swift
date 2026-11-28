import Foundation
import UIKit

// Launch arguments that let a run be driven from the Mac without touching the screen:
//   --autorun [rounds]     the #21 hotspot batch (default 14 rounds)
//   --ft-probe             #6 phase A: try fast-transfer command variants, save replies
//   --ft-get <name> [runs] #6: download one recording over WiFi fast transfer (default 3 runs)
// Example:
//   xcrun devicectl device process launch --device <udid> \
//     com.huiw86.dnoteprobe --autorun 3

extension Probe {
    @MainActor
    func autoRunIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        let batchFlag = args.firstIndex(of: "--autorun")
        let ftProbe = args.contains("--ft-probe")
        let ftGet = args.firstIndex(of: "--ft-get").flatMap { $0 + 1 < args.count ? $0 : nil }
        guard batchFlag != nil || ftProbe || ftGet != nil else { return }

        guard await connectForAutomation() else { return }

        if let i = ftGet {
            let name = args[i + 1]
            let runs = Int(args.count > i + 2 ? args[i + 2] : "") ?? 3
            run("ft-get") { try await self.fastTransferRuns(name: name, runs: runs) }
            return
        }
        if ftProbe {
            run("ft-probe") { try await self.fastTransferProbe() }
            return
        }
        if let flag = batchFlag {
            let rounds = Int(args.count > flag + 1 ? args[flag + 1] : "") ?? 14
            log.add("autorun: requested rounds=\(rounds)")
            run("hotspot-batch") { try await self.hotspotRuns(count: rounds) }
        }
    }

    /// Wait for Bluetooth, then reuse the live connection or connect to the first card seen.
    @MainActor
    private func connectForAutomation() async -> Bool {
        // Bluetooth comes up a moment after launch.
        for _ in 0..<40 where state != "poweredOn" { try? await Task.sleep(for: .milliseconds(500)) }
        guard state == "poweredOn" else { log.add("autorun: bluetooth \(state), giving up"); return false }

        if connected != nil {
            log.add("autorun: reusing existing connection")
            return true
        }
        startScan()
        for _ in 0..<120 where cards.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
        guard let card = cards.first else {
            log.add("autorun: no card in 60 s — is it awake? giving up")
            return false
        }
        do {
            try await connect(card.peripheral)
            try await deviceInfo()
            return true
        } catch {
            log.add("autorun: connect failed \(error.localizedDescription)")
            return false
        }
    }
}
