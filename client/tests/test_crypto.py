"""Advertisement parsing, key derivation, ChaCha20 and audio file decryption."""
import hashlib
import hmac
import random
import struct
import sys

import pytest
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms

import dnote_protocol as P


def chacha20_cryptography(key, nonce, data):
    """Reference ChaCha20 from the cryptography package (counter 0, 12-byte nonce)."""
    d = Cipher(algorithms.ChaCha20(key, bytes(4) + nonce), mode=None).decryptor()
    return d.update(data) + d.finalize()


# ------------------------------------------------------------------ advertisement

def adv_data(bid=0x0102, pid=0x0304, fw=(1, 50), hw=(2, 0), battery=87, power=2, sid=0x0A0B0C):
    """Manufacturer data after the company ID, as bleak hands it over."""
    return (struct.pack(">HH", bid, pid) + bytes(fw) + bytes(hw)
            + bytes([battery, power]) + sid.to_bytes(3, "big"))


def test_parse_advertisement():
    info = P.parse_advertisement(P.CID_VALUE, adv_data())
    assert info == P.AdvInfo(valid=True, cid=8867, bid=0x0102, pid=0x0304,
                             firmware_version="v1.50", hardware_version="v2.0",
                             battery=87, power_state=2, sid=0x0A0B0C)


def test_parse_advertisement_ignores_trailing_bytes():
    assert P.parse_advertisement(P.CID_VALUE, adv_data() + b"\xff\xff").sid == 0x0A0B0C


def test_parse_advertisement_wrong_company_id():
    assert P.parse_advertisement(0x004C, adv_data()).valid is False


def test_parse_advertisement_too_short():
    assert P.parse_advertisement(P.CID_VALUE, adv_data()[:-1]).valid is False


# ------------------------------------------------------------------ key derivation

def test_derive_device_key_is_hmac_sha256_of_sn():
    expected = hmac.new(P.DEVICE_KEY_SECRET, b"TESTSN0001", hashlib.sha256).digest()
    assert P.derive_device_key("TESTSN0001") == expected
    assert P.derive_device_key(b"TESTSN0001") == expected
    assert len(expected) == 32


def test_derive_device_key_differs_per_sn():
    assert P.derive_device_key("TESTSN0001") != P.derive_device_key("TESTSN0002")


# ------------------------------------------------------------------ ChaCha20

def test_chacha20_py_rfc8439_keystream_block_zero():
    # RFC 8439 A.1 test vector #1: all-zero key and nonce, block counter 0.
    expected = bytes.fromhex(
        "76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7"
        "da41597c5157488d7724e03fb8d84a376a43b8f41518a11cc387b669b2ee6586")
    assert P._chacha20_py(bytes(32), bytes(12), bytes(64)) == expected


@pytest.mark.parametrize("length", [0, 1, 63, 64, 65, 1000, 4987])
def test_chacha20_py_matches_cryptography(length):
    rng = random.Random(length)
    key = bytes(rng.getrandbits(8) for _ in range(32))
    nonce = bytes(rng.getrandbits(8) for _ in range(12))
    data = bytes(rng.getrandbits(8) for _ in range(length))
    expected = chacha20_cryptography(key, nonce, data)
    assert P._chacha20_py(key, nonce, data) == expected
    assert P._chacha20(key, nonce, data) == expected


def test_chacha20_falls_back_to_pure_python(monkeypatch):
    key, nonce, data = bytes(range(32)), bytes(range(12)), b"synthetic" * 20
    expected = P._chacha20(key, nonce, data)
    # A None entry makes the import inside _chacha20 raise ImportError.
    monkeypatch.setitem(sys.modules, "cryptography.hazmat.primitives.ciphers", None)
    assert P._chacha20(key, nonce, data) == expected


# ------------------------------------------------------------------ encrypted audio files

def encrypt(plain, seed=1):
    """Build an 'encryt' file the way the card does (synthetic header and nonce)."""
    rng = random.Random(seed)
    header = b"encryt" + bytes(rng.getrandbits(8) for _ in range(18))
    nonce = bytes(rng.getrandbits(8) for _ in range(12))
    key = hmac.new(P.DEVICE_KEY_SECRET, header[6:24], hashlib.sha256).digest()
    return header + nonce + P._chacha20(key, nonce, header + plain)


PLAIN = bytes(range(256)) * 3


def test_is_encrypted_audio():
    assert P.is_encrypted_audio(b"encryt")
    assert not P.is_encrypted_audio(b"encry")
    assert not P.is_encrypted_audio(b"OggS\x00\x02")


def test_decrypt_round_trip():
    enc = encrypt(PLAIN)
    assert len(enc) == 60 + len(PLAIN)
    assert P.decrypt_audio_file(enc) == PLAIN


def test_decrypt_empty_audio():
    assert P.decrypt_audio_file(encrypt(b"")) == b""


@pytest.mark.parametrize("index", [10, 23, 24, 35, 36, 59],
                         ids=["key-material", "key-material-end", "nonce", "nonce-end",
                              "check-block", "check-block-end"])
def test_decrypt_tampered_byte_fails_verification(index):
    enc = bytearray(encrypt(PLAIN))
    enc[index] ^= 0x01
    with pytest.raises(ValueError, match="verification mismatch"):
        P.decrypt_audio_file(bytes(enc))


def test_decrypt_tampered_audio_byte_is_not_detected():
    # The check block covers only the header; audio bytes are not authenticated.
    enc = bytearray(encrypt(PLAIN))
    enc[100] ^= 0xFF
    out = P.decrypt_audio_file(bytes(enc))
    assert out[40] == PLAIN[40] ^ 0xFF
    assert out[:40] + out[41:] == PLAIN[:40] + PLAIN[41:]


def test_decrypt_rejects_short_or_unencrypted_input():
    with pytest.raises(ValueError, match="too short"):
        P.decrypt_audio_file(encrypt(PLAIN)[:59])
    with pytest.raises(ValueError, match="not an encrypted"):
        P.decrypt_audio_file(b"x" * 60)
