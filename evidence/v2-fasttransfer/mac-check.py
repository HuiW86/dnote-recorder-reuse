"""#6: decode a fast-transfer download with the Mac client and compare with the #5 BLE result.

Usage: python3 evidence/v2-fasttransfer/mac-check.py <name>.ft.raw
"""
import hashlib
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "client"))
from dnote_protocol import decrypt_audio_file, split_opus_frames  # noqa: E402
from ogg_opus import wrap_opus_frames_as_ogg  # noqa: E402

# 20261106040350.opus downloaded over BLE three times in #5 (evidence/v3-pair/07-throughput.sha256).
BLE_OGG_SHA256 = "c45eebf1e2366415c1abbb97684bdcf5d111baf30124bc3a6b7edf92a7201968"

raw = open(sys.argv[1], "rb").read()
print("raw", len(raw), hashlib.sha256(raw).hexdigest())
frames, rem = split_opus_frames(decrypt_audio_file(raw), 40)
ogg = wrap_opus_frames_as_ogg(frames)
h = hashlib.sha256(ogg).hexdigest()
print("ogg", h, f"{len(frames)} frames, remainder {len(rem)}B")
print("matches #5 BLE ogg:", h == BLE_OGG_SHA256)
