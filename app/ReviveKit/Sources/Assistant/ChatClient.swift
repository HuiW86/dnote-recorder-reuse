// Minimal client for an OpenAI-compatible `/chat/completions` (ADR-009). This module is the one
// place in ReviveKit that uses the network; device modules never depend on it (CLAUDE.md rule 3).

import Foundation

/// What can go wrong talking to the user's service.
public enum AssistantError: Error, Equatable, Sendable {
    /// No usable address or model.
    case notConfigured
    /// The service answered with a status other than 200; the body is cut to 1000 characters.
    case http(Int, String)
    /// The service answered 200 but the reply could not be used.
    case badReply(String)
    /// No answer: offline, DNS, TLS, timeout.
    case unreachable(String)
}

extension AssistantError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没有设置 AI 服务。"
        case .http(let code, let body):
            return "AI 服务返回错误 \(code)：\(String(body.prefix(200)))"
        case .badReply(let why):
            return "AI 服务的回答看不懂：\(why)"
        case .unreachable(let why):
            return "连不上 AI 服务：\(why)"
        }
    }
}

public struct ChatClient: Sendable {
    public let session: URLSession
    public let timeout: TimeInterval

    /// Tests pass a session whose configuration routes requests to a `URLProtocol` stub.
    public init(session: URLSession = .shared, timeout: TimeInterval = 300) {
        self.session = session
        self.timeout = timeout
    }

    /// Sends one system and one user message and returns the reply text with any `<think>`
    /// block removed. `json` asks for `response_format: {"type": "json_object"}`.
    public func complete(_ config: ServiceConfig, system: String, user: String, json: Bool) async throws -> String {
        let request = try makeRequest(config, system: system, user: user, json: json, stream: false)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // A cancelled task (the user left the page) is not a network failure.
            if Task.isCancelled { throw CancellationError() }
            throw AssistantError.unreachable(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw AssistantError.http(code, String(String(decoding: data, as: UTF8.self).prefix(1000)))
        }
        guard let reply = try? JSONDecoder().decode(ReplyBody.self, from: data) else {
            throw AssistantError.badReply("不是 chat/completions 的格式")
        }
        guard let content = reply.choices.first?.message.content else {
            throw AssistantError.badReply("没有 choices")
        }
        return Self.stripThinking(content)
    }

    private func makeRequest(_ config: ServiceConfig, system: String, user: String, json: Bool,
                             stream: Bool) throws -> URLRequest {
        guard config.isComplete, let url = Self.endpoint(config.baseURL) else { throw AssistantError.notConfigured }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let body = RequestBody(
            model: config.model.trimmingCharacters(in: .whitespacesAndNewlines),
            temperature: 0.2,
            messages: [RequestBody.Message(role: "system", content: system),
                       RequestBody.Message(role: "user", content: user)],
            responseFormat: json ? RequestBody.ResponseFormat(type: "json_object") : nil,
            stream: stream ? true : nil)
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    // MARK: Streaming (features.md G3 "SSE 流式")

    /// The reply in pieces as the service writes it (`stream: true`, server-sent events). A
    /// service that ignores `stream` and answers with one JSON body is handed over in one piece.
    /// Pieces are raw: a `<think>` block may arrive in them; show `visibleText` of the sum.
    /// Cancelling the consuming task cancels the request.
    public func stream(_ config: ServiceConfig, system: String, user: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(config, system: system, user: user, json: false, stream: true)
                    try await read(request) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func read(_ request: URLRequest, onPiece: (String) -> Void) async throws {
        var reader = StreamReader()
        #if canImport(FoundationNetworking)
        // Linux Foundation has no `bytes(for:)`: read the whole body, then split it.
        let (data, response) = try await send(request)
        try Self.check(response, body: data)
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            if let piece = try reader.feed(String(line)) { onPiece(piece) }
            if reader.isDone { break }
        }
        #else
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AssistantError.unreachable(error.localizedDescription)
        }
        if (response as? HTTPURLResponse)?.statusCode != 200 {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 1000 { break }
            }
            try Self.check(response, body: body)
        }
        do {
            for try await line in bytes.lines {
                if let piece = try reader.feed(line) { onPiece(piece) }
                if reader.isDone { break }
            }
        } catch let error as AssistantError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AssistantError.unreachable(error.localizedDescription)
        }
        #endif
        if let whole = try reader.finish() { onPiece(whole) }
    }

    #if canImport(FoundationNetworking)
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AssistantError.unreachable(error.localizedDescription)
        }
    }
    #endif

    private static func check(_ response: URLResponse, body: Data) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw AssistantError.http(code, String(String(decoding: body, as: UTF8.self).prefix(1000)))
        }
    }

    /// What to show of a reply that is still arriving: closed `<think>` blocks removed, and an
    /// open one (the model is still thinking) cut off.
    public static func visibleText(_ text: String) -> String {
        var s = stripThinking(text)
        if let open = s.range(of: "<think>") { s = String(s[..<open.lowerBound]) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `<baseURL>/chat/completions`, with trailing slashes and spaces of the base removed. Nil
    /// unless the address is http or https with a host.
    public static func endpoint(_ baseURL: String) -> URL? {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t"))
        guard let url = URL(string: base + "/chat/completions"),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Some models put their reasoning in `<think>…</think>` before the answer; drop it.
    /// An unclosed `<think>` is left as is.
    public static func stripThinking(_ text: String) -> String {
        var s = text
        while let open = s.range(of: "<think>"),
              let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
            s.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct RequestBody: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
    }

    let model: String
    let temperature: Double
    let messages: [Message]
    /// Left out of the JSON when nil.
    let responseFormat: ResponseFormat?
    /// Left out of the JSON when nil (not streamed).
    let stream: Bool?

    enum CodingKeys: String, CodingKey {
        case model, temperature, messages, stream
        case responseFormat = "response_format"
    }
}

/// Reads a streamed reply line by line: `data: {...}` events with `choices[0].delta.content`,
/// ended by `data: [DONE]`. Comment lines and other fields are skipped. A reply with no events
/// at all is kept and read as one ordinary chat completion at the end.
struct StreamReader {
    private(set) var isDone = false
    private var sawEvent = false
    private var plain = ""

    /// The text a line adds, if any. Throws when an event carries the service's error.
    mutating func feed(_ line: String) throws -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else {
            if !sawEvent { plain += line + "\n" }
            return nil
        }
        sawEvent = true
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            isDone = true
            return nil
        }
        let data = Data(payload.utf8)
        if let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) {
            if let message = chunk.error?.message { throw AssistantError.badReply(message) }
            guard let piece = chunk.choices?.first?.delta?.content, !piece.isEmpty else { return nil }
            return piece
        }
        return nil
    }

    /// The whole reply when the service answered without events; nil after a streamed reply.
    func finish() throws -> String? {
        guard !sawEvent else { return nil }
        guard let reply = try? JSONDecoder().decode(ReplyBody.self, from: Data(plain.utf8)) else {
            throw AssistantError.badReply("不是 chat/completions 的格式")
        }
        guard let content = reply.choices.first?.message.content else {
            throw AssistantError.badReply("没有 choices")
        }
        return content
    }
}

private struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }

        let delta: Delta?
    }

    struct ErrorBody: Decodable {
        let message: String?
    }

    let choices: [Choice]?
    let error: ErrorBody?
}

private struct ReplyBody: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}
