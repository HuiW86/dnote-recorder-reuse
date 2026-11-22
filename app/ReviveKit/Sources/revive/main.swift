// `revive`: the library on the command line, and as an MCP server for AI assistants
// (features.md X19). Reads and adds to the Mac app's library; never deletes or edits a recording,
// never talks to a card, never uses the network.
//
//   revive overview | search <words…> | get <id> [--no-transcript] | todos
//   revive add-text [--title T] <file | ->
//   revive add-audio [--title T] <file>
//   revive mcp [--read-only]
//   common: --library <folder>   (default: the Mac app's library; also $REVIVE_LIBRARY)

import Foundation
import Library
import LibraryTools
#if canImport(Player)
import Player
#endif

let usage = """
    用法：revive [--library <文件夹>] <命令>
      overview                      录音库概况和最近的录音
      search <关键词…>              搜索标题、文字稿和纪要
      get <编号> [--no-transcript]  读一条录音（编号可以只给开头 8 位）
      todos                         未完成的待办
      add-text [--title 标题] <文件|->   把文字存成新的一条（- 表示从标准输入读）
      add-audio [--title 标题] <文件>    把音频文件存成新的一条
      mcp [--read-only]             作为 MCP 服务运行（标准输入输出），给 AI 助手用
    录音库默认是闻笺 Mac 版的（~/Library/Application Support/com.huiw86.revive.mac/library），
    也可以用环境变量 REVIVE_LIBRARY 指定。

    """

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// Pulls `--name value` out of the arguments.
func option(_ name: String, _ args: inout [String]) -> String? {
    guard let index = args.firstIndex(of: name) else { return nil }
    guard index + 1 < args.count else { fail("\(name) 后面要跟一个值\n\n" + usage, code: 2) }
    let value = args[index + 1]
    args.removeSubrange(index...(index + 1))
    return value
}

func flag(_ name: String, _ args: inout [String]) -> Bool {
    guard let index = args.firstIndex(of: name) else { return false }
    args.remove(at: index)
    return true
}

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || flag("--help", &args) || flag("-h", &args) {
    print(usage, terminator: "")
    exit(args.isEmpty ? 2 : 0)
}

let folder = option("--library", &args) ?? ProcessInfo.processInfo.environment["REVIVE_LIBRARY"]
let root = folder.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    ?? LibraryLocation.macApp
let database: AppDatabase
do {
    guard let opened = try AppDatabase.existing(directory: root) else {
        fail("找不到闻笺的录音库：\(root.path)\n先打开一次闻笺 Mac 版，或用 --library 指定录音库所在的文件夹。")
    }
    database = opened
} catch {
    fail("打不开录音库 \(root.path)：\(error)")
}
let library: RecordingLibrary
do {
    library = RecordingLibrary(database: database, store: try AudioStore(root: root))
} catch {
    fail("打不开录音库的音频文件夹 \(root.path)：\(error)")
}

let command = args.removeFirst()
let readOnlyFlag = command == "mcp" && flag("--read-only", &args)
let newer = (try? database.isNewerThanThisBuild()) ?? false
let readOnlyReason: String? = newer ? "闻笺比这个 revive 新，请换成同一版本的 revive 再存入"
    : readOnlyFlag ? "以 --read-only 启动" : nil
#if canImport(Player)
let importAudio: (@Sendable (URL) async throws -> ImportedAudio)? = { url in
    let prepared = try await AudioImporter.prepare(url)
    return ImportedAudio(file: prepared.file, durationMs: prepared.durationMs)
}
#else
let importAudio: (@Sendable (URL) async throws -> ImportedAudio)? = nil
#endif
let tools = LibraryTools(library: library, importAudio: importAudio, readOnlyReason: readOnlyReason)

@MainActor
func run(_ body: () async throws -> String) async {
    do {
        print(try await body())
    } catch {
        fail((error as? LocalizedError)?.errorDescription ?? String(describing: error))
    }
}

switch command {
case "overview":
    await run { try tools.overview() }
case "search":
    guard !args.isEmpty else { fail("search 后面要跟关键词\n\n" + usage, code: 2) }
    await run { try tools.search(args.joined(separator: " ")) }
case "get":
    let noTranscript = flag("--no-transcript", &args)
    guard let id = args.first else { fail("get 后面要跟录音编号\n\n" + usage, code: 2) }
    await run { try tools.get(id, transcript: !noTranscript) }
case "todos":
    await run { try tools.todos() }
case "add-text":
    let title = option("--title", &args)
    guard let source = args.first else { fail("add-text 后面要跟文件，或 - 表示标准输入\n\n" + usage, code: 2) }
    let data = source == "-" ? FileHandle.standardInput.readDataToEndOfFile()
        : (FileManager.default.contents(atPath: (source as NSString).expandingTildeInPath) ?? Data())
    guard let text = TextImport.decode(data) else { fail("读不出文字：\(source)") }
    let name = title ?? (source == "-" ? nil : URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent)
    await run { try tools.addText(text, title: name) }
case "add-audio":
    let title = option("--title", &args)
    guard let path = args.first else { fail("add-audio 后面要跟音频文件\n\n" + usage, code: 2) }
    await run { try await tools.addAudio(path: path, title: title) }
case "mcp":
    // stdout carries the protocol only; anything for a person goes to stderr.
    FileHandle.standardError.write(Data("revive mcp：录音库 \(root.path)\(readOnlyReason.map { "（只读：\($0)）" } ?? "")\n".utf8))
    let server = MCPServer(tools: tools)
    while let line = readLine(strippingNewline: true) {
        if let reply = await server.handle(line) {
            // Unbuffered, so the client gets each reply as soon as it is written.
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
    }
default:
    fail("不认识的命令：\(command)\n\n" + usage, code: 2)
}
