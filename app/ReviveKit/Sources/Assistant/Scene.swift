// Scene taxonomy for summaries (features.md G2a, #68).
//
// Adapted from andyhuo520/beanpod, commit 0d00fab, Shared/Domain.swift (enum `Scene`),
// MIT License, Copyright (c) 2026 berryxia. See NOTICE at the repository root.
// Changes: names are plain Chinese strings (no localization lookup), no icons or colors.
//
// Named `RecordingScene`, not `Scene`, so the app shell can import this module next to SwiftUI,
// whose `Scene` protocol the App body uses.

import Foundation

/// What kind of recording this is; decides which headed sections the summary has.
/// The raw value is the code the model answers with and the one stored in `Summary.scene`.
public enum RecordingScene: String, CaseIterable, Codable, Sendable, Identifiable {
    case meeting, interview, sales, talk, call, media, conference, lesson, memo, other

    public var id: String { rawValue }

    /// Display name, also used for the model (prompts are always Simplified Chinese).
    public var name: String {
        switch self {
        case .meeting: "会议"
        case .interview: "访谈"
        case .sales: "销售"
        case .talk: "沟通"
        case .call: "电话"
        case .media: "自媒体"
        case .conference: "大会"
        case .lesson: "课程"
        case .memo: "灵感"
        case .other: "其他"
        }
    }

    /// One sentence the model uses to tell the scenes apart.
    public var definition: String {
        switch self {
        case .meeting: "多人围绕议题讨论并形成决定的内部会议、例会、评审"
        case .interview: "一方提问一方回答：采访、用户访谈、面试、调研"
        case .sales: "向客户介绍产品、谈价格、处理异议、推进成交"
        case .talk: "两三个人之间的交流：一对一、汇报、谈心、协商"
        case .call: "电话或语音通话，通常较短、目的单一"
        case .media: "为发布内容而录：口播、选题讨论、脚本、播客录制"
        case .conference: "一人对多人的公开演讲：发布会、论坛、行业大会"
        case .lesson: "讲课、培训、讲座、读书分享等教学内容"
        case .memo: "一个人自言自语记想法、备忘、灵感"
        case .other: "以上都不像"
        }
    }

    /// Section headings a summary of this scene uses.
    public var headings: [String] {
        switch self {
        case .meeting: ["结论与决定", "讨论要点", "分歧与风险"]
        case .interview: ["核心观点", "原话金句", "值得追问"]
        case .sales: ["客户需求", "顾虑与异议", "预算与决策人", "下一步"]
        case .talk: ["达成的共识", "没谈拢的地方", "对方的诉求"]
        case .call: ["来电目的", "说定的事"]
        case .media: ["选题与角度", "可用金句", "可剪片段"]
        case .conference: ["演讲主题", "核心观点", "数据与案例"]
        case .lesson: ["知识点", "例子与方法", "没讲透的地方"]
        case .memo: ["想法", "可以怎么做"]
        case .other: ["要点"]
        }
    }

    /// Words the keyword fallback counts when no model is configured.
    public var keywords: [String] {
        switch self {
        case .meeting: ["会议", "议题", "同步一下", "各位", "排期", "评审", "周会", "对齐", "散会"]
        case .interview: ["采访", "访谈", "请问您", "能不能分享", "您怎么看", "面试", "自我介绍"]
        case .sales: ["报价", "价格", "合同", "折扣", "预算", "试用", "签约", "席位", "客户", "优惠", "采购"]
        case .talk: ["我觉得", "你怎么想", "聊一下", "反馈", "沟通一下"]
        case .call: ["喂", "您好我是", "电话", "回头打给", "挂了", "拜拜"]
        case .media: ["口播", "选题", "脚本", "粉丝", "这期视频", "播放量", "封面", "大家好我是", "点赞", "关注"]
        case .conference: ["各位来宾", "发布会", "大会", "今天很荣幸", "演讲", "论坛", "嘉宾"]
        case .lesson: ["同学们", "这节课", "知识点", "作业", "考试", "讲到", "课程", "培训"]
        case .memo: ["记一下", "备忘", "突然想到", "提醒自己", "想法是"]
        case .other: []
        }
    }
}
