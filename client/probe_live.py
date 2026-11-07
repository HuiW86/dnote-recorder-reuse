#!/usr/bin/env python3
"""
probe_live.py — Issue #4 (V1): probe realtime recording (0x51/0x54 -> 0x68 stream).

Methods:
  51        send 0x51 [1] (start recording with realtime flag)
  54        send 0x54 [1] (start realtime recording)
  official  mimic DreameNote App: 0x51 [1]; if no 0x68 within 0.5s send 0x54 [1];
            answer every 0x54 notification with another 0x54 [1] (capped)

Every notification is logged (hex + timestamp) to notify.jsonl; 0x68 entries keep
only the 8-byte head plus audio length/hash. 0x68 payloads are stripped of their
5-byte header (App does slice(5)), concatenated to live.bin, split into 40-byte
frames and wrapped as live.ogg. live.bin/live.ogg hold room audio: keep local.

Usage:
  python probe_live.py --address <addr> --method official --seconds 10
  python probe_live.py --address <addr> --method official --seconds 60 --repeat 3
"""

from __future__ import annotations
import argparse
import asyncio
import collections
import hashlib
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dnote_protocol as P
from ogg_opus import wrap_opus_frames_as_ogg

from bleak import BleakClient

LIVE_AUDIO = 0x68
LIVE_HEADER_LEN = 5
FRAME_LEN = 40
FRAME_MS = 20
MAX_54_REPLIES = 3


class Probe:
    def __init__(self, client: BleakClient, outdir: str):
        self.client = client
        self.t0 = time.monotonic()
        self.log = open(os.path.join(outdir, "notify.jsonl"), "w")
        self.outdir = outdir
        self.audio = bytearray()
        self.headers = []             # 5-byte headers of 0x68 frames
        self.live_count = 0
        self.first_live_t = None
        self.last_live_t = None
        self.cmd_counts = collections.Counter()
        self.replies_54 = 0
        self.reply_54_enabled = False
        self.waiters: dict[int, asyncio.Future] = {}

    def now(self):
        return round(time.monotonic() - self.t0, 3)

    def note(self, event: str, **kw):
        if self.log.closed:  # disconnect callback fires after normal teardown
            return
        rec = {"t": self.now(), "event": event, **kw}
        self.log.write(json.dumps(rec, ensure_ascii=False) + "\n")
        self.log.flush()
        if event != "notify" or kw.get("cmd") != f"0x{LIVE_AUDIO:02x}":
            print(json.dumps(rec, ensure_ascii=False))

    def on_notify(self, _char, data: bytearray):
        data = bytes(data)
        cmd = data[1] if len(data) >= 2 else -1
        self.cmd_counts[cmd] += 1
        if cmd == LIVE_AUDIO:
            # keep headers only; raw audio goes to live.bin (not committed)
            self.note("notify", cmd=f"0x{cmd:02x}", len=len(data), head=data[:8].hex(),
                      audio_len=max(len(data) - 8, 0),
                      audio_sha256=hashlib.sha256(data[8:]).hexdigest()[:16])
        else:
            self.note("notify", cmd=f"0x{cmd:02x}", len=len(data), hex=data.hex())
        if cmd == LIVE_AUDIO and len(data) >= 3:
            body = data[3:3 + data[2]]
            self.headers.append(body[:LIVE_HEADER_LEN].hex())
            self.audio += body[LIVE_HEADER_LEN:]
            self.live_count += 1
            t = time.monotonic()
            self.first_live_t = self.first_live_t or t
            self.last_live_t = t
            if self.live_count in (1, 10, 100) or self.live_count % 500 == 0:
                print(f"  0x68 #{self.live_count} len={len(data)} audio={len(self.audio)}B")
            return
        if cmd == P.Cmd.START_REALTIME and self.reply_54_enabled:
            if self.replies_54 < MAX_54_REPLIES:
                self.replies_54 += 1
                asyncio.get_event_loop().create_task(
                    self.send("0x54[1] (reply to 0x54)", P.build_frame(P.Cmd.START_REALTIME, b"\x01")))
            else:
                self.note("skip_54_reply", reason="cap reached")
        w = self.waiters.pop(cmd, None)
        if w and not w.done():
            w.set_result(data)

    async def send(self, label: str, frame: bytes):
        self.note("send", label=label, hex=frame.hex())
        try:
            await self.client.write_gatt_char(P.WRITE_UUID, frame, response=True)
        except Exception as e:
            self.note("send_error", label=label, error=repr(e))

    async def query(self, label: str, frame: bytes, cmd: int, timeout=3.0):
        fut = asyncio.get_event_loop().create_future()
        self.waiters[cmd] = fut
        await self.send(label, frame)
        try:
            data = await asyncio.wait_for(fut, timeout)
            fr = P.parse_frame(data)
            payload = fr.payload.hex() if isinstance(fr.payload, (bytes, bytearray)) else fr.payload
            self.note("reply", label=label, payload=payload)
            return fr.payload
        except asyncio.TimeoutError:
            self.waiters.pop(cmd, None)
            self.note("timeout", label=label)
            return None


