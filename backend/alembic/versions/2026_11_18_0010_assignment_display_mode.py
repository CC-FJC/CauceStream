"""device_media_assignments.display_mode

Revision ID: 0010
Revises: 0009
Create Date: 2026-11-18

Adds the per-assignment reproduction surface for `url` media:
'webview' (in-app) or 'external' (device-side fullscreen browser tab,
Custom Tabs/Chrome — webAR with camera). The decision lives in the
assignment, not the media: the same URL can target different devices
with a different surface. Server default 'webview' keeps every
pre-existing assignment byte-identical in behavior.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "0010"
down_revision: Union[str, None] = "0009"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table("device_media_assignments") as batch_op:
        batch_op.add_column(
            sa.Column(
                "display_mode",
                sa.String(length=8),
                nullable=False,
                server_default="webview",
            )
        )


def downgrade() -> None:
    with op.batch_alter_table("device_media_assignments") as batch_op:
        batch_op.drop_column("display_mode")
