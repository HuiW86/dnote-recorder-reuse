import Foundation
import GRDB
import Library
@testable import LibraryTools
import Testing

// X19 接入 AI 助手 (features.md; test-spec.md T-M5-20…23): the library tools and the MCP server,
// on a library in a temporary folder. No network, no assistant app.

/// A library with: a card recording with transcript and summary, a phone recording, a text note,
/// and a card recording moved to 最近删除.
@MainActor
final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)")
    let library: RecordingLibrary
    let meeting: Recording
    let phone: Recording
    let trashed: Recording
    let utc = TimeZone(identifier: "UTC")!

    init() throws {
        let library = RecordingLibrary(database: try AppDatabase.onDisk(directory: root), store: try AudioStore(root: root))
        self.library = library
        let device = try library.upsertDevice(sn: "S") { $0.name = "卡"; $0.firmware = "1.50" }
        func card(_ name: String, title: String, at seconds: TimeInterval, ms: Int) throws -> Recording {
            let item = try library.syncItem(deviceId: device.id, name: name, size: 10)
            let id = UUID()
            let path = try library.store.storeAudio(Data("OggS".utf8), id: id)
            let r = Recording(id: id, deviceId: device.id, source: .card, cardFileName: name, cardFileSize: 10,
                              startedAt: Date(timeIntervalSince1970: seconds), durationMs: ms, audioPath: path,
                              audioSha256: "x", title: title, createdAt: Date(), updatedAt: Date())
            _ = try library.commitStored(r, item: item, deleteAfterSync: false)
            return r
        }
        meeting = try card("a.opus", title: "产品周会", at: 1_795_000_000, ms: 1_950_000)
        try library.saveTranscript(Transcript(recordingId: meeting.id, engine: "on-device", language: "zh", segments: [
            TranscriptSegment(startMs: 0, text: "先看上周的发布"),
            TranscriptSegment(startMs: 187_000, text: "离线同步下周做完"),
        ], createdAt: Date()))
        _ = try library.saveSummary(Summary(recordingId: meeting.id, scene: "meeting", title: "产品周会", summary: "回顾发布，排下周。",
                                            sections: [SummarySection(heading: "决定", items: ["离线同步优先"])],
                                            todos: [SummaryTodo(text: "写离线同步的测试"), SummaryTodo(text: "发周报", done: true)],
                                            tags: ["周会", "同步"], people: ["小王"],
                                            outline: [OutlineItem(title: "发布回顾", points: ["崩溃率下降"])],
                                            quotes: ["先让卡能用"], model: "test", createdAt: Date()))
        let audio = root.appendingPathComponent("in.m4a")
        try Data("m4a".utf8).write(to: audio)
        phone = try library.addLocalRecording(file: audio, source: .phone, startedAt: Date(timeIntervalSince1970: 1_795_100_000),
                                              durationMs: 45_000, title: nil)
        _ = try library.addTextRecording(text: "灵感：卡上的按键可以标重点", title: "随手记",
                                         startedAt: Date(timeIntervalSince1970: 1_795_200_000))
        trashed = try card("b.opus", title: "删掉的会议", at: 1_795_300_000, ms: 60_000)
        try library.trashRecording(id: trashed.id)
    }

    func tools(readOnly: String? = nil, audio: (@Sendable (URL) async throws -> ImportedAudio)? = nil) -> LibraryTools {
        LibraryTools(library: library, importAudio: audio, readOnlyReason: readOnly, timeZone: utc,
                     now: { Date(timeIntervalSince1970: 1_795_400_000) })
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

@MainActor
struct LibraryToolsTests {
    @Test func searchSkipsTheTrashAndShowsShortIds() throws {
        let f = try Fixture()
        let text = try f.tools().search("离线 同步")
        #expect(text.contains("找到 1 条录音"))
        #expect(text.contains("[\(LibraryTools.shortId(f.meeting.id))] 2026-11-18 11:06 · 产品周会 · 32 分钟 · 录音卡"))
        #expect(try f.tools().search("会议").contains("没有找到"))  // only the trashed one says 会议
    }

    @Test func getRendersSummaryTodosAndTimedTranscript() throws {
        let f = try Fixture()
        let text = try f.tools().get(LibraryTools.shortId(f.meeting.id))
        for expected in ["# 产品周会", "- 编号：\(f.meeting.id.uuidString.lowercased())", "- 时长：32 分钟", "- 来源：录音卡",
                         "- 标签：周会、同步", "- 人物：小王", "## 摘要", "回顾发布，排下周。", "## 决定", "- 离线同步优先",
                         "- [ ] 写离线同步的测试", "- [x] 发周报", "1. 发布回顾", "   - 崩溃率下降", "> 先让卡能用",
                         "## 文字稿", "[00:00] 先看上周的发布", "[03:07] 离线同步下周做完"] {
            #expect(text.contains(expected), "missing \(expected)")
        }
        #expect(!(try f.tools().get(f.meeting.id.uuidString, transcript: false)).contains("## 文字稿"))
        let phone = try f.tools().get(f.phone.id.uuidString)
        #expect(phone.contains("（还没有纪要）") && phone.contains("（还没有文字稿）") && phone.contains("手机录音"))
    }

    @Test func idsMustBeKnownUniqueAndNotTrashed() throws {
        let f = try Fixture()
        #expect(throws: LibraryToolError.notFound("abc")) { try f.tools().get("abc") }
        #expect(throws: LibraryToolError.notFound("ffffffff")) { try f.tools().get("ffffffff") }
        let trashedId = LibraryTools.shortId(f.trashed.id)
        #expect(throws: LibraryToolError.notFound(trashedId)) { try f.tools().get(trashedId) }
    }

    @Test func todosAreOpenOnesByRecording() throws {
        let f = try Fixture()
        let text = try f.tools().todos()
        #expect(text.contains("1 条未完成的待办"))
        #expect(text.contains("产品周会（\(LibraryTools.shortId(f.meeting.id))，2026-11-18 11:06）"))
        #expect(text.contains("- [ ] 写离线同步的测试"))
        #expect(!text.contains("发周报"))
    }

    @Test func overviewCountsWhatTheListShows() throws {
        let f = try Fixture()
        let text = try f.tools().overview(recent: 2)
        #expect(text.contains("录音库共 3 条录音（导入 1，录音卡 1，手机录音 1）"))
        #expect(text.contains("未完成的待办 1 条，还没转文字的录音 1 条"))
        #expect(text.contains("常用标签：同步（1）、周会（1）"))
        let recent = text.components(separatedBy: "最近的录音：")[1]
        #expect(recent.contains("随手记 · 文字 · 导入"))
        #expect(!recent.contains("产品周会"))  // only the 2 newest
    }

    @Test func addingTextAndAudio() async throws {
        let f = try Fixture()
        let text = try f.tools().addText("第一段\n\n第二段", title: "助手存的")
        #expect(text.contains("已存入「助手存的」"))
        #expect(try f.library.recordings().contains { $0.title == "助手存的" && $0.durationMs == 0 })
        #expect(throws: LibraryToolError.emptyText) { try f.tools().addText("  \n ", title: nil) }

        let source = f.root.appendingPathComponent("voice memo.wav")
        try Data("RIFF".utf8).write(to: source)
        let tools = f.tools(audio: { url in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("conv-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let out = dir.appendingPathComponent("import.m4a")
            try FileManager.default.copyItem(at: url, to: out)
            return ImportedAudio(file: out, durationMs: 90_000)
        })
        #expect(tools.canAddAudio)
        let added = try await tools.addAudio(path: source.path, title: nil)
        #expect(added.contains("已存入「voice memo」") && added.contains("1 分钟"))
        let stored = try #require(try f.library.recordings().first { $0.title == "voice memo" })
        #expect(stored.source == .import && stored.startedAt == Date(timeIntervalSince1970: 1_795_400_000))
        await #expect(throws: LibraryToolError.notFound("/no/such.wav")) {
            try await tools.addAudio(path: "/no/such.wav", title: nil)
        }
        let refusing = f.tools(audio: { _ in throw CocoaError(.fileReadCorruptFile) })
        await #expect(throws: LibraryToolError.unsupportedAudio(source.path)) {
            try await refusing.addAudio(path: source.path, title: nil)
        }
    }

    @Test func readOnlyRefusesWrites() async throws {
        let f = try Fixture()
        let tools = f.tools(readOnly: "测试", audio: { _ in ImportedAudio(file: URL(fileURLWithPath: "/x"), durationMs: 1) })
        #expect(!tools.canWrite && !tools.canAddAudio)
        #expect(throws: LibraryToolError.readOnly("测试")) { try tools.addText("x", title: nil) }
        await #expect(throws: LibraryToolError.readOnly("测试")) { try await tools.addAudio(path: "/x", title: nil) }
        #expect(try f.library.recordings().count == 4)
    }

    @Test func formatting() {
        #expect(LibraryTools.duration(45_000) == "45 秒")
        #expect(LibraryTools.duration(3_720_000) == "1 小时 2 分钟")
        #expect(LibraryTools.clock(187_000) == "03:07")
        #expect(LibraryTools.clock(3_723_000) == "1:02:03")
    }
}

