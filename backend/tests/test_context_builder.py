from datetime import UTC, datetime, timedelta

from models.meeting_context import (
    AnswerPayload,
    EventKind,
    EventProvenance,
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
from services.context_builder import ContextBudget, MeetingContextBuilder
from services.model_provider import ProviderCapabilities
from services.prompt_builder import MeetingPromptBuilder


START = datetime(2026, 7, 25, 9, 0, tzinfo=UTC)


def event(sequence: int, kind: EventKind, payload) -> MeetingEvent:
    return MeetingEvent(
        event_id=f"event-{sequence}",
        meeting_id="meeting-a",
        sequence=sequence,
        occurred_at=START + timedelta(minutes=sequence),
        kind=kind,
        provenance=EventProvenance(source="test"),
        payload=payload,
    )


def test_selector_obeys_budget_keeps_relevant_visual_evidence_and_stable_order() -> (
    None
):
    events = [
        event(
            index,
            EventKind.TRANSCRIPT,
            TranscriptPayload(
                segment_id=f"segment-{index}",
                speaker="成员",
                text=("一般讨论 " * 14) + str(index),
            ),
        )
        for index in range(1, 11)
    ]
    events.extend(
        [
            event(
                11,
                EventKind.SCREENSHOT,
                ScreenshotPayload(
                    asset_id="asset-1",
                    relative_path="assets/meeting-a/board.png",
                    mime_type="image/png",
                    sha256="abc",
                ),
            ),
            event(
                12,
                EventKind.SCREENSHOT_ANALYSIS,
                ScreenshotAnalysisPayload(
                    asset_id="asset-1",
                    status="completed",
                    text="截图显示回滚负责人是周岚",
                    vision_used=True,
                ),
            ),
        ]
    )
    record = MeetingRecord(meeting_id="meeting-a", started_at=START, events=events)

    selection = MeetingContextBuilder(token_estimator=len).select(
        record,
        "截图中的回滚负责人是谁？",
        ContextBudget(total_tokens=260, answer_reserve=80, summary_reserve=50),
    )

    assert selection.estimated_tokens <= 180
    assert [selected.sequence for selected in selection.events] == sorted(
        selected.sequence for selected in selection.events
    )
    assert EventKind.SCREENSHOT in [selected.kind for selected in selection.events]
    assert EventKind.SCREENSHOT_ANALYSIS in [
        selected.kind for selected in selection.events
    ]
    assert selection.omitted_count > 0
    assert selection.derived_summary
    assert [source.source_id for source in selection.sources] == [
        f"M{selected.sequence}" for selected in selection.events
    ]


def test_relevant_screenshot_analysis_keeps_its_raw_image_ahead_of_unrelated_evidence() -> (
    None
):
    record = MeetingRecord(
        meeting_id="meeting-a",
        started_at=START,
        events=[
            event(
                1,
                EventKind.SCREENSHOT,
                ScreenshotPayload(
                    asset_id="asset-1",
                    relative_path="assets/meeting-a/board.png",
                    mime_type="image/png",
                    sha256="abc",
                ),
            ),
            event(
                2,
                EventKind.SCREENSHOT_ANALYSIS,
                ScreenshotAnalysisPayload(
                    asset_id="asset-1",
                    status="completed",
                    text="截图显示周岚负责回滚",
                    vision_used=True,
                ),
            ),
            event(
                3,
                EventKind.SUMMARY,
                SummaryPayload(summary_text="与当前问题无关的会议摘要"),
            ),
        ],
    )

    selection = MeetingContextBuilder(token_estimator=lambda _: 30).select(
        record,
        "周岚负责什么？",
        ContextBudget(total_tokens=80, answer_reserve=20, summary_reserve=0),
    )

    assert [selected.kind for selected in selection.events] == [
        EventKind.SCREENSHOT,
        EventKind.SCREENSHOT_ANALYSIS,
    ]


def test_selector_only_uses_prior_turns_from_requested_thread() -> None:
    record = MeetingRecord(
        meeting_id="meeting-a",
        started_at=START,
        events=[
            event(
                1,
                EventKind.USER_QUESTION,
                QuestionPayload(
                    request_id="q1", thread_id="main", question="主要风险？"
                ),
            ),
            event(
                2,
                EventKind.ASSISTANT_ANSWER,
                AnswerPayload(request_id="q1", thread_id="main", answer="范围漂移"),
            ),
            event(
                3,
                EventKind.USER_QUESTION,
                QuestionPayload(
                    request_id="q2", thread_id="private", question="薪资？"
                ),
            ),
            event(
                4,
                EventKind.ASSISTANT_ANSWER,
                AnswerPayload(request_id="q2", thread_id="private", answer="不相关"),
            ),
        ],
    )

    selection = MeetingContextBuilder().select(
        record,
        "继续说明",
        ContextBudget(total_tokens=500, answer_reserve=100),
        thread_id="main",
    )

    assert [selected.sequence for selected in selection.events] == [1, 2]


def test_selector_omits_lifecycle_noise_and_uses_compact_source_labels() -> None:
    record = MeetingRecord(
        meeting_id="meeting-a",
        started_at=START,
        events=[
            event(
                1,
                EventKind.LIFECYCLE,
                LifecyclePayload(status=MeetingStatus.ACTIVE, detail="会议已创建"),
            ),
            event(
                2,
                EventKind.TRANSCRIPT,
                TranscriptPayload(
                    segment_id="segment-2", speaker="成员", text="周岚负责回滚"
                ),
            ),
        ],
    )

    selection = MeetingContextBuilder().select(
        record,
        "谁负责回滚？",
        ContextBudget(total_tokens=500, answer_reserve=100),
    )

    assert [selected.kind for selected in selection.events] == [EventKind.TRANSCRIPT]
    assert selection.sources[0].label == "会议转写 · 07-25 09:02 UTC"


def test_selector_keeps_lifecycle_events_for_status_questions() -> None:
    record = MeetingRecord(
        meeting_id="meeting-a",
        started_at=START,
        events=[
            event(
                1,
                EventKind.LIFECYCLE,
                LifecyclePayload(status=MeetingStatus.COMPLETED, detail="会议已结束"),
            )
        ],
    )

    selection = MeetingContextBuilder().select(
        record,
        "这场会议是否已经结束？",
        ContextBudget(total_tokens=500, answer_reserve=100),
    )

    assert [selected.kind for selected in selection.events] == [EventKind.LIFECYCLE]


def test_prompt_has_system_developer_user_boundaries_and_exact_question() -> None:
    record = MeetingRecord(
        meeting_id="meeting-a",
        started_at=START,
        events=[
            event(
                1,
                EventKind.SUMMARY,
                SummaryPayload(summary_text="范围已经冻结"),
            )
        ],
    )
    selection = MeetingContextBuilder().select(
        record,
        "  原样保留这个问题？  ",
        ContextBudget(total_tokens=500, answer_reserve=100),
    )

    request = MeetingPromptBuilder().build(
        selection,
        "  原样保留这个问题？  ",
        ProviderCapabilities(
            provider="deepseek", model="deepseek-chat", supports_vision=False
        ),
    )

    assert [message.role for message in request.messages] == [
        "system",
        "developer",
        "user",
    ]
    assert request.messages[-1].content == "  原样保留这个问题？  "
    assert "[M1]" in request.messages[1].content


def test_text_only_provider_discloses_pixels_were_not_seen_but_vision_gets_asset_part() -> (
    None
):
    record = MeetingRecord(
        meeting_id="meeting-a",
        started_at=START,
        events=[
            event(
                1,
                EventKind.SCREENSHOT,
                ScreenshotPayload(
                    asset_id="asset-1",
                    relative_path="assets/meeting-a/screen.png",
                    mime_type="image/png",
                    sha256="abc",
                ),
            )
        ],
    )
    selection = MeetingContextBuilder().select(
        record,
        "图上是什么？",
        ContextBudget(total_tokens=500, answer_reserve=100),
    )

    text_request = MeetingPromptBuilder().build(
        selection,
        "图上是什么？",
        ProviderCapabilities(
            provider="deepseek", model="deepseek-chat", supports_vision=False
        ),
    )
    vision_request = MeetingPromptBuilder().build(
        selection,
        "图上是什么？",
        ProviderCapabilities(provider="openai", model="gpt-4o", supports_vision=True),
    )

    assert text_request.degraded_vision is True
    assert "提供方不支持图像输入" in text_request.messages[1].content
    assert vision_request.degraded_vision is False
    developer_parts = vision_request.messages[1].content
    assert any(part.type == "image_asset" for part in developer_parts)
