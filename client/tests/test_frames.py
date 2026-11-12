"""build_frame / parse_frame and the frame_* helpers."""
import json
import struct

import pytest

import dnote_protocol as P


def frame(cmd, body=b""):
    return bytes([P.PID, cmd, len(body)]) + body


# ------------------------------------------------------------------ build_frame

def test_build_frame_without_payload():
    assert P.build_frame(0x80) == bytes([0xA0, 0x80, 0x00])


def test_build_frame_bytes_and_bytearray():
    assert P.build_frame(0x83, b"\x01") == bytes([0xA0, 0x83, 0x01, 0x01])
    assert P.build_frame(0x83, bytearray(b"\x00")) == bytes([0xA0, 0x83, 0x01, 0x00])


def test_build_frame_str_is_utf8():
    assert P.build_frame(0x86, "名") == bytes([0xA0, 0x86, 3]) + "名".encode("utf-8")


def test_build_frame_dict_is_compact_json_without_ascii_escaping():
    out = P.build_frame(0x91, {"name": "录音.opus"})
    body = '{"name":"录音.opus"}'.encode("utf-8")
    assert out == bytes([0xA0, 0x91, len(body)]) + body


def test_build_frame_list_is_json():
    assert P.build_frame(0x90, [1, 2]) == bytes([0xA0, 0x90, 5]) + b"[1,2]"


def test_build_frame_masks_cmd_to_one_byte():
    assert P.build_frame(0x150)[1] == 0x50


def test_build_frame_max_length():
    assert len(P.build_frame(0x86, b"x" * 255)) == 258
    with pytest.raises(ValueError):
        P.build_frame(0x86, b"x" * 256)


def test_frame_helpers():
    assert P.frame_query_device_info() == bytes([0xA0, 0x80, 0])
    assert P.frame_set_usb_storage(True) == bytes([0xA0, 0x82, 1, 1])
    assert P.frame_set_usb_storage(False) == bytes([0xA0, 0x82, 1, 0])
    assert P.frame_delete_file("a.opus") == frame(0x91, b'{"name":"a.opus"}')
    assert P.frame_request_file("a.opus", offset=7) == frame(
        0x70, b'{"cmd":1,"name":"a.opus","offset":7}')
    assert P.frame_start_recording(True) == bytes([0xA0, 0x51, 1, 1])
    assert P.frame_unbond() == bytes([0xA0, 0xA0, 1, 0])
    assert P.frame_bond(bytes(range(16))) == frame(0xA0, b"\x01" + bytes(range(16)))
    assert P.frame_set_chacha20(False, bytes(32)) == frame(0xA2, b"\x00" + bytes(32))


def test_frame_helpers_reject_wrong_lengths():
    with pytest.raises(ValueError):
        P.frame_bond(bytes(15))
    with pytest.raises(ValueError):
        P.frame_set_chacha20(True, bytes(31))


# ------------------------------------------------------------------ parse_frame: framing

@pytest.mark.parametrize("data", [b"", b"\xa0", b"\xa0\x80"])
def test_parse_short_frame_is_invalid(data):
    assert P.parse_frame(data).valid is False


def test_parse_wrong_pid_is_invalid():
    assert P.parse_frame(bytes([0xA1, 0x80, 0x00])).valid is False


def test_parse_length_larger_than_data_is_invalid():
    assert P.parse_frame(bytes([0xA0, 0x91, 0x02, 0x01])).valid is False


def test_parse_empty_payload():
    fr = P.parse_frame(bytes([0xA0, 0x50, 0x00]))
    assert (fr.valid, fr.cmd, fr.payload) == (True, 0x50, None)


def test_parse_ignores_bytes_after_length():
    fr = P.parse_frame(frame(0x91, b"\x01") + b"\xff\xff")
    assert fr.payload == b"\x01"


def test_parse_round_trip_with_build_frame():
    fr = P.parse_frame(P.build_frame(0x92, {"name": "x.opus", "size": 12}))
    assert fr.valid and fr.cmd == 0x92
    assert fr.payload == {"name": "x.opus", "size": 12}


