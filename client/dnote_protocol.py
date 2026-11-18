"""
dnote_protocol.py — 追觅 D·NOTE (DNOTE001B) 录音卡 BLE 协议实现

本模块为纯协议层，不依赖任何蓝牙库，便于单元测试与跨栈复用。
协议内容逆向自官方 DreameNote App (com.dnote.dreame, Capacitor/JS 实现)。

帧格式:  [PID=0xA0][CMD][LEN][PAYLOAD...]
  - PID   固定 0xA0
  - CMD   命令字 (见 Cmd)
  - LEN   PAYLOAD 字节数 (单字节, 0~255)
  - 多数命令 PAYLOAD 为 UTF-8 JSON; 少数为裸字节 (见各 frame_* 函数注释)

GATT:
  SERVICE 00006001-0000-1000-8000-00805f9b34fb
  WRITE   00006002-0000-1000-8000-00805f9b34fb   (write / writeWithoutResponse)
  NOTIFY  00006003-0000-1000-8000-00805f9b34fb   (notifications)

广播:
  厂商数据公司 ID = 0x22A3 (十进制 8867); FE98 为 SIG 成员 service UUID
"""

from __future__ import annotations
import json
import struct
import hmac
import hashlib
from dataclasses import dataclass
from datetime import datetime

# ------------------------------------------------------------------ 常量

SERVICE_UUID = "00006001-0000-1000-8000-00805f9b34fb"
WRITE_UUID   = "00006002-0000-1000-8000-00805f9b34fb"
NOTIFY_UUID  = "00006003-0000-1000-8000-00805f9b34fb"

PID = 0xA0
CID_VALUE = 8867  # 广播厂商数据公司 ID

# 从 App 中硬编码提取的派生密钥 secret (32 字节)。
# ChaCha20 音频密钥 = HMAC-SHA256(DEVICE_KEY_SECRET, 设备序列号 sn 的 UTF-8)
DEVICE_KEY_SECRET = bytes([
    58, 127, 209, 158, 82, 196, 139, 6, 175, 45, 232, 116, 25, 92, 179, 240,
    110, 161, 71, 220, 131, 47, 149, 107, 12, 212, 231, 56, 242, 26, 142, 89,
])


class Cmd:
    # 查询 / 设置
    QUERY_DEVICE_INFO      = 0x80  # -> JSON {sn, btaddr, bt, recmode, ...}
    QUERY_DEVICE_SWITCHES  = 0x81
    SET_USB_MASS_STORAGE   = 0x82  # payload: [0|1]
    SET_LED                = 0x83  # payload: [0|1]
    SET_MOTOR              = 0x84  # payload: [0|1]
    SET_NOISE_CANCEL       = 0x85  # payload: [0|1]
    SET_BT_NAME            = 0x86  # payload: JSON {bt}
    SYNC_TIME              = 0x87  # payload: JSON {time:"YYYYMMDDHHmmss"}
    SET_WIFI_AP            = 0x88  # payload: JSON {ap,ssid,psk}
    SET_WIFI_STA           = 0x89  # payload: JSON {wifi_ssid,wifi_password,url}
    SET_SAVE_WAV           = 0x8A  # payload: [0|1]
    SET_VAD                = 0x8B  # payload: [0|1]
    SET_GAIN               = 0x8C  # payload: [1..9]
    SET_NOISE_LEVEL        = 0x8D  # payload: [1..9]
    SET_IDLE_SHUTDOWN      = 0x8F  # payload: uint32 BE 秒
    # 文件
    QUERY_FILE_LIST        = 0x90  # -> 逐条 JSON {index,name,size,end}
    DELETE_FILE            = 0x91  # payload: JSON {name}
    QUERY_FILE_SIZE        = 0x92  # payload: JSON {name}
    RESTORE_FACTORY        = 0x93
    FORMAT_DISK            = 0x94
    SHUTDOWN               = 0x95
    # 录音
    STOP_RECORDING         = 0x50
    START_RECORDING        = 0x51  # payload: [0|1]; [1] also streams 0x68 realtime audio
    PAUSE_RECORDING        = 0x52
    RESUME_RECORDING       = 0x53
    START_REALTIME         = 0x54  # payload: [0|1]; no effect alone on fw v1.50 (see PROTOCOL.md 4.3)
    REALTIME_AUDIO         = 0x68  # notify: [flag|seq(1)][offset(4,BE)][opus frames]
    QUERY_REC_STATUS       = 0x56
    # 文件数据传输
    REQUEST_FILE_DATA      = 0x70  # payload: JSON {cmd,name,offset}
    # 绑定 / 加密
    BOND                   = 0xA0  # payload: [1]+16B bondId  (解绑: [0])
    QUERY_BOND             = 0xA1  # -> {isBonded, bondId}
    SET_CHACHA20_KEY       = 0xA2  # payload: [enable]+32B key
    QUERY_CHACHA20         = 0xA3
    # 固件 (L3, 暂不使用)
    FW_START               = 0xB0
    FW_DATA                = 0xB1


