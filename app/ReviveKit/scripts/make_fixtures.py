#!/usr/bin/env python3
"""Generate cross-language fixtures for the CardProtocol tests.

The Python client in client/ is the reference implementation; the Swift port must
produce byte-identical output. Synthetic data only: no real recordings, no real sn.

Run from anywhere: python3 app/ReviveKit/scripts/make_fixtures.py
Importing this module writes nothing; client/tests calls build_files() to check
that the committed fixtures are reproducible.
"""
import hashlib, hmac, json, os, random, struct, sys
from datetime import datetime

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "client"))
import dnote_protocol as P
from ogg_opus import wrap_opus_frames_as_ogg

OUT = os.path.join(ROOT, "app", "ReviveKit", "Tests", "CardProtocolTests", "Fixtures")


def build_files():
    """Return {file name: bytes} for every fixture, without writing anything."""
    # Audio: same seed and layout as ios-prototype/tools/make_fixtures.py.
    rng = random.Random(7)
    plain = bytes(rng.getrandbits(8) for _ in range(40 * 123 + 7))  # 123 frames + 7 B remainder
    header = b"encryt" + bytes(rng.getrandbits(8) for _ in range(18))
    nonce = bytes(rng.getrandbits(8) for _ in range(12))
    key = hmac.new(P.DEVICE_KEY_SECRET, header[6:24], hashlib.sha256).digest()
    enc = header + nonce + P._chacha20_py(key, nonce, header + plain)
    assert P.decrypt_audio_file(enc) == plain
    frames, _ = P.split_opus_frames(plain, 40)
    ogg = wrap_opus_frames_as_ogg(frames)

    C = P.Cmd
    key_for_test_sn = P.derive_device_key("TESTSN0001")
    vectors = {
        "deviceInfo": P.frame_query_device_info(),
        "switches": P.frame_query_switches(),
        "recordingStatus": P.frame_query_rec_status(),
        "bondStatus": P.frame_query_bond(),
        "encryptionStatus": P.build_frame(C.QUERY_CHACHA20),
        "ledOn": P.build_frame(C.SET_LED, bytes([1])),
        "motorOff": P.build_frame(C.SET_MOTOR, bytes([0])),
        "noiseCancelOn": P.build_frame(C.SET_NOISE_CANCEL, bytes([1])),
        "vadOff": P.build_frame(C.SET_VAD, bytes([0])),
        "gain1": P.build_frame(C.SET_GAIN, bytes([1])),
        "gain9": P.build_frame(C.SET_GAIN, bytes([9])),
        "noiseLevel5": P.build_frame(C.SET_NOISE_LEVEL, bytes([5])),
        "autoOff600": P.build_frame(C.SET_IDLE_SHUTDOWN, struct.pack(">I", 600)),
        "syncTime": P.frame_sync_time(datetime(2026, 11, 7, 9, 30, 5)),
        "startRecording": P.frame_start_recording(False),
        "stopRecording": P.frame_stop_recording(),
        "pauseRecording": P.build_frame(C.PAUSE_RECORDING),
        "resumeRecording": P.build_frame(C.RESUME_RECORDING),
        "listFiles": P.frame_query_file_list(),
        "download": P.frame_request_file("20261106080407.opus"),
        "downloadResume": P.frame_request_file("20261106080407.opus", offset=474030),
        "delete": P.frame_delete_file("20261106080407.opus"),
        "bond": P.frame_bond(bytes([0x11] * 16)),
        "unbond": P.frame_unbond(),
        "setEncryptionKey": P.frame_set_chacha20(True, key_for_test_sn),
    }

    return {
        "encrypted.bin": enc,
        "plain.bin": plain,
        "expected_ogg.bin": ogg,
        "frame_vectors.json": (json.dumps({k: v.hex() for k, v in vectors.items()}, indent=2, sort_keys=True) + "\n").encode(),
    }


def main():
    files = build_files()
    os.makedirs(OUT, exist_ok=True)
    for name, data in files.items():
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(data)
        print(name, len(data), hashlib.sha256(data).hexdigest()[:16])


if __name__ == "__main__":
    main()
