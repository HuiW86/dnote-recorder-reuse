#!/usr/bin/env python3
"""
probe_m1.py — Issue #34: verify device behaviours left open in prd.md §9.

Tests:
  switches  read 0x81; toggle each M1 setting (0x83-0x8F), read back, restore
  pause     0x51 [0] -> 0x52 pause -> 0x53 resume -> 0x50 stop; download and
            measure duration to tell whether the paused span was recorded
  offset    0x70 with a non-zero offset: compare against a full download, both
            on the same connection and after a mid-transfer disconnect

Every notification is logged to <out>/<test>.jsonl. Per ADR-006 the logs never
contain the raw sn, btaddr or bondId: 0x80/0xA1 payloads are redacted and not
hex-dumped. Audio is never written to <out>; only sizes and sha256 are logged.

Usage:
  python probe_m1.py --address <addr> --out <dir> switches|pause|offset [--name F]
"""

from __future__ import annotations
import argparse
import asyncio
import hashlib
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dnote_protocol as P

from bleak import BleakClient

SENSITIVE_CMDS = {0x80, 0xA1}


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def redact(payload):
    """Mask identifiers per ADR-006."""
    if not isinstance(payload, dict):
        return payload
    out = dict(payload)
    if "sn" in out:
        out["sn"] = "sha256:" + sha(str(out["sn"]).encode())[:8]
    if "btaddr" in out:
        a = str(out["btaddr"])
        out["btaddr"] = "****" + a[-4:]
    if "bondId" in out:
        out["bondId"] = "<redacted>" if out["bondId"] else None
    return out


def jsonable(v):
    if isinstance(v, (bytes, bytearray)):
        return {"len": len(v), "sha256": sha(bytes(v))[:16]}
    if isinstance(v, dict):
        return {k: jsonable(x) for k, x in v.items()}
    return v


class Probe:
    def __init__(self, client: BleakClient, log_path: str):
        self.client = client
        self.log = open(log_path, "a")
        self.t0 = time.monotonic()
        self.waiters: dict[int, asyncio.Future] = {}
        self.file_cb = None
        self.list_items: list = []
        self.list_done: asyncio.Event | None = None

    def note(self, kind: str, **kw):
        rec = {"t": round(time.monotonic() - self.t0, 3), "kind": kind, **kw}
        self.log.write(json.dumps(rec, ensure_ascii=False) + "\n")
        self.log.flush()
        print(json.dumps(rec, ensure_ascii=False))

    def on_notify(self, _c, data: bytearray):
        data = bytes(data)
        fr = P.parse_frame(data)
        if not fr.valid:
            self.note("notify-invalid", hex=data.hex())
            return
        if fr.cmd == P.Cmd.REQUEST_FILE_DATA:
            if self.file_cb:
                self.file_cb(fr.payload)
            return
        if fr.cmd == P.Cmd.QUERY_FILE_LIST and isinstance(fr.payload, dict):
            if fr.payload.get("end") == 1:
                if self.list_done:
                    self.list_done.set()
            else:
                self.list_items.append(fr.payload)
            return
        entry = {"cmd": f"0x{fr.cmd:02x}", "payload": jsonable(redact(fr.payload))}
        if fr.cmd not in SENSITIVE_CMDS:
            entry["hex"] = data.hex()
        self.note("notify", **entry)
        w = self.waiters.pop(fr.cmd, None)
        if w and not w.done():
            w.set_result(fr.payload)

    async def start(self):
        await self.client.start_notify(P.NOTIFY_UUID, self.on_notify)

    async def write(self, frame: bytes):
        self.note("write", hex=frame.hex())
        await self.client.write_gatt_char(P.WRITE_UUID, frame, response=True)

    async def request(self, frame: bytes, expect: int, timeout=8.0):
        fut = asyncio.get_event_loop().create_future()
        self.waiters[expect] = fut
        await self.write(frame)
        try:
            return await asyncio.wait_for(fut, timeout)
        except asyncio.TimeoutError:
            self.waiters.pop(expect, None)
            self.note("timeout", cmd=f"0x{expect:02x}")
            return None

    async def file_list(self):
        self.list_items, self.list_done = [], asyncio.Event()
        await self.write(P.frame_query_file_list())
        try:
            await asyncio.wait_for(self.list_done.wait(), 15)
        except asyncio.TimeoutError:
            self.note("timeout", cmd="0x90")
        return list(self.list_items)

    async def download(self, name: str, offset=0, stop_after=None, timeout=180.0):
        """Return (bytes, chunk offsets seen, terminal status). stop_after: bytes."""
        chunks, offsets = [], []
        done = asyncio.get_event_loop().create_future()
        received = 0

        def cb(pl):
            nonlocal received
            if not isinstance(pl, dict):
                return
            status = pl.get("start", 0) & 0xF0
            data = pl.get("data", b"")
            offsets.append(pl.get("offset"))
            if status in (P.FileStatus.CANCELLED, P.FileStatus.ERROR, P.FileStatus.NOT_FOUND):
                if not done.done():
                    done.set_result(f"0x{status:02x}")
                return
            if data:
                chunks.append(data)
                received += len(data)
            if status == P.FileStatus.EOF and not done.done():
                done.set_result("eof")
            elif stop_after and received >= stop_after and not done.done():
                done.set_result("stopped")

        self.file_cb = cb
        try:
            await self.write(P.frame_request_file(name, cmd=1, offset=offset))
            status = await asyncio.wait_for(done, timeout)
        except asyncio.TimeoutError:
            status = "timeout"
        finally:
            self.file_cb = None
        return b"".join(chunks), offsets, status


