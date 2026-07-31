from __future__ import annotations

import json
import threading
from datetime import UTC, datetime
from pathlib import Path

from models.meeting_context import (
    EventKind,
    EventProvenance,
    LegacyMigrationReference,
    MeetingEvent,
    MeetingRecord,
    MeetingStatus,
    SummaryPayload,
    TranscriptPayload,
)


class MeetingNotFoundError(KeyError):
    pass


class TranscriptNotFoundError(KeyError):
    pass


class MeetingRepository:
    def __init__(self, root: str | Path):
        self.root = Path(root)
        self.records_directory = self.root / "meetings" / "v2"
        self.assets_directory = self.root / "assets"
        self.records_directory.mkdir(parents=True, exist_ok=True)
        self.assets_directory.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()

    def create(self, meeting_id: str, started_at: datetime) -> MeetingRecord:
        with self._lock:
            existing = self.get(meeting_id)
            if (
                existing is not None
                and existing.status != MeetingStatus.RECOVERY_REQUIRED
            ):
                return existing
            record = MeetingRecord(meeting_id=meeting_id, started_at=started_at)
            self._write(record)
            return record

    def append(self, meeting_id: str, event: MeetingEvent) -> MeetingRecord:
        with self._lock:
            record = self.get(meeting_id)
            if record is None or record.status == MeetingStatus.RECOVERY_REQUIRED:
                raise MeetingNotFoundError(meeting_id)
            sequence = record.events[-1].sequence + 1 if record.events else 1
            bound_event = event.model_copy(
                update={"meeting_id": meeting_id, "sequence": sequence}
            )
            updated = record.model_copy(
                update={"events": [*record.events, bound_event]}
            )
            self._write(updated)
            return updated

    def finish(
        self,
        meeting_id: str,
        ended_at: datetime,
        status: MeetingStatus = MeetingStatus.COMPLETED,
    ) -> MeetingRecord:
        with self._lock:
            record = self.get(meeting_id)
            if record is None or record.status == MeetingStatus.RECOVERY_REQUIRED:
                raise MeetingNotFoundError(meeting_id)
            updated = record.model_copy(update={"ended_at": ended_at, "status": status})
            self._write(updated)
            return updated

    def set_title(self, meeting_id: str, title: str) -> MeetingRecord:
        with self._lock:
            record = self.get(meeting_id)
            if record is None or record.status == MeetingStatus.RECOVERY_REQUIRED:
                raise MeetingNotFoundError(meeting_id)
            updated = record.model_copy(update={"title": title})
            self._write(updated)
            return updated

    def enrich_transcript_translation(
        self,
        meeting_id: str,
        segment_id: str,
        translated_text: str,
    ) -> MeetingEvent:
        normalized = translated_text.strip()
        if not normalized:
            raise ValueError("translated_text must not be empty")
        with self._lock:
            record = self.get(meeting_id)
            if record is None or record.status == MeetingStatus.RECOVERY_REQUIRED:
                raise MeetingNotFoundError(meeting_id)
            matches = [
                index
                for index, event in enumerate(record.events)
                if event.kind == EventKind.TRANSCRIPT
                and isinstance(event.payload, TranscriptPayload)
                and event.payload.segment_id == segment_id
            ]
            if not matches:
                raise TranscriptNotFoundError((meeting_id, segment_id))
            if len(matches) > 1:
                raise ValueError("segment_id is not unique within the meeting")
            index = matches[0]
            original = record.events[index]
            enriched = original.model_copy(
                update={
                    "payload": original.payload.model_copy(
                        update={"translated_text": normalized}
                    )
                }
            )
            events = list(record.events)
            events[index] = enriched
            self._write(record.model_copy(update={"events": events}))
            return enriched

    def get(self, meeting_id: str) -> MeetingRecord | None:
        with self._lock:
            path = self._path(meeting_id)
            if not path.exists():
                self._migrate_legacy()
            if not path.exists():
                return None
            return self._read(path)

    def list(self) -> list[MeetingRecord]:
        with self._lock:
            self._migrate_legacy()
            records = [
                self._read(path) for path in self.records_directory.glob("*.json")
            ]
            return sorted(records, key=lambda record: record.started_at, reverse=True)

    def _read(self, path: Path) -> MeetingRecord:
        try:
            return MeetingRecord.model_validate_json(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            return MeetingRecord.recovery_item(
                path.stem,
                f"无法读取本地会议记录，原文件已保留：{error.__class__.__name__}",
            )

    def _write(self, record: MeetingRecord) -> None:
        path = self._path(record.meeting_id)
        temporary = path.with_suffix(".tmp")
        temporary.write_text(
            record.model_dump_json(indent=2),
            encoding="utf-8",
        )
        temporary.replace(path)

    def _path(self, meeting_id: str) -> Path:
        if (
            not meeting_id
            or meeting_id in {".", ".."}
            or any(separator in meeting_id for separator in ("/", "\\"))
        ):
            raise ValueError("meeting_id contains an invalid path component")
        return self.records_directory / f"{meeting_id}.json"

    def _migrate_legacy(self) -> None:
        legacy_path = self.root / "desktop-sessions.json"
        if not legacy_path.exists():
            return
        try:
            raw = json.loads(legacy_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return
        if isinstance(raw, dict):
            entries = raw.items()
        elif isinstance(raw, list):
            entries = (
                (str(item.get("session_id") or f"legacy-{index}"), item)
                for index, item in enumerate(raw)
                if isinstance(item, dict)
            )
        else:
            return
        for source_key, payload in entries:
            if not isinstance(payload, dict):
                continue
            meeting_id = str(payload.get("session_id") or source_key)
            try:
                path = self._path(meeting_id)
            except ValueError:
                continue
            if path.exists():
                continue
            record = self._legacy_record(meeting_id, str(source_key), payload)
            self._write(record)

    def _legacy_record(
        self,
        meeting_id: str,
        source_key: str,
        payload: dict,
    ) -> MeetingRecord:
        started_at = self._date(payload.get("start_time"))
        ended_at = self._optional_date(payload.get("end_time"))
        status = (
            MeetingStatus.COMPLETED
            if ended_at is not None or payload.get("current_summary")
            else MeetingStatus.INCOMPLETE
        )
        events: list[MeetingEvent] = []
        for segment in payload.get("transcript_segments") or []:
            if (
                not isinstance(segment, dict)
                or not str(segment.get("text") or "").strip()
            ):
                continue
            occurred_at = self._date(segment.get("timestamp"), fallback=started_at)
            events.append(
                MeetingEvent(
                    meeting_id=meeting_id,
                    sequence=len(events) + 1,
                    occurred_at=occurred_at,
                    kind=EventKind.TRANSCRIPT,
                    provenance=EventProvenance(source="legacy_desktop_session"),
                    payload=TranscriptPayload(
                        segment_id=str(
                            segment.get("id") or f"legacy-{len(events) + 1}"
                        ),
                        speaker=str(segment.get("speaker") or "发言人"),
                        text=str(segment["text"]),
                        translated_text=segment.get("translated_text"),
                    ),
                )
            )
        summary = payload.get("current_summary")
        if isinstance(summary, dict) and summary.get("summary_text"):
            events.append(
                MeetingEvent(
                    meeting_id=meeting_id,
                    sequence=len(events) + 1,
                    occurred_at=ended_at
                    or (events[-1].occurred_at if events else started_at),
                    kind=EventKind.SUMMARY,
                    provenance=EventProvenance(source="legacy_desktop_session"),
                    payload=SummaryPayload(
                        summary_text=str(summary["summary_text"]),
                        tasks=list(summary.get("tasks") or []),
                        key_points=list(summary.get("key_points") or []),
                        decisions=list(summary.get("decisions") or []),
                    ),
                )
            )
        return MeetingRecord(
            meeting_id=meeting_id,
            title=payload.get("title"),
            status=status,
            started_at=started_at,
            ended_at=ended_at,
            events=events,
            migration=LegacyMigrationReference(
                source_file="desktop-sessions.json",
                source_key=source_key,
            ),
        )

    @staticmethod
    def _optional_date(value: object) -> datetime | None:
        if not value:
            return None
        return MeetingRepository._date(value)

    @staticmethod
    def _date(value: object, fallback: datetime | None = None) -> datetime:
        if isinstance(value, datetime):
            parsed = value
        elif isinstance(value, str):
            try:
                parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            except ValueError:
                parsed = fallback or datetime.now(UTC)
        else:
            parsed = fallback or datetime.now(UTC)
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)
