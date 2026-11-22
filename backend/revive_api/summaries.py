"""Transcript -> summary, the same way the app does it with the user's own service (ADR-009: one
source of prompts). A line-for-line port of app/ReviveKit/Sources/Assistant/Scene.swift and
Summarizer.swift, which are the source; tests/test_summaries.py checks the prompts against the
fixtures the app's PromptFixtureTests checks too (app/ReviveKit/Tests/AssistantTests/Fixtures/
prompts), so the two cannot drift apart unnoticed.

The prompts and reply rules are adapted from andyhuo520/beanpod, commit 0d00fab, Shared/Analyzer.swift
and Shared/Domain.swift, MIT License, Copyright (c) 2026 berryxia (see NOTICE at the repository root),
by way of the app's Swift code.

Lengths count characters (code points). Swift counts grapheme clusters; for Chinese text they are
the same, and the difference elsewhere (emoji with modifiers) only moves a cut by a character."""

import json
from dataclasses import dataclass, field


@dataclass(frozen=True)
class Scene:
    code: str
    name: str
    definition: str
    headings: tuple[str, ...]


# The order matters: it is the order of the prompt's scene guide (RecordingScene.allCases).
SCENES: tuple[Scene, ...] = (
    Scene(
        "meeting", "会议", "多人围绕议题讨论并形成决定的内部会议、例会、评审", ("结论与决定", "讨论要点", "分歧与风险")
    ),
    Scene("interview", "访谈", "一方提问一方回答：采访、用户访谈、面试、调研", ("核心观点", "原话金句", "值得追问")),
    Scene(
        "sales",
        "销售",
        "向客户介绍产品、谈价格、处理异议、推进成交",
        ("客户需求", "顾虑与异议", "预算与决策人", "下一步"),
    ),
    Scene("talk", "沟通", "两三个人之间的交流：一对一、汇报、谈心、协商", ("达成的共识", "没谈拢的地方", "对方的诉求")),
    Scene("call", "电话", "电话或语音通话，通常较短、目的单一", ("来电目的", "说定的事")),
    Scene("media", "自媒体", "为发布内容而录：口播、选题讨论、脚本、播客录制", ("选题与角度", "可用金句", "可剪片段")),
    Scene("conference", "大会", "一人对多人的公开演讲：发布会、论坛、行业大会", ("演讲主题", "核心观点", "数据与案例")),
    Scene("lesson", "课程", "讲课、培训、讲座、读书分享等教学内容", ("知识点", "例子与方法", "没讲透的地方")),
    Scene("memo", "灵感", "一个人自言自语记想法、备忘、灵感", ("想法", "可以怎么做")),
    Scene("other", "其他", "以上都不像", ("要点",)),
)
BY_CODE = {s.code: s for s in SCENES}

LONG_TRANSCRIPT_THRESHOLD = 9000
CHUNK_SIZE = 6000
PROFESSION_LIMIT = 40
SENTENCE_ENDS = "。！？!?\n"


# MARK: Prompts


def chunk_prompt(index: int) -> str:
    return (
        f"你在帮人整理一段长录音的文字稿。这是其中第 {index} 段。"
        "用简体中文列出这一段里的事实、观点、数字、人名、约定和待办，每条一行，不要评论，不要编造。"
    )


RETITLE_PROMPT = (
    "你在给一段录音起标题。换一个角度重新起一个：可以突出结论、人物、数字或要做的事，"
    "但不要和「现在的标题」相同或只改几个字。不超过 18 个字，简体中文，只写录音里真有的内容。\n"
    '只输出一个 JSON 对象，不要任何别的文字：{"title": "新标题"}'
)


def profession_rule(job: str) -> str:
    return (
        f"用户的职业是「{job}」。职业只影响先写哪些要点、用什么说法：把这个职业会关心的结论、数字、风险和后续动作排在前面，"
        "用这个行业惯用的叫法。\n"
        "职业不改变内容：每一条都必须能在文字稿里找到对应的原话。不要推断态度、立场或共识，"
        "不要写「没有异议」「已达成一致」「已确认」「无反对意见」这类原文没有明说的结论；"
        "原文没说的就不写，不要因为职业补充录音里没有的东西。"
    )


def system_prompt(fixed_scene: str | None, profession: str = "") -> str:
    """The summary prompt; `fixed_scene` is a scene code the user picked, None lets the model choose."""
    guide = "\n".join(f"- {s.code}（{s.name}）：{s.definition}。栏目：{'、'.join(s.headings)}" for s in SCENES)
    scene_rule = f"场景已经确定是 {fixed_scene}，不要改。" if fixed_scene else "先判断场景，从下面的英文代号里选一个。"
    base = f"""你是录音整理助手。整理时抓住结论、事实和后续要做的事。

{scene_rule}
{guide}

然后只输出一个 JSON 对象，不要任何别的文字：
{{
  "scene": "场景的英文代号",
  "title": "一句话标题，不超过 18 个字，说清这段录音是什么事",
  "summary": "两到四句话的摘要，先说结论",
  "sections": [{{"heading": "所选场景的栏目名", "items": ["这一栏下的要点，每条一句完整的话"]}}],
  "todos": ["后续要做的事，写清谁、做什么、什么时候；没有就给空数组"],
  "tags": ["2 到 5 个主题标签，名词，不带 #"],
  "people": ["出现的人名或称呼；没有就给空数组"],
  "outline": [{{"title": "按录音里谈到的先后，一个话题一条", "points": ["这个话题下的要点，每条一句"]}}],
  "quotes": ["录音里值得记住的原话，一字不改地摘出来；没有就给空数组"]
}}

要求：
- sections 必须使用所选场景的栏目名，某一栏没有内容就不要输出这一栏。
- outline 按时间顺序，3 到 7 个话题；quotes 最多 5 句，必须是文字稿里的原话。
- 只写录音里真有的内容。数字、金额、日期、人名照原样写，听不清的不要猜。
- 全部用简体中文。"""
    job = profession.strip()[:PROFESSION_LIMIT]
    return base + "\n\n" + profession_rule(job) if job else base


