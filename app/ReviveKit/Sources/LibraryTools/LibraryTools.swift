// What an AI assistant may do with the library (features.md X19): search it, read one recording,
// list open todos, get an overview, and add a text or an audio file. Shared by the `revive`
// command line and its MCP server. Offline: nothing here uses the network (CLAUDE.md rule 3,
// scripts/check-m1-rules.sh); whatever the assistant does with the text is up to the assistant.

import Foundation
import Library

/// A file converted for the library, from `AudioImporter.prepare` (Player, Apple platforms only).
public struct ImportedAudio: Sendable {
    public let file: URL
    public let durationMs: Int

    public init(file: URL, durationMs: Int) {
        self.file = file
        self.durationMs = durationMs
    }
}

public enum LibraryToolError: Error, Equatable, LocalizedError {
    case notFound(String)
    /// More than one recording starts with this id.
    case ambiguous(String)
    case emptyText
    case readOnly(String)
    case unsupportedAudio(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): "没有这条录音：\(id)"
        case .ambiguous(let id): "有不止一条录音的编号以 \(id) 开头，请多给几位"
        case .emptyText: "文字是空的"
        case .readOnly(let why): "这个录音库现在只能读：\(why)"
        case .unsupportedAudio(let path): "不是能识别的音频：\(path)"
        }
    }
}

@MainActor
public final class LibraryTools {
    let library: RecordingLibrary
    let importAudio: (@Sendable (URL) async throws -> ImportedAudio)?
    /// Set when writes must not happen; reads still work.
    public let readOnlyReason: String?
    let now: () -> Date
    let formatter: DateFormatter

    /// `importAudio` nil: adding audio is not offered. `readOnlyReason` non-nil: no writes.
    public init(library: RecordingLibrary, importAudio: (@Sendable (URL) async throws -> ImportedAudio)? = nil,
                readOnlyReason: String? = nil, timeZone: TimeZone = .current, now: @escaping () -> Date = { Date() }) {
        self.library = library
        self.importAudio = importAudio
        self.readOnlyReason = readOnlyReason
        self.now = now
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
    }

    public var canWrite: Bool { readOnlyReason == nil }
    public var canAddAudio: Bool { canWrite && importAudio != nil }

    // MARK: Reading

    /// Recordings whose title, transcript or summary contain every word, newest first.
    public func search(_ query: String, limit: Int = 20) throws -> String {
        let found = try library.searchRecordings(query)
        guard !found.isEmpty else { return "没有找到包含「\(query)」的录音。" }
        let shown = found.prefix(max(1, limit))
        var lines = ["找到 \(found.count) 条录音\(found.count > shown.count ? "，列出最新的 \(shown.count) 条" : "")："]
        lines += shown.map(row)
        lines.append("")
        lines.append("加上编号读一条的纪要和文字稿：get_recording（MCP），或 revive get <编号>。")
        return lines.joined(separator: "\n")
    }

    /// One recording as Markdown: facts, summary, todos, outline, quotes, then the transcript.
    public func get(_ id: String, transcript includeTranscript: Bool = true) throws -> String {
        let recording = try find(id)
        var out = ["# \(recording.title)", ""]
        var facts = ["- 编号：\(recording.id.uuidString.lowercased())",
                     "- 时间：\(formatter.string(from: recording.startedAt))"]
        if recording.durationMs > 0 { facts.append("- 时长：\(Self.duration(recording.durationMs))") }
        facts.append("- 来源：\(Self.source(recording))")
        if recording.isStarred { facts.append("- 已标星") }
        let summary = try library.summary(recordingId: recording.id)
        if let summary {
            if !summary.tags.isEmpty { facts.append("- 标签：\(summary.tags.joined(separator: "、"))") }
            if !summary.people.isEmpty { facts.append("- 人物：\(summary.people.joined(separator: "、"))") }
        }
        out += facts
        if let summary {
            if !summary.summary.isEmpty { out += ["", "## 摘要", "", summary.summary] }
            for section in summary.sections where !section.items.isEmpty {
                out += ["", "## \(section.heading)", ""] + section.items.map { "- \($0)" }
            }
            if !summary.todos.isEmpty {
                out += ["", "## 待办", ""] + summary.todos.map { "- [\($0.done ? "x" : " ")] \($0.text)" }
            }
            if !summary.outline.isEmpty {
                out += ["", "## 大纲", ""]
                for (n, item) in summary.outline.enumerated() {
                    out.append("\(n + 1). \(item.title)")
                    out += item.points.map { "   - \($0)" }
                }
            }
            if !summary.quotes.isEmpty { out += ["", "## 金句", ""] + summary.quotes.map { "> \($0)" } }
        } else {
            out += ["", "（还没有纪要）"]
        }
        if includeTranscript {
            if let transcript = try library.transcript(recordingId: recording.id), !transcript.segments.isEmpty {
                out += ["", "## 文字稿", ""]
                // Text files have no times: every line is at 0.
                let timed = transcript.segments.contains { $0.startMs > 0 }
                out += transcript.segments.map { timed ? "[\(Self.clock($0.startMs))] \($0.text)" : $0.text }
            } else {
                out += ["", "（还没有文字稿）"]
            }
        }
        return out.joined(separator: "\n")
    }

