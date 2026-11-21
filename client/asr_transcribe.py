#!/usr/bin/env python3
"""Transcribe a set of recordings with an OpenAI-compatible `/audio/transcriptions` (#12, #67).

docs/asr-evaluation.md §4: one directory per engine, one text file per recording, named like
its reference. This fills such a directory for an engine that has the OpenAI-compatible
interface (SenseVoiceSmall on 硅基流动, OpenAI, Groq…), so `asr_eval.py` can score it:

    export SILICONFLOW_API_KEY=…
    python asr_transcribe.py audio/ sensevoice/ \\
        --base-url https://api.siliconflow.cn/v1 --model FunAudioLLM/SenseVoiceSmall \\
        --key-env SILICONFLOW_API_KEY --language zh

    audio/meeting-30min.m4a  ->  sensevoice/meeting-30min.txt
    sensevoice/timing.csv        file,seconds,bytes

The audio is uploaded to that service; use only recordings you may send there. Nothing is
written into the repository by this tool, and recordings must not be committed (CLAUDE.md
rule 4). Keys are read from the environment variable named, never from the command line.
A file that already has its text is skipped, so a run cut short can be resumed.
Pure standard library.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Callable

AUDIO_SUFFIXES = (".m4a", ".mp3", ".wav", ".ogg", ".opus", ".flac", ".aac", ".webm")
MIME = {".m4a": "audio/mp4", ".mp3": "audio/mpeg", ".wav": "audio/wav", ".ogg": "audio/ogg",
        ".opus": "audio/ogg", ".flac": "audio/flac", ".aac": "audio/aac", ".webm": "audio/webm"}

# (url, headers, body) -> response body; tests replace it.
Post = Callable[[str, dict, bytes], bytes]


class TranscribeError(ValueError):
    pass


def _urllib_post(url: str, headers: dict, body: bytes) -> bytes:
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")
    with urllib.request.urlopen(request, timeout=900) as response:
        return response.read()


def multipart(fields: list[tuple[str, str]], file_name: str, mime: str, data: bytes,
              boundary: str) -> bytes:
    parts = [f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n".encode()
             for name, value in fields]
    parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{file_name}\"\r\n"
                 f"Content-Type: {mime}\r\n\r\n".encode() + data + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts)


def transcribe(audio: Path, base_url: str, model: str, key: str, language: str | None,
               post: Post = _urllib_post) -> str:
    fields = [("model", model), ("response_format", "json")]
    if language:
        fields.append(("language", language))
    boundary = f"asr-{uuid.uuid4().hex}"
    body = multipart(fields, audio.name, MIME.get(audio.suffix.lower(), "application/octet-stream"),
                     audio.read_bytes(), boundary)
    headers = {"Content-Type": f"multipart/form-data; boundary={boundary}", "Authorization": f"Bearer {key}"}
    try:
        raw = post(f"{base_url.rstrip('/')}/audio/transcriptions", headers, body)
    except urllib.error.HTTPError as error:
        raise TranscribeError(f"HTTP {error.code}") from None
    except (urllib.error.URLError, OSError) as error:
        raise TranscribeError(str(error)) from None
    try:
        text = json.loads(raw)["text"]
    except (KeyError, TypeError, ValueError):
        raise TranscribeError("reply has no text") from None
    if not isinstance(text, str):
        raise TranscribeError("reply has no text")
    return text.strip()


def run(audio_dir: Path, out: Path, base_url: str, model: str, key_env: str, language: str | None,
        post: Post = _urllib_post, clock: Callable[[], float] = time.monotonic,
        log: Callable[[str], None] = print) -> tuple[int, list[str]]:
    """Returns (files transcribed now, failures). Files that already have text are skipped."""
    key = os.environ.get(key_env, "")
    if not key:
        raise TranscribeError(f"environment variable {key_env} is empty")
    files = sorted(p for p in audio_dir.iterdir() if p.suffix.lower() in AUDIO_SUFFIXES and p.is_file())
    if not files:
        raise TranscribeError(f"no audio files in {audio_dir}")
    stems = [p.stem for p in files]
    if len(set(stems)) != len(stems):
        raise TranscribeError("two audio files share a name; the texts would overwrite each other")
    out.mkdir(parents=True, exist_ok=True)
    timing = out / "timing.csv"
    new_timing = not timing.exists()
    done, failures = 0, []
    with timing.open("a", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        if new_timing:
            writer.writerow(["file", "seconds", "bytes"])
        for audio in files:
            target = out / f"{audio.stem}.txt"
            if target.exists():
                log(f"skip {audio.name}: {target.name} is there")
                continue
            start = clock()
            try:
                text = transcribe(audio, base_url, model, key, language, post)
            except TranscribeError as error:
                failures.append(f"{audio.name}: {error}")
                continue
            target.write_text(text + "\n", encoding="utf-8")
            writer.writerow([audio.name, f"{clock() - start:.1f}", audio.stat().st_size])
            done += 1
            log(f"done {audio.name}")
    return done, failures


def main(argv: list[str] | None = None, post: Post = _urllib_post) -> int:
    parser = argparse.ArgumentParser(description="transcribe recordings with an OpenAI-compatible service")
    parser.add_argument("audio", type=Path, help="directory of recordings")
    parser.add_argument("out", type=Path, help="this engine's directory of texts")
    parser.add_argument("--base-url", required=True, help="up to the version, e.g. https://api.siliconflow.cn/v1")
    parser.add_argument("--model", required=True)
    parser.add_argument("--key-env", required=True, help="name of the environment variable holding the key")
    parser.add_argument("--language", help="e.g. zh; left out when not given")
    args = parser.parse_args(argv)
    try:
        done, failures = run(args.audio, args.out, args.base_url, args.model, args.key_env, args.language, post)
    except (OSError, TranscribeError) as error:
        print(f"asr_transcribe: {error}", file=sys.stderr)
        return 2
    print(f"transcribed {done} file(s) into {args.out}")
    for failure in failures:
        print(f"failed: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
