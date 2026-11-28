"""Model tokens of attempts that produced nothing are kept as `llm_unbilled` usage: a cost of
running the service, never counted against a user's allowance (usage.py; prd.md §8).

Revision ID: 0006
Revises: 0005
Create Date: 2026-11-25 10:00:00
"""

from collections.abc import Sequence

import sqlalchemy as sa
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
    # Cost records are never deleted to go back. 0005's code runs on this schema unchanged (it
    # reads only asr_seconds and llm_tokens), so roll back the code and keep this migration.
    # A NOT VALID check is no way out either: deleting an account would then fail on these rows.
    kept = op.get_bind().execute(sa.text("SELECT 1 FROM usage_records WHERE kind = 'llm_unbilled' LIMIT 1"))
    if kept.first() is not None:
        raise RuntimeError(
            "usage_records holds llm_unbilled costs; 0005's code runs on 0006 unchanged, so keep this "
            "migration. Export and remove those rows by hand first if the schema must go back."
        )
    op.drop_constraint("usage_records_kind", "usage_records", type_="check")
    op.create_check_constraint("usage_records_kind", "usage_records", "kind IN ('asr_seconds', 'llm_tokens')")
