"""Opus TOC byte decoding and the card-format check (#66)."""
import pytest

import dnote_protocol as P


@pytest.mark.parametrize("byte, mode, bandwidth, frame_us, stereo, code", [
    (0x48, "SILK", "WB", 20000, False, 0),    # config 9: what 16 kHz 20 ms speech usually is
    (0x08, "SILK", "NB", 20000, False, 0),    # config 1
    (0x58, "SILK", "WB", 60000, False, 0),    # config 11
    (0x68, "Hybrid", "SWB", 20000, False, 0), # config 13
    (0x78, "Hybrid", "FB", 20000, False, 0),  # config 15
    (0x80, "CELT", "NB", 2500, False, 0),     # config 16
    (0xB8, "CELT", "WB", 20000, False, 0),    # config 23
    (0xFC, "CELT", "FB", 20000, True, 0),     # config 31, stereo
    (0x4B, "SILK", "WB", 20000, False, 3),    # code 3: frame count in the next byte
])
def test_toc_fields(byte, mode, bandwidth, frame_us, stereo, code):
    t = P.opus_toc(byte)
    assert (t["mode"], t["bandwidth"], t["frame_us"], t["stereo"], t["code"]) == \
        (mode, bandwidth, frame_us, stereo, code)


def test_every_config_decodes():
    durations = {P.opus_toc(c << 3)["frame_us"] for c in range(32)}
    assert durations == {2500, 5000, 10000, 20000, 40000, 60000}


def frame(toc, n=40):
    return bytes([toc]) + bytes(n - 1)


def test_stats_count_first_bytes():
    assert P.opus_toc_stats([frame(0x48), frame(0x48), frame(0x58)]) == {0x48: 2, 0x58: 1}
    assert P.opus_toc_stats([]) == {}


def test_card_format_accepts_uniform_20ms_mono():
    assert P.opus_frames_match_card_format([frame(0x48)] * 5)
    assert P.opus_frames_match_card_format([frame(0xB8)] * 5)  # CELT 20 ms is fine too
    assert P.opus_frames_match_card_format([frame(0x48), frame(0xB8)])  # mode switch, still 20 ms


def test_card_format_accepts_code3_with_one_frame():
    # The card's live stream carries 0x4b (code 3); a count byte of 1 is one 20 ms frame.
    one = bytes([0x4B, 0x01]) + bytes(38)
    two = bytes([0x4B, 0x02]) + bytes(38)
    assert P.opus_frames_match_card_format([frame(0x48), one, one])
    assert not P.opus_frames_match_card_format([one, two])
    assert not P.opus_frames_match_card_format([bytes([0x4B])])


@pytest.mark.parametrize("frames", [
    [],                                   # nothing to judge
    [frame(0x48), frame(0x58)],           # one 60 ms frame among 20 ms ones
    [frame(0x58)] * 3,                    # 60 ms
    [frame(0x4C)] * 3,                    # stereo
    [frame(0x49)] * 3,                    # two frames per packet
])
def test_card_format_rejects(frames):
    assert not P.opus_frames_match_card_format(frames)


def test_random_bytes_do_not_pass():
    import random
    rng = random.Random(7)
    buf = bytes(rng.getrandbits(8) for _ in range(40 * 50))
    frames, _ = P.split_opus_frames(buf)
    assert not P.opus_frames_match_card_format(frames)
