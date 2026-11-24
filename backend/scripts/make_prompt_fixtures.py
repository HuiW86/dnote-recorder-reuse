"""Writes the summary prompts as fixtures both the app and the backend test against (ADR-009: one
source of prompts). The app's Summarizer.swift is the source: change it, port the change to
revive_api/summaries.py, run this, and commit the fixtures with both. The app's PromptFixtureTests
and the backend's tests/test_summaries.py then check their own prompts against these files.

    cd backend && .venv/bin/python scripts/make_prompt_fixtures.py
"""

from pathlib import Path

from revive_api import summaries as s

FIXTURES = Path(__file__).resolve().parents[2] / "app/ReviveKit/Tests/AssistantTests/Fixtures/prompts"

# name -> text. Keep the same names in PromptFixtureTests.swift.
CASES = {
    "system-auto.txt": s.system_prompt(None),
    "system-meeting.txt": s.system_prompt("meeting"),
    "system-auto-profession.txt": s.system_prompt(None, " 律师 "),
    "chunk-2.txt": s.chunk_prompt(2),
    "chunk-notes.txt": s.chunk_notes(["第一段的要点", "第二段的要点"]),
    "user-65min.txt": s.user_message("第一句。\n第二句。", 3_900_000),
    "retitle.txt": s.RETITLE_PROMPT,
    "retitle-user.txt": s.retitle_message("周会\n下周三上线。", "2026-11-20 09:30"),
}


def main() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    for name, text in CASES.items():
        (FIXTURES / name).write_text(text, encoding="utf-8", newline="")
    print(f"wrote {len(CASES)} fixtures to {FIXTURES}")


if __name__ == "__main__":
    main()
