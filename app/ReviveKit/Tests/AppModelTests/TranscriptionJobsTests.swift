import AppModel
import Foundation
import Testing

// #75 处理进度与预计时间: the estimate for a running transcription, learned from earlier runs.
@MainActor
struct TranscriptionJobsTests {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    @Test func estimatesFromWhatEarlierRunsTook() throws {
        let suite = "jobs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = Clock()
        let jobs = TranscriptionJobs(defaults: defaults, now: { clock.now })
        let first = UUID()

        // Nothing measured yet: half a second of work per second of audio on the phone.
        #expect(jobs.rate(network: false) == 0.5)
        #expect(jobs.remainingText(first) == nil)

        // A 10-minute recording took 2 minutes: 0.2 s per second, blended toward the start value.
        #expect(jobs.begin(first, audioMs: 600_000, usesNetwork: false))
        #expect(!jobs.begin(first, audioMs: 600_000, usesNetwork: false))
        #expect(jobs.remainingText(first) == "预计还要 5 分钟")
        clock.now += 120
        jobs.end(first, succeeded: true)
        #expect(abs(jobs.rate(network: false) - (0.5 * 0.6 + 0.2 * 0.4)) < 1e-9)
        #expect(jobs.rate(network: true) == 0.15)  // learned separately

        // The next 10-minute run: 0.38 × 600 = 228 s; 200 s in, under a minute is left.
        let second = UUID()
        #expect(jobs.begin(second, audioMs: 600_000, usesNetwork: false))
        #expect(jobs.remainingText(second) == "预计还要 4 分钟")
        clock.now += 200
        #expect(jobs.remainingText(second) == "预计还要不到 1 分钟")
        clock.now += 60
        #expect(jobs.remainingText(second) == "快好了")
        // A failed run teaches nothing.
        jobs.end(second, succeeded: false)
        #expect(abs(jobs.rate(network: false) - 0.38) < 1e-9)
        #expect(jobs.remainingText(second) == nil)
    }
}