def prompt_duration(ms: int) -> str:
    """ "45 秒", "12 分钟", "1 小时 5 分"."""
    seconds = max(0, ms) // 1000
    minutes = seconds // 60
    if minutes >= 60:
        hours, rest = divmod(minutes, 60)
        return f"{hours} 小时" if rest == 0 else f"{hours} 小时 {rest} 分"
    return f"{minutes} 分钟" if minutes >= 1 else f"{seconds} 秒"


def user_message(material: str, duration_ms: int) -> str:
    return f"录音时长：{prompt_duration(duration_ms)}\n\n文字稿：\n{material}"


def chunk_notes(notes: list[str]) -> str:
    return "\n\n".join(f"【第 {i} 段】\n{note}" for i, note in enumerate(notes, 1))


def material(segments: list[dict]) -> str:
    """A stored transcript's text, one segment per line."""
    return "\n".join(s["text"] for s in segments)


def split(text: str, size: int) -> list[str]:
    """Pieces of at most `size` characters, each ending at the last sentence end within the final
    quarter of the piece (at most 400 characters back), else cut at `size`."""
    size = max(1, size)
    pieces = []
    rest = text
    while len(rest) > size:
        window_start = size - min(400, size // 4)
        end = size
        for i in range(size - 1, window_start - 1, -1):
            if rest[i] in SENTENCE_ENDS:
                end = i + 1
                break
        pieces.append(rest[:end])
        rest = rest[end:]
    if rest:
        pieces.append(rest)
    return pieces


# MARK: Reply


class BadReply(Exception):
    pass


@dataclass
class Draft:
    scene: str
    title: str
    summary: str
    sections: list[dict] = field(default_factory=list)
    todos: list[str] = field(default_factory=list)
    tags: list[str] = field(default_factory=list)
    people: list[str] = field(default_factory=list)
    outline: list[dict] = field(default_factory=list)
    quotes: list[str] = field(default_factory=list)

    def content(self) -> dict:
        return {
            "title": self.title,
            "summary": self.summary,
            "sections": self.sections,
            "todos": self.todos,
            "tags": self.tags,
            "people": self.people,
            "outline": self.outline,
            "quotes": self.quotes,
        }


def strip_thinking(text: str) -> str:
    """Removes closed <think>…</think> blocks some models put before the answer."""
    while True:
        open_at = text.find("<think>")
        if open_at < 0:
            break
        close_at = text.find("</think>", open_at + len("<think>"))
        if close_at < 0:
            break
        text = text[:open_at] + text[close_at + len("</think>") :]
    return text.strip()


def _trimmed(value) -> str:
    return value.strip() if isinstance(value, str) else ""


def _strings(value) -> list[str]:
    if not isinstance(value, list):
        return []
    return [v.strip() for v in value if isinstance(v, str) and v.strip()]


def parse(reply: str, fixed_scene: str | None) -> Draft:
    """Reads the model's JSON tolerantly, with the app's caps (Summarizer.parse)."""
    text = strip_thinking(reply)
    start, end = text.find("{"), text.rfind("}")
    try:
        if start < 0 or end <= start:
            raise ValueError
        obj = json.loads(text[start : end + 1])
        if not isinstance(obj, dict):
            raise ValueError
    except ValueError as error:
        raise BadReply("不是 JSON") from error
    summary = _trimmed(obj.get("summary"))
    if not summary:
        raise BadReply("没有摘要")
    said = _trimmed(obj.get("scene")).lower()
    scene = fixed_scene or (said if said in BY_CODE else next((s.code for s in SCENES if s.name == said), "other"))
    sections = []
    for entry in obj.get("sections") if isinstance(obj.get("sections"), list) else []:
        if isinstance(entry, dict):
            heading, items = _trimmed(entry.get("heading")), _strings(entry.get("items"))
            if heading and items:
                sections.append({"heading": heading, "items": items})
    tags = [t for t in (t.replace("#", "").strip() for t in _strings(obj.get("tags"))) if t]
    outline = []
    for entry in obj.get("outline") if isinstance(obj.get("outline"), list) else []:
        if isinstance(entry, dict) and _trimmed(entry.get("title")):
            outline.append({"title": _trimmed(entry.get("title"))[:40], "points": _strings(entry.get("points"))[:6]})
    quotes = [q for q in (q.strip('“”"「」『』') for q in _strings(obj.get("quotes"))) if q]
    return Draft(
        scene=scene,
        title=_trimmed(obj.get("title"))[:30],
        summary=summary,
        sections=sections,
        todos=_strings(obj.get("todos")),
        tags=tags[:6],
        people=_strings(obj.get("people"))[:12],
        outline=outline[:8],
        quotes=quotes[:5],
    )
