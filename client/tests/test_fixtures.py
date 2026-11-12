"""The committed CardProtocol fixtures are reproducible from the Python client."""
import json
import os

import pytest

import dnote_protocol as P
from ogg_opus import wrap_opus_frames_as_ogg

FIXTURE_NAMES = ["encrypted.bin", "plain.bin", "expected_ogg.bin", "frame_vectors.json"]
# The iOS prototype keeps copies of the audio fixtures; the same generator writes them.
PROTOTYPE_FIXTURES_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "ios-prototype", "Tests", "Fixtures")
PROTOTYPE_FIXTURE_NAMES = ["encrypted.bin", "plain.bin", "expected_ogg.bin"]


@pytest.fixture(scope="module")
def generated(make_fixtures):
    return make_fixtures.build_files()


def test_generator_produces_exactly_the_committed_set(generated):
    assert sorted(generated) == sorted(FIXTURE_NAMES)


@pytest.mark.parametrize("name", FIXTURE_NAMES)
def test_generated_fixture_is_byte_identical(generated, fixture_bytes, name):
    assert generated[name] == fixture_bytes(name)


def test_generator_writes_exactly_the_prototype_copies(make_fixtures):
    assert sorted(make_fixtures.PROTOTYPE_FILES) == sorted(PROTOTYPE_FIXTURE_NAMES)


@pytest.mark.parametrize("name", PROTOTYPE_FIXTURE_NAMES)
def test_prototype_fixture_copy_is_byte_identical(generated, name):
    with open(os.path.join(PROTOTYPE_FIXTURES_DIR, name), "rb") as f:
        assert f.read() == generated[name]


def test_encrypted_fixture_decrypts_to_plain(fixture_bytes):
    assert P.decrypt_audio_file(fixture_bytes("encrypted.bin")) == fixture_bytes("plain.bin")


def test_plain_fixture_wraps_to_expected_ogg(fixture_bytes):
    frames, rest = P.split_opus_frames(fixture_bytes("plain.bin"))
    assert (len(frames), len(rest)) == (123, 7)
    assert wrap_opus_frames_as_ogg(frames) == fixture_bytes("expected_ogg.bin")


def test_frame_vectors_are_well_formed(fixture_bytes):
    vectors = json.loads(fixture_bytes("frame_vectors.json"))
    for name, hexstr in vectors.items():
        fr = P.parse_frame(bytes.fromhex(hexstr))
        assert fr.valid, name
