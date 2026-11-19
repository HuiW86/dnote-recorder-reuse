// Rewriting a recording into something to publish or send (features.md X15), and asking a
// question about it (G3, single recording). Both go to the user's own service (ADR-009), with
// the recording's text only. Prompts adapted from andyhuo520/beanpod (commit 0d00fab,
// Shared/Domain.swift `RewriteTemplate`, Shared/Analyzer.swift `rewrite` and `answer`), MIT.

import Foundation
import Library

public enum RewriteStyle: String, CaseIterable, Sendable, Identifiable {
    case voiceover, shortVideo, thread, article, email, bilingual

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .voiceover: "口播稿"
        case .shortVideo: "短视频脚本"
        case .thread: "社交媒体长帖"
        case .article: "公众号文章"
        case .email: "会后邮件"
        case .bilingual: "中英对照"
        }
    }

    public var instruction: String {
        switch self {
        case .voiceover: "改写成一篇可以直接对着镜头念的口播稿：第一人称，口语但干净利落，开头三句内抛出最抓人的点，短句为主，每段不超过三句，结尾有一句收束。不要小标题，不要表情符号。"
        case .shortVideo: "改写成一条 60 秒左右的短视频脚本：先给一句钩子，然后按「画面 / 口播」两栏逐镜头写，5 到 8 个镜头，最后给一句行动号召。"
        case .thread: "改写成一条适合发在社交媒体上的长帖：开头一句话点明观点，中间分 3 到 5 个要点，每点两三句，语气直接，有具体细节和数字，结尾一句总结。"
        case .article: "改写成一篇公众号文章：有标题，有 3 到 4 个小标题分段，开头用一个场景或问题引入，行文连贯，保留原话里的具体例子。"
        case .email: "改写成一封会后跟进邮件：称呼、一句话说明来意、分点列出达成的结论和各自的待办（带负责人和时间）、礼貌收尾。简洁。"
        // X15 双语对照 (beanpod Shared/Translate.swift): Chinese and English paragraph by paragraph.
        case .bilingual: "整理成中英对照：先把内容整理成通顺的段落，然后每段先写中文、紧接着写对应的英文译文，两种语言意思一致，人名、数字、术语保持一致；原文是英文时同样先中文后英文。不加标题以外的说明。"
        }
    }
}

public struct Rewriter: Sendable {
    /// Text beyond this is cut, so one request stays within common context limits.
    public static let maxMaterial = 24_000

    public let client: ChatClient

    public init(client: ChatClient = ChatClient()) {
        self.client = client
    }

    /// What the service reads: the summary when there is one, then the transcript, cut to
    /// `maxMaterial` characters.
    public static func material(summary: Summary?, transcript: Transcript?) -> String {
        var parts: [String] = []
        if let summary {
            var text = "【纪要】\n" + summary.summary
            for section in summary.sections where !section.items.isEmpty {
                text += "\n\(section.heading)：\n" + section.items.map { "- \($0)" }.joined(separator: "\n")
            }
            parts.append(text)
        }
        if let transcript { parts.append("【文字稿】\n" + Summarizer.material(from: transcript)) }
        return String(parts.joined(separator: "\n\n").prefix(maxMaterial))
    }

    public func rewrite(material: String, style: RewriteStyle, extra: String = "",
                        config: ServiceConfig) async throws -> String {
        let extraLine = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        let system = """
            你是一位文字编辑。下面是一段录音的内容，请按要求改写。
            要求：\(style.instruction)\(extraLine.isEmpty ? "" : "\n补充要求：\(extraLine)")
            只用录音里有的事实、观点和例子，不要编造数据或经历。录音里的口语垫词不要带进成品。
            直接输出成品，不要解释你做了什么。用简体中文。
            """
        let reply = try await client.complete(config, system: system, user: material, json: false)
        guard !reply.isEmpty else { throw AssistantError.badReply("回复是空的") }
        return reply
    }

    public func answer(question: String, material: String, config: ServiceConfig) async throws -> String {
        let system = """
            你根据用户自己的这条录音回答问题。只用下面给出的材料，材料里没有就直说没有记录到，不要编。
            回答简洁，用提问所用的语言回答。
            """
        let reply = try await client.complete(config, system: system,
                                              user: "材料：\n\(material)\n\n问题：\(question)", json: false)
        guard !reply.isEmpty else { throw AssistantError.badReply("回复是空的") }
        return reply
    }
}
