#!/usr/bin/env python3
"""
dnote.py — 追觅 D·NOTE (DNOTE001B) 录音卡 离线客户端 (命令行)

不依赖官方 App 与追觅云。通过 BLE 直连录音卡，支持:
  scan      扫描并识别录音卡
  info      连接并打印设备信息 (序列号、固件、电量等)
  status    查询录音状态 / 绑定状态 / 加密状态
  record    让设备开始录音 (可选时长后自动停止)
  stop      停止录音
  list      列出设备上的录音文件
  pull      下载全部(或指定)录音到本地, 自动解密并封装为 .ogg
  usb       开/关 USB 存储模式
  pair      绑定录音卡 (bondId 持久化到本地 .bond.json; 重复执行结果不变)
  unpair    解绑录音卡并清除本地 bondId
  synctime  校准设备时间

依赖:  pip install bleak cryptography

用法示例:
  python dnote.py scan
  python dnote.py info
  python dnote.py record --seconds 20
  python dnote.py list
  python dnote.py pull --out ./recordings
  python dnote.py pull --keep          # 下载后不删除设备上的文件(默认就是不删)
"""

from __future__ import annotations
import argparse
import asyncio
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dnote_protocol as P
from ogg_opus import wrap_opus_frames_as_ogg

try:
    from bleak import BleakScanner, BleakClient
    from bleak.backends.characteristic import BleakGATTCharacteristic
except ImportError:
    print("需要安装 bleak:  pip install bleak cryptography", file=sys.stderr)
    sys.exit(2)

SCAN_SECONDS = 15.0
BOND_STORE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".bond.json")


# ----------------------------------------------------------- 扫描 / 识别

def _adv_from_bleak(adv) -> P.AdvInfo | None:
    md = getattr(adv, "manufacturer_data", None) or {}
    for cid, data in md.items():
        info = P.parse_advertisement(cid, bytes(data))
        if info.valid:
            return info
    return None


async def scan(timeout=SCAN_SECONDS, want_print=True):
    """返回 [(device, advertisement_data, AdvInfo), ...] 中识别为 D·NOTE 的项。"""
    found = {}
    def cb(dev, adv):
        info = _adv_from_bleak(adv)
        if info:
            found[dev.address] = (dev, adv, info)
    scanner = BleakScanner(detection_callback=cb)
    await scanner.start()
    await asyncio.sleep(timeout)
    await scanner.stop()
    results = list(found.values())
    if want_print:
        if not results:
            print("未发现 D·NOTE 录音卡。请确认: 设备已唤醒(按一下按键)、靠近手机、未被其它设备连接。")
        for dev, adv, info in results:
            name = dev.name or adv.local_name or "?"
            print(f"[{name}]  {dev.address}")
            print(f"    固件 {info.firmware_version}  硬件 {info.hardware_version}  "
                  f"电量 {info.battery}%  SID {info.sid}  RSSI {adv.rssi}dBm")
    return results


async def _pick_device(address=None):
    if address:
        return address
    results = await scan(want_print=False)
    if not results:
        raise SystemExit("未发现录音卡。先运行 `scan`，或用 --address 指定地址。")
    if len(results) > 1:
        print("发现多台，请用 --address 指定其一:")
        for dev, adv, info in results:
            print(f"  {dev.address}  {dev.name or '?'}")
        raise SystemExit(1)
    return results[0][0].address


# ----------------------------------------------------------- 连接会话封装

