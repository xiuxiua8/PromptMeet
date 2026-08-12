import asyncio
import json
from datetime import UTC, datetime

from models.meeting_context import (
    EventKind,
    EventProvenance,
    MeetingEvent,
    MeetingRecord,
    MeetingStatus,
    SummaryPayload,
    TranscriptPayload,
)
from services.meeting_repository import MeetingRepository
from services.meeting_title_service import MeetingTitleService

START = datetime(2026, 7, 30, 10, 0, tzinfo=UTC)


def append_transcript(
    repository: MeetingRepository,
    meeting_id: str,
    text: str,
) -> None:
    repository.append(
        meeting_id,
        MeetingEvent(
            occurred_at=START,
            kind=EventKind.TRANSCRIPT,
            provenance=EventProvenance(source="native_transcript"),
            payload=TranscriptPayload(
                segment_id=f"segment-{meeting_id}",
                speaker="林晨",
                text=text,
            ),
        ),
    )


def append_summary(repository: MeetingRepository, meeting_id: str) -> None:
    repository.append(
        meeting_id,
        MeetingEvent(
            occurred_at=START,
            kind=EventKind.SUMMARY,
            provenance=EventProvenance(source="summary_service"),
            payload=SummaryPayload(
                summary_text="确认周五发布并准备回滚",
                decisions=["周五发布"],
                tasks=[{"task": "周岚准备回滚方案"}],
            ),
        ),
    )


def test_ai_title_replaces_the_persisted_fallback(tmp_path) -> None:
    repository = MeetingRepository(tmp_path)
    repository.create("meeting-a", START)
    append_transcript(
        repository, "meeting-a", "我们确认周五发布，并由周岚准备回滚方案。"
    )
    append_summary(repository, "meeting-a")
    seen_records: list[MeetingRecord] = []

    async def generate(record: MeetingRecord) -> str:
        seen_records.append(record)
        return "周五发布与回滚准备"

    title = asyncio.run(
        MeetingTitleService(repository, generator=generate).finalize("meeting-a")
    )

    assert title == "周五发布与回滚准备"
    assert repository.get("meeting-a").title == title
    assert [record.meeting_id for record in seen_records] == ["meeting-a"]
    assert {
        event.payload.text
        for event in seen_records[0].events
        if isinstance(event.payload, TranscriptPayload)
    } == {"我们确认周五发布，并由周岚准备回滚方案。"}


def test_ai_failure_keeps_deterministic_fallback_without_changing_completion(
    tmp_path,
) -> None:
    repository = MeetingRepository(tmp_path)
    repository.create("meeting-a", START)
    append_transcript(repository, "meeting-a", "好的。")
    append_transcript(repository, "meeting-a", "讨论移动端登录失败后的恢复流程。")
    repository.finish("meeting-a", START.replace(hour=11), MeetingStatus.COMPLETED)

    async def unavailable(_: MeetingRecord) -> str:
        raise RuntimeError("provider unavailable")

    title = asyncio.run(
        MeetingTitleService(repository, generator=unavailable).finalize("meeting-a")
    )
    restored = repository.get("meeting-a")

    assert title == "讨论移动端登录失败后的恢复流程"
    assert restored.title == title
    assert restored.status == MeetingStatus.COMPLETED
    assert restored.ended_at == START.replace(hour=11)


def test_fallback_and_generation_never_cross_meeting_boundaries(tmp_path) -> None:
    repository = MeetingRepository(tmp_path)
    repository.create("meeting-a", START)
    repository.create("meeting-b", START.replace(hour=12))
    append_transcript(repository, "meeting-a", "讨论移动端登录恢复流程。")
    append_transcript(repository, "meeting-b", "讨论海外账单税率调整。")
    generator_inputs: list[tuple[str, list[str]]] = []

    async def generate(record: MeetingRecord) -> str:
        generator_inputs.append(
            (
                record.meeting_id,
                [
                    event.payload.text
                    for event in record.events
                    if isinstance(event.payload, TranscriptPayload)
                ],
            )
        )
        return "移动端登录恢复流程"

    service = MeetingTitleService(repository, generator=generate)
    assert (
        service.fallback_title(repository.get("meeting-a")) == "讨论移动端登录恢复流程"
    )
    assert service.fallback_title(repository.get("meeting-b")) == "讨论海外账单税率调整"

    asyncio.run(service.finalize("meeting-a"))

    assert generator_inputs == [("meeting-a", ["讨论移动端登录恢复流程。"])]
    assert repository.get("meeting-b").title is None


def test_generic_ai_title_is_rejected_in_favor_of_meeting_content(tmp_path) -> None:
    repository = MeetingRepository(tmp_path)
    repository.create("meeting-a", START)
    append_summary(repository, "meeting-a")

    async def generate(_: MeetingRecord) -> str:
        return "新会议"

    title = asyncio.run(
        MeetingTitleService(repository, generator=generate).finalize("meeting-a")
    )

    assert title == "确认周五发布并准备回滚"
    assert repository.get("meeting-a").title == title


def test_generic_transcript_is_skipped_for_deterministic_fallback(tmp_path) -> None:
    repository = MeetingRepository(tmp_path)
    repository.create("meeting-a", START)
    append_transcript(repository, "meeting-a", "新会议。")
    append_transcript(repository, "meeting-a", "讨论移动端登录恢复流程。")

    title = MeetingTitleService(repository).persist_fallback("meeting-a")

    assert title == "讨论移动端登录恢复流程"
    assert repository.get("meeting-a").title == title


def test_empty_meeting_uses_truthful_stable_timestamp_title(tmp_path) -> None:
    repository = MeetingRepository(tmp_path)
    record = repository.create("empty", START)

    title = MeetingTitleService(repository).persist_fallback("empty")

    assert title == "20260730 10:00 空会议"
    assert MeetingTitleService(repository).fallback_title(record) == title
    assert MeetingRepository(tmp_path).get("empty").title == title


def test_fallback_keeps_leading_number_in_meaningful_topic(tmp_path) -> None:
    repository = MeetingRepository(tmp_path)
    repository.create("meeting-3d", START)
    append_transcript(repository, "meeting-3d", "3D视觉重建方案评审。")

    title = MeetingTitleService(repository).fallback_title(repository.get("meeting-3d"))

    assert title == "3D视觉重建方案评审"


def test_version_two_record_without_title_remains_readable_without_rewrite(
    tmp_path,
) -> None:
    record_directory = tmp_path / "meetings" / "v2"
    record_directory.mkdir(parents=True)
    path = record_directory / "legacy-v2.json"
    raw = {
        "schema_version": 2,
        "meeting_id": "legacy-v2",
        "status": "completed",
        "started_at": START.isoformat(),
        "ended_at": START.replace(hour=11).isoformat(),
        "events": [],
    }
    original = json.dumps(raw, ensure_ascii=False, indent=2)
    path.write_text(original, encoding="utf-8")

    restored = MeetingRepository(tmp_path).get("legacy-v2")

    assert restored.title is None
    assert path.read_text(encoding="utf-8") == original