async def connect(addr, log_path):
    client = BleakClient(addr)
    await client.connect()
    p = Probe(client, log_path)
    await p.start()
    return client, p


# ------------------------------------------------------------------ switches

M1_SETTINGS = [
    # (cmd, field guessed in PROTOCOL.md §4.1, kind)
    (0x83, "led", "bool"),
    (0x84, "motor", "bool"),
    (0x85, "nc", "bool"),
    (0x8B, "vad", "bool"),
    (0x8C, "gain", "level"),
    (0x8D, "nn", "level"),
    (0x8F, "autoff", "seconds"),
]


def encode(kind, value) -> bytes:
    if kind == "seconds":
        return int(value).to_bytes(4, "big")
    return bytes([int(value)])


async def test_switches(addr, out):
    client, p = await connect(addr, os.path.join(out, "switches.jsonl"))
    results = []
    try:
        base = await p.request(P.build_frame(0x81), 0x81)
        p.note("baseline", switches=base)
        if not isinstance(base, dict):
            p.note("abort", reason="0x81 did not return JSON")
            return
        for cmd, field, kind in M1_SETTINGS:
            orig = base.get(field)
            if orig is None:
                results.append({"cmd": f"0x{cmd:02x}", "field": field, "result": "field-missing"})
                continue
            if kind == "bool":
                new = 0 if int(orig) else 1
            elif kind == "level":
                new = 5 if int(orig) != 5 else 6
            else:
                new = int(orig) + 60 if int(orig) else 600
            ack = await p.request(P.build_frame(cmd, encode(kind, new)), cmd, timeout=3)
            await asyncio.sleep(0.5)
            after = await p.request(P.build_frame(0x81), 0x81)
            got = after.get(field) if isinstance(after, dict) else None
            changed = {k: (base.get(k), after.get(k)) for k in (after or {}) if after.get(k) != base.get(k)}
            # Restore before moving on so a failure leaves the card as it was.
            await p.request(P.build_frame(cmd, encode(kind, orig)), cmd, timeout=3)
            await asyncio.sleep(0.5)
            restored = await p.request(P.build_frame(0x81), 0x81)
            ok_restore = isinstance(restored, dict) and restored.get(field) == orig
            r = {"cmd": f"0x{cmd:02x}", "field": field, "orig": orig, "set": new,
                 "ack": jsonable(ack), "readback": got, "match": got == new,
                 "changed_fields": changed, "restored": ok_restore}
            results.append(r)
            p.note("result", **r)
    finally:
        p.note("summary", results=results)
        await client.disconnect()


# ------------------------------------------------------------------ pause

