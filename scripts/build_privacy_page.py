#!/usr/bin/env python3
"""Build the public privacy policy page from docs/release/privacy-policy.md.

docs/release/testflight.md §1: the policy is hosted in a separate public repository with
GitHub Pages, without the maintenance box at the top of the draft and with every 【…】
placeholder filled in. This does both and refuses to write a page that is not ready:

    python3 scripts/build_privacy_page.py \\
        --fill YYYY-MM-DD=2026-12-01 --fill 开发者名称=… --fill 联系邮箱=… \\
        --out ../wenjian-app/privacy.md

GitHub Pages turns privacy.md into privacy.html. Exit code 1 when a placeholder is left or a
name that may not appear does (CLAUDE.md rule 5); `--draft` writes anyway, for a preview.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "docs" / "release" / "privacy-policy.md"
PLACEHOLDER = re.compile(r"【([^】]+)】")
# CLAUDE.md rule 5: the only allowed mention of the card's maker is 「适用于 D·NOTE 录音卡」.
FORBIDDEN = ("追觅", "Dreame", "DreameNote")
FRONT_MATTER = "---\ntitle: 闻笺隐私政策\nlang: zh-CN\n---\n\n"


class PageError(ValueError):
    pass


def strip_maintenance(text: str) -> str:
    """Everything from the policy's own title on: the draft's heading, its maintenance box and
    the rule under it are for this repository only."""
    marker = "\n---\n"
    if text.lstrip().startswith("# ") and marker in text:
        head, rest = text.split(marker, 1)
        if "维护说明" in head:
            return rest.lstrip("\n")
    raise PageError("the draft no longer starts with its maintenance box and a --- rule; check the source")


def fill(text: str, values: dict[str, str]) -> str:
    return PLACEHOLDER.sub(lambda m: values.get(m.group(1), m.group(0)), text)


def problems(page: str) -> list[str]:
    found = [f"placeholder 【{name}】 is not filled in" for name in dict.fromkeys(PLACEHOLDER.findall(page))]
    found += [f"「{name}」 may not appear (CLAUDE.md rule 5)" for name in FORBIDDEN if name in page]
    return found


def build(source: str, values: dict[str, str]) -> tuple[str, list[str]]:
    page = fill(strip_maintenance(source), values)
    return FRONT_MATTER + page.rstrip() + "\n", problems(page)


def _pairs(specs: list[str]) -> dict[str, str]:
    values = {}
    for spec in specs:
        key, sep, value = spec.partition("=")
        if not sep or not key.strip() or not value.strip():
            raise PageError(f"--fill wants 键=值, got {spec!r}")
        values[key.strip()] = value.strip()
    return values


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="build the public privacy policy page")
    parser.add_argument("--fill", action="append", default=[], help="placeholder=value, e.g. 联系邮箱=…")
    parser.add_argument("--out", type=Path, required=True, help="where to write privacy.md")
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--draft", action="store_true", help="write even with problems, for a preview")
    args = parser.parse_args(argv)
    try:
        page, found = build(args.source.read_text(encoding="utf-8"), _pairs(args.fill))
    except (OSError, PageError) as error:
        print(f"build_privacy_page: {error}", file=sys.stderr)
        return 2
    for problem in found:
        print(f"build_privacy_page: {problem}", file=sys.stderr)
    if found and not args.draft:
        print("build_privacy_page: nothing written", file=sys.stderr)
        return 1
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(page, encoding="utf-8")
    print(f"wrote {args.out}" + (" (draft)" if found else ""))
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
