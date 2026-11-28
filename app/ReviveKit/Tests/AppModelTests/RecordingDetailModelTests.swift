import AppModel
import CardProtocol
import CardTestSupport
import Foundation
import Library
import Player
import SyncEngine
import Assistant
import Testing
import Transcription

// Recording detail (product-spec.md P06) on a synthetic recording.

@MainActor
private final class DetailFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("detail-\(UUID().uuidString)")
    let library: RecordingLibrary
    let player: RecordingPlayer
    let recording: Recording

    init(audio: Data? = nil) async throws {
        library = RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
        player = RecordingPlayer(library: library)
        let frames = try SyntheticOpus.sine(seconds: 2)
        let data = audio ?? OggOpus.wrap(frames)
        let id = UUID()
        let path = try library.store.storeAudio(data, id: id)
        let start = try #require(CardFile.startDate(fileName: "20261107140211.opus"))
        let r = Recording(id: id, deviceId: nil, source: .card, cardFileName: "20261107140211.opus",
                          cardFileSize: data.count, startedAt: start, durationMs: frames.count * 20,
                          audioPath: path, audioSha256: "", title: "2026-11-07 14:02", createdAt: start, updatedAt: start)
        try await library.database.writer.write { try r.insert($0) }
        recording = r
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

@MainActor
struct RecordingDetailModelTests {
    @Test func playSkipPauseThenDelete() async throws {
        let f = try await DetailFixture()
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player)
        #expect(model.title == "11月7日 14:02")
        #expect(model.startedAtText == "2026-11-07 14:02:11")
        #expect(model.durationText == "2 秒")
        #expect(!model.audioMissing)

        // Dragging the bar before the first play starts playing there; back 15 s does nothing.
        model.skip(by: -15)
        #expect(!model.isPlaying)
        model.seek(to: 1)
        await waitUntil("playing from the bar") { model.isPlaying }
        f.player.stop()
        await waitUntil("stopped") { !model.isPlaying }

        model.togglePlay()
        await waitUntil("playing") { model.isPlaying }
        f.player.volume = 0
        #expect(abs(model.duration - 2) < 0.05)
        model.skip(by: 15)
        #expect(model.currentTime <= model.duration)
        model.skip(by: -15)
        #expect(model.currentTime < 0.1)
        model.togglePlay()
        #expect(!model.isPlaying && f.player.state == .paused)

        // X6: a custom title is shown as it is; an empty one puts the recording time back.
        #expect(model.editableTitle == "")
        model.rename(to: "  周会  ")
        #expect(model.title == "周会" && model.editableTitle == "周会")
        model.rename(to: "")
        #expect(model.title == "11月7日 14:02")

        // X21: 标星 from the page's menu is stored and survives a trash round trip.
        #expect(!model.isStarred)
        model.toggleStar()
        #expect(model.isStarred && model.toast?.text == "已标星")
        #expect(try f.library.recording(id: f.recording.id)?.isStarred == true)
        model.toggleStar()
        #expect(!model.isStarred && model.toast?.text == "已取消星标")
        model.toggleStar()

        // D1b: delete moves it to 最近删除; the row and the audio stay until it is purged.
        model.delete()
        #expect(model.isDeleted)
        #expect(f.player.state == .idle)
        #expect(try f.library.recording(id: f.recording.id)?.trashedAt != nil)
        #expect(FileManager.default.fileExists(atPath: f.library.store.url(forAudioPath: f.recording.audioPath).path))
        try f.library.restoreRecording(id: f.recording.id)
        #expect(try f.library.recording(id: f.recording.id)?.isStarred == true)
    }

    /// X9: the transcript is stored, survives a reload, and failures become a toast.
    @Test func transcribesStoresAndReportsFailures() async throws {
        let f = try await DetailFixture()
        let off = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player)
        #expect(!off.canTranscribe && off.transcript == nil)

        let segments = [TranscriptSegment(startMs: 0, text: "那就下周三。"), TranscriptSegment(startMs: 1200, text: "好的")]
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player,
                                         transcriber: FakeTranscriber(result: .success(segments)))
        #expect(model.canTranscribe)
        model.transcribe()
        await waitUntil("transcribed") { model.transcript != nil && !model.isTranscribing }
        #expect(model.transcript?.segments == segments)
        #expect(model.timeText(segments[1]) == "00:00:01")
        let reloaded = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player)
        #expect(reloaded.transcript?.segments == segments)

        // #89: the line being played is known once this recording is in the player.
        #expect(model.currentSegmentIndex == nil)
        model.play(from: segments[1])
        await waitUntil("second line") { model.currentSegmentIndex == 1 }
        f.player.stop()

        let failing = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player,
                                           transcriber: FakeTranscriber(result: .failure(.unsupportedLanguage)))
        failing.transcribe()
        await waitUntil("toast") { failing.toast != nil }
        #expect(failing.toast?.text == "这部手机不支持离线识别这种语言")
        #expect(failing.transcript?.segments == segments)  // the earlier text stays

        // X11: the user's service with no connection gives the advice, not "转写失败，请重试".
        let offline = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player,
                                           transcriber: OfflineTranscriber())
        offline.transcribe()
        await waitUntil("offline toast") { offline.toast != nil }
        #expect(offline.toast?.text == AssistantError.offlineAdvice)
        #expect(offline.transcript?.segments == segments)

        // Removed with the recording.
        try f.library.deleteRecording(id: f.recording.id)
        #expect(try f.library.transcript(recordingId: f.recording.id) == nil)
    }

    /// G1 and X11: no service means no button and a hint; with one, the summary is stored and
    /// its to-dos can be ticked. The service is a stub that never touches the network.
    @Test func summarizesWithTheUsersServiceAndTicksTodos() async throws {
        let f = try await DetailFixture()
        try f.library.saveTranscript(Transcript(recordingId: f.recording.id, engine: "test", language: "zh-CN",
                                                segments: [TranscriptSegment(startMs: 0, text: "周三发布。")],
                                                createdAt: Date()))
        let none = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player)
        #expect(!none.canSummarize)
        let unset = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player,
                                         assistant: AssistantConfigSource { nil })
        #expect(!unset.canSummarize && unset.summaryHint != nil)

        let reply = #"{"scene":"meeting","title":"定发布日","summary":"周三发布。","sections":[],"todos":["发通知"],"tags":[],"people":[]}"#
        let config = ServiceConfig(baseURL: "https://example.invalid/v1", model: "m", apiKey: "")
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player,
                                         assistant: AssistantConfigSource { config },
                                         summarizer: Summarizer(client: ChatClient(session: CannedReply.session(reply))))
        #expect(model.canSummarize && model.summaryHint == nil)
        model.summarize()
        await waitUntil("summarized") { model.summary != nil && !model.isSummarizing }
        #expect(model.summary?.title == "定发布日")
        #expect(model.sceneName == "会议")
        // G1: the summary's title becomes the recording's, as the default title was not the user's.
        #expect(model.title == "定发布日" && model.editableTitle == "定发布日")
        #expect(model.summary?.todos.map(\.text) == ["发通知"])
        model.setTodo(0, done: true)
        #expect(model.summary?.todos.first?.done == true)
        let reloaded = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player)
        #expect(reloaded.summary?.todos.first?.done == true)

        // Made again elsewhere (录完自动整理) while this page still shows the old one: the tick is
        // not moved onto the new todo at that place; the page shows the new summary instead.
        var again = try #require(try f.library.summary(recordingId: f.recording.id))
        again.todos = [SummaryTodo(text: "订会议室")]
        try f.library.saveSummary(again)
        model.setTodo(0, done: false)
        #expect(try f.library.summary(recordingId: f.recording.id)?.todos == [SummaryTodo(text: "订会议室")])
        #expect(model.summary?.todos.map(\.text) == ["订会议室"])
        #expect(model.toast?.text == OverviewModel.summaryChangedText)
    }

    @Test func missingAudioIsShownNotPlayed() async throws {
        let f = try await DetailFixture()
        try FileManager.default.removeItem(at: f.library.store.url(forAudioPath: f.recording.audioPath))
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player)
        #expect(model.audioMissing)
        #expect(model.exportFile() == nil)
    }

    @Test func unplayableFileToasts() async throws {
        let f = try await DetailFixture(audio: Data(repeating: 0x5A, count: 4000))
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player)
        model.togglePlay()
        await waitUntil("toast") { model.toast != nil }
        #expect(model.toast?.text == "无法播放这条录音")
        #expect(!model.isPlaying && !model.isPreparing)
    }

    @Test func exportsUnderTitle() async throws {
        let f = try await DetailFixture()
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player)
        // #85: named as the page shows the recording, not by the stored "2026-11-07 14:02".
        let url = try #require(model.exportFile())
        #expect(url.lastPathComponent == "11月7日 14.02.ogg")
        model.rename(to: "周会")
        #expect(try #require(model.exportFile()).lastPathComponent == "周会.ogg")
        #expect(model.originalFormat == "OGG")
        #if canImport(CoreText)
        // J1: the PDF is named like the other exports and is a PDF.
        let pdf = try #require(model.exportPDF())
        #expect(pdf.lastPathComponent == "周会.pdf")
        #expect(try Data(contentsOf: pdf).prefix(5) == Data("%PDF-".utf8))
        #endif
        // J1: the Word document is a ZIP package named the same way.
        let docx = try #require(model.exportDOCX())
        #expect(docx.lastPathComponent == "周会.docx")
        #expect(try Data(contentsOf: docx).prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        RecordingExporter.cleanUp()
    }

    /// G1 and X6: a summary keeps a title the user typed; "让 AI 重新起标题" replaces it when
    /// asked; "按场景重新生成" keeps the chosen scene. Same canned reply as the summary test, so
    /// tests running side by side see the same content.
    @Test func aiTitleKeepsTheUsersTitleUnlessAsked() async throws {
        let f = try await DetailFixture()
        try f.library.saveTranscript(Transcript(recordingId: f.recording.id, engine: "test", language: "zh-CN",
                                                segments: [TranscriptSegment(startMs: 0, text: "周三发布。")],
                                                createdAt: Date()))
        let reply = #"{"scene":"meeting","title":"定发布日","summary":"周三发布。","sections":[],"todos":["发通知"],"tags":[],"people":[]}"#
        let config = ServiceConfig(baseURL: "https://example.invalid/v1", model: "m", apiKey: "")
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player,
                                         assistant: AssistantConfigSource { config },
                                         summarizer: Summarizer(client: ChatClient(session: CannedReply.session(reply))))
        model.rename(to: "我的标题")
        model.summarize(scene: .interview)
        await waitUntil("summarized") { model.summary != nil && !model.isSummarizing }
        #expect(model.title == "我的标题")
        #expect(model.sceneName == "访谈")  // the scene the user picked, not the model's
        #expect(model.scenes.count == RecordingScene.allCases.count)

        #expect(model.canRetitle)
        model.retitle()
        await waitUntil("retitled") { !model.isRetitling && model.title != "我的标题" }
        #expect(model.title == "定发布日")
        #expect(model.toast?.text == "已换成「定发布日」")
        #expect(try f.library.recording(id: f.recording.id)?.hasAITitle == true)

        // It replaced the user's title: 撤销 puts that back as the user's.
        #expect(model.toast?.action == "撤销")
        model.undoRetitle()
        #expect(model.title == "我的标题")
        #expect(model.toast?.text == "已恢复「我的标题」")
        #expect(try f.library.recording(id: f.recording.id)?.titleSource == .user)

        // Renamed again after the AI title: 撤销 leaves the newer title alone.
        model.retitle()
        await waitUntil("retitled again") { !model.isRetitling && model.title == "定发布日" }
        model.rename(to: "后来改的")
        model.undoRetitle()
        #expect(model.title == "后来改的")
        #expect(model.toast?.text == "标题已经又改过，没有恢复")
    }

    /// 纠错词库 (#75): fixing a word in a line is remembered, and the next transcript of any
    /// recording comes out corrected; the settings list shows and deletes it.
    @Test func correctedWordsFixLaterTranscripts() async throws {
        let f = try await DetailFixture()
        try f.library.saveTranscript(Transcript(recordingId: f.recording.id, engine: "t", language: "zh-CN",
                                                segments: [TranscriptSegment(startMs: 0, text: "汇款率还在排查")],
                                                createdAt: Date()))
        let fake = FakeTranscriber(result: .success([TranscriptSegment(startMs: 0, text: "汇款要加快")]))
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player,
                                         transcriber: fake)
        model.editLine(0, to: "回款率还在排查")
        #expect(model.transcript?.segments.first?.text == "回款率还在排查")
        #expect(model.toast?.text == "已修改，以后转写会自动改正这个词")

        let corrections = CorrectionsModel(library: f.library)
        #expect(corrections.corrections.map(\.right) == ["回款"])

        model.transcribe()
        await waitUntil("transcribed again") { model.transcript?.segments.first?.text == "回款要加快" }
        corrections.delete(try #require(corrections.corrections.first))
        #expect(corrections.corrections.isEmpty)
    }

    /// D1c: "移到文件夹" puts the recording in a folder, a new one or none.
    @Test func movesBetweenFolders() async throws {
        let f = try await DetailFixture()
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player)
        #expect(model.folderName == nil && model.folders.isEmpty)
        model.moveToNewFolder(named: "   ")
        #expect(model.folders.isEmpty)
        model.moveToNewFolder(named: "客户")
        #expect(model.folderName == "客户")
        #expect(model.toast?.text == "已移到「客户」")
        let other = try #require(try f.library.createFolder(named: "家里"))
        model.move(toFolder: other.id)
        #expect(model.folderName == "家里")
        #expect(try f.library.recording(id: f.recording.id)?.folderId == other.id)
        model.move(toFolder: nil)
        #expect(model.folderName == nil && model.toast?.text == "已移出文件夹")
    }

    /// #85: turning transcription on or off in settings applies to a page that is already open.
    @Test func transcriptionSwitchAppliesToAnOpenPage() async throws {
        let f = try await DetailFixture()
        let setting = SwitchSetting()
        let fake = FakeTranscriber(result: .success([TranscriptSegment(startMs: 0, text: "好")]))
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player,
                                         transcriberSource: { setting.on ? fake as any SpeechTranscribing : nil })
        #expect(!model.canTranscribe)
        setting.on = true
        #expect(model.canTranscribe)
        model.transcribe()
        await waitUntil("transcribed") { model.transcript != nil && !model.isTranscribing }
        setting.on = false
        #expect(!model.canTranscribe)
        #expect(model.transcript?.segments.first?.text == "好")
    }
}

