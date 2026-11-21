"""summary_scores: blind summary scores joined with the key and averaged (#12, #68)."""
import json

import pytest

import summary_scores as S

HEADER = "output_id,sample,scorer,fabrications,coverage,todos,structure,concision,parsed\n"


def _files(tmp_path, scores, key):
    s = tmp_path / "scores.csv"
    k = tmp_path / "key.csv"
    s.write_text(HEADER + scores, encoding="utf-8")
    k.write_text("output_id,model,prompt\n" + key, encoding="utf-8")
    return s, k


def test_groups_by_model_and_prompt_and_ranks_failures_last(tmp_path):
    s, k = _files(tmp_path,
                  "o1,5min,甲,0,5,4,4,5,1\n"
                  "o1,5min,乙,0,4,4,5,5,1\n"
                  "o2,30min,甲,0,3,3,4,4,1\n"
                  "o3,5min,甲,1,5,5,5,5,1\n"
                  "o4,5min,甲,0,2,2,2,2,0\n",
                  "o1,deepseek-chat,A\no2,deepseek-chat,A\no3,qwen-plus,A\no4,qwen-plus,B\n")
    groups = S.aggregate(s, k)
    assert [(g.model, g.prompt) for g in groups] == [("deepseek-chat", "A"), ("qwen-plus", "B"), ("qwen-plus", "A")]
    best = groups[0]
    assert best.rows == 3 and best.samples == {"5min", "30min"} and best.failed == 0
    assert best.mean("coverage") == pytest.approx(4.0)
    assert best.overall == pytest.approx((4 + 11 / 3 + 13 / 3 + 14 / 3) / 4)
    # Making something up fails the output even with full marks; ranked last.
    assert groups[-1].failed == 1 and groups[-1].overall == 5
    assert groups[1].unparsed == 1

    table = S.markdown_table(groups)
    assert table.splitlines()[2].startswith("| deepseek-chat | A | 3 | 2 | 0 | 0 | 4.00 |")


@pytest.mark.parametrize("row,message", [
    ("o1,5min,甲,0,6,4,4,4,1\n", "coverage must be 1–5"),
    ("o1,5min,甲,-1,4,4,4,4,1\n", "fabrications must be >= 0"),
    ("o1,5min,甲,0,4,4,4,4,2\n", "parsed must be 0–1"),
    ("o1,5min,甲,0,四,4,4,4,1\n", "coverage is not a whole number"),
    ("o9,5min,甲,0,4,4,4,4,1\n", "output o9 is not in key.csv"),
])
def test_rejects_bad_rows_with_their_line(tmp_path, row, message):
    s, k = _files(tmp_path, row, "o1,m,A\n")
    with pytest.raises(S.ScoreError, match=message):
        S.aggregate(s, k)


def test_rejects_missing_columns_and_duplicate_keys(tmp_path):
    s, k = _files(tmp_path, "o1,5min,甲,0,4,4,4,4,1\n", "o1,m,A\no1,m,B\n")
    with pytest.raises(S.ScoreError, match="listed twice"):
        S.aggregate(s, k)
    k.write_text("output_id,model\no1,m\n", encoding="utf-8")
    with pytest.raises(S.ScoreError, match="missing columns prompt"):
        S.aggregate(s, k)


def test_cli_table_json_and_errors(tmp_path, capsys):
    s, k = _files(tmp_path, "o1,5min,甲,0,4,4,4,4,1\n", "o1,m,A\n")
    assert S.main([str(s), str(k)]) == 0
    assert "| m | A | 1 | 1 | 0 | 0 | 4.00 | 4.00 | 4.00 | 4.00 | 4.00 |" in capsys.readouterr().out
    assert S.main([str(s), str(k), "--json"]) == 0
    assert json.loads(capsys.readouterr().out)[0]["overall"] == 4
    s.write_text(HEADER, encoding="utf-8")
    assert S.main([str(s), str(k)]) == 2
    assert "no scores" in capsys.readouterr().err
