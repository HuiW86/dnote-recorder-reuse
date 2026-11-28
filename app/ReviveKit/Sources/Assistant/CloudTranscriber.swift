// Transcription by the user's own service (features.md X11, ADR-009): the recording's audio is
// uploaded as M4A to an OpenAI-compatible `/audio/transcriptions`. Unlike summaries, the audio
// leaves the phone here, so the app only offers it where the user turned it on and says so.

import Foundation
import Library
import Player
import Transcription

public struct CloudTranscriber: SpeechTranscribing {
    public static let engineName = "cloud"
    public var engineName: String { Self.engineName }
    public var usesNetwork: Bool { true }
    /// Most providers refuse uploads above 25 MB; stay under it.
    public static let maxUploadBytes = 24 * 1024 * 1024

    private let library: RecordingLibrary
    private let config: ServiceConfig
    private let session: URLSession

    /// `config.model` is the transcription model, such as "whisper-1"; address and key are the
    /// user's service.
    public init(library: RecordingLibrary, config: ServiceConfig, session: URLSession = .shared) {
        self.library = library
        self.config = config
        self.session = session
    }

    public func transcribe(_ recording: Recording, language: String) async throws -> [TranscriptSegment] {
        guard config.isComplete, let url = Self.endpoint(config.baseURL) else {
            throw TranscriptionError.failed("没有设置转写服务")
        }
        let file: URL
        do {
            // Its own directory: `RecordingExporter.cleanUp` empties the shared one when a share sheet closes.
            file = try await RecordingExporter.exportM4A(
                for: recording, library: library,
                in: FileManager.default.temporaryDirectory.appendingPathComponent("cloud-transcription", isDirectory: true))
        } catch PlayerError.audioMissing {
            throw TranscriptionError.audioMissing
        } catch {
            throw TranscriptionError.failed("decode: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let audio = try Self.readUpload(file)
        // Ask for sentence timings; a service that does not know the option gets a plain request.
        do {
            return try await send(url: url, audio: audio, language: language, detailed: true,
                                  durationMs: recording.durationMs)
        } catch TranscriptionError.failed(let why) where why.hasPrefix("http 400") || why.hasPrefix("http 422") {
            return try await send(url: url, audio: audio, language: language, detailed: false,
                                  durationMs: recording.durationMs)
        }
    }

    static func readUpload(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let tooLarge = TranscriptionError.failed("录音太长，超过服务允许的上传大小")
        let size = try file.seekToEnd()
        guard size <= UInt64(maxUploadBytes) else { throw tooLarge }
        try file.seek(toOffset: 0)
        var audio = Data()
        audio.reserveCapacity(Int(size))
        // Keep the bound even if the file grows after the initial size check.
        while let chunk = try file.read(upToCount: min(256 * 1024, maxUploadBytes - audio.count + 1)),
              !chunk.isEmpty {
            guard chunk.count <= maxUploadBytes - audio.count else { throw tooLarge }
            audio.append(chunk)
        }
        return audio
    }

    private func send(url: URL, audio: Data, language: String, detailed: Bool,
                      durationMs: Int) async throws -> [TranscriptSegment] {
        let boundary = "revive-\(UUID().uuidString)"
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        var fields = [("model", config.model.trimmingCharacters(in: .whitespacesAndNewlines))]
        if let code = language.split(separator: "-").first, !code.isEmpty { fields.append(("language", String(code))) }
        if detailed { fields.append(("response_format", "verbose_json")) }
        request.httpBody = Self.multipartBody(boundary: boundary, fields: fields, fileName: "audio.m4a",
                                              mimeType: "audio/mp4", file: audio)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // No connection reads as advice (AssistantError.offline); anything else stays a failure.
            let network = AssistantError.network(error)
            if network == .offline { throw network }
            throw TranscriptionError.failed("连不上转写服务：\(error.localizedDescription)")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw TranscriptionError.failed("http \(code) \(String(String(decoding: data, as: UTF8.self).prefix(300)))")
        }
        let segments = try Self.segments(from: data, durationMs: durationMs)
        guard !segments.isEmpty else { throw TranscriptionError.noSpeech }
        return segments
    }

    /// `<baseURL>/audio/transcriptions`, under the same rules as the chat endpoint.
    public static func endpoint(_ baseURL: String) -> URL? {
        guard let chat = ChatClient.endpoint(baseURL) else { return nil }
        return chat.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("audio").appendingPathComponent("transcriptions")
    }

    public static func multipartBody(boundary: String, fields: [(String, String)], fileName: String,
                                     mimeType: String, file: Data) -> Data {
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
        for (name, value) in fields {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"\(name)\"")
            line("")
            line(value)
        }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"")
        line("Content-Type: \(mimeType)")
        line("")
        body.append(file)
        line("")
        line("--\(boundary)--")
        return body
    }

    /// Sentences from the reply. With `segments` (verbose_json) their start times are used; with
    /// only `text`, the text is split at sentence ends and start times are estimated from the
    /// position in the text, spread over `durationMs`.
    public static func segments(from data: Data, durationMs: Int) throws -> [TranscriptSegment] {
        struct Reply: Decodable {
            struct Segment: Decodable {
                let start: Double?
                let text: String
            }
            let text: String?
            let segments: [Segment]?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw TranscriptionError.failed("转写服务的回复看不懂")
        }
        if let segments = reply.segments, !segments.isEmpty {
            return segments.compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(startMs: max(0, Int((segment.start ?? 0) * 1000)), text: text)
            }
        }
        let text = (reply.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if "。！？!?；;\n".contains(character) {
                sentences.append(current)
                current = ""
            }
        }
        sentences.append(current)
        let parts = sentences.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let total = max(1, parts.reduce(0) { $0 + $1.count })
        var before = 0
        return parts.map { part in
            defer { before += part.count }
            return TranscriptSegment(startMs: durationMs * before / total, text: part)
        }
    }
}