class FileStatus:
    """0x70 响应中 start 字节的高 4 位 (start & 0xF0)。"""
    EOF       = 0x20
    CANCELLED = 0x30
    ERROR     = 0x40
    NOT_FOUND = 0xF0


LIVE_HEADER_LEN = 5  # 0x68 payload header before Opus data


class PowerState:
    Unknown = 0
    BatteryOnly = 1
    ChargingOnly = 2
    PoweringOutOnly = 3
    PassThrough = 4


# ------------------------------------------------------------------ 帧编解码

def build_frame(cmd: int, payload=None) -> bytes:
    """按 [PID][CMD][LEN][PAYLOAD] 组帧。
    payload 可为 None / bytes / str / dict(自动 JSON 编码)。"""
    if payload is None:
        body = b""
    elif isinstance(payload, (bytes, bytearray)):
        body = bytes(payload)
    elif isinstance(payload, str):
        body = payload.encode("utf-8")
    else:  # dict / list -> JSON
        body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if len(body) > 255:
        raise ValueError("payload too long for single-byte length field")
    return bytes([PID, cmd & 0xFF, len(body)]) + body


@dataclass
class Frame:
    valid: bool
    cmd: int = 0
    payload: object = None


def parse_frame(data: bytes) -> Frame:
    """解析设备通知帧。返回 Frame；对已知命令做结构化解码。"""
    if len(data) < 3:
        return Frame(valid=False)
    pid, cmd, lc = data[0], data[1], data[2]
    if pid != PID or len(data) < 3 + lc:
        return Frame(valid=False)
    if lc == 0:
        return Frame(valid=True, cmd=cmd, payload=None)

    body = data[3:3 + lc]

    # 0x70 文件数据: [start(1)][offset(4,BE)][data...]
    if cmd == 0x70:
        if lc < 5:
            # No offset field. A bare 1-byte 0x4X is the card refusing the transfer
            # (PROTOCOL.md §5); keep the status byte so callers see the error.
            return Frame(valid=True, cmd=cmd,
                         payload={"start": body[0], "offset": 0, "data": b""})
        start = body[0]
        offset = struct.unpack(">I", body[1:5])[0]
        return Frame(valid=True, cmd=cmd,
                     payload={"start": start, "offset": offset, "data": body[5:]})

    # 0x68 实时音频: [flag(hi4)|seq(lo4)][offset(4,BE)][data...]
    if cmd == 0x68 and lc >= LIVE_HEADER_LEN:
        return Frame(valid=True, cmd=cmd, payload={
            "flag": body[0] >> 4,
            "seq": body[0] & 0x0F,
            "offset": struct.unpack(">I", body[1:5])[0],
            "data": body[LIVE_HEADER_LEN:],
        })

    # 0xA1 绑定信息: [isBonded(1)][bondId(16)]
    if cmd == 0xA1:
        return Frame(valid=True, cmd=cmd, payload={
            "isBonded": body[0] == 1,
            "bondId": body[1:17] if lc >= 17 else None,
        })

    # 单字节响应
    if lc == 1:
        return Frame(valid=True, cmd=cmd, payload=body)

    # 其余按 JSON 解析, 失败则原样返回文本
    try:
        return Frame(valid=True, cmd=cmd, payload=json.loads(body.decode("utf-8")))
    except Exception:
        return Frame(valid=True, cmd=cmd, payload=body.decode("utf-8", "replace"))


# ------------------------------------------------------------------ 广播解析

@dataclass
class AdvInfo:
    valid: bool
    cid: int = 0
    bid: int = 0
    pid: int = 0
    firmware_version: str = ""
    hardware_version: str = ""
    battery: int = 0
    power_state: int = 0
    sid: int = 0


def parse_advertisement(manufacturer_id: int, data: bytes) -> AdvInfo:
    """解析广播厂商数据。
    bleak 的 manufacturer_data 是 {company_id: bytes}；本函数需要
    company_id 与其后的 data 一并传入(内部会重建 App 所见的字节序)。"""
    buf = bytes([(manufacturer_id >> 8) & 0xFF, manufacturer_id & 0xFF]) + bytes(data)
    if len(buf) < 15:
        return AdvInfo(valid=False)
    cid = struct.unpack(">H", buf[0:2])[0]
    if cid != CID_VALUE:
        return AdvInfo(valid=False)
    bid = struct.unpack(">H", buf[2:4])[0]
    pid = struct.unpack(">H", buf[4:6])[0]
    fw = f"v{buf[6]}.{buf[7]}"
    hw = f"v{buf[8]}.{buf[9]}"
    battery = buf[10]
    power = buf[11]
    sid = (buf[12] << 16) | (buf[13] << 8) | buf[14]
    return AdvInfo(valid=True, cid=cid, bid=bid, pid=pid,
                   firmware_version=fw, hardware_version=hw,
                   battery=battery, power_state=power, sid=sid)


