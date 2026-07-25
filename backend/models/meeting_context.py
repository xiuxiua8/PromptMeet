from __future__ import annotations

import uuid
from datetime import UTC, datetime
from enum import StrEnum
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field


class MeetingStatus(StrEnum):
    ACTIVE = "active"
    COMPLETED = "completed"
    INCOMPLETE = "incomplete"
    RECOVERY_REQUIRED = "recovery_required"


class EventKind(StrEnum):
    LIFECYCLE = "lifecycle"
    TRANSCRIPT = "transcript"
    SCREENSHOT = "screenshot"
    SCREENSHOT_ANALYSIS = "screenshot_analysis"
    USER_QUESTION = "user_question"
    ASSISTANT_ANSWER = "assistant_answer"
    SUMMARY = "summary"


class EventProvenance(BaseModel):
    model_config = ConfigDict(extra="forbid")

    source: str
    provider: str | None = None
    model: str | None = None
    request_id: str | None = None


class EvidenceSource(BaseModel):
    model_config = ConfigDict(extra="forbid")

    source_id: str
    event_id: str
    label: str


class LifecyclePayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["lifecycle"] = "lifecycle"
    status: MeetingStatus
    detail: str | None = None


class TranscriptPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["transcript"] = "transcript"
    segment_id: str
    text: str
    speaker: str = "发言人"
    source: str | None = None
    translated_text: str | None = None


class ScreenshotPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["screenshot"] = "screenshot"
    asset_id: str
    relative_path: str
    mime_type: str
    sha256: str
    width: int | None = None
    height: int | None = None
    capture_status: Literal["available", "missing"] = "available"


class ScreenshotAnalysisPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["screenshot_analysis"] = "screenshot_analysis"
    asset_id: str
    status: Literal["completed", "failed", "unsupported"]
    text: str
    vision_used: bool = False


class QuestionPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["user_question"] = "user_question"
    request_id: str
    thread_id: str = "main"
    question: str


class AnswerPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["assistant_answer"] = "assistant_answer"
    request_id: str
    thread_id: str = "main"
    answer: str
    sources: list[EvidenceSource] = Field(default_factory=list)
    degraded_vision: bool = False
    status: Literal["completed", "failed"] = "completed"
    error_message: str | None = None


class SummaryPayload(BaseModel):
    model_config = ConfigDict(extra="allow")

    type: Literal["summary"] = "summary"
    summary_text: str
    tasks: list[dict] = Field(default_factory=list)
    key_points: list[str] = Field(default_factory=list)
    decisions: list[str] = Field(default_factory=list)
    derived: bool = False


EventPayload = Annotated[
    LifecyclePayload
    | TranscriptPayload
    | ScreenshotPayload
    | ScreenshotAnalysisPayload
    | QuestionPayload
    | AnswerPayload
    | SummaryPayload,
    Field(discriminator="type"),
]


class MeetingEvent(BaseModel):
    model_config = ConfigDict(extra="forbid")

    event_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    meeting_id: str = ""
    sequence: int = 0
    occurred_at: datetime
    kind: EventKind
    provenance: EventProvenance
    payload: EventPayload


class LegacyMigrationReference(BaseModel):
    model_config = ConfigDict(extra="forbid")

    source_file: str
    source_key: str


class MeetingRecord(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: Literal[2] = 2
    meeting_id: str
    title: str | None = None
    status: MeetingStatus = MeetingStatus.ACTIVE
    started_at: datetime
    ended_at: datetime | None = None
    events: list[MeetingEvent] = Field(default_factory=list)
    migration: LegacyMigrationReference | None = None

    @classmethod
    def recovery_item(cls, meeting_id: str, detail: str) -> MeetingRecord:
        now = datetime.now(UTC)
        return cls(
            meeting_id=meeting_id,
            title="需要恢复的会议记录",
            status=MeetingStatus.RECOVERY_REQUIRED,
            started_at=now,
            events=[
                MeetingEvent(
                    meeting_id=meeting_id,
                    sequence=1,
                    occurred_at=now,
                    kind=EventKind.LIFECYCLE,
                    provenance=EventProvenance(source="meeting_repository"),
                    payload=LifecyclePayload(
                        status=MeetingStatus.RECOVERY_REQUIRED,
                        detail=detail,
                    ),
                )
            ],
        )