# ------------------------------------------------------------------ parse_frame: 0x70 file data

def test_parse_file_data_chunk():
    body = bytes([0x10]) + struct.pack(">I", 474030) + b"abc"
    fr = P.parse_frame(frame(0x70, body))
    assert fr.valid and fr.cmd == 0x70
    assert fr.payload == {"start": 0x10, "offset": 474030, "data": b"abc"}


def test_parse_file_data_header_only():
    body = bytes([P.FileStatus.EOF]) + struct.pack(">I", 9)
    assert P.parse_frame(frame(0x70, body)).payload == {
        "start": P.FileStatus.EOF, "offset": 9, "data": b""}


def test_parse_file_data_one_byte_refusal():
    # A bare 0x4X is the card refusing the transfer (PROTOCOL.md §5).
    fr = P.parse_frame(bytes([0xA0, 0x70, 0x01, 0x41]))
    assert fr.valid and fr.cmd == 0x70
    assert fr.payload == {"start": 0x41, "offset": 0, "data": b""}
    assert fr.payload["start"] & 0xF0 == P.FileStatus.ERROR


@pytest.mark.parametrize("lc", [2, 3, 4])
def test_parse_file_data_shorter_than_header_keeps_status(lc):
    body = bytes([0xF0]) + bytes(lc - 1)
    assert P.parse_frame(frame(0x70, body)).payload == {"start": 0xF0, "offset": 0, "data": b""}


# ------------------------------------------------------------------ parse_frame: 0x68 realtime audio

def test_parse_realtime_audio():
    body = bytes([0x2B]) + struct.pack(">I", 80) + bytes(40)
    fr = P.parse_frame(frame(0x68, body))
    assert fr.payload == {"flag": 0x2, "seq": 0xB, "offset": 80, "data": bytes(40)}


def test_parse_realtime_audio_header_only():
    fr = P.parse_frame(frame(0x68, bytes([0x10]) + struct.pack(">I", 0)))
    assert fr.payload == {"flag": 1, "seq": 0, "offset": 0, "data": b""}


def test_parse_realtime_audio_too_short_falls_through():
    # Fewer than 5 bytes is not an audio packet; it is handled like any other reply.
    assert P.parse_frame(frame(0x68, b"\x01")).payload == b"\x01"


# ------------------------------------------------------------------ parse_frame: 0xA1 bond info

def test_parse_bond_info_with_bond_id():
    bond_id = bytes(range(0x10, 0x20))
    fr = P.parse_frame(frame(0xA1, b"\x01" + bond_id))
    assert fr.payload == {"isBonded": True, "bondId": bond_id}


def test_parse_bond_info_without_bond_id():
    # One byte for 0xA1 hits the bond branch, not the generic one-byte branch.
    assert P.parse_frame(frame(0xA1, b"\x00")).payload == {"isBonded": False, "bondId": None}


def test_parse_bond_info_truncated_bond_id():
    fr = P.parse_frame(frame(0xA1, b"\x01" + bytes(10)))
    assert fr.payload == {"isBonded": True, "bondId": None}


# ------------------------------------------------------------------ parse_frame: generic replies

def test_parse_one_byte_reply_is_bytes():
    # e.g. 0x91 delete acknowledgement on fw v1.50.
    fr = P.parse_frame(frame(0x91, b"\x01"))
    assert fr.valid and fr.cmd == 0x91
    assert fr.payload == b"\x01" and isinstance(fr.payload, bytes)


def test_parse_json_body():
    body = json.dumps({"index": 0, "name": "a.opus", "size": 100, "end": 0}).encode()
    assert P.parse_frame(frame(0x90, body)).payload == {
        "index": 0, "name": "a.opus", "size": 100, "end": 0}


def test_parse_non_json_body_returns_text():
    assert P.parse_frame(frame(0x51, b"hello")).payload == "hello"


def test_parse_invalid_utf8_body_is_replaced():
    assert P.parse_frame(frame(0x51, b"\xff\xfe")).payload == "��"
