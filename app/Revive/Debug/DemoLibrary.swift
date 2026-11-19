#if DEBUG
import AVFoundation
import CardLink
import CardProtocol
import Foundation
import Library

/// `-demoLibrary YES` (scripts/shots.sh): a made-up library for screenshots on the Simulator,
/// kept apart from the real one, and a card link that never connects. DEBUG builds only; no
/// real card, no network.
enum DemoLibrary {
    /// Fills an empty demo library: one paired card and a few phone recordings with
    /// transcripts and summaries. Does nothing when it already has a card.
    static func seedIfEmpty(_ library: RecordingLibrary) {
        guard ((try? library.pairedDevices()) ?? []).isEmpty else { return }
        do {
            _ = try library.upsertDevice(sn: "DEMO000000000001") { device in
                device.name = "示例录音卡"
                device.firmware = "1.50"
                device.peripheralId = UUID().uuidString
                device.pairedAt = Date()
            }
            let now = Date()
            for (index, item) in samples.enumerated() {
                let startedAt = now.addingTimeInterval(item.hoursAgo * -3600)
                let file = try silentAudio(seconds: item.seconds, name: "demo-\(index)")
                let recording = try library.addLocalRecording(file: file, source: .phone, startedAt: startedAt,
                                                              durationMs: item.seconds * 1000, title: item.title)
                if item.starred { try library.setStarred(id: recording.id, true) }
                guard !item.lines.isEmpty else { continue }
                let step = max(1, item.seconds * 1000 / item.lines.count)
                try library.saveTranscript(Transcript(
                    recordingId: recording.id, engine: "demo", language: "zh-CN",
                    segments: item.lines.enumerated().map { TranscriptSegment(startMs: $0.offset * step, text: $0.element) },
                    createdAt: startedAt))
                if let summary = item.summary {
                    try library.saveSummary(Summary(
                        recordingId: recording.id, scene: "meeting", title: summary.title, summary: summary.text,
                        sections: [SummarySection(heading: "要点", items: summary.points)],
                        todos: summary.todos.map { SummaryTodo(text: $0) }, tags: summary.tags,
                        people: summary.people,
                        outline: summary.points.map { OutlineItem(title: $0, points: []) }, quotes: Array(item.lines.prefix(1)),
                        model: "demo", createdAt: startedAt.addingTimeInterval(600)))
                }
            }
        } catch {
            print("demo library: \(error)")
        }
    }

    private struct Sample {
        var title: String
        var hoursAgo: Double
        var seconds: Int
        var starred = false
        var lines: [String] = []
        var summary: SampleSummary?
    }

    private struct SampleSummary {
        var title: String
        var text: String
        var points: [String]
        var todos: [String]
        var tags: [String]
        var people: [String]
    }

    private static let samples: [Sample] = [
        Sample(title: "周会：下周发布排期", hoursAgo: 2, seconds: 90, starred: true,
               lines: ["先看一下这周的进度。", "安装包周三能出来吗？", "可以，周二晚上冻结代码。", "那周四发外部测试。"],
               summary: SampleSummary(title: "周四发外部测试", text: "周二晚上冻结代码，周三出安装包，周四发外部测试。",
                                      points: ["周二晚上冻结代码", "周三出安装包"],
                                      todos: ["周二前合并界面改版", "准备外部测试说明", "通知测试的同事"],
                                      tags: ["发布", "外部测试"], people: ["小王", "小李"])),
        Sample(title: "客户访谈：录音整理的习惯", hoursAgo: 5, seconds: 75,
               lines: ["你平时录完音怎么整理？", "一般回去再听一遍，挑重点记下来。", "最麻烦的是找到说过某句话的地方。"],
               summary: SampleSummary(title: "找回关键的那句话最费时间", text: "受访者录完会重听一遍，最费时的是定位某句话。",
                                      points: ["录完会重听", "定位关键句费时"],
                                      todos: ["整理访谈结论发给团队"], tags: ["访谈", "用户研究"], people: ["受访者 A"])),
        Sample(title: "灵感：周末的选题", hoursAgo: 28, seconds: 40, lines: ["可以做一期讲怎么整理录音的内容。"]),
        Sample(title: "电话：确认场地", hoursAgo: 52, seconds: 35),
    ]

    /// A silent AAC file of `seconds`, in a temporary folder.
    private static func silentAudio(seconds: Int, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("demo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).m4a")
        try? FileManager.default.removeItem(at: url)
        let rate = 16_000.0
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: 1]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return url }
        buffer.frameLength = frames  // zero-filled: silence
        for _ in 0..<seconds { try file.write(from: buffer) }
        return url
    }
}

/// A card link that is ready but never finds or connects a card, for the demo library.
@MainActor
final class DemoCardLink: CardLink {
    let state: LinkState = .idle
    let peripheralId: UUID? = nil
    let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation

    init() {
        let pair = AsyncStream<LinkEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func startScan() {}
    func stopScan() {}
    func connect(_ id: UUID) async throws { throw LinkError.connectFailed }
    func connectWhenSeen(_ id: UUID) throws {}
    func disconnect() {}
    func send(_ request: CardRequest) async throws { throw LinkError.notConnected }
}
#endif