async def test_pause(addr, out, seg=10.0):
    client, p = await connect(addr, os.path.join(out, "pause.jsonl"))
    try:
        st = await p.request(P.frame_query_rec_status(), P.Cmd.QUERY_REC_STATUS)
        if isinstance(st, dict) and st.get("rec") == 1:
            p.note("abort", reason="card already recording")
            return
        started = await p.request(P.frame_start_recording(False), P.Cmd.START_RECORDING)
        name = started.get("name") if isinstance(started, dict) else None
        p.note("phase", phase="recording", name=name)
        await asyncio.sleep(seg)
        ack = await p.request(P.build_frame(P.Cmd.PAUSE_RECORDING), P.Cmd.PAUSE_RECORDING, timeout=3)
        p.note("phase", phase="paused", ack=jsonable(ack))
        await asyncio.sleep(1)
        p.note("status-during-pause", status=await p.request(P.frame_query_rec_status(), P.Cmd.QUERY_REC_STATUS))
        await asyncio.sleep(seg - 1)
        ack = await p.request(P.build_frame(P.Cmd.RESUME_RECORDING), P.Cmd.RESUME_RECORDING, timeout=3)
        p.note("phase", phase="resumed", ack=jsonable(ack))
        await asyncio.sleep(1)
        p.note("status-after-resume", status=await p.request(P.frame_query_rec_status(), P.Cmd.QUERY_REC_STATUS))
        await asyncio.sleep(seg - 1)
        await p.request(P.frame_stop_recording(), P.Cmd.STOP_RECORDING, timeout=3)
        p.note("phase", phase="stopped")
        await asyncio.sleep(2)
        files = await p.file_list()
        size = next((f.get("size") for f in files if f.get("name") == name), None)
        if not name or size is None:
            p.note("abort", reason="new file not listed", name=name)
            return
        raw, _, status = await p.download(name)
        plain = P.decrypt_audio_file(raw) if P.is_encrypted_audio(raw) else raw
        frames, rem = P.split_opus_frames(plain, 40)
        dur = len(frames) * 0.02
        p.note("result", name=name, size=size, got=len(raw), status=status,
               frames=len(frames), remainder=len(rem), duration_s=round(dur, 2),
               expected_if_paused=round(2 * seg, 1), expected_if_not_paused=round(3 * seg, 1),
               audio_sha256=sha(plain)[:16])
    finally:
        await client.disconnect()


# ------------------------------------------------------------------ offset

async def test_offset(addr, out, name):
    log = os.path.join(out, "offset.jsonl")
    client, p = await connect(addr, log)
    try:
        full, offs, status = await p.download(name)
        p.note("full", name=name, len=len(full), status=status, sha256=sha(full)[:16],
               first_offsets=offs[:3], chunks=len(offs))
        if status != "eof":
            return
        for off in (len(full) // 2, len(full) // 2 + 13):
            part, offs, status = await p.download(name, offset=off)
            p.note("same-connection", offset=off, len=len(part), status=status,
                   first_offsets=offs[:3], matches_tail=part == full[off:],
                   matches_whole=part == full)
        # Interrupted transfer: stop halfway, drop the link, resume on a new connection.
        head, offs, status = await p.download(name, stop_after=len(full) // 2)
        p.note("interrupted", got=len(head), status=status)
    finally:
        await client.disconnect()
    await asyncio.sleep(3)
    client, p = await connect(addr, log)
    try:
        tail, offs, status = await p.download(name, offset=len(head))
        joined = head + tail
        p.note("resumed", offset=len(head), len=len(tail), status=status,
               first_offsets=offs[:3], joined_len=len(joined),
               joined_sha256=sha(joined)[:16], equals_full=joined == full)
    finally:
        await client.disconnect()


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--address", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("test", choices=["switches", "pause", "offset"])
    ap.add_argument("--name", help="file for the offset test")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    if a.test == "switches":
        await test_switches(a.address, a.out)
    elif a.test == "pause":
        await test_pause(a.address, a.out)
    else:
        if not a.name:
            raise SystemExit("--name is required for offset")
        await test_offset(a.address, a.out, a.name)


if __name__ == "__main__":
    asyncio.run(main())
