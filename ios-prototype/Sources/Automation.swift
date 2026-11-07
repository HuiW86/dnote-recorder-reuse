import Foundation
import UIKit

// Launch arguments that let a run be driven from the Mac without touching the screen:
//   --autorun [rounds]     the #21 hotspot batch (default 14 rounds)
//   --delete <name>        delete one recording, by exact name (repeatable)
// Example:
//   xcrun devicectl device process launch --device <udid> \
//     com.huiw86.dnoteprobe --delete 20261106100604.opus

extension Probe {
    @MainActor
    func autoRunIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        let batchFlag = args.firstIndex(of: "--autorun")
        let deleteNames = args.indices.filter { args[$0] == "--delete" }
            .compactMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        guard batchFlag != nil || !deleteNames.isEmpty else { return }

        guard await connectForAutomation() else { return }

        if !deleteNames.isEmpty {
            run("delete") { try await self.deleteRecordings(named: deleteNames) }
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

    /// Stop any recording first (a file being written cannot be removed), then delete only the
    /// names given — an exact match in the card's own listing, never a guess — and re-list to
    /// confirm. Anything not found is reported and left alone.
    private func deleteRecordings(named names: [String]) async throws {
        try await stopRecording()
        try await listFiles()
        log.add("delete: card holds \(files.count) files before: "
                + files.map { "\($0.name)(\($0.size))" }.joined(separator: " "))

        let present = names.filter { name in files.contains { $0.name == name } }
        let missing = names.filter { !present.contains($0) }
        for name in missing { log.add("delete: \(name) NOT on card, skipped") }
        guard !present.isEmpty else { log.add("delete: nothing to do [FAIL]"); return }

        for name in present {
            try sendRaw(buildFrame(Cmd.deleteFile, json: ["name": name]))
            log.add("delete: 0x91 sent \(name)")
            try await Task.sleep(for: .seconds(2))
        }
        try await listFiles()
        for name in present {
            let gone = !files.contains { $0.name == name }
            log.add("delete: \(name) \(gone ? "gone [PASS]" : "STILL PRESENT [FAIL]")")
        }
        log.add("delete: card holds \(files.count) files after")
    }
}