class Session:
    """封装一次 BLE 连接: 发命令、收通知、按命令字分发。"""
    def __init__(self, client: BleakClient):
        self.client = client
        self._waiters: dict[int, asyncio.Future] = {}
        self._file_cb = None          # 下载时的分片回调
        self._list_items = []         # 文件列表累积
        self._list_done = None        # asyncio.Event

    def _on_notify(self, _char, data: bytearray):
        fr = P.parse_frame(bytes(data))
        if not fr.valid:
            return
        # 文件列表 0x90: 逐条 {index,name,size,end}
        if fr.cmd == P.Cmd.QUERY_FILE_LIST and isinstance(fr.payload, dict):
            pl = fr.payload
            if pl.get("end") == 1:
                if self._list_done:
                    self._list_done.set()
            else:
                self._list_items.append({"index": pl.get("index"),
                                         "name": pl.get("name"),
                                         "size": pl.get("size")})
            return
        # 文件数据 0x70
        if fr.cmd == P.Cmd.REQUEST_FILE_DATA and self._file_cb:
            self._file_cb(fr.payload)
            return
        # 其它: 唤醒等待该命令字的 future
        w = self._waiters.pop(fr.cmd, None)
        if w and not w.done():
            w.set_result(fr.payload)

    async def start(self):
        await self.client.start_notify(P.NOTIFY_UUID, self._on_notify)

    async def write(self, frame: bytes, response=True):
        await self.client.write_gatt_char(P.WRITE_UUID, frame, response=response)

    async def request(self, frame: bytes, expect_cmd: int, timeout=8.0):
        """发命令并等待对应命令字的通知返回。"""
        fut = asyncio.get_event_loop().create_future()
        self._waiters[expect_cmd] = fut
        await self.write(frame)
        try:
            return await asyncio.wait_for(fut, timeout)
        except asyncio.TimeoutError:
            self._waiters.pop(expect_cmd, None)
            raise

    async def device_info(self):
        return await self.request(P.frame_query_device_info(), P.Cmd.QUERY_DEVICE_INFO)

    async def bond_info(self):
        return await self.request(P.frame_query_bond(), P.Cmd.QUERY_BOND)

    async def rec_status(self):
        return await self.request(P.frame_query_rec_status(), P.Cmd.QUERY_REC_STATUS)

    async def file_list(self, timeout=15.0):
        self._list_items = []
        self._list_done = asyncio.Event()
        await self.write(P.frame_query_file_list())
        try:
            await asyncio.wait_for(self._list_done.wait(), timeout)
        except asyncio.TimeoutError:
            pass
        return list(self._list_items)

    async def download(self, name: str, size_hint=0, timeout=None):
        """下载单个文件, 返回拼接后的原始字节(可能是 'encryt' 密文或裸 opus)。"""
        if timeout is None:
            # Measured BLE throughput is ~23 KB/s; allow down to 5 KB/s.
            timeout = max(120.0, size_hint / 5000)
        chunks = []
        done = asyncio.get_event_loop().create_future()
        def cb(payload):
            if not isinstance(payload, dict):
                return
            start = payload.get("start", 0)
            status = start & 0xF0
            data = payload.get("data", b"")
            if status in (P.FileStatus.CANCELLED, P.FileStatus.ERROR, P.FileStatus.NOT_FOUND):
                if not done.done():
                    done.set_exception(RuntimeError(f"传输中止 status=0x{status:02x}"))
                return
            if data:
                chunks.append(data)
            if status == P.FileStatus.EOF:
                if not done.done():
                    done.set_result(True)
        self._file_cb = cb
        try:
            await self.write(P.frame_request_file(name, cmd=1, offset=0))
            await asyncio.wait_for(done, timeout)
        finally:
            self._file_cb = None
        return b"".join(chunks)


# ----------------------------------------------------------- 各命令实现

def _decode_to_ogg(raw: bytes, sn: str | None):
    """原始字节 -> (ogg_bytes, note)。自动判断是否加密。"""
    note = ""
    if P.is_encrypted_audio(raw):
        if not sn:
            raise RuntimeError("文件已加密, 但未取得设备序列号, 无法解密")
        plain = P.decrypt_audio_file(raw)   # 用 DEVICE_KEY_SECRET + sn 内部派生
        note = "已解密"
    else:
        plain = raw
        note = "明文"
    frames, remainder = P.split_opus_frames(plain, 40)
    ogg = wrap_opus_frames_as_ogg(frames)
    return ogg, f"{note}, {len(frames)}帧" + (f", 余{len(remainder)}B" if remainder else "")


async def cmd_info(args):
    addr = await _pick_device(args.address)
    async with BleakClient(addr) as client:
        s = Session(client); await s.start()
        info = await s.device_info()
        print("设备信息:", info)
        try:
            print("绑定:", await s.bond_info())
        except Exception as e:
            print("绑定查询失败:", e)


