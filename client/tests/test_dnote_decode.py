"""dnote._decode_to_ogg: decrypts from the file header alone, no serial number."""
import inspect

import pytest


def test_decode_takes_no_serial(dnote):
    assert list(inspect.signature(dnote._decode_to_ogg).parameters) == ["raw"]


def test_decode_encrypted_fixture_without_serial(dnote, fixture_bytes):
    ogg, note = dnote._decode_to_ogg(fixture_bytes("encrypted.bin"))
    assert ogg == fixture_bytes("expected_ogg.bin")
    assert note == "已解密, 123帧, 余7B"


def test_decode_plain_input(dnote, fixture_bytes):
    ogg, note = dnote._decode_to_ogg(fixture_bytes("plain.bin"))
    assert ogg == fixture_bytes("expected_ogg.bin")
    assert note == "明文, 123帧, 余7B"


def test_decode_corrupt_encrypted_input_raises(dnote, fixture_bytes):
    # cmd_pull catches this and keeps the raw bytes; it must never return bad audio.
    enc = bytearray(fixture_bytes("encrypted.bin"))
    enc[40] ^= 0x01
    with pytest.raises(ValueError):
        dnote._decode_to_ogg(bytes(enc))