def analyze(probe: Probe, seconds: float, disconnected_at):
    frames, rest = P.split_opus_frames(bytes(probe.audio), FRAME_LEN)
    span = (probe.last_live_t - probe.first_live_t) if probe.first_live_t else 0.0
    toc = collections.Counter(f[0] for f in frames)
    chunk_lens = collections.Counter()
    for line in open(os.path.join(probe.outdir, "notify.jsonl")):
        r = json.loads(line)
        if r.get("cmd") == f"0x{LIVE_AUDIO:02x}":
            chunk_lens[r["len"]] += 1
    expected = span * 1000 / FRAME_MS if span else 0
    summary = {
        "seconds_requested": seconds,
        "disconnected_at": disconnected_at,
        "notify_counts": {f"0x{k:02x}": v for k, v in probe.cmd_counts.items()},
        "live_notifications": probe.live_count,
        "live_notify_len_hist": dict(chunk_lens),
        "audio_bytes": len(probe.audio),
        "frames_40B": len(frames),
        "remainder_bytes": len(rest),
        "live_span_s": round(span, 3),
        "expected_frames_by_span": round(expected),
        "frame_deviation_pct": round((len(frames) - expected) / expected * 100, 2) if expected else None,
        "toc_byte_hist_top5": {f"0x{k:02x}": v for k, v in toc.most_common(5)},
        "distinct_toc_bytes": len(toc),
        "header_samples": probe.headers[:5] + (["..."] + probe.headers[-3:] if len(probe.headers) > 5 else []),
        "replies_54_sent": probe.replies_54,
    }
    with open(os.path.join(probe.outdir, "live.bin"), "wb") as f:
        f.write(probe.audio)
    if frames:
        with open(os.path.join(probe.outdir, "live.ogg"), "wb") as f:
            f.write(wrap_opus_frames_as_ogg(frames))
    with open(os.path.join(probe.outdir, "summary.json"), "w") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)
    return summary


async def run_once(address: str, method: str, seconds: float, outdir: str):
    os.makedirs(outdir, exist_ok=True)
    disconnected = {"at": None}
    probe_ref = {}

    def on_disconnect(_c):
        p = probe_ref.get("p")
        disconnected["at"] = p.now() if p else -1
        if p:
            p.note("disconnected")

    async with BleakClient(address, disconnected_callback=on_disconnect) as client:
        probe = Probe(client, outdir)
        probe_ref["p"] = probe
        probe.note("connected", address=address, method=method, seconds=seconds)
        await client.start_notify(P.NOTIFY_UUID, probe.on_notify)

        await probe.query("0x80 device info", P.frame_query_device_info(), P.Cmd.QUERY_DEVICE_INFO)
        await probe.query("0x56 rec status (before)", P.frame_query_rec_status(), P.Cmd.QUERY_REC_STATUS)

        if method == "51":
            await probe.send("0x51[1]", P.build_frame(P.Cmd.START_RECORDING, b"\x01"))
        elif method == "54":
            await probe.send("0x54[1]", P.build_frame(P.Cmd.START_REALTIME, b"\x01"))
        elif method == "official":
            probe.reply_54_enabled = True
            await probe.send("0x51[1]", P.build_frame(P.Cmd.START_RECORDING, b"\x01"))
            await asyncio.sleep(0.5)
            if probe.live_count == 0 and client.is_connected:
                await probe.send("0x54[1] (no 0x68 after 0.5s)",
                                 P.build_frame(P.Cmd.START_REALTIME, b"\x01"))

        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline and client.is_connected:
            await asyncio.sleep(0.2)

        if client.is_connected:
            await probe.send("0x50 stop", P.frame_stop_recording())
            await asyncio.sleep(2.0)
            if client.is_connected:
                await probe.query("0x56 rec status (after)", P.frame_query_rec_status(),
                                  P.Cmd.QUERY_REC_STATUS)
        probe.note("done")
        probe.log.close()
        return analyze(probe, seconds, disconnected["at"])


async def main_async(args):
    stamp = time.strftime("%Y%m%d-%H%M%S")
    results = []
    for i in range(1, args.repeat + 1):
        outdir = os.path.join(args.out, f"{stamp}-{args.method}-{args.seconds:g}s-run{i}")
        print(f"\n=== run {i}/{args.repeat}: method={args.method} seconds={args.seconds} -> {outdir}")
        try:
            summary = await run_once(args.address, args.method, args.seconds, outdir)
        except Exception as e:
            summary = {"error": repr(e)}
            os.makedirs(outdir, exist_ok=True)
            with open(os.path.join(outdir, "summary.json"), "w") as f:
                json.dump(summary, f, ensure_ascii=False, indent=2)
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        results.append(summary)
        if i < args.repeat:
            await asyncio.sleep(args.gap)
    return results


def main():
    ap = argparse.ArgumentParser(description="Probe D·NOTE realtime recording (issue #4)")
    ap.add_argument("--address", required=True)
    ap.add_argument("--method", choices=["51", "54", "official"], required=True)
    ap.add_argument("--seconds", type=float, default=10)
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--gap", type=float, default=5, help="seconds between repeated runs")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                  "..", "evidence", "v1-live"))
    asyncio.run(main_async(ap.parse_args()))


if __name__ == "__main__":
    main()
