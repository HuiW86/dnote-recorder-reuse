"""Speech recognition behind one interface, so the engine can be swapped (backend-design.md §4.5,
docs/asr-evaluation.md). The engine is picked by the ASR comparison; until then, and until there is
a cloud account, `StandInTranscriber` keeps the pipeline runnable in development. Production
refuses to start with it."""

from dataclasses import dataclass, field
from typing import Protocol


@dataclass(frozen=True)
class Segment:
    start_ms: int
    end_ms: int
    text: str
    # The engine's label for the voice ("S1", "S2", ...); None without diarization.
    speaker: str | None = None


@dataclass(frozen=True)
class TranscriptResult:
    language: str
    segments: list[Segment]
    # How much audio the engine heard; billed as ASR seconds (prd.md §8 usage_records).
    audio_ms: int
    provider: str
    extra: dict = field(default_factory=dict)


class TranscriberError(Exception):
    """`code` lands in the task's error_code; retryable errors are retried by the task queue."""

    def __init__(self, code: str, message: str, retryable: bool):
        super().__init__(code)
        self.code = code
        self.message = message
        self.retryable = retryable


class Transcriber(Protocol):
    name: str

    async def transcribe(
        self, audio_url: str, content_type: str, language: str, speakers: bool, duration_ms: int
    ) -> TranscriptResult:
        """Recognises the audio at `audio_url` (a short-lived presigned URL). `language` is a code
        such as "zh" or "auto"; `speakers` asks for diarization. Raises TranscriberError."""
        ...


class StandInTranscriber:
    """Development only: hears nothing, returns one line saying so, spanning the recording."""

    name = "stand-in"

    async def transcribe(
        self, audio_url: str, content_type: str, language: str, speakers: bool, duration_ms: int
    ) -> TranscriptResult:
        text = "（开发用的替身转写，没有识别真实内容）"
        return TranscriptResult(
            language="zh" if language == "auto" else language,
            segments=[Segment(0, duration_ms, text, "S1" if speakers else None)],
            audio_ms=duration_ms,
            provider=self.name,
        )
