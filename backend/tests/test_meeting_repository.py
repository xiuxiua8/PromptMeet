import json
from datetime import UTC, datetime

from models.meeting_context import (
    EventKind,
    EventProvenance,
    MeetingEvent,
    MeetingStatus,
    SummaryPayload,
    TranscriptPayload,
)
from services.meeting_repository import MeetingRepository


START = datetime(2026, 7, 25, 10, 0, tzinfo=UTC)


def transcript_event(text: str, at: datetime = START) -> MeetingEvent:
    return MeetingEvent(
        occurred_at=at,
        kind=EventKind.TRANSCRIPT,
        provenance=EventProvenance(source="native_transcript"),
        payload=TranscriptPayload(
            segment_id=f"segment-{text}", text=text, speaker="林晨"
        ),
    )


def test_append_assigns_stable_sequence_and_never_crosses_meetings(tmp_path) -> None:
    repository = MeetingRepository(tmp_path)
    repository.create("meeting-a", START)
    repository.create("meeting-b", START)

    first = repository.append("meeting-a", transcript_event("第一条"))
    second = repository.append("meeting-a", transcript_event("第二条"))

    assert [event.sequence for event in first.events] == [1]
    assert [event.sequence for event in second.events] == [1, 2]
    assert [event.payload.text for event in repository.get("meeting-a").events] == [
        "第一条",
        "第二条",
    ]
    assert repository.get("meeting-b").events == []


def test_records_survive_repository_relaunch_and_finish_atomically(tmp_path) -> None:
    repository = MeetingRepository(tmp_path)
    repository.create("meeting-a", START)
    repository.append("meeting-a", transcript_event("保留内容"))
    repository.finish("meeting-a", START.replace(hour=11), MeetingStatus.COMPLETED)

    restored = MeetingRepository(tmp_path).get("meeting-a")

    assert restored is not None
    assert restored.schema_version == 2
    assert restored.status == MeetingStatus.COMPLETED
    assert restored.ended_at == START.replace(hour=11)
    assert restored.events[0].payload.text == "保留内容"
    assert not list((tmp_path / "meetings" / "v2").glob("*.tmp"))


def test_legacy_desktop_sessions_are_migrated_without_removing_source(tmp_path) -> None:
    legacy_path = tmp_path / "desktop-sessions.json"
    legacy_path.write_text(
        json.dumps(
            {
                "legacy-session": {
                    "session_id": "legacy-session",
                    "start_time": "2026-07-25T10:00:00+00:00",
                    "transcript_segments": [
                        {
                            "id": "segment-1",
                            "speaker": "周岚",
                            "text": "周五上线",
                            "timestamp": "2026-07-25T10:01:00+00:00",
                        }
                    ],
                    "current_summary": {
                        "summary_text": "确认周五上线",
                        "tasks": [{"task": "准备回滚"}],
                        "key_points": ["范围冻结"],
                        "decisions": ["周五上线"],
                    },
                    "unrecognized_user_field": {"must": "remain in source"},
                }
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    records = MeetingRepository(tmp_path).list()

    assert legacy_path.exists()
    assert json.loads(legacy_path.read_text(encoding="utf-8"))["legacy-session"][
        "unrecognized_user_field"
    ] == {"must": "remain in source"}
    assert len(records) == 1
    assert records[0].schema_version == 2
    assert records[0].migration is not None
    assert records[0].migration.source_key == "legacy-session"
    assert [event.kind for event in records[0].events] == [
        EventKind.TRANSCRIPT,
        EventKind.SUMMARY,
    ]
    assert isinstance(records[0].events[1].payload, SummaryPayload)


def test_corrupt_versioned_record_is_preserved_and_visible_as_recovery_item(
    tmp_path,
) -> None:
    record_directory = tmp_path / "meetings" / "v2"
    record_directory.mkdir(parents=True)
    corrupt_path = record_directory / "damaged-meeting.json"
    corrupt_path.write_text("{not valid json", encoding="utf-8")

    records = MeetingRepository(tmp_path).list()

    assert corrupt_path.read_text(encoding="utf-8") == "{not valid json"
    assert records[0].meeting_id == "damaged-meeting"
    assert records[0].status == MeetingStatus.RECOVERY_REQUIRED
    assert records[0].events[0].kind == EventKind.LIFECYCLE
    assert "无法读取" in records[0].events[0].payload.detail