# ------------------------------------------------------------------ 命令构造 (便捷封装)

def frame_query_device_info():   return build_frame(Cmd.QUERY_DEVICE_INFO)
def frame_query_switches():      return build_frame(Cmd.QUERY_DEVICE_SWITCHES)
def frame_set_usb_storage(on):   return build_frame(Cmd.SET_USB_MASS_STORAGE, bytes([1 if on else 0]))
def frame_sync_time(dt=None):
    t = (dt or datetime.now()).strftime("%Y%m%d%H%M%S")
    return build_frame(Cmd.SYNC_TIME, {"time": t})
def frame_query_file_list():     return build_frame(Cmd.QUERY_FILE_LIST)
def frame_query_file_size(name): return build_frame(Cmd.QUERY_FILE_SIZE, {"name": name})
def frame_delete_file(name):     return build_frame(Cmd.DELETE_FILE, {"name": name})
def frame_request_file(name, cmd=1, offset=0):
    """cmd=1 启动下载(App 使用值)；offset 断点续传起点。"""
    return build_frame(Cmd.REQUEST_FILE_DATA, {"cmd": cmd, "name": name, "offset": offset})
def frame_start_recording(flag=False):
    """flag=True: record and stream realtime audio via 0x68."""
    return build_frame(Cmd.START_RECORDING, bytes([1 if flag else 0]))
def frame_stop_recording():      return build_frame(Cmd.STOP_RECORDING)
def frame_query_rec_status():    return build_frame(Cmd.QUERY_REC_STATUS)
def frame_query_bond():          return build_frame(Cmd.QUERY_BOND)
def frame_bond(bond_id):
    if len(bond_id) != 16:
        raise ValueError("bondId must be 16 bytes")
    return build_frame(Cmd.BOND, bytes([1]) + bytes(bond_id))
def frame_unbond():              return build_frame(Cmd.BOND, bytes([0]))
def frame_set_chacha20(enable, key32):
    if len(key32) != 32:
        raise ValueError("key must be 32 bytes")
    return build_frame(Cmd.SET_CHACHA20_KEY, bytes([1 if enable else 0]) + bytes(key32))


# ------------------------------------------------------------------ 密钥派生 & 音频解密

def derive_device_key(sn: str | bytes) -> bytes:
    """ChaCha20 音频密钥 = HMAC-SHA256(DEVICE_KEY_SECRET, sn)。"""
    msg = sn.encode("utf-8") if isinstance(sn, str) else bytes(sn)
    return hmac.new(DEVICE_KEY_SECRET, msg, hashlib.sha256).digest()


def is_encrypted_audio(buf: bytes) -> bool:
    return len(buf) >= 6 and buf[:6] == b"encryt"


def decrypt_audio_file(buf: bytes) -> bytes:
    """解密 'encryt' 格式文件，返回明文(裸 Opus 帧流)。

    文件布局 (与 App decryptAudioFile 对应):
      [0:6]   magic "encryt"
      [0:24]  头 24 字节 (含 magic)，解密后用于校验
      [6:24]  18 字节派生料 -> HMAC 输入
      [24:36] 12 字节 ChaCha20 nonce
      [36:60] 24 字节校验块(密文)
      [60:]   音频密文
    解密: key = HMAC-SHA256(DEVICE_KEY_SECRET, buf[6:24])
          明文 = ChaCha20(key, nonce, buf[36:60] + buf[60:])
          校验: 明文[0:24] == buf[0:24]
          返回: 明文[24:]
    """
    if len(buf) < 60:
        raise ValueError("encrypted file too short")
    if not is_encrypted_audio(buf):
        raise ValueError("not an encrypted audio file")
    header24 = buf[0:24]
    key_material = buf[6:24]
    nonce = buf[24:36]
    ct = buf[36:60] + buf[60:]
    key = hmac.new(DEVICE_KEY_SECRET, key_material, hashlib.sha256).digest()
    plain = _chacha20(key, nonce, ct)
    if plain[0:24] != header24:
        raise ValueError("verification mismatch (wrong key or corrupt file)")
    return plain[24:]


def _chacha20(key: bytes, nonce: bytes, data: bytes) -> bytes:
    """ChaCha20 流密码。优先用 cryptography 库；否则纯 Python 实现。
    App 使用 @noble/ciphers 的 chacha20，12 字节 nonce，初始计数 0。"""
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms
        # cryptography 的 ChaCha20 需要 16 字节 nonce = counter(4,LE)+nonce(12)
        full_nonce = (0).to_bytes(4, "little") + bytes(nonce)
        c = Cipher(algorithms.ChaCha20(bytes(key), full_nonce), mode=None)
        d = c.decryptor()
        return d.update(bytes(data)) + d.finalize()
    except Exception:
        return _chacha20_py(key, nonce, data)


