"""Device-media assignment schemas."""

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

SyncStatus = Literal["synchronized", "pending"]

# Reproduction surface of an assigned `url` media: in-app WebView or
# an external fullscreen browser tab (device-side Custom Tabs/Chrome).
DisplayMode = Literal["webview", "external"]


class AssignmentCreate(BaseModel):
    """Payload for PUT /api/devices/{device_uid}/assignment."""

    media_id: int = Field(ge=1)
    # Only meaningful for `url` media (the service rejects 'external'
    # for any other type): the operator picks it per assignment and
    # can flip it later by reassigning — the revision bump switches the
    # client to the other surface immediately.
    display_mode: DisplayMode = "webview"


class AssignmentRead(BaseModel):
    """The vigente assignment of a device: which media the
    administration assigned and whether the device reports playing it.

    `media_id` is the identifier the device client must report back in
    its heartbeat (`payload.current_media`) for the assignment to become
    `synchronized`."""

    model_config = ConfigDict(from_attributes=True)

    id: int
    device_id: int
    device_uid: str
    media_id: int
    media_name: str
    sync_status: SyncStatus
    # Reproduction surface chosen at assignment time ('url' media).
    display_mode: DisplayMode
    revision: int = Field(ge=1)
    created_at: datetime
    updated_at: datetime


class AssignmentSetResult(AssignmentRead):
    """Response of PUT /api/devices/{device_uid}/assignment.

    `delivered` is STRICTLY "the command was written to the device's
    live WebSocket without error". It is not receipt confirmation, not
    execution confirmation, and never affects `sync_status` (only a
    heartbeat reporting the media does that). False means the
    assignment is persisted and the device will receive it through
    `playback.sync` on its next connection.
    """

    delivered: bool
