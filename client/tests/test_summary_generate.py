"""summary_generate: the blind set for the summary comparison (#12, #68). No network: a stub
stands in for the services."""
import csv
import json
import urllib.error

import pytest

import summary_generate as G
import summary_scores as S


def _reply(content):
    return json.dumps({"choices": [{"message": {"content": content}}]}).encode()


class Stub:
    def __init__(self, fail_model=None):
        self.calls = []
        self.fail_model = fail_model

    def __call__(self, url, headers, body):
        request = json.loads(body)
        self.calls.append((url, headers, request))
        if request["model"] == self.fail_model:
            raise urllib.error.HTTPError(url, 429, "rate limited", {}, None)
        system, user = (m["content"] for m in request["messages"])
        return _reply(f"<think>想一想</think>{request['model']}|{system}|{user}")


def _setup(tmp_path):
    refs = tmp_path / "refs"
    refs.mkdir()
    (refs / "m5.txt").write_text("五分钟的文字稿", encoding="utf-8")
    (refs / "m30.txt").write_text("三十分钟的文字稿", encoding="utf-8")
    prompt = tmp_path / "c.txt"
    prompt.write_text("提示词C", encoding="utf-8")
    exports = tmp_path / "exports-a"
    exports.mkdir()
    (exports / "m5.md").write_text("App 里生成的 A", encoding="utf-8")
    (exports / "m30.md").write_text("App 里生成的 A（长）", encoding="utf-8")
    return refs, prompt, exports


def test_writes_a_blind_set_with_key_timing_and_template(tmp_path, monkeypatch):
    monkeypatch.setenv("KEY_ONE", "test-key-not-real")
    refs, prompt, exports = _setup(tmp_path)
    out = tmp_path / "blind"
    stub = Stub()
    code = G.main(["--transcripts", str(refs), "--out", str(out), "--prompt", f"C={prompt}",
                   "--model", "m1=https://api.example.com/v1/,model-one,KEY_ONE",
                   "--existing", f"A@model-one={exports}", "--scorers", "甲,乙", "--seed", "3"], post=stub)
    assert code == 0

    # Two transcripts × one prompt × one model through the service, two made elsewhere.
    assert len(stub.calls) == 2
    url, headers, request = stub.calls[0]
    assert url == "https://api.example.com/v1/chat/completions"
    assert headers["Authorization"] == "Bearer test-key-not-real"
    assert [m["role"] for m in request["messages"]] == ["system", "user"]

    files = sorted(p.name for p in out.glob("o*.md"))
    assert files == ["o01.md", "o02.md", "o03.md", "o04.md"]
    texts = {p.name: p.read_text(encoding="utf-8") for p in out.glob("o*.md")}
    # No thinking, and nothing in the names says which model or prompt made it.
    assert all("<think>" not in t for t in texts.values())
    key = list(csv.DictReader((out / "key.csv").open(encoding="utf-8")))
    assert sorted((k["model"], k["prompt"]) for k in key) == [("m1", "C")] * 2 + [("model-one", "A")] * 2
    timing = {r["output_id"]: r["seconds"] for r in csv.DictReader((out / "timing.csv").open(encoding="utf-8"))}
    made_elsewhere = {k["output_id"] for k in key if k["prompt"] == "A"}
    assert all(timing[i] == "" for i in made_elsewhere)
    assert all(timing[i] != "" for i in timing if i not in made_elsewhere)

    template = list(csv.reader((out / "scores-template.csv").open(encoding="utf-8")))
    assert template[0] == G.SCORE_HEADER
    assert len(template) == 1 + 4 * 2
    assert {row[2] for row in template[1:]} == {"甲", "乙"}

    # Filled in, the template is what summary_scores reads.
    filled = out / "scores.csv"
    with filled.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(template[0])
        for row in template[1:]:
            w.writerow(row[:3] + ["0", "4", "4", "4", "4", "1"])
    groups = S.aggregate(filled, out / "key.csv")
    assert {(g.model, g.prompt) for g in groups} == {("model-one", "A"), ("m1", "C")}


