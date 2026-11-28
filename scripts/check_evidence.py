#!/usr/bin/env python3
"""Static check for CLAUDE.md hard rule 4: evidence keeps no card identifiers.

In every text file under evidence/:
  - `sn` appears only as the first 8 hex digits of its SHA-256 ("sha256:7036aa3b");
  - `btaddr` keeps at most its last two bytes ("…162f"), and no full MAC address appears;
  - no `bondId` value is written down.

The files listed in LEGACY predate the rule (ADR-006, 2026-11-06). ADR-006 keeps them as they are
while the repository is private and has them cleaned, with the history rewritten, before it is
made public; until then they are skipped here, and the list must only ever shrink.

    python3 scripts/check_evidence.py           # exit 1 and the offending lines on a violation
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EVIDENCE = ROOT / "evidence"
BINARY = {".png", ".jpg", ".jpeg", ".bin", ".gif", ".pdf", ".ogg", ".raw", ".caf", ".m4a"}

LEGACY = frozenset(
    {
        "v1-live/README.md",
        "v1-live/20261106-034450-51-10s-run1/notify.jsonl",
        "v1-live/20261106-034524-54-10s-run1/notify.jsonl",
        "v1-live/20261106-034553-official-10s-run1/notify.jsonl",
        "v1-live/20261106-034628-51-60s-run1/notify.jsonl",
        "v1-live/20261106-034628-51-60s-run2/notify.jsonl",
        "v1-live/20261106-034628-51-60s-run3/notify.jsonl",
        "v2-fasttransfer/README.md",
        "v2-fasttransfer/probe.log",
        "v3-pair/00-pair-refuse.log",
        "v3-pair/04-pair-idempotent.log",
        "v3-pair/r1-pair.log",
        "v3-pair/r1-unpair.log",
        "v3-pair/r2-pair.log",
        "v3-pair/r2-unpair.log",
        "v3-pair/r3-pair.log",
        "v3-pair/r3-unpair.log",
        "v7-ios/README.md",
        "v7-ios/probe.log",
        "v21-hotspot/README.md",
        "v21-hotspot/probe-batch.log",
    }
)

_SN = re.compile(r"""["']?\bsn["']?\s*[:=]\s*["']?([^"',}\s]+)""")
_SN_OK = re.compile(r"(?:sha256:)?[0-9a-f]{8}|<[^>]*>|…|\.\.\.|\*+|None|null")
# Prose in a README: sn `…` or 序列号 `…`.
_SN_PROSE = re.compile(r"(?:\bsn|序列号)\s*[:：]?\s*`([0-9A-Za-z:]{8,})`")
_BTADDR = re.compile(r"""["']?\bbt_?addr["']?\s*[:=]\s*["']?([^"',}\s]+)""", re.I)
_MAC = re.compile(r"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b")
_BOND = re.compile(r"""["']?\bbond_?id["']?\s*[:=]\s*["']?([0-9A-Za-z+/=]{16,})""", re.I)


def problems(text: str) -> list[tuple[int, str]]:
    """(line number, why) for every identifier that is not redacted."""
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        for m in [*_SN.finditer(line), *_SN_PROSE.finditer(line)]:
            if not _SN_OK.fullmatch(m.group(1)):
                found.append((number, "sn is not redacted to sha256:<8 hex>"))
        for m in _BTADDR.finditer(line):
            if len(re.findall(r"[0-9A-Fa-f]", m.group(1))) > 4:
                found.append((number, "btaddr keeps more than its last two bytes"))
        if _MAC.search(line):
            found.append((number, "full Bluetooth address"))
        if _BOND.search(line):
            found.append((number, "bondId is recorded"))
    return found


def check(root: Path = EVIDENCE, legacy: frozenset[str] = LEGACY) -> list[str]:
    report = []
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        relative = path.relative_to(root).as_posix()
        if relative in legacy or path.suffix.lower() in BINARY:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        report += [f"evidence/{relative}:{n}: {why}" for n, why in problems(text)]
    return report


def main() -> int:
    missing = sorted(name for name in LEGACY if not (EVIDENCE / name).is_file())
    if missing:
        # A cleaned legacy file must leave the list, so the list only ever shrinks.
        print("FAIL: legacy files no longer present; remove them from LEGACY:", *missing, sep="\n  ")
        return 1
    report = check()
    if report:
        print("FAIL: card identifiers in evidence (CLAUDE.md rule 4, ADR-006):", *report, sep="\n  ")
        return 1
    print(f"OK: evidence is redacted ({len(LEGACY)} legacy files left for the pre-publication cleanup)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