    /// Todos not yet ticked, grouped by recording, newest recording first.
    public func todos() throws -> String {
        let open = try library.openTodos()
        guard !open.isEmpty else { return "没有未完成的待办。" }
        var lines = ["\(open.count) 条未完成的待办："]
        var current: UUID?
        for todo in open {
            if todo.recording.id != current {
                current = todo.recording.id
                lines += ["", "\(todo.recording.title)（\(Self.shortId(todo.recording.id))，\(formatter.string(from: todo.recording.startedAt))）"]
            }
            lines.append("- [ ] \(todo.text)")
        }
        return lines.joined(separator: "\n")
    }

    /// Counts, the latest recordings, the most used tags.
    public func overview(recent: Int = 10) throws -> String {
        let all = try live()
        let digest = try library.digest(summaryLimit: 0)
        var lines = ["录音库共 \(all.count) 条录音"]
        if !all.isEmpty {
            let bySource = Dictionary(grouping: all, by: Self.source).map { "\($0.key) \($0.value.count)" }.sorted()
            lines[0] += "（\(bySource.joined(separator: "，"))）"
        }
        lines.append("未完成的待办 \(digest.openTodos.count) 条，还没转文字的录音 \(digest.untranscribedCount) 条")
        if !digest.tags.isEmpty {
            lines.append("常用标签：" + digest.tags.prefix(10).map { "\($0.name)（\($0.count)）" }.joined(separator: "、"))
        }
        if !all.isEmpty {
            lines += ["", "最近的录音："] + all.prefix(max(1, recent)).map(row)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Writing

    /// A text becomes a recording without audio (features.md E2), lines as its transcript.
    public func addText(_ text: String, title: String?) throws -> String {
        if let readOnlyReason { throw LibraryToolError.readOnly(readOnlyReason) }
        guard let recording = try library.addTextRecording(text: text, title: title, startedAt: now(), now: now()) else {
            throw LibraryToolError.emptyText
        }
        return "已存入「\(recording.title)」（\(Self.shortId(recording.id))）。重新打开闻笺就能看到。"
    }

    /// An audio file becomes a recording with source 导入, converted as a pick from Files is.
    public func addAudio(path: String, title: String?) async throws -> String {
        if let readOnlyReason { throw LibraryToolError.readOnly(readOnlyReason) }
        guard let importAudio else { throw LibraryToolError.unsupportedAudio(path) }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LibraryToolError.notFound(path) }
        let prepared: ImportedAudio
        do { prepared = try await importAudio(url) } catch { throw LibraryToolError.unsupportedAudio(path) }
        defer { try? FileManager.default.removeItem(at: prepared.file.deletingLastPathComponent()) }
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let recording = try library.addLocalRecording(
            file: prepared.file, source: .import, startedAt: now(), durationMs: prepared.durationMs,
            title: name?.isEmpty == false ? name : url.deletingPathExtension().lastPathComponent, now: now())
        return "已存入「\(recording.title)」（\(Self.shortId(recording.id))，\(Self.duration(recording.durationMs))）。重新打开闻笺就能看到。"
    }

    // MARK: Ids and text

    /// Recordings not in 最近删除, newest first: what the app's list shows.
    func live() throws -> [Recording] {
        try library.recordings().filter { $0.trashedAt == nil }.sorted { $0.startedAt > $1.startedAt }
    }

    /// The first 8 hex digits: enough to tell recordings apart, short enough to type.
    static func shortId(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }

    /// A full id, or the start of one (at least 4 characters, dashes optional).
    func find(_ id: String) throws -> Recording {
        let wanted = id.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: "")
        guard wanted.count >= 4 else { throw LibraryToolError.notFound(id) }
        let matches = try live().filter {
            $0.id.uuidString.lowercased().replacingOccurrences(of: "-", with: "").hasPrefix(wanted)
        }
        guard let first = matches.first else { throw LibraryToolError.notFound(id) }
        guard matches.count == 1 else { throw LibraryToolError.ambiguous(id) }
        return first
    }

    /// "- [a1b2c3d4] 2026-11-20 14:02 · 周会 · 32 分钟 · 录音卡 · ★"
    func row(_ recording: Recording) -> String {
        var parts = [formatter.string(from: recording.startedAt), recording.title]
        parts.append(recording.durationMs > 0 ? Self.duration(recording.durationMs) : "文字")
        parts.append(Self.source(recording))
        if recording.isStarred { parts.append("★") }
        return "- [\(Self.shortId(recording.id))] " + parts.joined(separator: " · ")
    }

    static func source(_ recording: Recording) -> String {
        switch recording.source {
        case .card: "录音卡"
        case .phone: "手机录音"
        case .import: "导入"
        case .realtime: "实时录音"
        }
    }

    /// "1 小时 5 分钟", "12 分钟", "45 秒".
    static func duration(_ ms: Int) -> String {
        let seconds = ms / 1000
        if seconds >= 3600 { return "\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分钟" }
        if seconds >= 60 { return "\(seconds / 60) 分钟" }
        return "\(seconds) 秒"
    }

    /// "03:07", "1:02:03".
    static func clock(_ ms: Int) -> String {
        let s = ms / 1000
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