/// The settings switch as the page reads it.
@MainActor
private final class SwitchSetting {
    var on = false
}

private struct FakeTranscriber: SpeechTranscribing {
    let result: Result<[TranscriptSegment], TranscriptionError>

    func transcribe(_ recording: Recording, language: String) async throws -> [TranscriptSegment] {
        try result.get()
    }
}

/// The user's own service on a phone with no connection.
private struct OfflineTranscriber: SpeechTranscribing {
    var engineName: String { "cloud" }
    var usesNetwork: Bool { true }

    func transcribe(_ recording: Recording, language: String) async throws -> [TranscriptSegment] {
        throw AssistantError.offline
    }
}

/// Answers every request with one chat completion carrying `content`; no network.
private final class CannedReply: URLProtocol {
    nonisolated(unsafe) static var content = ""

    static func session(_ content: String) -> URLSession {
        Self.content = content
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CannedReply.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = try? JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": Self.content]]],
        ])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 逐句润色 (#75) and 单句循环 (X20) on the detail page.
@MainActor
struct PolishAndLoopTests {
    /// The polished text replaces each line's and keeps its time; 恢复原文 brings the
    /// transcribed text back. The service is a stub on its own host, never the network.
    @Test func polishesAndRestores() async throws {
        let f = try await DetailFixture()
        let raw = [TranscriptSegment(startMs: 0, text: "嗯那个周三发布"), TranscriptSegment(startMs: 900, text: "嗯")]
        try f.library.saveTranscript(Transcript(recordingId: f.recording.id, engine: "t", language: "zh-CN",
                                                segments: raw, createdAt: Date()))
        let none = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player)
        #expect(!none.canPolish)

        let base = HostReply.register(#"{"lines": ["周三发布。", ""]}"#)
        let config = ServiceConfig(baseURL: base, model: "m", apiKey: "")
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player,
                                         assistant: AssistantConfigSource { config },
                                         polisher: Polisher(client: ChatClient(session: HostReply.session())))
        #expect(model.canPolish && model.transcript?.isPolished == false)
        model.polish()
        await waitUntil("polished") { model.transcript?.isPolished == true && !model.isPolishing }
        #expect(model.transcript?.segments == [TranscriptSegment(startMs: 0, text: "周三发布。"),
                                               TranscriptSegment(startMs: 900, text: "嗯")])
        #expect(model.toast?.text == "已润色，可以随时恢复原文")
        model.restoreOriginal()
        #expect(model.transcript?.segments == raw && model.transcript?.isPolished == false)
        #expect(model.toast?.text == "已恢复原文")
        #expect(try f.library.transcript(recordingId: f.recording.id)?.segments == raw)
    }

    /// G3 "SSE 流式": the sheet opens at once, empty and streaming, and ends with the reply
    /// (here from a service that does not stream); closing it clears it.
    @Test func rewriteOpensTheSheetAndFillsIt() async throws {
        let f = try await DetailFixture()
        try f.library.saveTranscript(Transcript(recordingId: f.recording.id, engine: "t", language: "zh-CN",
                                                segments: [TranscriptSegment(startMs: 0, text: "周三发布。")],
                                                createdAt: Date()))
        let base = HostReply.register("<think>想想</think>**周三**发布")
        let config = ServiceConfig(baseURL: base, model: "m", apiKey: "")
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player,
                                         assistant: AssistantConfigSource { config },
                                         summarizer: Summarizer(client: ChatClient(session: HostReply.session())))
        model.rewrite(.email)
        let opened = try #require(model.assistantOutput)
        #expect(opened.title == "会后邮件" && opened.text.isEmpty && opened.isStreaming)
        #expect(model.isAsking)
        await waitUntil("answered") { model.assistantOutput?.isStreaming == false && !model.isAsking }
        #expect(model.assistantOutput?.text == "**周三**发布")
        #expect(model.assistantOutput?.id == opened.id && model.assistantOutput?.isCutOff == false)
        model.assistantOutput = nil
        #expect(model.assistantOutput == nil)
    }

    /// v105 device acceptance: after a tag was deleted, regenerating the summary showed it again
    /// on the page until it was reopened. The page now shows the summary as stored.
    @Test func regeneratedSummaryKeepsADeletedTagOut() async throws {
        let f = try await DetailFixture()
        try f.library.saveTranscript(Transcript(recordingId: f.recording.id, engine: "t", language: "zh-CN",
                                                segments: [TranscriptSegment(startMs: 0, text: "周四发外部测试。")],
                                                createdAt: Date()))
        try f.library.deleteTag("外部测试")
        let reply = #"{"scene":"meeting","title":"发布","summary":"周四发外部测试。","tags":["外部测试","发布"]}"#
        let base = HostReply.register(reply)
        let config = ServiceConfig(baseURL: base, model: "m", apiKey: "")
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player,
                                         assistant: AssistantConfigSource { config },
                                         summarizer: Summarizer(client: ChatClient(session: HostReply.session())))
        model.summarize()
        await waitUntil("summarized") { model.summary != nil && !model.isSummarizing }
        #expect(model.summary?.tags == ["发布"])
        #expect(try f.library.summary(recordingId: f.recording.id)?.tags == ["发布"])
    }

    /// E2 文字文件: a text-only recording shows its text, has nothing to play, transcribe or
    /// export as audio, and never counts as missing its audio.
    @Test func textOnlyRecordingHasNoAudio() async throws {
        let f = try await DetailFixture()
        let text = try #require(try f.library.addTextRecording(text: "周三发布。\n测试通过以后上线。", title: "会议记录",
                                                               startedAt: Date()))
        let fake = FakeTranscriber(result: .success([]))
        let model = RecordingDetailModel(recordingId: text.id, library: f.library, player: f.player, transcriber: fake)
        #expect(!model.hasAudio && !model.audioMissing && !model.canTranscribe)
        #expect(model.transcript?.segments.count == 2)
        #expect(model.durationText == "文字" && model.sizeText == "")
        #expect(RecordingText.subtitle(text, deviceName: nil).hasSuffix("文字 · 导入"))
        model.togglePlay()
        model.play(from: try #require(model.transcript?.segments.first))
        model.toggleLoop(lineAt: 0)
        #expect(!model.isPlaying && !model.audioMissing && model.loopingIndex == nil)
        #expect(model.exportFile() == nil && model.audioMissing == false)
        #expect(model.exportMarkdown() != nil)
        RecordingExporter.cleanUp()
    }

    /// X20 单词分级: offered for a foreign transcript with a service; the list is kept, grouped
    /// from the hardest level down, and a word plays its line.
    @Test func listsWordsByLevel() async throws {
        let f = try await DetailFixture()
        try f.library.saveTranscript(Transcript(recordingId: f.recording.id, engine: "t", language: "en-US",
                                                segments: [TranscriptSegment(startMs: 0, text: "The rollout is next week."),
                                                           TranscriptSegment(startMs: 900, text: "We must mitigate the risk.")],
                                                createdAt: Date()))
        let none = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player)
        #expect(none.transcriptIsForeign && !none.canListWords)
        let reply = #"{"words":[{"word":"rollout","level":"B2","meaning":"上线","line":1},{"word":"mitigate","level":"C1","meaning":"缓解","line":2}]}"#
        let base = HostReply.register(reply)
        let config = ServiceConfig(baseURL: base, model: "m", apiKey: "")
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player,
                                         assistant: AssistantConfigSource { config },
                                         summarizer: Summarizer(client: ChatClient(session: HostReply.session())))
        #expect(model.canListWords && model.wordList == nil)
        model.listWords()
        await waitUntil("listed") { model.wordList != nil && !model.isListingWords }
        #expect(model.toast?.text == "找到 2 个生词")
        #expect(model.words(atLeast: .a1).map(\.level) == [.c1, .b2])
        #expect(model.words(atLeast: .c1).flatMap { $0.words.map(\.word) } == ["mitigate"])
        let reopened = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player)
        #expect(reopened.wordList?.words.count == 2)
        model.play(word: try #require(model.wordList?.words.last))
        await waitUntil("playing") { model.isPlaying }
        f.player.volume = 0
        model.leave()
        f.player.stop()
    }

    /// X20 难句解析: 「解释这一句」 opens the same sheet, titled for it; out of range does nothing.
    @Test func explainsALine() async throws {
        let f = try await DetailFixture()
        try f.library.saveTranscript(Transcript(recordingId: f.recording.id, engine: "t", language: "en-US",
                                                segments: [TranscriptSegment(startMs: 0, text: "Let's ship it.")],
                                                createdAt: Date()))
        let base = HostReply.register("我们发布吧。")
        let config = ServiceConfig(baseURL: base, model: "m", apiKey: "")
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player,
                                         assistant: AssistantConfigSource { config },
                                         summarizer: Summarizer(client: ChatClient(session: HostReply.session())))
        model.explainLine(3)
        #expect(model.assistantOutput == nil && !model.isAsking)
        model.explainLine(0)
        #expect(model.assistantOutput?.title == "解释这一句")
        await waitUntil("explained") { model.assistantOutput?.isStreaming == false && !model.isAsking }
        #expect(model.assistantOutput?.text == "我们发布吧。")
    }

    /// J1 思维导图: offered only with an outline; named like the other exports, after the page title.
    @Test func exportsTheMindMap() async throws {
        let f = try await DetailFixture()
        let none = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player)
        #expect(!none.canExportMindMap && none.exportMindMap() == nil)
        try f.library.saveSummary(Summary(recordingId: f.recording.id, scene: "meeting", title: "定发布日", summary: "s",
                                          sections: [], todos: [], tags: [], people: [],
                                          outline: [OutlineItem(title: "排期", points: ["周三"])], model: "m",
                                          createdAt: Date()))
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player)
        #expect(model.canExportMindMap)
        let url = try #require(model.exportMindMap())
        #expect(url.lastPathComponent == "11月7日 14.02.opml")
        #expect(try String(contentsOf: url, encoding: .utf8).contains(#"<outline text="周三"/>"#))
    }

    @Test func loopRangeAndSteps() {
        let starts = [0, 1_000, 2_500]
        #expect(RecordingDetailModel.loopRange(starts, index: 0, durationMs: 4_000) == 0..<1_000)
        #expect(RecordingDetailModel.loopRange(starts, index: 2, durationMs: 4_000) == 2_500..<4_000)
        #expect(RecordingDetailModel.loopRange(starts, index: 3, durationMs: 4_000) == nil)
        #expect(RecordingDetailModel.loopRange([0, 0], index: 0, durationMs: 4_000) == nil)
        let line = 1_000..<2_500
        #expect(RecordingDetailModel.loopStep(positionMs: 1_200, range: line, finished: false) == .wait)
        #expect(RecordingDetailModel.loopStep(positionMs: 2_500, range: line, finished: false) == .restart)
        #expect(RecordingDetailModel.loopStep(positionMs: 2_700, range: line, finished: false) == .restart)
        #expect(RecordingDetailModel.loopStep(positionMs: 0, range: line, finished: true) == .restart)
        // Far outside the line: something else moved the playhead.
        #expect(RecordingDetailModel.loopStep(positionMs: 9_000, range: line, finished: false) == .stop)
        #expect(RecordingDetailModel.loopStep(positionMs: 0, range: 3_000..<4_000, finished: false) == .stop)
    }

    /// The first line plays again from its start after reaching the second; playing another line
    /// or toggling the same one ends the loop.
    @Test func loopsALine() async throws {
        let f = try await DetailFixture()
        try f.library.saveTranscript(Transcript(recordingId: f.recording.id, engine: "t", language: "zh-CN",
                                                segments: [TranscriptSegment(startMs: 0, text: "一"),
                                                           TranscriptSegment(startMs: 800, text: "二")],
                                                createdAt: Date()))
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player)
        model.toggleLoop(lineAt: 0)
        #expect(model.loopingIndex == 0)
        await waitUntil("playing") { model.isPlaying }
        f.player.volume = 0
        await waitUntil("near the end of the line") { model.currentTime > 0.5 }
        await waitUntil("back at the start") { model.currentTime < 0.3 }
        #expect(model.loopingIndex == 0 && model.isPlaying)

        model.toggleLoop(lineAt: 0)
        #expect(model.loopingIndex == nil)
        model.toggleLoop(lineAt: 1)
        #expect(model.loopingIndex == 1)
        model.play(from: TranscriptSegment(startMs: 0, text: "一"))
        #expect(model.loopingIndex == nil)
        model.leave()
        f.player.stop()
    }
}

/// Answers each request with one chat completion, per host so parallel tests do not share it.
private final class HostReply: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: String] = [:]

    /// Registers `content` under a new host and returns a base URL on it.
    static func register(_ content: String) -> String {
        let host = "\(UUID().uuidString.lowercased()).stub.test"
        lock.lock()
        replies[host] = content
        lock.unlock()
        return "https://\(host)/v1"
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HostReply.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let content = request.url?.host.flatMap { Self.replies[$0] }
        Self.lock.unlock()
        guard let content, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let body = try? JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": content]]],
        ])
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
