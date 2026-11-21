"""asr_eval: character error rate for the ASR comparison (#12, #67). Text only, no audio."""
import json

import pytest

import asr_eval as E


def test_normalize_drops_punctuation_spaces_and_width():
    assert E.normalize("你好，世界！ Hello  World.") == "你好世界helloworld"
    # Full-width digits and letters become half-width; digits count.
    assert E.normalize("ＡＢ１２３。") == "ab123"
    assert E.normalize("第一行\n第二行\t") == "第一行第二行"
    assert E.normalize("“引号”《书名》……") == "引号书名"


def test_identical_text_has_no_errors():
    c = E.edit_counts("下周三上线", "下周三上线")
    assert (c.substitutions, c.deletions, c.insertions, c.reference_chars) == (0, 0, 0, 5)
    assert c.cer == 0


@pytest.mark.parametrize("ref,hyp,expected", [
    ("回款率", "汇款率", (1, 0, 0)),        # one wrong character
    ("下周三上线", "下周上线", (0, 1, 0)),   # one missing
    ("下周上线", "下周三上线", (0, 0, 1)),   # one extra
    ("abc", "", (0, 3, 0)),
    ("", "abc", (0, 0, 3)),
    ("今天开会讨论预算", "今天会议讨论预算和人员", (2, 0, 3)),
])
def test_counts_substitutions_deletions_insertions(ref, hyp, expected):
    c = E.edit_counts(ref, hyp)
    assert (c.substitutions, c.deletions, c.insertions) == expected
    assert c.reference_chars == len(ref)
    assert c.errors == sum(expected)


def test_cer_without_reference_is_none():
    assert E.edit_counts("", "").cer is None


def test_markdown_export_reads_only_the_transcript_section(tmp_path):
    md = tmp_path / "a.md"
    md.write_text("# 周会\n\n## 摘要\n\n这段不算。\n\n## 文字稿\n\n**00:00:00** 那就下周三。\n\n"
                  "**00:01:05** 好的\n\n## 大纲\n\n也不算\n", encoding="utf-8")
    assert E.normalize(E.transcript_text(md)) == "那就下周三好的"
    # A .md without that heading, and any .txt, are read whole.
    plain = tmp_path / "b.md"
    plain.write_text("全部都算。", encoding="utf-8")
    assert E.transcript_text(plain) == "全部都算。"


def _write(directory, files):
    directory.mkdir()
    for name, text in files.items():
        (directory / name).write_text(text, encoding="utf-8")
    return directory


def test_scores_engines_and_counts_missing_files(tmp_path):
    refs = _write(tmp_path / "refs", {"m1.txt": "下周三上线。", "m2.txt": "预算再议"})
    good = _write(tmp_path / "good", {"m1.txt": "下周三上线", "m2.md": "## 文字稿\n\n**00:00:02** 预算再议\n"})
    partial = _write(tmp_path / "partial", {"m1.txt": "下周上线"})

    g = E.score(refs, good)
    assert g.engine == "good" and g.missing == []
    assert g.totals.errors == 0 and g.totals.reference_chars == 9

    p = E.score(refs, partial)
    assert p.missing == ["m2"]
    assert p.per_file["m1"].deletions == 1
    assert p.per_file["m2"].deletions == 4  # no output: all deleted
    assert p.totals.cer == pytest.approx(5 / 9)

    table = E.markdown_table([g, p])
    assert "| good | 2 | 9 | 0 | 0 | 0 | 0.00% | — |" in table
    assert "| partial | 2 | 9 | 0 | 5 | 0 | 55.56% | m2 |" in table


def test_cli_prints_table_or_json(tmp_path, capsys):
    refs = _write(tmp_path / "refs", {"m1.txt": "好的"})
    engine = _write(tmp_path / "engine", {"m1.txt": "好"})
    assert E.main([str(refs), str(engine)]) == 0
    assert "| engine | 1 | 2 | 0 | 1 | 0 | 50.00% | — |" in capsys.readouterr().out

    assert E.main([str(refs), str(engine), "--json"]) == 0
    data = json.loads(capsys.readouterr().out)
    assert data[0]["totals"]["cer"] == 0.5 and data[0]["per_file"]["m1"]["deletions"] == 1


def test_cli_reports_an_empty_reference_directory(tmp_path, capsys):
    refs = tmp_path / "refs"
    refs.mkdir()
    assert E.main([str(refs), str(refs)]) == 2
    assert "no .txt or .md references" in capsys.readouterr().err