def test_the_same_seed_gives_the_same_order(tmp_path, monkeypatch):
    monkeypatch.setenv("KEY_ONE", "k")
    refs, prompt, _ = _setup(tmp_path)
    keys = []
    for name in ("a", "b"):
        out = tmp_path / name
        assert G.main(["--transcripts", str(refs), "--out", str(out), "--prompt", f"C={prompt}",
                       "--model", "m1=https://x/v1,model-one,KEY_ONE", "--seed", "9"], post=Stub()) == 0
        keys.append((out / "key.csv").read_text(encoding="utf-8"))
    assert keys[0] == keys[1]


def test_failures_are_reported_and_left_out(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("KEY_ONE", "k")
    refs, prompt, exports = _setup(tmp_path)
    (exports / "m30.md").unlink()
    out = tmp_path / "blind"
    code = G.main(["--transcripts", str(refs), "--out", str(out), "--prompt", f"C={prompt}",
                   "--model", "ok=https://x/v1,good,KEY_ONE", "--model", "busy=https://x/v1,bad,KEY_ONE",
                   "--existing", f"A@good={exports}"], post=Stub(fail_model="bad"))
    assert code == 1
    err = capsys.readouterr().err
    assert err.count("HTTP 429") == 2
    assert "m30 × A × good: no file" in err
    assert len(list(out.glob("o*.md"))) == 2 + 1


def test_refuses_bad_input(tmp_path, monkeypatch, capsys):
    refs, prompt, _ = _setup(tmp_path)
    # The key comes from the environment only.
    monkeypatch.delenv("NOT_SET", raising=False)
    stub = Stub()
    assert G.main(["--transcripts", str(refs), "--out", str(tmp_path / "o"), "--prompt", f"C={prompt}",
                   "--model", "m=https://x/v1,model,NOT_SET"], post=stub) == 2
    assert "NOT_SET is empty" in capsys.readouterr().err
    assert stub.calls == []  # nothing was sent
    with pytest.raises(G.GenerateError, match="name=base_url,model,KEY_ENV"):
        G.parse_model("m=https://x/v1,model")
    with pytest.raises(G.GenerateError, match="prompt@model=dir"):
        G.existing("A", tmp_path, ["m5"])
    # A second run must not mix into an existing set.
    monkeypatch.setenv("KEY_ONE", "k")
    out = tmp_path / "blind"
    args = ["--transcripts", str(refs), "--out", str(out), "--prompt", f"C={prompt}",
            "--model", "m=https://x/v1,model,KEY_ONE"]
    assert G.main(args, post=Stub()) == 0
    assert G.main(args, post=Stub()) == 2
    assert "already holds a blind set" in capsys.readouterr().err


def test_plain_prompt_asks_for_the_apps_fields():
    text = (G.Path(G.__file__).parent / "prompts" / "c-plain-minutes.txt").read_text(encoding="utf-8")
    for field in ('"title"', '"summary"', '"sections"', '"todos"'):
        assert field in text


def test_beanpod_prompt_drops_its_source_note_and_asks_for_the_scenes():
    path = G.Path(G.__file__).parent / "prompts" / "b-beanpod.txt"
    assert "0d00fab" in path.read_text(encoding="utf-8")
    text = G.read_prompt(path)
    assert text.startswith("你是录音整理助手。") and "0d00fab" not in text and "\n# " not in text
    for scene in ("meeting", "interview", "sales", "talk", "call", "media", "conference", "lesson", "memo", "other"):
        assert f"- {scene}（" in text
    for field in ('"scene"', '"title"', '"summary"', '"sections"', '"todos"', '"tags"', '"people"'):
        assert field in text


def test_a_prompt_without_a_source_note_is_sent_unchanged():
    path = G.Path(G.__file__).parent / "prompts" / "c-plain-minutes.txt"
    assert G.read_prompt(path) == path.read_text(encoding="utf-8")
