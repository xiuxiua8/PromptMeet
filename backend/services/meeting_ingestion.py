from __future__ import annotations

import hashlib
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from models.meeting_context import (
    AnswerPayload,
    EventKind,
    EventProvenance,
    EvidenceSource,
    LifecyclePayload,
    MeetingEvent,
    MeetingRecord,
    MeetingStatus,
    QuestionPayload,
    ScreenshotAnalysisPayload,
    ScreenshotPayload,
    SummaryPayload,
    TranscriptPayload,
)
from services.meeting_repository import MeetingNotFoundError, MeetingRepository


@dataclass(frozen=True)
class ScreenshotAnalysisResult:
    status: str
    text: str
    vision_used: bool
    provider: str | None = None
    model: str | None = None


class MeetingIngestionService:
    def __init__(self, repository: MeetingRepository):
        self.repository = repository

    def start(self, meeting_id: str, started_at: datetime) -> MeetingRecord:
        record = self.repository.create(meeting_id, self._aware(started_at))
        if not any(event.kind == EventKind.LIFECYCLE for event in record.events):
            record = self.repository.append(
                meeting_id,
                MeetingEvent(
                    occurred_at=self._aware(started_at),
                    kind=EventKind.LIFECYCLE,
                    provenance=EventProvenance(source="session_api"),
                    payload=LifecyclePayload(
                        status=MeetingStatus.ACTIVE, detail="会议已创建"
                    ),
                ),
            )
        return record

    def transcript(self, meeting_id: str, transcript: dict) -> MeetingEvent:
        event = MeetingEvent(
            occurred_at=self._date(transcript.get("timestamp")),
            kind=EventKind.TRANSCRIPT,
            provenance=EventProvenance(source="native_transcript"),
            payload=TranscriptPayload(
                segment_id=str(transcript.get("id") or ""),
                text=str(transcript.get("text") or "").strip(),
                speaker=str(transcript.get("speaker") or "发言人"),
                source=transcript.get("source"),
                translated_text=transcript.get("translated_text"),
            ),
        )
        return self.repository.append(meeting_id, event).events[-1]

    def screenshot(self, meeting_id: str, path: Path, mime_type: str) -> MeetingEvent:
        resolved = path.resolve()
        root = self.repository.root.resolve()
        if root not in resolved.parents:
            raise ValueError("截图必须存储在 PromptMeet 数据目录内")
        data = resolved.read_bytes()
        width, height = self._dimensions(data, mime_type)
        event = MeetingEvent(
            occurred_at=datetime.now(UTC),
            kind=EventKind.SCREENSHOT,
            provenance=EventProvenance(source="native_screenshot"),
            payload=ScreenshotPayload(
                asset_id=resolved.stem,
                relative_path=resolved.relative_to(root).as_posix(),
                mime_type=mime_type,
                sha256=hashlib.sha256(data).hexdigest(),
                width=width,
                height=height,
            ),
        )
        return self.repository.append(meeting_id, event).events[-1]

    def screenshot_analysis(
        self,
        meeting_id: str,
        asset_id: str,
        result: ScreenshotAnalysisResult,
    ) -> MeetingEvent:
        event = MeetingEvent(
            occurred_at=datetime.now(UTC),
            kind=EventKind.SCREENSHOT_ANALYSIS,
            provenance=EventProvenance(
                source="multimodal_analysis",
                provider=result.provider,
                model=result.model,
            ),
            payload=ScreenshotAnalysisPayload(
                asset_id=asset_id,
                status=result.status,
                text=result.text,
                vision_used=result.vision_used,
            ),
        )
        return self.repository.append(meeting_id, event).events[-1]

    def question(
        self,
        meeting_id: str,
        request_id: str,
        thread_id: str,
        question: str,
    ) -> tuple[MeetingEvent, MeetingRecord]:
        record = self._required(meeting_id)
        for existing in record.events:
            if (
                existing.kind == EventKind.USER_QUESTION
                and isinstance(existing.payload, QuestionPayload)
                and existing.payload.request_id == request_id
            ):
                return existing, record
        event = MeetingEvent(
            occurred_at=datetime.now(UTC),
            kind=EventKind.USER_QUESTION,
            provenance=EventProvenance(source="user", request_id=request_id),
            payload=QuestionPayload(
                request_id=request_id,
                thread_id=thread_id,
                question=question,
            ),
        )
        updated = self.repository.append(meeting_id, event)
        return updated.events[-1], updated

    def answer(
        self,
        meeting_id: str,
        request_id: str,
        thread_id: str,
        answer: str,
        sources: list[EvidenceSource],
        *,
        degraded_vision: bool,
        provider: str,
        model: str,
    ) -> MeetingEvent:
        event = MeetingEvent(
            occurred_at=datetime.now(UTC),
            kind=EventKind.ASSISTANT_ANSWER,
            provenance=EventProvenance(
                source="meeting_agent",
                provider=provider,
                model=model,
                request_id=request_id,
            ),
            payload=AnswerPayload(
                request_id=request_id,
                thread_id=thread_id,
                answer=answer,
                sources=sources,
                degraded_vision=degraded_vision,
            ),
        )
        return self.repository.append(meeting_id, event).events[-1]

    def answer_failure(
        self,
        meeting_id: str,
        request_id: str,
        thread_id: str,
        message: str,
    ) -> MeetingEvent:
        event = MeetingEvent(
            occurred_at=datetime.now(UTC),
            kind=EventKind.ASSISTANT_ANSWER,
            provenance=EventProvenance(
                source="meeting_agent",
                request_id=request_id,
            ),
            payload=AnswerPayload(
                request_id=request_id,
                thread_id=thread_id,
                answer="",
                status="failed",
                error_message=message,
            ),
        )
        return self.repository.append(meeting_id, event).events[-1]

    def summary(self, meeting_id: str, summary: dict) -> MeetingEvent:
        event = MeetingEvent(
            occurred_at=datetime.now(UTC),
            kind=EventKind.SUMMARY,
            provenance=EventProvenance(source="summary_service"),
            payload=SummaryPayload(
                summary_text=str(summary.get("summary_text") or ""),
                tasks=list(summary.get("tasks") or []),
                key_points=list(summary.get("key_points") or []),
                decisions=list(summary.get("decisions") or []),
            ),
        )
        return self.repository.append(meeting_id, event).events[-1]

    def finish(
        self,
        meeting_id: str,
        status: MeetingStatus = MeetingStatus.COMPLETED,
        detail: str = "会议已结束",
    ) -> MeetingRecord:
        now = datetime.now(UTC)
        try:
            self.repository.append(
                meeting_id,
                MeetingEvent(
                    occurred_at=now,
                    kind=EventKind.LIFECYCLE,
                    provenance=EventProvenance(source="session_api"),
                    payload=LifecyclePayload(status=status, detail=detail),
                ),
            )
            return self.repository.finish(meeting_id, now, status)
        except MeetingNotFoundError:
            raise

    def _required(self, meeting_id: str) -> MeetingRecord:
        record = self.repository.get(meeting_id)
        if record is None or record.status == MeetingStatus.RECOVERY_REQUIRED:
            raise MeetingNotFoundError(meeting_id)
        return record

    @staticmethod
    def _date(value: object) -> datetime:
        if isinstance(value, datetime):
            return MeetingIngestionService._aware(value)
        if isinstance(value, str):
            try:
                return MeetingIngestionService._aware(
                    datetime.fromisoformat(value.replace("Z", "+00:00"))
                )
            except ValueError:
                pass
        return datetime.now(UTC)

    @staticmethod
    def _aware(value: datetime) -> datetime:
        return value if value.tzinfo else value.replace(tzinfo=UTC)

    @staticmethod
    def _dimensions(data: bytes, mime_type: str) -> tuple[int | None, int | None]:
        if mime_type == "image/png" and len(data) >= 24 and data.startswith(b"\x89PNG"):
            return int.from_bytes(data[16:20], "big"), int.from_bytes(
                data[20:24], "big"
            )
        return None, None
