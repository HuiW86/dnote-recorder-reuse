"""Model tokens of attempts that produced nothing are kept as `llm_unbilled` usage: a cost of
running the service, never counted against a user's allowance (usage.py; prd.md §8).

Revision ID: 0006
Revises: 0005
Create Date: 2026-11-25 10:00:00
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0006"
down_revision: str | None = "0005"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.drop_constraint("usage_records_kind", "usage_records", type_="check")
    op.create_check_constraint(
        "usage_records_kind", "usage_records", "kind IN ('asr_seconds', 'llm_tokens', 'llm_unbilled')"
    )


def downgrade() -> None:
    # Going back keeps the wider check and every llm_unbilled row: cost records are never deleted,
    # and 0005's code reads only asr_seconds and llm_tokens, so it runs on this unchanged. (A NOT
    # VALID check would make deleting an account fail on those rows when user_id is set to NULL.)
    pass
