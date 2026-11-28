"""check_log.py: a frame log exported from the debug page, judged against the device test criteria."""
import check_log as L

LIST = """\
2026-11-26 10:00:00.000 [fg] tx 90 len=0
2026-11-26 10:00:00.100 [fg] rx 90 len=61 {"name":"20261126095900.opus","size":400,"index":0,"end":0}
2026-11-26 10:00:00.200 [fg] rx 90 len=39 {"name":"","size":0,"index":1,"end":1}
"""
DOWNLOAD = """\
2026-11-26 10:00:01.000 [bg] rx 55 len=0
2026-11-26 10:00:02.000 [bg] tx 70 len=49 {"cmd":1,"name":"20261126095900.opus","offset":0}
2026-11-26 10:00:02.100 [bg] rx 70 len=205 status=0x00 offset=0 data=<200 B>
2026-11-26 10:00:02.200 [lock] rx 70 len=205 status=0x2E offset=200 data=<200 B>
"""
DELETE = '2026-11-26 10:00:03.000 [lock] tx 91 len=30 {"name":"20261126095900.opus"}\n'


def judge(text, redaction=()):
    return L.check(L.parse(text), list(redaction))


def test_a_clean_sync_and_delete_passes():
    r = judge(LIST + DOWNLOAD + DELETE)
    assert r.failures == []
    assert any("delete 20261126095900.opus: after its download completed" in line for line in r.lines)
    assert any("after 1.0 s" in line for line in r.lines)  # stop -> download
    assert any("400 B, eof" in line and "[bg→lock]" in line for line in r.lines)


def test_forbidden_and_unknown_commands_fail():
    r = judge(LIST + "2026-11-26 10:00:05.000 [fg] tx 94 len=0\n2026-11-26 10:00:06.000 [fg] tx 89 len=2 {}\n")
    assert any("forbidden command 94" in f for f in r.failures)
    assert any("89 is not in the app's whitelist" in f for f in r.failures)


def test_a_delete_before_the_download_completed_fails():
    partial = DOWNLOAD.split("\n")[1] + "\n" + DOWNLOAD.split("\n")[2] + "\n"
    r = judge(LIST + partial + DELETE)
    assert any("download in this log never completed" in f for f in r.failures)
    assert any("never completed in this log" in n for n in r.notes)


def test_a_delete_of_a_file_downloaded_earlier_is_only_noted():
    r = judge(LIST + DELETE)
    assert r.failures == [] and any("not in this log" in n for n in r.notes)


def test_a_short_file_fails():
    short = DOWNLOAD.replace("status=0x2E offset=200 data=<200 B>", "status=0x2E offset=200 data=<100 B>")
    assert any("listed as 400 B" in f for f in judge(LIST + short).failures)


def test_a_slow_start_after_the_stop_is_noted():
    late = DOWNLOAD.replace("10:00:02.000 [bg] tx 70", "10:00:15.000 [bg] tx 70")
    assert any("wants ≤ 10 s" in n for n in judge(LIST + late).notes)


def test_settings_are_read_back():
    ok = ("2026-11-26 10:01:00.000 [fg] tx 8C len=1 05\n"
          '2026-11-26 10:01:00.100 [fg] rx 81 len=78 {"led":1,"gain":5,"autoff":600}\n'
          "2026-11-26 10:01:01.000 [fg] tx 8F len=4 00 00 01 2C\n"
          '2026-11-26 10:01:01.100 [fg] rx 81 len=78 {"led":1,"gain":5,"autoff":600}\n')
    r = judge(ok)
    assert any("gain=5: read back" in line for line in r.lines)
    assert any("autoff written as 300" in f for f in r.failures)


def test_redaction_problems_fail_and_an_empty_log_says_so():
    assert any("rule 4" in f for f in judge(LIST, [(2, "sn is not redacted")]).failures)
    assert "DEBUG build" in judge("not a frame log").failures[0]


def test_the_real_evidence_logs_pass():
    import pathlib

    root = pathlib.Path(L.__file__).resolve().parent.parent / "evidence"
    for name in ("v46-merge-smoke/card-debug.log", "v38-card-link/05-replies.log"):
        assert L.main([str(root / name)]) == 0


def test_the_name_a_recording_started_with_is_the_file_downloaded():
    started = '2026-11-26 09:59:00.000 [fg] rx 54 len=30 {"name":"20261126095900.opus"}\n'
    r = judge(started + LIST + DOWNLOAD)
    assert any("downloaded under that name" in line for line in r.lines)
    other = started.replace("095900", "095959")
    assert any("no download of that name" in n for n in judge(other + LIST + DOWNLOAD).notes)


def test_a_case_fails_what_is_over_its_pass_line():
    late = DOWNLOAD.replace("10:00:02.000 [bg] tx 70", "10:00:15.000 [bg] tx 70")
    r = judge(LIST + late)
    r.judge(["T-M1-51"])
    assert any(f.startswith("T-M1-51:") and "wants ≤ 10 s" in f for f in r.failures)
    on_time = judge(LIST + DOWNLOAD)
    on_time.judge(["T-M1-51"])
    assert on_time.failures == []


def test_a_case_with_nothing_to_judge_is_not_a_pass(tmp_path):
    # A 400 B download says nothing about throughput: T-M1-53 cannot pass on it.
    log = tmp_path / "short.log"
    log.write_text(LIST + DOWNLOAD, encoding="utf-8")
    assert L.main([str(log)]) == 0
    assert L.main(["--case", "T-M1-53", str(log)]) == 1