async def cmd_status(args):
    addr = await _pick_device(args.address)
    async with BleakClient(addr) as client:
        s = Session(client); await s.start()
        print("录音状态:", await s.rec_status())
        print("绑定:", await s.bond_info())


async def cmd_record(args):
    addr = await _pick_device(args.address)
    async with BleakClient(addr) as client:
        s = Session(client); await s.start()
        await s.write(P.frame_start_recording(False))
        print("已发送开始录音。")
        if args.seconds:
            print(f"录音 {args.seconds}s ...")
            await asyncio.sleep(args.seconds)
            await s.write(P.frame_stop_recording())
            print("已停止。等待设备写盘...")
            await asyncio.sleep(2.0)


async def cmd_stop(args):
    addr = await _pick_device(args.address)
    async with BleakClient(addr) as client:
        s = Session(client); await s.start()
        await s.write(P.frame_stop_recording())
        print("已发送停止录音。")


async def cmd_list(args):
    addr = await _pick_device(args.address)
    async with BleakClient(addr) as client:
        s = Session(client); await s.start()
        items = await s.file_list()
        if not items:
            print("设备上没有录音文件。")
        for it in items:
            print(f"  [{it['index']}] {it['name']}  {it['size']} bytes")


async def cmd_pull(args):
    addr = await _pick_device(args.address)
    os.makedirs(args.out, exist_ok=True)
    async with BleakClient(addr) as client:
        s = Session(client); await s.start()
        info = await s.device_info()
        sn = info.get("sn") if isinstance(info, dict) else None
        items = await s.file_list()
        if args.name:
            items = [it for it in items if it["name"] == args.name]
        if not items:
            print("无文件可下载。"); return
        for it in items:
            name = it["name"]
            print(f"下载 {name} ({it['size']}B) ...", end="", flush=True)
            t0 = time.time()
            try:
                raw = await s.download(name, it["size"])
            except Exception as e:
                print(f" 失败: {e}"); continue
            dt = time.time() - t0
            try:
                ogg, note = _decode_to_ogg(raw, sn)
            except Exception as e:
                # 解码失败也把原始字节存下来, 便于排查
                rawpath = os.path.join(args.out, name + ".raw")
                with open(rawpath, "wb") as f: f.write(raw)
                print(f" 解码失败({e}); 原始数据存至 {rawpath}")
                continue
            base = os.path.splitext(name)[0]
            outpath = os.path.join(args.out, base + ".ogg")
            with open(outpath, "wb") as f: f.write(ogg)
            print(f" OK {len(raw)}B/{dt:.1f}s -> {outpath} ({note})")
            # 默认不删除设备上的文件; 仅当 --delete 时才删
            if args.delete:
                await s.write(P.frame_delete_file(name))
                print(f"    已删除设备上的 {name}")


async def cmd_usb(args):
    addr = await _pick_device(args.address)
    async with BleakClient(addr) as client:
        s = Session(client); await s.start()
        await s.write(P.frame_set_usb_storage(args.on == "on"))
        print(f"USB 存储模式: {args.on}")


async def cmd_synctime(args):
    addr = await _pick_device(args.address)
    async with BleakClient(addr) as client:
        s = Session(client); await s.start()
        await s.write(P.frame_sync_time())
        print("已校准设备时间。")


# ----------------------------------------------------------- 绑定 (0xA0 / 0xA1)

def _load_bonds() -> dict:
    try:
        with open(BOND_STORE) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def _save_bonds(bonds: dict):
    with open(BOND_STORE, "w") as f:
        json.dump(bonds, f, indent=2)


def _fmt_bond(b) -> str:
    if not isinstance(b, dict):
        return repr(b)
    bid = b.get("bondId")
    return f"isBonded={b.get('isBonded')} bondId={bid.hex() if bid else None}"


async def _bond_write(s: Session, frame: bytes):
    """Send 0xA0 and report the device's 0xA0 reply, if any (not documented)."""
    try:
        ack = await s.request(frame, P.Cmd.BOND, timeout=2.0)
        print(f"  0xA0 响应: {ack.hex() if isinstance(ack, (bytes, bytearray)) else ack}")
    except asyncio.TimeoutError:
        print("  0xA0 无响应 (2s)")


