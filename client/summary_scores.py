#!/usr/bin/env python3
"""Aggregate blind scores of summaries, by model and prompt set (#12, #68).

docs/summary-evaluation.md describes the method. Scorers see outputs only by an id and fill
in `scores.csv`; which model and prompt set made each output lives in a separate `key.csv`,
joined only here, so scoring stays blind.

scores.csv  output_id,sample,scorer,fabrications,coverage,todos,structure,concision,parsed
key.csv     output_id,model,prompt

    python summary_scores.py scores.csv key.csv [--json]

- fabrications: how many statements are not in the transcript (0 = none). Any output with
  one or more fails, whatever its other scores: a summary that makes things up is unusable.
- coverage, todos, structure, concision: 1 (poor) to 5 (good).
- parsed: 1 when the reply could be read as the app expects (valid JSON, the fields there).

Pure standard library; reads no transcript or summary text, only the scores.
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

DIMENSIONS = ("coverage", "todos", "structure", "concision")
SCORE_COLUMNS = ("output_id", "sample", "scorer", "fabrications", *DIMENSIONS, "parsed")
KEY_COLUMNS = ("output_id", "model", "prompt")


class ScoreError(ValueError):
    pass


@dataclass
class Group:
    model: str
    prompt: str
    rows: int = 0
    failed: int = 0
    unparsed: int = 0
    sums: dict[str, int] = field(default_factory=lambda: {d: 0 for d in DIMENSIONS})
    samples: set[str] = field(default_factory=set)

    def mean(self, dimension: str) -> float:
        return self.sums[dimension] / self.rows

    @property
    def overall(self) -> float:
        return sum(self.mean(d) for d in DIMENSIONS) / len(DIMENSIONS)


def _read(path: Path, columns: tuple[str, ...]) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        missing = [c for c in columns if c not in (reader.fieldnames or [])]
        if missing:
            raise ScoreError(f"{path.name}: missing columns {', '.join(missing)}")
        return [{k: (v or "").strip() for k, v in row.items()} for row in reader]


def _int(row: dict[str, str], column: str, low: int, high: int | None, where: str) -> int:
    try:
        value = int(row[column])
    except ValueError:
        raise ScoreError(f"{where}: {column} is not a whole number: {row[column]!r}") from None
    if value < low or (high is not None and value > high):
        bound = f"{low}–{high}" if high is not None else f">= {low}"
        raise ScoreError(f"{where}: {column} must be {bound}, got {value}")
    return value


def aggregate(scores_path: Path, key_path: Path) -> list[Group]:
    key = {}
    for row in _read(key_path, KEY_COLUMNS):
        if row["output_id"] in key:
            raise ScoreError(f"{key_path.name}: output {row['output_id']} is listed twice")
        key[row["output_id"]] = (row["model"], row["prompt"])
    groups: dict[tuple[str, str], Group] = {}
    for line, row in enumerate(_read(scores_path, SCORE_COLUMNS), start=2):
        where = f"{scores_path.name} line {line}"
        if row["output_id"] not in key:
            raise ScoreError(f"{where}: output {row['output_id']} is not in {key_path.name}")
        model, prompt = key[row["output_id"]]
        group = groups.setdefault((model, prompt), Group(model, prompt))
        group.rows += 1
        group.samples.add(row["sample"])
        if _int(row, "fabrications", 0, None, where) > 0:
            group.failed += 1
        if _int(row, "parsed", 0, 1, where) == 0:
            group.unparsed += 1
        for d in DIMENSIONS:
            group.sums[d] += _int(row, d, 1, 5, where)
    if not groups:
        raise ScoreError(f"{scores_path.name}: no scores")
    # Fewest failures first, then the best overall score.
    return sorted(groups.values(), key=lambda g: (g.failed, -g.overall, g.model, g.prompt))


def markdown_table(groups: list[Group]) -> str:
    rows = ["| 模型 | 提示词 | 评分次数 | 样本数 | 有编造 | 解析失败 | 覆盖 | 待办 | 结构 | 简洁 | 平均 |",
            "|---|---|---|---|---|---|---|---|---|---|---|"]
    for g in groups:
        means = " | ".join(f"{g.mean(d):.2f}" for d in DIMENSIONS)
        rows.append(f"| {g.model} | {g.prompt} | {g.rows} | {len(g.samples)} | {g.failed} | {g.unparsed} | "
                    f"{means} | {g.overall:.2f} |")
    return "\n".join(rows)


def as_json(groups: list[Group]) -> str:
    return json.dumps([{"model": g.model, "prompt": g.prompt, "rows": g.rows, "samples": sorted(g.samples),
                        "failed": g.failed, "unparsed": g.unparsed,
                        "means": {d: g.mean(d) for d in DIMENSIONS}, "overall": g.overall}
                       for g in groups], ensure_ascii=False, indent=2)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="aggregate blind summary scores by model and prompt set")
    parser.add_argument("scores", type=Path)
    parser.add_argument("key", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    try:
        groups = aggregate(args.scores, args.key)
    except (OSError, ScoreError) as error:
        print(f"summary_scores: {error}", file=sys.stderr)
        return 2
    print(as_json(groups) if args.json else markdown_table(groups))
    return 0


if __name__ == "__main__":
    sys.exit(main())
