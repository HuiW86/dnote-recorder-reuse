#!/usr/bin/env python3
"""Generate the blind set of summaries for the prompt × model comparison (#12, #68).

docs/summary-evaluation.md §4 step 1. For every reference transcript × prompt × model it asks
an OpenAI-compatible `/chat/completions` (system = the prompt, user = the transcript), and it
can also take outputs made elsewhere (prompt A run inside 闻笺 and exported). Everything is
shuffled and written as `o01.md`, `o02.md`… with no model or prompt in the name:

    out/o01.md …                the outputs, for the scorers
    out/key.csv                 output_id,model,prompt (hold back until scoring is done)
    out/timing.csv              output_id,seconds (empty for outputs made elsewhere)
    out/scores-template.csv     one row per output and scorer, scores left blank

    python summary_generate.py --transcripts refs --out blind \\
        --prompt C=prompts/c-plain-minutes.txt \\
        --model deepseek-chat=https://api.deepseek.com/v1,deepseek-chat,DEEPSEEK_API_KEY \\
        --existing A@deepseek-chat=exports-a --scorers 甲,乙

Keys are read from the environment variable named in --model, never from the command line.
The transcripts are sent to the services named; use only material you may send there.
Pure standard library.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import random
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

_THINK = re.compile(r"<think>.*?</think>", re.S)
SCORE_HEADER = ["output_id", "sample", "scorer", "fabrications", "coverage", "todos", "structure",
                "concision", "parsed"]


@dataclass(frozen=True)
class Model:
    name: str
    base_url: str
    model: str
    key_env: str


@dataclass
class Output:
    sample: str
    model: str
    prompt: str
    text: str
    seconds: float | None


class GenerateError(ValueError):
    pass


# (url, headers, body) -> response body; tests replace it.
Post = Callable[[str, dict, bytes], bytes]


def _urllib_post(url: str, headers: dict, body: bytes) -> bytes:
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")
    with urllib.request.urlopen(request, timeout=300) as response:
        return response.read()


def parse_model(spec: str) -> Model:
    """`name=base_url,model,KEY_ENV`."""
    name, sep, rest = spec.partition("=")
    parts = rest.split(",")
    if not sep or len(parts) != 3 or not all(p.strip() for p in [name, *parts]):
        raise GenerateError(f"--model wants name=base_url,model,KEY_ENV, got {spec!r}")
    return Model(name.strip(), parts[0].strip().rstrip("/"), parts[1].strip(), parts[2].strip())


def parse_pair(spec: str, flag: str) -> tuple[str, str]:
    name, sep, value = spec.partition("=")
    if not sep or not name.strip() or not value.strip():
        raise GenerateError(f"{flag} wants name=value, got {spec!r}")
    return name.strip(), value.strip()


def complete(model: Model, system: str, user: str, post: Post = _urllib_post) -> str:
    key = os.environ.get(model.key_env, "")
    if not key:
        raise GenerateError(f"environment variable {model.key_env} is empty")
    body = json.dumps({"model": model.model, "temperature": 0.2,
                       "messages": [{"role": "system", "content": system},
                                    {"role": "user", "content": user}]}, ensure_ascii=False).encode()
    headers = {"Content-Type": "application/json", "Authorization": f"Bearer {key}"}
    try:
        reply = json.loads(post(f"{model.base_url}/chat/completions", headers, body))
        content = reply["choices"][0]["message"]["content"]
    except urllib.error.HTTPError as error:
        raise GenerateError(f"{model.name}: HTTP {error.code}") from None
    except (urllib.error.URLError, OSError) as error:
        raise GenerateError(f"{model.name}: {error}") from None
    except (KeyError, IndexError, TypeError, ValueError):
        raise GenerateError(f"{model.name}: not a chat/completions reply") from None
    return _THINK.sub("", content or "").strip()


def _transcripts(directory: Path) -> dict[str, str]:
    found = {p.stem: p.read_text(encoding="utf-8") for p in sorted(directory.glob("*.txt"))}
    if not found:
        raise GenerateError(f"no .txt transcripts in {directory}")
    return found


def generate(transcripts: dict[str, str], prompts: dict[str, str], models: list[Model],
             post: Post = _urllib_post, clock: Callable[[], float] = time.monotonic,
             log: Callable[[str], None] = print) -> tuple[list[Output], list[str]]:
    """Every transcript × prompt × model; failures are reported and left out, not retried."""
    outputs, failures = [], []
    for sample, transcript in transcripts.items():
        for prompt_name, prompt in prompts.items():
            for model in models:
                start = clock()
                try:
                    text = complete(model, prompt, transcript, post)
                except GenerateError as error:
                    failures.append(f"{sample} × {prompt_name} × {model.name}: {error}")
                    continue
                outputs.append(Output(sample, model.name, prompt_name, text, clock() - start))
                log(f"done {sample} × {prompt_name} × {model.name}")
    return outputs, failures


def existing(label: str, directory: Path, samples: list[str]) -> tuple[list[Output], list[str]]:
    """Outputs made elsewhere: `prompt@model=dir`, one file per sample, named like it."""
    prompt, sep, model = label.partition("@")
    if not sep or not prompt or not model:
        raise GenerateError(f"--existing wants prompt@model=dir, got {label!r}")
    outputs, missing = [], []
    for sample in samples:
        files = sorted(p for p in directory.glob(f"{sample}.*") if p.suffix.lower() in (".md", ".txt", ".json"))
        if not files:
            missing.append(f"{sample} × {prompt} × {model}: no file in {directory}")
            continue
        outputs.append(Output(sample, model, prompt, files[0].read_text(encoding="utf-8"), None))
    return outputs, missing


def write_blind(outputs: list[Output], out: Path, scorers: list[str], seed: int | None) -> list[str]:
    """Shuffles and writes the set; returns the ids in file order."""
    if not outputs:
        raise GenerateError("nothing to write")
    out.mkdir(parents=True, exist_ok=True)
    if any(out.glob("o*.md")) or (out / "key.csv").exists():
        raise GenerateError(f"{out} already holds a blind set; use an empty directory")
    order = list(outputs)
    random.Random(seed).shuffle(order)
    width = max(2, len(str(len(order))))
    ids = [f"o{i:0{width}d}" for i in range(1, len(order) + 1)]
    for output_id, o in zip(ids, order):
        (out / f"{output_id}.md").write_text(o.text + "\n", encoding="utf-8")
    with (out / "key.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["output_id", "model", "prompt"])
        w.writerows([output_id, o.model, o.prompt] for output_id, o in zip(ids, order))
    with (out / "timing.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["output_id", "seconds"])
        w.writerows([output_id, "" if o.seconds is None else f"{o.seconds:.1f}"] for output_id, o in zip(ids, order))
    with (out / "scores-template.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(SCORE_HEADER)
        for output_id, o in zip(ids, order):
            for scorer in scorers:
                w.writerow([output_id, o.sample, scorer] + [""] * (len(SCORE_HEADER) - 3))
    return ids


def main(argv: list[str] | None = None, post: Post = _urllib_post) -> int:
    parser = argparse.ArgumentParser(description="generate a blind set of summaries")
    parser.add_argument("--transcripts", type=Path, required=True, help="reference transcripts, .txt")
    parser.add_argument("--out", type=Path, required=True, help="an empty directory for the blind set")
    parser.add_argument("--prompt", action="append", default=[], help="name=file with the system prompt")
    parser.add_argument("--model", action="append", default=[], help="name=base_url,model,KEY_ENV")
    parser.add_argument("--existing", action="append", default=[], help="prompt@model=dir of outputs made elsewhere")
    parser.add_argument("--scorers", default="甲,乙", help="comma-separated, for the scores template")
    parser.add_argument("--seed", type=int, help="fixes the shuffle")
    args = parser.parse_args(argv)
    try:
        transcripts = _transcripts(args.transcripts)
        prompts = {name: Path(path).read_text(encoding="utf-8")
                   for name, path in (parse_pair(p, "--prompt") for p in args.prompt)}
        models = [parse_model(m) for m in args.model]
        if prompts and not models:
            raise GenerateError("--prompt needs at least one --model")
        # A missing key stops the run before anything is sent.
        for model in models:
            if not os.environ.get(model.key_env):
                raise GenerateError(f"environment variable {model.key_env} is empty")
        outputs, failures = generate(transcripts, prompts, models, post) if prompts else ([], [])
        for spec in args.existing:
            label, directory = parse_pair(spec, "--existing")
            more, missing = existing(label, Path(directory), list(transcripts))
            outputs += more
            failures += missing
        scorers = [s.strip() for s in args.scorers.split(",") if s.strip()]
        ids = write_blind(outputs, args.out, scorers, args.seed)
    except (OSError, GenerateError) as error:
        print(f"summary_generate: {error}", file=sys.stderr)
        return 2
    print(f"wrote {len(ids)} outputs to {args.out}; keep key.csv away from the scorers")
    for failure in failures:
        print(f"missing: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
