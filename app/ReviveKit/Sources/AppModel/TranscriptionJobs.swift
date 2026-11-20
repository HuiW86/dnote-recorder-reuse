import Foundation
import Observation

/// Recordings being transcribed right now, shared by every recording page. A transcription
/// outlives the page that started it, so a page opened again for the same recording must see
/// that one is running instead of starting a second (#85).
///
/// It also learns how long transcription takes per second of audio, separately for this phone
/// and for the user's service, so a page can say how much longer a run will take (#75
/// 处理进度与预计时间, from beanpod's Shared/ProcessingETA.swift idea).
@MainActor
@Observable
public final class TranscriptionJobs {
    public static let shared = TranscriptionJobs()

    public private(set) var running: Set<UUID> = []
    /// Recordings whose summary is being made right now, from a page or by 录完自动整理, so the
    /// two never run at once and a page sees the other's result arrive.
    public private(set) var summarizing: Set<UUID> = []
    /// When each running job started, its audio length, and whether it uses the network.
    @ObservationIgnored private var started: [UUID: (at: Date, audioMs: Int, network: Bool)] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date

    /// Seconds of work per second of audio before anything has been measured.
    static let initialRate: (onDevice: Double, network: Double) = (0.5, 0.15)

    public init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    /// False when this recording is already being transcribed.
    public func begin(_ id: UUID, audioMs: Int = 0, usesNetwork: Bool = false) -> Bool {
        guard running.insert(id).inserted else { return false }
        started[id] = (now(), audioMs, usesNetwork)
        return true
    }

    /// False when a summary of this recording is already being made.
    public func beginSummary(_ id: UUID) -> Bool { summarizing.insert(id).inserted }

    public func endSummary(_ id: UUID) { summarizing.remove(id) }

    /// `succeeded` runs teach the rate: an average weighted toward recent runs.
    public func end(_ id: UUID, succeeded: Bool = false) {
        running.remove(id)
        guard let job = started.removeValue(forKey: id), succeeded, job.audioMs >= 5_000 else { return }
        let measured = now().timeIntervalSince(job.at) / (Double(job.audioMs) / 1000)
        let key = Self.rateKey(network: job.network)
        let previous = rate(network: job.network)
        defaults.set(previous * 0.6 + measured * 0.4, forKey: key)
    }

    /// Seconds of work per second of audio, as learned so far.
    public func rate(network: Bool) -> Double {
        let stored = defaults.double(forKey: Self.rateKey(network: network))
        return stored > 0 ? stored : (network ? Self.initialRate.network : Self.initialRate.onDevice)
    }

    /// Seconds still to go for a running job; nil when it is not running. Never below zero.
    public func remainingSeconds(_ id: UUID) -> Double? {
        guard running.contains(id), let job = started[id] else { return nil }
        let total = Double(job.audioMs) / 1000 * rate(network: job.network)
        return max(0, total - now().timeIntervalSince(job.at))
    }

    /// "预计还要 3 分钟", "预计还要不到 1 分钟", "快好了"; nil when it is not running.
    public func remainingText(_ id: UUID) -> String? {
        guard let seconds = remainingSeconds(id) else { return nil }
        if seconds < 5 { return "快好了" }
        if seconds < 60 { return "预计还要不到 1 分钟" }
        return "预计还要 \(Int((seconds / 60).rounded(.up))) 分钟"
    }

    private static func rateKey(network: Bool) -> String {
        network ? "revive.transcriptionRate.network" : "revive.transcriptionRate.onDevice"
    }
}
