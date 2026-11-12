"""split_opus_frames and wrap_opus_frames_as_ogg."""
import struct

import pytest

import dnote_protocol as P
from ogg_opus import _crc32_ogg, wrap_opus_frames_as_ogg


# ------------------------------------------------------------------ split_opus_frames

def test_split_exact_multiple():
    frames, rest = P.split_opus_frames(bytes(range(80)))
    assert frames == [bytes(range(40)), bytes(range(40, 80))] and rest == b""


def test_split_with_remainder():
    frames, rest = P.split_opus_frames(bytes(87))
    assert len(frames) == 2 and rest == bytes(7)


def test_split_shorter_than_one_frame():
    assert P.split_opus_frames(bytes(39)) == ([], bytes(39))
    assert P.split_opus_frames(b"") == ([], b"")


def test_split_custom_frame_length():
    assert P.split_opus_frames(b"abcdefg", 3) == ([b"abc", b"def"], b"g")


# ------------------------------------------------------------------ Ogg pages

def crc_bitwise(data):
    """Independent bit-by-bit Ogg CRC-32 (poly 0x04C11DB7, init 0, no reflection)."""
    crc = 0
    for b in data:
        crc ^= b << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) if crc & 0x80000000 else (crc << 1)
            crc &= 0xFFFFFFFF
    return crc


def parse_pages(buf):
    pages, pos = [], 0
    while pos < len(buf):
        assert buf[pos:pos + 4] == b"OggS"
        version, htype, granule, serial, seq, crc, nseg = struct.unpack_from("<BBqIIIB", buf, pos + 4)
        lacing = list(buf[pos + 27:pos + 27 + nseg])
        start = pos + 27 + nseg
        end = start + sum(lacing)
        raw = bytearray(buf[pos:end])
        raw[22:26] = b"\x00\x00\x00\x00"
        packets, cur, off = [], b"", start
        for n in lacing:
            cur += buf[off:off + n]
            off += n
            if n < 255:
                packets.append(cur)
                cur = b""
        pages.append(dict(version=version, htype=htype, granule=granule, serial=serial,
                          seq=seq, crc=crc, crc_calc=crc_bitwise(bytes(raw)),
                          lacing=lacing, packets=packets))
        pos = end
    return pages


def frames_of(n, size=40):
    return [bytes([i % 256]) * size for i in range(n)]


def test_crc_table_matches_bitwise_crc():
    for data in (b"", b"\x00", b"OggS", bytes(range(256))):
        assert _crc32_ogg(data) == crc_bitwise(data)


def test_ogg_structure_123_frames():
    frames = frames_of(123)
    pages = parse_pages(wrap_opus_frames_as_ogg(frames))
    assert len(pages) == 2 + 3                      # OpusHead, OpusTags, 50 + 50 + 23 frames
    assert [p["seq"] for p in pages] == [0, 1, 2, 3, 4]
    assert all(p["version"] == 0 and p["serial"] == 1 for p in pages)
    assert [p["htype"] for p in pages] == [0x02, 0x00, 0x00, 0x00, 0x04]
    assert [p["granule"] for p in pages] == [0, 0, 50 * 960, 100 * 960, 123 * 960]
    assert all(p["crc"] == p["crc_calc"] for p in pages)
    assert [len(p["packets"]) for p in pages] == [1, 1, 50, 50, 23]
    assert all(l == 40 for p in pages[2:] for l in p["lacing"])
    assert [pkt for p in pages[2:] for pkt in p["packets"]] == frames


def test_ogg_headers():
    pages = parse_pages(wrap_opus_frames_as_ogg(frames_of(1)))
    head = pages[0]["packets"][0]
    assert head == b"OpusHead" + bytes([1, 1]) + struct.pack("<HIhB", 312, 16000, 0, 0)
    tags = pages[1]["packets"][0]
    assert tags == b"OpusTags" + struct.pack("<I", 12) + b"dnote-client" + struct.pack("<I", 0)


def test_ogg_eos_only_on_last_page_when_pages_are_full():
    pages = parse_pages(wrap_opus_frames_as_ogg(frames_of(100)))
    assert [p["htype"] for p in pages] == [0x02, 0x00, 0x00, 0x04]
    assert pages[-1]["granule"] == 100 * 960


def test_ogg_single_frame():
    pages = parse_pages(wrap_opus_frames_as_ogg(frames_of(1)))
    assert [p["htype"] for p in pages] == [0x02, 0x00, 0x04]
    assert pages[-1]["granule"] == 960


def test_ogg_lacing_for_large_packets():
    frames = [bytes(255), bytes(300)]
    pages = parse_pages(wrap_opus_frames_as_ogg(frames))
    assert pages[2]["lacing"] == [255, 0, 255, 45]
    assert pages[2]["packets"] == frames
    assert pages[2]["crc"] == pages[2]["crc_calc"]


@pytest.mark.parametrize("serial,per_page,per_frame", [(7, 10, 480), (0xFFFFFFFF, 1, 960)])
def test_ogg_parameters(serial, per_page, per_frame):
    pages = parse_pages(wrap_opus_frames_as_ogg(frames_of(12), serial=serial,
                                                packets_per_page=per_page,
                                                granule_per_frame=per_frame))
    assert all(p["serial"] == serial for p in pages)
    assert len(pages) == 2 + -(-12 // per_page)
    assert pages[-1]["granule"] == 12 * per_frame and pages[-1]["htype"] == 0x04
