"""
ogg_opus.py — 将设备输出的裸 Opus 帧 (16kHz 单声道 20ms) 封装为标准 .ogg 文件。

对应 App 的 OggOpusEncoder:
  inputSampleRate=16000, channels=1, frameDurationMs=20,
  preSkip=312, granulePerFrame=20*48=960 (granule 以 48kHz 计)
每个 Opus packet = 一帧 (40 字节)。
"""

from __future__ import annotations
import struct

_CRC_TABLE = []
def _init_crc():
    for i in range(256):
        r = i << 24
        for _ in range(8):
            r = ((r << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if (r & 0x80000000) else (r << 1) & 0xFFFFFFFF
        _CRC_TABLE.append(r)
_init_crc()

def _crc32_ogg(data: bytes) -> int:
    crc = 0
    for b in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ _CRC_TABLE[((crc >> 24) & 0xFF) ^ b]
    return crc & 0xFFFFFFFF


def _ogg_page(serial: int, seq: int, granule: int, segments: list[bytes],
              header_type: int) -> bytes:
    # 分段表: 每个 packet 的长度用 255-lacing 表示
    lacing = bytearray()
    body = bytearray()
    for seg in segments:
        n = len(seg)
        while n >= 255:
            lacing.append(255); n -= 255
        lacing.append(n)
        body += seg
    page = bytearray()
    page += b"OggS"
    page += bytes([0])                       # version
    page += bytes([header_type])             # 0x02=BOS, 0x04=EOS, 0x00=normal
    page += struct.pack("<q", granule)       # granule position
    page += struct.pack("<I", serial)
    page += struct.pack("<I", seq)
    page += struct.pack("<I", 0)             # CRC placeholder
    page += bytes([len(lacing)])
    page += bytes(lacing)
    page += bytes(body)
    crc = _crc32_ogg(bytes(page))
    page[22:26] = struct.pack("<I", crc)
    return bytes(page)


def _opus_head(channels=1, pre_skip=312, input_rate=16000) -> bytes:
    return (b"OpusHead" + bytes([1, channels]) +
            struct.pack("<H", pre_skip) +
            struct.pack("<I", input_rate) +
            struct.pack("<h", 0) +            # output gain
            bytes([0]))                       # channel mapping family


def _opus_tags(vendor=b"dnote-client") -> bytes:
    out = b"OpusTags"
    out += struct.pack("<I", len(vendor)) + vendor
    out += struct.pack("<I", 0)               # 0 comments
    return out


def wrap_opus_frames_as_ogg(frames: list[bytes], serial: int = 1,
                            pre_skip: int = 312,
                            granule_per_frame: int = 960,
                            packets_per_page: int = 50) -> bytes:
    """返回完整 .ogg 字节流。"""
    out = bytearray()
    seq = 0
    # BOS: OpusHead
    out += _ogg_page(serial, seq, 0, [_opus_head(pre_skip=pre_skip)], header_type=0x02); seq += 1
    # OpusTags
    out += _ogg_page(serial, seq, 0, [_opus_tags()], header_type=0x00); seq += 1
    # 音频页
    granule = 0
    for i in range(0, len(frames), packets_per_page):
        chunk = frames[i:i + packets_per_page]
        granule += granule_per_frame * len(chunk)
        is_last = (i + packets_per_page) >= len(frames)
        out += _ogg_page(serial, seq, granule, chunk,
                         header_type=0x04 if is_last else 0x00)
        seq += 1
    return bytes(out)
