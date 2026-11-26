import CoreFoundation
import Foundation

/// The Model Context Protocol over stdio (features.md X19): one JSON-RPC 2.0 message per line in,
/// one per line out. Implements `initialize`, `ping`, `tools/list` and `tools/call`; everything
/// the tools return is text. An assistant app (Claude Desktop, Cursor…) starts `revive mcp` and
/// talks to it; nothing here opens a network connection.
@MainActor
public final class MCPServer {
    public static let serverName = "wenjian"
    public static let serverVersion = "0.1.0"
    /// Newest first; a client asking for one of these gets it echoed back.
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let tools: LibraryTools

    public init(tools: LibraryTools) {
        self.tools = tools
    }

    /// The reply to one line, or nil for a notification (or an empty line).
    public func handle(_ line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              let message = object as? [String: Any] else {
            return encode(error: -32700, "Parse error", id: NSNull())
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            // A response to something we never sent, or not JSON-RPC at all.
            return id == nil ? nil : encode(error: -32600, "Invalid Request", id: id!)
        }
        // Notifications (no id) get no reply: notifications/initialized, cancelled, …
        guard let id else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            let version = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
            return encode(result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": Self.serverName, "title": "闻笺录音库", "version": Self.serverVersion],
                "instructions": Self.instructions,
            ], id: id)
        case "ping":
            return encode(result: [:], id: id)
        case "tools/list":
            return encode(result: ["tools": toolList()], id: id)
        case "tools/call":
            guard let name = params["name"] as? String else {
                return encode(error: -32602, "Invalid params: missing tool name", id: id)
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard toolList().contains(where: { $0["name"] as? String == name }) else {
                return encode(error: -32602, "Unknown tool: \(name)", id: id)
            }
            do {
                let text = try await call(name, arguments)
                return encode(result: ["content": [["type": "text", "text": text]], "isError": false], id: id)
            } catch {
                // Tool failures go back as a result the model can read, not as a protocol error.
                let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                return encode(result: ["content": [["type": "text", "text": text]], "isError": true], id: id)
            }
        default:
            return encode(error: -32601, "Method not found: \(method)", id: id)
        }
    }

    static let instructions = """
        闻笺的录音库：录音卡同步来的、手机录的和导入的录音，以及它们的文字稿、纪要和待办。\
        先用 search_recordings 或 library_overview 找到录音的编号，再用 get_recording 读全文。\
        存入的文字或音频会成为录音库里新的一条，不会改动或删除已有的录音。
        """

    // MARK: Tools

    func toolList() -> [[String: Any]] {
        var list: [[String: Any]] = [
            tool("search_recordings", "按关键词搜索录音的标题、文字稿和纪要（多个词用空格分开，都要出现），返回编号、时间、标题，最新的在前。",
                 properties: ["query": ["type": "string", "description": "关键词"],
                              "limit": ["type": "integer", "description": "最多返回几条，默认 20", "minimum": 1]],
                 required: ["query"], readOnly: true),
            tool("get_recording", "读一条录音：时间、来源、标签、摘要、要点、待办、大纲、金句和带时间的文字稿。",
                 properties: ["id": ["type": "string", "description": "录音编号，可以只给开头 8 位"],
                              "include_transcript": ["type": "boolean", "description": "是否附上文字稿，默认是"]],
                 required: ["id"], readOnly: true),
            tool("list_todos", "列出所有录音纪要里还没完成的待办，按录音分组，最新的录音在前。",
                 properties: [:], required: [], readOnly: true),
            tool("library_overview", "录音库概况：各来源的条数、未完成的待办数、还没转文字的条数、常用标签和最近的录音。",
                 properties: ["recent": ["type": "integer", "description": "列出最近几条录音，默认 10", "minimum": 1]],
                 required: [], readOnly: true),
        ]
        if tools.canWrite {
            list.append(tool("add_text_note", "把一段文字存成录音库里新的一条（没有音频，文字按段落成为文字稿）。",
                             properties: ["text": ["type": "string", "description": "要存的文字"],
                                          "title": ["type": "string", "description": "标题；不给就用当前时间"]],
                             required: ["text"], readOnly: false))
        }
        if tools.canAddAudio {
            list.append(tool("add_audio_file", "把这台电脑上的一个音频文件存成录音库里新的一条（来源记为「导入」）。",
                             properties: ["path": ["type": "string", "description": "音频文件的完整路径"],
                                          "title": ["type": "string", "description": "标题；不给就用文件名"]],
                             required: ["path"], readOnly: false))
        }
        return list
    }

    private func tool(_ name: String, _ description: String, properties: [String: Any], required: [String],
                      readOnly: Bool) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required],
            // Hints only: adding never changes or removes an existing recording.
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "idempotentHint": readOnly,
                            "openWorldHint": false],
        ]
    }

    private func call(_ name: String, _ arguments: [String: Any]) async throws -> String {
        switch name {
        case "search_recordings":
            return try tools.search(try string("query", arguments), limit: int("limit", arguments) ?? 20)
        case "get_recording":
            return try tools.get(try string("id", arguments), transcript: arguments["include_transcript"] as? Bool ?? true)
        case "list_todos":
            return try tools.todos()
        case "library_overview":
            return try tools.overview(recent: int("recent", arguments) ?? 10)
        case "add_text_note":
            return try tools.addText(try string("text", arguments), title: arguments["title"] as? String)
        case "add_audio_file":
            return try await tools.addAudio(path: try string("path", arguments), title: arguments["title"] as? String)
        default:
            throw ArgumentError("没有这个工具：\(name)")
        }
    }

    private struct ArgumentError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    private func string(_ key: String, _ arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArgumentError("缺少参数 \(key)")
        }
        return value
    }

    private func int(_ key: String, _ arguments: [String: Any]) throws -> Int? {
        guard let raw = arguments[key] else { return nil }
        let value: Int?
        if let text = raw as? String {
            value = Int(text)
        } else if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            value = Int(exactly: number)
        } else {
            value = nil
        }
        guard let value, value >= 1 else { throw ArgumentError("参数 \(key) 须为正整数") }
        return value
    }

    // MARK: JSON-RPC

    private func encode(result: [String: Any], id: Any) -> String {
        serialize(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(error code: Int, _ message: String, id: Any) -> String {
        serialize(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// One line: no pretty-printing, so a newline in the text is escaped, never literal.
    private func serialize(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
