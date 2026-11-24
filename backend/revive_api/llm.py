"""The language model behind one interface, so the provider can be swapped (backend-design.md §4.5
"大模型做成网关"). Requests are shaped like OpenAI's /chat/completions, which is what the app sends
to a service the user configures (ADR-009), so both paths ask the same question the same way. Until
there is a cloud account and the summary comparison picks a model (docs/summary-evaluation.md),
`StandInChatModel` keeps the pipeline runnable in development. Production refuses to start with it."""

import json
import re
from dataclasses import dataclass
from typing import Protocol


@dataclass(frozen=True)
class ChatReply:
    text: str
    # The model that answered, stored with the result so it can be redone later.
    model: str
    prompt_tokens: int
    completion_tokens: int


class ChatModelError(Exception):
    """`code` lands in the task's error_code; retryable errors are retried by the task queue."""

    def __init__(self, code: str, message: str, retryable: bool):
        super().__init__(code)
        self.code = code
        self.message = message
        self.retryable = retryable


class ChatModel(Protocol):
    name: str

    async def complete(self, system: str, user: str, json_reply: bool) -> ChatReply:
        """One system and one user message; `json_reply` asks for a JSON object
        (response_format json_object). Raises ChatModelError."""
        ...


class StandInChatModel:
    """Development only. Answers a summary request with the opening sentences of the transcript,
    like the app's keyword fallback, and says it is a stand-in; anything else gets the first lines."""

    name = "stand-in"

    async def complete(self, system: str, user: str, json_reply: bool) -> ChatReply:
        material = user.split("文字稿：\n", 1)[-1]
        sentences = [s.strip() for s in re.split(r"[。！？!?\n]", material) if len(s.strip()) > 3]
        if json_reply:
            text = json.dumps(
                {
                    "scene": "other",
                    "title": (sentences[0] if sentences else "")[:16],
                    "summary": "（开发用的替身纪要）" + "。".join(sentences[:2]),
                    "sections": [],
                    "todos": [],
                    "tags": [],
                    "people": [],
                },
                ensure_ascii=False,
            )
        else:
            text = "\n".join(sentences[:5])
        return ChatReply(text, self.name, len(system) + len(user), len(text))
