"""asr_transcribe: fills an engine's directory for asr_eval (#12, #67). A stub stands in for the
service; the "audio" is a few bytes, never a real recording."""
import csv
import json
import urllib.error

import asr_eval as E
import asr_transcribe as T


class Stub:
    def __init__(self, texts, fail=()):
        self.texts = texts
        self.fail = set(fail)
        self.calls = []

    def __call__(self, url, headers, body):
        self.calls.append((url, headers, body))
        name = body.split(b'filename="', 1)[1].split(b'"', 1)[0].decode()
        if name in self.fail:
            raise urllib.error.HTTPError(url, 413, "too large", {}, None)
        return json.dumps({"text": self.texts[name]}).encode()


def _audio(tmp_path, names):
    d = tmp_path / "audio"
    d.mkdir()
    for n in names:
        (d / n).write_bytes(b"\x00fake audio " + n.encode())
    (d / "notes.txt").write_text("not audio", encoding="utf-8")
    return d


def test_writes_one_text_per_recording_that_asr_eval_scores(tmp_path, monkeypatch):
    monkeypatch.setenv("ASR_KEY", "test-key-not-real")
    audio = _audio(tmp_path, ["m5.m4a", "m30.wav"])
    out = tmp_path / "sensevoice"
    stub = Stub({"m5.m4a": " 下周三上线。 ", "m30.wav": "预算再议"})
    assert T.main([str(audio), str(out), "--base-url", "https://api.example.com/v1/", "--model", "sv",
                   "--key-env", "ASR_KEY", "--language", "zh"], post=stub) == 0

    assert len(stub.calls) == 2  # notes.txt is not audio
    url, headers, body = stub.calls[0]
    assert url == "https://api.example.com/v1/audio/transcriptions"
    assert headers["Authorization"] == "Bearer test-key-not-real"
    assert headers["Content-Type"].startswith("multipart/form-data; boundary=")
    assert b'name="model"\r\n\r\nsv\r\n' in body and b'name="language"\r\n\r\nzh\r\n' in body
    assert b"Content-Type: audio/wav" in body or b"Content-Type: audio/mp4" in body

    assert (out / "m5.txt").read_text(encoding="utf-8") == "下周三上线。\n"
    rows = list(csv.DictReader((out / "timing.csv").open(encoding="utf-8")))
    assert sorted(r["file"] for r in rows) == ["m30.wav", "m5.m4a"]

    refs = tmp_path / "refs"
    refs.mkdir()
    (refs / "m5.txt").write_text("下周三上线", encoding="utf-8")
    (refs / "m30.txt").write_text("预算再议", encoding="utf-8")
    assert E.score(refs, out).totals.errors == 0


def test_resumes_and_reports_failures(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("ASR_KEY", "k")
    audio = _audio(tmp_path, ["a.m4a", "b.m4a", "c.m4a"])
    out = tmp_path / "engine"
    out.mkdir()
    (out / "a.txt").write_text("已经有了\n", encoding="utf-8")
    stub = Stub({"b.m4a": "乙", "c.m4a": "丙"}, fail={"c.m4a"})
    assert T.main([str(audio), str(out), "--base-url", "https://x/v1", "--model", "m", "--key-env", "ASR_KEY"],
                  post=stub) == 1
    assert [c[2].split(b'filename="')[1][:5] for c in stub.calls] == [b"b.m4a", b"c.m4a"]  # a skipped
    assert (out / "a.txt").read_text(encoding="utf-8") == "已经有了\n"
    assert not (out / "c.txt").exists()
    assert "c.m4a: HTTP 413" in capsys.readouterr().err
    # No language given: none sent.
    assert b'name="language"' not in stub.calls[0][2]


def test_refuses_without_a_key_or_audio(tmp_path, monkeypatch, capsys):
    audio = _audio(tmp_path, ["a.m4a"])
    monkeypatch.delenv("NOT_SET", raising=False)
    stub = Stub({})
    assert T.main([str(audio), str(tmp_path / "o"), "--base-url", "https://x/v1", "--model", "m",
                   "--key-env", "NOT_SET"], post=stub) == 2
    assert "NOT_SET is empty" in capsys.readouterr().err and stub.calls == []

    monkeypatch.setenv("K", "k")
    empty = tmp_path / "empty"
    empty.mkdir()
    assert T.main([str(empty), str(tmp_path / "o"), "--base-url", "https://x/v1", "--model", "m",
                   "--key-env", "K"], post=stub) == 2
    assert "no audio files" in capsys.readouterr().err


def test_same_name_twice_is_refused(tmp_path, monkeypatch):
    monkeypatch.setenv("K", "k")
    audio = _audio(tmp_path, ["a.m4a", "a.wav"])
    try:
        T.run(audio, tmp_path / "o", "https://x/v1", "m", "K", None, post=Stub({}), log=lambda _: None)
    except T.TranscribeError as error:
        assert "share a name" in str(error)
    else:
        raise AssertionError("expected a refusal")


def test_reply_without_text_is_a_failure(tmp_path):
    audio = tmp_path / "a.m4a"
    audio.write_bytes(b"x")
    try:
        T.transcribe(audio, "https://x/v1", "m", "k", None, post=lambda *_: b'{"segments": []}')
    except T.TranscribeError as error:
        assert "no text" in str(error)
    else:
        raise AssertionError("expected a failure")
