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
        guard config.isComplete, let url = Self.endpoint(config.baseURL) else { throw AssistantError.notConfigured }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let body = RequestBody(
            model: config.model.trimmingCharacters(in: .whitespacesAndNewlines),
            temperature: 0.2,
            messages: [RequestBody.Message(role: "system", content: system),
                       RequestBody.Message(role: "user", content: user)],
            responseFormat: json ? RequestBody.ResponseFormat(type: "json_object") : nil)
        request.httpBody = try JSONEncoder().encode(body)

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

    enum CodingKeys: String, CodingKey {
        case model, temperature, messages
        case responseFormat = "response_format"
    }
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
