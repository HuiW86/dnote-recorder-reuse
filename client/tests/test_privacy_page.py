"""scripts/build_privacy_page.py: the public privacy page is the draft without its maintenance
box, every placeholder filled in, and none of the names rule 5 forbids."""
import importlib.util
import os

from conftest import REPO_ROOT

_spec = importlib.util.spec_from_file_location(
    "build_privacy_page", os.path.join(REPO_ROOT, "scripts", "build_privacy_page.py"))
P = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(P)

FILLED = {"YYYY-MM-DD": "2026-12-01", "开发者名称": "示例开发者", "联系邮箱": "privacy@example.com"}


def test_the_draft_in_the_repo_builds_once_filled_in():
    source = P.SOURCE.read_text(encoding="utf-8")
    page, found = P.build(source, FILLED)
    assert found == [], found
    assert page.startswith("---\ntitle: 闻笺隐私政策\n")
    assert "维护说明" not in page and "公开版草稿" not in page
    assert "# 闻笺隐私政策" in page and "privacy@example.com" in page
    assert "适用于 D·NOTE 录音卡" in page  # the one allowed mention stays


def test_unfilled_placeholders_are_reported():
    page, found = P.build(P.SOURCE.read_text(encoding="utf-8"), {"YYYY-MM-DD": "2026-12-01"})
    assert "placeholder 【联系邮箱】 is not filled in" in found
    assert "placeholder 【开发者名称】 is not filled in" in found
    assert len([f for f in found if "联系邮箱" in f]) == 1  # reported once, though used twice


def test_forbidden_names_are_reported():
    source = "# 草稿\n\n> 维护说明\n\n---\n\n# 闻笺隐私政策\n\n与 Dreame 无关。\n"
    _, found = P.build(source, {})
    assert found == ["「Dreame」 may not appear (CLAUDE.md rule 5)"]


def test_refuses_a_source_without_the_maintenance_box():
    try:
        P.build("# 闻笺隐私政策\n\n正文\n", {})
    except P.PageError as error:
        assert "maintenance box" in str(error)
    else:
        raise AssertionError("expected a refusal")


def test_cli_writes_only_a_ready_page_unless_draft(tmp_path, capsys):
    out = tmp_path / "site" / "privacy.md"
    assert P.main(["--out", str(out)]) == 1
    assert not out.exists() and "nothing written" in capsys.readouterr().err

    assert P.main(["--out", str(out), "--draft"]) == 1
    assert out.exists() and "【联系邮箱】" in out.read_text(encoding="utf-8")

    args = ["--out", str(out)] + [arg for k, v in FILLED.items() for arg in ("--fill", f"{k}={v}")]
    assert P.main(args) == 0
    assert "【" not in out.read_text(encoding="utf-8")
    assert P.main(["--out", str(out), "--fill", "联系邮箱"]) == 2
