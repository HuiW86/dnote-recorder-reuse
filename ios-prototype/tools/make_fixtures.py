#!/usr/bin/env python3
"""Generate cross-language fixtures for the Swift unit tests.

Uses the Python reference implementation in client/ so the Swift port must
produce byte-identical results. Synthetic data only; no real recordings.
"""
import hashlib, hmac, os, random, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "client"))
import dnote_protocol as P
from ogg_opus import wrap_opus_frames_as_ogg

out = os.path.join(ROOT, "ios-prototype", "Tests", "Fixtures")
rng = random.Random(7)
plain = bytes(rng.getrandbits(8) for _ in range(40 * 123 + 7))  # 123 frames + 7B remainder
header = b"encryt" + bytes(rng.getrandbits(8) for _ in range(18))
nonce = bytes(rng.getrandbits(8) for _ in range(12))
key = hmac.new(P.DEVICE_KEY_SECRET, header[6:24], hashlib.sha256).digest()
enc = header + nonce + P._chacha20_py(key, nonce, header + plain)
assert P.decrypt_audio_file(enc) == plain

frames, _ = P.split_opus_frames(plain, 40)
ogg = wrap_opus_frames_as_ogg(frames)
for name, data in [("encrypted.bin", enc), ("plain.bin", plain), ("expected_ogg.bin", ogg)]:
    with open(os.path.join(out, name), "wb") as f:
        f.write(data)
    print(name, len(data), hashlib.sha256(data).hexdigest())