async def _bond_state(s: Session) -> dict:
    b = await s.bond_info()
    return b if isinstance(b, dict) else {}


async def _query_bond_fresh(addr):
    async with BleakClient(addr) as client:
        s = Session(client); await s.start()
        return await _bond_state(s)


async def cmd_pair(args):
    addr = await _pick_device(args.address)
    bonds = _load_bonds()
    local = bytes.fromhex(bonds[addr]) if addr in bonds else None
    async with BleakClient(addr) as client:
        s = Session(client); await s.start()
        cur = await _bond_state(s)
        print("当前:", _fmt_bond(cur))
        if cur.get("isBonded") and local and cur.get("bondId") == local:
            print("已绑定本地 bondId, 跳过。")
            return
        if cur.get("isBonded") and not args.force:
            raise SystemExit("设备已绑定其它 bondId。确认要覆盖请先 `unpair` 或加 --force。")
        bond_id = local or os.urandom(16)
        print(f"写入 bondId={bond_id.hex()}")
        await _bond_write(s, P.frame_bond(bond_id))
        same = await _bond_state(s)
        print("同连接查询:", _fmt_bond(same))
        # H1 holds: the same-connection 0xA1 is authoritative. Save now so a failed
        # reconnect below cannot lose a bondId that is already on the card.
        if not (same.get("isBonded") and same.get("bondId") == bond_id):
            raise SystemExit("绑定未生效, 未保存 bondId。")
        bonds[addr] = bond_id.hex()
        _save_bonds(bonds)
        print(f"已保存到 {BOND_STORE}")
    # Reconnect check is informational only.
    try:
        fresh = await _query_bond_fresh(addr)
        ok_fresh = bool(fresh.get("isBonded")) and fresh.get("bondId") == bond_id
        print("重连后查询:", _fmt_bond(fresh), f"(一致={ok_fresh})")
    except Exception as e:
        print(f"重连复查失败 (不影响已保存的 bondId): {e!r}")


async def cmd_unpair(args):
    addr = await _pick_device(args.address)
    async with BleakClient(addr) as client:
        s = Session(client); await s.start()
        print("当前:", _fmt_bond(await _bond_state(s)))
        await _bond_write(s, P.frame_unbond())
        same = await _bond_state(s)
        print("同连接查询:", _fmt_bond(same))
    fresh = await _query_bond_fresh(addr)
    print("重连后查询:", _fmt_bond(fresh))
    print(f"结果: 不重连生效={not same.get('isBonded')}  重连后生效={not fresh.get('isBonded')}")
    bonds = _load_bonds()
    if bonds.pop(addr, None):
        _save_bonds(bonds)
        print("已清除本地 bondId。")


async def cmd_scan(args):
    await scan(args.timeout)


def main():
    ap = argparse.ArgumentParser(description="D·NOTE 录音卡离线客户端")
    ap.add_argument("--address", help="BLE 设备地址(跳过扫描)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("scan"); sp.add_argument("--timeout", type=float, default=SCAN_SECONDS)
    sub.add_parser("info")
    sub.add_parser("status")
    sp = sub.add_parser("record"); sp.add_argument("--seconds", type=float, default=0)
    sub.add_parser("stop")
    sub.add_parser("list")
    sp = sub.add_parser("pull")
    sp.add_argument("--out", default="./recordings")
    sp.add_argument("--name", help="只下载指定文件名")
    sp.add_argument("--delete", action="store_true", help="下载后删除设备上的文件(默认不删)")
    sp = sub.add_parser("usb"); sp.add_argument("on", choices=["on", "off"])
    sub.add_parser("synctime")
    sp = sub.add_parser("pair")
    sp.add_argument("--force", action="store_true", help="设备已绑定其它 bondId 时仍覆盖")
    sub.add_parser("unpair")

    args = ap.parse_args()
    fn = {
        "scan": cmd_scan, "info": cmd_info, "status": cmd_status,
        "record": cmd_record, "stop": cmd_stop, "list": cmd_list,
        "pull": cmd_pull, "usb": cmd_usb, "synctime": cmd_synctime,
        "pair": cmd_pair, "unpair": cmd_unpair,
    }[args.cmd]
    asyncio.run(fn(args))


if __name__ == "__main__":
    main()