def _chacha20_py(key: bytes, nonce: bytes, data: bytes) -> bytes:
    def rotl(x, n): return ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF
    def qr(s, a, b, c, d):
        s[a] = (s[a] + s[b]) & 0xFFFFFFFF; s[d] ^= s[a]; s[d] = rotl(s[d], 16)
        s[c] = (s[c] + s[d]) & 0xFFFFFFFF; s[b] ^= s[c]; s[b] = rotl(s[b], 12)
        s[a] = (s[a] + s[b]) & 0xFFFFFFFF; s[d] ^= s[a]; s[d] = rotl(s[d], 8)
        s[c] = (s[c] + s[d]) & 0xFFFFFFFF; s[b] ^= s[c]; s[b] = rotl(s[b], 7)
    const = b"expand 32-byte k"
    key_w = struct.unpack("<8I", key)
    nonce_w = struct.unpack("<3I", nonce)
    out = bytearray()
    counter = 0
    for off in range(0, len(data), 64):
        state = list(struct.unpack("<4I", const)) + list(key_w) + [counter] + list(nonce_w)
        w = state[:]
        for _ in range(10):
            qr(w, 0, 4, 8, 12); qr(w, 1, 5, 9, 13); qr(w, 2, 6, 10, 14); qr(w, 3, 7, 11, 15)
            qr(w, 0, 5, 10, 15); qr(w, 1, 6, 11, 12); qr(w, 2, 7, 8, 13); qr(w, 3, 4, 9, 14)
        ks = b"".join(struct.pack("<I", (w[i] + state[i]) & 0xFFFFFFFF) for i in range(16))
        block = data[off:off + 64]
        out += bytes(b ^ k for b, k in zip(block, ks))
        counter += 1
    return bytes(out)


# ------------------------------------------------------------------ Opus -> OGG 封装

def split_opus_frames(buf: bytes, frame_len: int = 40):
    """设备音频为定长 40 字节/帧 (16kHz 单声道 20ms Opus)。"""
    frames = []
    i = 0
    while i <= len(buf) - frame_len:
        frames.append(buf[i:i + frame_len])
        i += frame_len
    return frames, buf[i:]


# ------------------------------------------------------------------ Opus 帧头 (TOC)

def opus_toc(first_byte: int) -> dict:
    """Decode the first byte of an Opus packet (TOC, RFC 6716 section 3.1).

    frame_us is one frame's duration in microseconds. code 0 means one frame per packet,
    1 and 2 mean two, 3 means the count is in the packet's second byte.
    """
    config = first_byte >> 3
    if config < 12:
        mode, frame_us = "SILK", (10000, 20000, 40000, 60000)[config % 4]
        bandwidth = ("NB", "MB", "WB")[config // 4]
    elif config < 16:
        mode, frame_us = "Hybrid", (10000, 20000)[config % 2]
        bandwidth = ("SWB", "FB")[(config - 12) // 2]
    else:
        mode, frame_us = "CELT", (2500, 5000, 10000, 20000)[config % 4]
        bandwidth = ("NB", "WB", "SWB", "FB")[(config - 16) // 4]
    return {"config": config, "mode": mode, "bandwidth": bandwidth, "frame_us": frame_us,
            "stereo": bool(first_byte & 0x04), "code": first_byte & 0x03}


def opus_toc_stats(frames) -> dict:
    """How often each TOC byte occurs across fixed-length frames: {toc_byte: count}."""
    stats = {}
    for f in frames:
        if f:
            stats[f[0]] = stats.get(f[0], 0) + 1
    return stats


def opus_frame_is_card_format(frame: bytes) -> bool:
    """One mono 20 ms frame in this packet. Code 0 says so directly; code 3 says so when the
    count in the second byte is 1 (the card's live stream carries TOC 0x4b, which is code 3:
    evidence/v1-live/README.md)."""
    if not frame:
        return False
    toc = opus_toc(frame[0])
    if toc["frame_us"] != 20000 or toc["stereo"]:
        return False
    if toc["code"] == 0:
        return True
    return toc["code"] == 3 and len(frame) >= 2 and (frame[1] & 0x3F) == 1


def opus_frames_match_card_format(frames) -> bool:
    """True when every frame holds one mono 20 ms Opus frame: what split_opus_frames and the
    OGG muxer assume (#66). Headers may differ between frames (an encoder can switch mode);
    misaligned data fails because few byte values pass."""
    frames = list(frames)
    return bool(frames) and all(opus_frame_is_card_format(f) for f in frames)
