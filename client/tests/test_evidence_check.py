"""scripts/check_evidence.py: evidence keeps no card identifiers (CLAUDE.md rule 4, ADR-006)."""
import importlib.util
import os

from conftest import REPO_ROOT

_spec = importlib.util.spec_from_file_location(
    "check_evidence", os.path.join(REPO_ROOT, "scripts", "check_evidence.py"))
E = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(E)

# Made-up identifiers in the card's formats; not any real card.
RAW_SN = "q1w2e3r4t5y6u7i8o9"


def test_the_repo_passes():
    assert E.main() == 0


def test_redacted_forms_pass():
    text = "\n".join([
        '{"sn":"sha256:0123abcd","btaddr":"…a1b2"}',
        "sn `sha256:0123abcd`；bondId 记为 `<bondId 16 B>`",
        "`sn` sha256 前 8 位 `0123abcd`",
        "日志不含原始 `sn`、`btaddr`、`bondId`",
        "bondId=None",
    ])
    assert E.problems(text) == []


def test_raw_identifiers_fail():
    assert E.problems(f'{{"sn":"{RAW_SN}"}}')
    assert E.problems(f"- 卡：序列号 `{RAW_SN}`，固件 `1.50`")
    assert E.problems(f"设备 sn `{RAW_SN}`")
    assert E.problems('{"btaddr": "0a1b2c3d4e5f"}')
    assert E.problems("connected to 0A:1B:2C:3D:4E:5F")
    assert E.problems("bondId=00112233445566778899aabbccddeeff")
    assert E.problems('{"isBonded":1,"bondId":"ABEiM0RVZneImaq7zN3u/w=="}')


def test_every_legacy_file_still_has_something_to_clean(tmp_path):
    # Without the list, each legacy file is reported: once one is cleaned, it leaves LEGACY.
    flagged = {line.split(":")[0].removeprefix("evidence/") for line in E.check(legacy=frozenset())}
    assert flagged == set(E.LEGACY)