@MainActor
struct ExistingLibraryTests {
    @Test func opensOnlyALibraryThatExists() throws {
        let f = try Fixture()
        #expect(try AppDatabase.existing(directory: f.root.appendingPathComponent("nothing")) == nil)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("nothing").path))
        let other = try #require(try AppDatabase.existing(directory: f.root))
        let library = RecordingLibrary(database: other, store: try AudioStore(root: f.root))
        #expect(try library.recordings().count == 4)
        #expect(try !other.isNewerThanThisBuild())
    }

    /// A library a newer build migrated: readable, but marked so the tool does not write.
    @Test func noticesANewerBuild() throws {
        let f = try Fixture()
        let opened = try #require(try AppDatabase.existing(directory: f.root))
        try opened.writer.write { try $0.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999')") }
        let again = try #require(try AppDatabase.existing(directory: f.root))
        #expect(try again.isNewerThanThisBuild())
        #expect(try RecordingLibrary(database: again, store: try AudioStore(root: f.root)).recordings().count == 4)
    }
}

@MainActor
struct MCPServerTests {
    private func reply(_ server: MCPServer, _ line: String) async throws -> [String: Any] {
        let text = try #require(await server.handle(line))
        #expect(!text.contains("\n"), "one message per line")
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func initializeAndPing() async throws {
        let f = try Fixture()
        let server = MCPServer(tools: f.tools())
        let hello = try await reply(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        let result = try #require(hello["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "wenjian")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect((hello["id"] as? NSNumber)?.intValue == 1)

        let future = try await reply(server, #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        #expect((future["result"] as? [String: Any])?["protocolVersion"] as? String == MCPServer.protocolVersions[0])
        #expect(future["id"] as? String == "a")

        #expect(await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(await server.handle("   ") == nil)
        let pong = try await reply(server, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        #expect((pong["result"] as? [String: Any])?.isEmpty == true)
    }

    @Test func toolListFollowsWhatMayBeDone() async throws {
        let f = try Fixture()
        func names(_ tools: LibraryTools) async throws -> [String] {
            let list = try await reply(MCPServer(tools: tools), #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
            let entries = try #require((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
            for entry in entries {
                #expect((entry["inputSchema"] as? [String: Any])?["type"] as? String == "object")
            }
            return entries.compactMap { $0["name"] as? String }
        }
        let audio: @Sendable (URL) async throws -> ImportedAudio = { _ in ImportedAudio(file: URL(fileURLWithPath: "/x"), durationMs: 1) }
        #expect(try await names(f.tools(audio: audio))
            == ["search_recordings", "get_recording", "list_todos", "library_overview", "add_text_note", "add_audio_file"])
        #expect(try await names(f.tools()).last == "add_text_note")  // no importer: no audio tool
        #expect(try await names(f.tools(readOnly: "x", audio: audio)) == ["search_recordings", "get_recording", "list_todos", "library_overview"])
    }

    @Test func callsReturnTextAndToolErrorsStayResults() async throws {
        let f = try Fixture()
        let server = MCPServer(tools: f.tools())
        func call(_ name: String, _ arguments: String) async throws -> (text: String, isError: Bool) {
            let r = try await reply(server, #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#)
            let result = try #require(r["result"] as? [String: Any], "no result: \(r)")
            let content = try #require(result["content"] as? [[String: Any]])
            return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
        }
        let found = try await call("search_recordings", #"{"query":"离线","limit":5}"#)
        #expect(!found.isError && found.text.contains("产品周会"))
        let one = try await call("get_recording", #"{"id":"\#(LibraryTools.shortId(f.meeting.id))","include_transcript":false}"#)
        #expect(one.text.contains("## 待办") && !one.text.contains("## 文字稿"))
        #expect(try await call("list_todos", "{}").text.contains("写离线同步的测试"))
        #expect(try await call("library_overview", #"{"recent":"3"}"#).text.contains("录音库共 3 条录音"))
        let saved = try await call("add_text_note", #"{"text":"助手：明天十点开会","title":"提醒"}"#)
        #expect(!saved.isError && saved.text.contains("已存入「提醒」"))

        let missing = try await call("get_recording", #"{"id":"ffffffff"}"#)
        #expect(missing.isError && missing.text.contains("没有这条录音"))
        let noArgument = try await call("search_recordings", "{}")
        #expect(noArgument.isError && noArgument.text.contains("缺少参数 query"))
        for value in ["0", "2.5", "true", #""too many""#] {
            let invalid = try await call("library_overview", #"{"recent":\#(value)}"#)
            #expect(invalid.isError && invalid.text.contains("recent"))
        }
    }

    @Test func protocolErrors() async throws {
        let f = try Fixture()
        let server = MCPServer(tools: f.tools(readOnly: "x"))
        func code(_ line: String) async throws -> Int? {
            ((try await reply(server, line))["error"] as? [String: Any])?["code"] as? Int
        }
        #expect(try await code("{not json") == -32700)
        #expect(try await code(#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#) == -32601)
        #expect(try await code(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#) == -32602)
        // Hidden in read-only mode, so unknown.
        #expect(try await code(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_text_note","arguments":{"text":"x"}}}"#) == -32602)
        #expect(try await code(#"{"jsonrpc":"2.0","id":1,"result":{}}"#) == -32600)
        #expect(await server.handle(#"{"jsonrpc":"2.0","result":{}}"#) == nil)
    }
}
