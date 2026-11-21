#!/usr/bin/env python3
"""Character error rate (CER) of ASR engines against hand-corrected reference transcripts.

For the ASR comparison of #12 and #67 (docs/asr-evaluation.md). One directory holds the
references, one directory per engine holds that engine's output, with the same file names:

    refs/meeting-30min.txt          the corrected reference
    sensevoice/meeting-30min.txt    an engine's text (.txt), or
    on-device/meeting-30min.md      闻笺's Markdown export: only its 「## 文字稿」 section is read,
                                    without the **00:01:05** times

    python asr_eval.py refs sensevoice on-device [--json]

Text is compared character by character after normalising: full-width forms become
half-width (NFKC), punctuation, symbols, spaces and control characters are dropped, Latin
letters are lowercased. CER = (substitutions + deletions + insertions) / reference characters.
Speaker labels, timing and price are not measured here; the document records them by hand.
No audio is read or written (CLAUDE.md rule 4).

Pure standard library. A 30-minute transcript (about 9 000 characters) takes tens of seconds,
since the alignment is a plain dynamic programme.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from dataclasses import asdict, dataclass, field
from pathlib import Path

_TIME_PREFIX = re.compile(r"^\s*\*\*\d{1,2}:\d{2}(?::\d{2})?\*\*\s*")
_TRANSCRIPT_HEADING = "## 文字稿"


def normalize(text: str) -> str:
    """The characters that count: no punctuation, symbols, spaces or control characters."""
    text = unicodedata.normalize("NFKC", text).lower()
    return "".join(ch for ch in text if unicodedata.category(ch)[0] not in "PSZC")


def transcript_text(path: Path) -> str:
    """A reference or hypothesis file as plain text. For 闻笺's Markdown export, only the lines
    of its 文字稿 section, without their times."""
    raw = path.read_text(encoding="utf-8")
    if path.suffix.lower() != ".md" or _TRANSCRIPT_HEADING not in raw:
        return raw
    section = raw.split(_TRANSCRIPT_HEADING, 1)[1]
    lines = []
    for line in section.splitlines():
        if line.startswith("## "):  # the next section
            break
        lines.append(_TIME_PREFIX.sub("", line))
    return "\n".join(lines)


@dataclass
class Counts:
    substitutions: int = 0
    deletions: int = 0
    insertions: int = 0
    reference_chars: int = 0

    @property
    def errors(self) -> int:
        return self.substitutions + self.deletions + self.insertions

    @property
    def cer(self) -> float | None:
        """None when there is no reference text to measure against."""
        return self.errors / self.reference_chars if self.reference_chars else None

    def __add__(self, other: Counts) -> Counts:
        return Counts(self.substitutions + other.substitutions, self.deletions + other.deletions,
                      self.insertions + other.insertions, self.reference_chars + other.reference_chars)


def edit_counts(reference: str, hypothesis: str) -> Counts:
    """Substitutions, deletions and insertions of a minimum edit alignment of two normalised
    strings. Ties prefer a substitution, then a deletion."""
    ref, hyp = reference, hypothesis
    # The shared start and end cost nothing; trimming them keeps long, mostly right
    # transcripts fast.
    start = 0
    while start < len(ref) and start < len(hyp) and ref[start] == hyp[start]:
        start += 1
    end = 0
    while end < len(ref) - start and end < len(hyp) - start and ref[-1 - end] == hyp[-1 - end]:
        end += 1
    ref = ref[start:len(ref) - end]
    hyp = hyp[start:len(hyp) - end]
    total = len(reference)
    if not ref:
        return Counts(insertions=len(hyp), reference_chars=total)
    if not hyp:
        return Counts(deletions=len(ref), reference_chars=total)

    # One row per reference character; each cell keeps the cost and how many of it are
    # deletions and insertions (substitutions are the rest).
    cost = list(range(len(hyp) + 1))
    dels = [0] * (len(hyp) + 1)
    ins = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        prev_cost, prev_dels, prev_ins = cost, dels, ins
        cost = [i] + [0] * len(hyp)
        dels = [i] + [0] * len(hyp)
        ins = [0] * (len(hyp) + 1)
        for j, h in enumerate(hyp, 1):
            diagonal = prev_cost[j - 1] + (r != h)
            up = prev_cost[j] + 1        # delete r
            left = cost[j - 1] + 1       # insert h
            if diagonal <= up and diagonal <= left:
                cost[j], dels[j], ins[j] = diagonal, prev_dels[j - 1], prev_ins[j - 1]
            elif up <= left:
                cost[j], dels[j], ins[j] = up, prev_dels[j] + 1, prev_ins[j]
            else:
                cost[j], dels[j], ins[j] = left, dels[j - 1], ins[j - 1] + 1
    deletions, insertions = dels[-1], ins[-1]
    return Counts(cost[-1] - deletions - insertions, deletions, insertions, total)


@dataclass
class EngineResult:
    engine: str
    totals: Counts = field(default_factory=Counts)
    per_file: dict[str, Counts] = field(default_factory=dict)
    #: References with no output from this engine; counted as all deleted.
    missing: list[str] = field(default_factory=list)


def _files(directory: Path) -> dict[str, Path]:
    """Transcript files by name without extension; .txt wins over .md for the same name."""
    found: dict[str, Path] = {}
    for path in sorted(directory.iterdir()):
        if path.suffix.lower() in (".txt", ".md") and path.is_file():
            if path.stem not in found or path.suffix.lower() == ".txt":
                found[path.stem] = path
    return found


def score(reference_dir: Path, engine_dir: Path) -> EngineResult:
    references = _files(reference_dir)
    if not references:
        raise ValueError(f"no .txt or .md references in {reference_dir}")
    outputs = _files(engine_dir)
    result = EngineResult(engine=engine_dir.name)
    for name, ref_path in references.items():
        reference = normalize(transcript_text(ref_path))
        if name in outputs:
            counts = edit_counts(reference, normalize(transcript_text(outputs[name])))
        else:
            result.missing.append(name)
            counts = Counts(deletions=len(reference), reference_chars=len(reference))
        result.per_file[name] = counts
        result.totals = result.totals + counts
    return result


def _percent(value: float | None) -> str:
    return "—" if value is None else f"{value * 100:.2f}%"


def markdown_table(results: list[EngineResult]) -> str:
    rows = ["| 引擎 | 文件数 | 参考字数 | 替换 | 删除 | 插入 | 字错率 | 缺少的文件 |",
            "|---|---|---|---|---|---|---|---|"]
    for r in results:
        t = r.totals
        rows.append(f"| {r.engine} | {len(r.per_file)} | {t.reference_chars} | {t.substitutions} | "
                    f"{t.deletions} | {t.insertions} | {_percent(t.cer)} | {', '.join(r.missing) or '—'} |")
    return "\n".join(rows)


def as_json(results: list[EngineResult]) -> str:
    def counts(c: Counts) -> dict:
        return {**asdict(c), "errors": c.errors, "cer": c.cer}

    return json.dumps([{"engine": r.engine, "totals": counts(r.totals), "missing": r.missing,
                        "per_file": {name: counts(c) for name, c in r.per_file.items()}}
                       for r in results], ensure_ascii=False, indent=2)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="ASR character error rate against reference transcripts")
    parser.add_argument("references", type=Path, help="directory of corrected reference transcripts")
    parser.add_argument("engines", type=Path, nargs="+", help="one directory per engine, same file names")
    parser.add_argument("--json", action="store_true", help="per-file and total counts as JSON")
    args = parser.parse_args(argv)
    try:
        results = [score(args.references, engine) for engine in args.engines]
    except (OSError, ValueError) as error:
        print(f"asr_eval: {error}", file=sys.stderr)
        return 2
    print(as_json(results) if args.json else markdown_table(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
