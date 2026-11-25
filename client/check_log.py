#!/usr/bin/env python3
"""Judges a frame log exported from the app's debug page (card-debug.log, DEBUG builds only) against
the protocol-level pass criteria of the device tests (docs/device-todo.md, docs/test-spec.md):

  commands   only the app's whitelist was sent, never 0x93/0x94/0xB0/0xB1   (T-M1-50, §3.5 gate 3)
  deletes    every 0x91 comes after that file was downloaded in full         (rule 2, T-M15-54)
  downloads  bytes, time and throughput per file, against ~24 KB/s ±20%     (T-M1-53)
  stops      from the card's "recording stopped" push to the first download (T-M1-51: ≤ 10 s)
  names      the file a recording started with (0x54 push) is the file downloaded (T-M15-53)
  settings   each setting written is read back by 0x81 with the same value  (T-M1-57)
  redaction  no raw sn, full btaddr or bondId in the log                     (rule 4)

    python check_log.py card-debug.log [more.log …]       exit 1 when a check fails

Prints a summary that can go into the evidence README as it is. Pure standard library.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

# The app's Command enum (app/ReviveKit/Sources/CardProtocol/Command.swift).
WHITELIST = {0x80, 0x81, 0x56, 0xA1, 0xA3, 0x83, 0x84, 0x85, 0x87, 0x8B, 0x8C, 0x8D, 0x8F,
             0x50, 0x51, 0x52, 0x53, 0x70, 0x90, 0x91, 0xA0, 0xA2}
FORBIDDEN = {0x93, 0x94, 0xB0, 0xB1}
BASELINE_KBPS = 24.0
# Below this a transfer is mostly request latency; throughput is not judged.
THROUGHPUT_MIN_BYTES = 1_000_000
STOP_TO_SYNC_SECONDS = 10.0
# Setting command -> 0x81 field. Switches are one byte; autoff is uint32 big-endian seconds.
SETTINGS = {0x83: "led", 0x84: "motor", 0x85: "nc", 0x8B: "vad", 0x8C: "gain", 0x8D: "nn", 0x8F: "autoff"}

_LINE = re.compile(
    r"^(?P<time>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}) \[(?P<state>\w+)\] "
    r"(?P<dir>tx|rx) (?P<cmd>[0-9A-F]{2}) len=(?P<len>\d+) ?(?P<rest>.*)$")
_CHUNK = re.compile(r"status=0x(?P<status>[0-9A-F]{2}) offset=(?P<offset>\d+) data=<(?P<size>\d+) B>")


@dataclass
class Frame:
    line: int
    time: datetime
    state: str
    direction: str
    cmd: int
    rest: str

    def json(self) -> dict:
        try:
            value = json.loads(self.rest)
        except ValueError:
            return {}
        return value if isinstance(value, dict) else {}


@dataclass
class Download:
    name: str
    offset: int
    started: Frame
    received: int = 0
    ended: Frame | None = None
    # eof, cancelled, error, not_found, or None while unfinished
    outcome: str | None = None

    @property
    def seconds(self) -> float | None:
        return None if self.ended is None else (self.ended.time - self.started.time).total_seconds()


@dataclass
class Report:
    failures: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    lines: list[str] = field(default_factory=list)


def parse(text: str) -> list[Frame]:
    frames = []
    for number, line in enumerate(text.splitlines(), 1):
        m = _LINE.match(line)
        if m:
            frames.append(Frame(number, datetime.strptime(m["time"], "%Y-%m-%d %H:%M:%S.%f"), m["state"],
                                m["dir"], int(m["cmd"], 16), m["rest"].strip()))
    return frames


def downloads(frames: list[Frame]) -> list[Download]:
    out: list[Download] = []
    current: Download | None = None
    for f in frames:
        if f.direction == "tx" and f.cmd == 0x70:
            body = f.json()
            current = Download(str(body.get("name", "")), int(body.get("offset", 0)), f)
            out.append(current)
        elif f.direction == "rx" and f.cmd == 0x70 and current is not None and current.outcome is None:
            m = _CHUNK.search(f.rest)
            if not m:
                continue
            current.received += int(m["size"])
            kind = int(m["status"], 16) & 0xF0
            if kind in (0x20, 0x30, 0x40, 0xF0):
                current.outcome = {0x20: "eof", 0x30: "cancelled", 0x40: "error", 0xF0: "not_found"}[kind]
                current.ended = f
    return out


def listed_sizes(frames: list[Frame]) -> dict[str, int]:
    sizes = {}
    for f in frames:
        if f.direction == "rx" and f.cmd == 0x90:
            body = f.json()
            if body.get("name"):
                sizes[body["name"]] = int(body.get("size", 0))
    return sizes


def check(frames: list[Frame], redaction=None) -> Report:
    r = Report()
    sent = [f for f in frames if f.direction == "tx"]
    if not frames:
        r.failures.append("no frames found: is this card-debug.log from a DEBUG build?")
        return r

    # Commands
    counts: dict[int, int] = {}
    for f in sent:
        counts[f.cmd] = counts.get(f.cmd, 0) + 1
    r.lines.append("commands sent: " + ", ".join(f"{c:02X}×{n}" for c, n in sorted(counts.items())))
    for f in sent:
        if f.cmd in FORBIDDEN:
            r.failures.append(f"line {f.line}: forbidden command {f.cmd:02X} sent (CLAUDE.md rule 1)")
        elif f.cmd not in WHITELIST:
            r.failures.append(f"line {f.line}: command {f.cmd:02X} is not in the app's whitelist")

    # Downloads
    sizes = listed_sizes(frames)
    loads = downloads(frames)
    complete: dict[str, int] = {}  # name -> line of the EOF that completed it
    for d in loads:
        size = sizes.get(d.name)
        whole = d.outcome == "eof" and (size is None or d.offset + d.received == size)
        if whole:
            complete.setdefault(d.name, d.ended.line)
        seconds = d.seconds
        speed = d.received / 1024 / seconds if seconds else None
        state = d.started.state if d.ended is None or d.ended.state == d.started.state else \
            f"{d.started.state}→{d.ended.state}"
        text = (f"download {d.name} from {d.offset}: {d.received} B, {d.outcome or 'unfinished'}"
                + (f", {seconds:.1f} s, {speed:.1f} KB/s" if speed else "") + f" [{state}]")
        if d.outcome == "eof" and size is not None and d.offset + d.received != size:
            r.failures.append(f"line {d.ended.line}: {d.name} ended at {d.offset + d.received} B, listed as {size} B")
        if speed and d.received >= THROUGHPUT_MIN_BYTES:
            text += f" ({speed / BASELINE_KBPS - 1:+.0%} vs {BASELINE_KBPS:g} KB/s)"
            if abs(speed - BASELINE_KBPS) / BASELINE_KBPS > 0.2:
                r.notes.append(f"{d.name}: {speed:.1f} KB/s is more than 20% from the {BASELINE_KBPS:g} KB/s baseline")
        r.lines.append(text)
    if not loads:
        r.lines.append("downloads: none")
    for name in dict.fromkeys(d.name for d in loads):
        if name not in complete:
            r.notes.append(f"{name}: downloaded in part only; never completed in this log")

    # Deletes after downloads (rule 2)
    earlier = []
    for f in sent:
        if f.cmd != 0x91:
            continue
        name = f.json().get("name", "")
        done = complete.get(name)
        if done is not None and done < f.line:
            r.lines.append(f"delete {name}: after its download completed (line {done}) ✓")
        elif any(d.name == name for d in loads if d.started.line < f.line):
            r.failures.append(f"line {f.line}: {name} deleted, but its download in this log never completed")
        else:
            earlier.append(name)
    if earlier:
        r.notes.append(f"{len(earlier)} file(s) deleted whose download is not in this log (an earlier session?): "
                       + ", ".join(earlier[:5]) + (" …" if len(earlier) > 5 else ""))

    # Recording stopped -> first download
    for f in frames:
        if f.direction == "rx" and f.cmd == 0x55:
            nxt = next((d for d in loads if d.started.time >= f.time), None)
            if nxt is None:
                r.notes.append(f"line {f.line}: recording stopped [{f.state}], no download after it in this log")
                continue
            wait = (nxt.started.time - f.time).total_seconds()
            r.lines.append(f"recording stopped [{f.state}] → download {nxt.name} after {wait:.1f} s")
            if wait > STOP_TO_SYNC_SECONDS:
                r.notes.append(f"line {f.line}: sync started {wait:.1f} s after the stop (T-M1-51 wants ≤ 10 s)")

    # The name the card announced when a recording started is the file that was downloaded
    downloaded = {d.name for d in loads}
    for f in frames:
        if f.direction == "rx" and f.cmd == 0x54:
            name = f.json().get("name", "")
            if not name or name == "NULL":
                continue
            if name in downloaded:
                r.lines.append(f"recording started as {name} [{f.state}] → downloaded under that name ✓")
            else:
                r.notes.append(f"line {f.line}: recording started as {name}; no download of that name in this log")

    # Settings read back
    for f in sent:
        key = SETTINGS.get(f.cmd)
        if key is None:
            continue
        raw = bytes.fromhex(f.rest.replace(" ", "")) if re.fullmatch(r"[0-9A-Fa-f ]+", f.rest or "-") else b""
        if not raw:
            continue
        wanted = int.from_bytes(raw, "big")
        back = next((g for g in frames if g.direction == "rx" and g.cmd == 0x81 and g.line > f.line), None)
        if back is None:
            r.notes.append(f"line {f.line}: {key}={wanted} written, never read back with 0x81 in this log")
        elif back.json().get(key) != wanted:
            r.failures.append(f"line {back.line}: {key} written as {wanted} (line {f.line}), read back as "
                              f"{back.json().get(key)}")
        else:
            r.lines.append(f"setting {key}={wanted}: read back ✓ (line {back.line})")

    # Redaction
    if redaction is not None:
        for number, why in redaction:
            r.failures.append(f"line {number}: {why} (CLAUDE.md rule 4)")
    return r


def _redaction(text: str):
    path = Path(__file__).resolve().parent.parent / "scripts" / "check_evidence.py"
    spec = importlib.util.spec_from_file_location("check_evidence", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.problems(text)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="judge a card-debug.log against the device test criteria")
    parser.add_argument("logs", nargs="+", type=Path)
    args = parser.parse_args(argv)
    failed = False
    for path in args.logs:
        text = path.read_text(encoding="utf-8")
        report = check(parse(text), _redaction(text))
        print(f"## {path.name}")
        for line in report.lines:
            print(f"- {line}")
        for note in report.notes:
            print(f"- NOTE {note}")
        for failure in report.failures:
            print(f"- FAIL {failure}")
        print(f"- result: {'FAIL' if report.failures else 'pass'}\n")
        failed |= bool(report.failures)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
