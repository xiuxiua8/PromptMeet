import asyncio
import importlib
from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from models.meeting_context import EventKind, EvidenceSource, MeetingStatus
from services.desktop_agent_service import (
    DesktopAgentService,
    MeetingAnswerResult,
    MeetingSummaryResult,
)
from services.meeting_ingestion import MeetingIngestionService, ScreenshotAnalysisResult
from services.meeting_repository import MeetingRepository
from services.desktop_storage import HybridSessionStorage

PNG = b"\x89PNG\r\n\x1a\nPromptMeet screenshot"


def full_summary_progress(source_events) -> dict[str, int]:
    return {
        event.event_id: len(DesktopAgentService.summary_event_text(event))
        for event in source_events
        if event.kind != EventKind.SUMMARY
    }


class FakeMeetingAgent:
    questions = [
        {"question": "谁负责上线？"},
        {"question": "何时冻结范围？"},
        {"question": "回滚标准是什么？"},
    ]

    async def generate_questions(self, context):
        return list(self.questions)

    async def analyze_screenshot(self, record, screenshot_event):
        return ScreenshotAnalysisResult(
            status="completed",
            text="截图显示周岚负责回滚演练",
            vision_used=True,
            provider="fake",
            model="fake-vision",
        )

    async def answer_meeting(self, record, question, emit, **kwargs):
        answer = "周岚负责回滚演练 [M3]。"
        await emit({"data": {"delta": answer}})
        await emit({"data": {"content": answer}})
        return MeetingAnswerResult(
            answer=answer,
            sources=[
                EvidenceSource(source_id="M3", event_id="fake-source", label="截图分析")
            ],
            degraded_vision=False,
            provider="fake",
            model="fake-model",
        )


def configure(main_service, root, monkeypatch) -> None:
    repository = MeetingRepository(root)
    monkeypatch.setattr(main_service, "meeting_repository", repository)
    monkeypatch.setattr(
        main_service,
        "meeting_ingestion",
        MeetingIngestionService(repository),
    )
    monkeypatch.setattr(
        main_service,
        "db_storage",
        HybridSessionStorage.from_environment(root, environment={}),
    )
    monkeypatch.setattr(main_service, "desktop_agent_service", FakeMeetingAgent())


def test_full_multimodal_meeting_survives_restart_and_accepts_follow_up(
    monkeypatch,
    tmp_path,
) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    main_service = importlib.import_module("main_service")
    root = tmp_path / "meeting-data"
    configure(main_service, root, monkeypatch)
    client = TestClient(main_service.app)

    meeting_id = client.post("/api/sessions").json()["session_id"]
    assert (
        client.post(f"/api/sessions/{meeting_id}/start-native-recording").status_code
        == 200
    )
    transcript = {
        "id": "4E2CB506-925E-4A6E-BB68-E5006AB09BDF",
        "text": "发布候选周五交付",
        "speaker": "林晨",
        "source": "microphone",
        "timestamp": "2026-07-25T10:00:00+00:00",
    }
    assert (
        client.post(
            f"/api/sessions/{meeting_id}/native-transcript",
            json=transcript,
        ).status_code
        == 200
    )
    screenshot = client.post(
        f"/api/sessions/{meeting_id}/native-screenshot",
        headers={"Content-Type": "image/png"},
        content=PNG,
    )
    assert screenshot.status_code == 200
    assert screenshot.json()["event"]["kind"] == "screenshot"

    answer = client.post(
        f"/api/meetings/{meeting_id}/questions",
        json={
            "request_id": "request-live",
            "thread_id": "main",
            "question": "谁负责回滚？",
        },
    )
    assert answer.status_code == 200
    assert answer.json()["answer"] == "周岚负责回滚演练 [M3]。"
    assert (
        client.post(f"/api/sessions/{meeting_id}/pause-native-recording").status_code
        == 200
    )
    paused = client.get(f"/api/sessions/{meeting_id}").json()["session"]
    assert paused["is_recording"] is True
    assert paused["is_paused"] is True
    assert (
        client.post(f"/api/sessions/{meeting_id}/resume-native-recording").status_code
        == 200
    )
    resumed = client.get(f"/api/sessions/{meeting_id}").json()["session"]
    assert resumed["is_paused"] is False
    assert (
        client.post(f"/api/sessions/{meeting_id}/stop-native-recording").status_code
        == 200
    )
    assert client.post(f"/api/sessions/{meeting_id}/store-session").status_code == 200
    assert not (root / "desktop-sessions.json").exists()

    configure(main_service, root, monkeypatch)
    history = client.get("/api/meetings").json()
    assert [meeting["meeting_id"] for meeting in history] == [meeting_id]
    assert history[0]["title"] == "发布候选周五交付"
    assert history[0]["status"] == "completed"
    kinds = [event["kind"] for event in history[0]["events"]]
    assert EventKind.TRANSCRIPT in kinds
    assert EventKind.SCREENSHOT in kinds
    assert EventKind.SCREENSHOT_ANALYSIS in kinds
    assert EventKind.USER_QUESTION in kinds
    assert EventKind.ASSISTANT_ANSWER in kinds
    lifecycle_details = [
        event["payload"].get("detail")
        for event in history[0]["events"]
        if event["kind"] == EventKind.LIFECYCLE
    ]
    assert "录音已暂停" in lifecycle_details
    assert "录音已恢复" in lifecycle_details
    legacy_projection = client.get("/db/sessions").json()
    assert legacy_projection[0]["schema_version"] == 2
    assert legacy_projection[0]["transcript_segments"][0]["text"] == "发布候选周五交付"

    follow_up = client.post(
        f"/api/meetings/{meeting_id}/questions",
        json={
            "request_id": "request-history",
            "thread_id": "main",
            "question": "历史会议里谁负责回滚？",
        },
    )
    assert follow_up.status_code == 200
    restored = client.get(f"/api/meetings/{meeting_id}").json()
    assert restored["events"][-1]["kind"] == "assistant_answer"
    assert restored["events"][-1]["payload"]["request_id"] == "request-history"


def test_meeting_completion_does_not_wait_for_ai_title_generation(
    monkeypatch,
    tmp_path,
) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    main_service = importlib.import_module("main_service")
    root = tmp_path / "meeting-data"
    configure(main_service, root, monkeypatch)
    release_title = asyncio.Event()

    class DelayedTitleAgent(FakeMeetingAgent):
        async def generate_meeting_title(self, record):
            await release_title.wait()
            return "移动端登录恢复方案"

    monkeypatch.setattr(main_service, "desktop_agent_service", DelayedTitleAgent())
    monkeypatch.setattr(
        main_service.websocket_manager,
        "broadcast_to_session",
        lambda *args, **kwargs: asyncio.sleep(0),
    )

    async def finish_meeting() -> None:
        created = await main_service.create_session()
        meeting_id = created["session_id"]
        await main_service.start_native_recording(meeting_id)
        await main_service.process_native_transcript(
            meeting_id,
            {
                "id": "6E2CB506-925E-4A6E-BB68-E5006AB09BDF",
                "text": "讨论移动端登录失败后的恢复方案",
                "speaker": "林晨",
                "source": "microphone",
                "timestamp": "2026-07-30T10:00:00+00:00",
            },
        )

        await asyncio.wait_for(
            main_service.stop_native_recording(meeting_id),
            timeout=0.5,
        )

        completed = main_service.meeting_repository.get(meeting_id)
        assert completed.status.value == "completed"
        assert completed.title == "讨论移动端登录失败后的恢复方案"
        title_task = main_service.meeting_title_tasks[meeting_id]
        assert not title_task.done()

        release_title.set()
        await title_task
        assert (
            main_service.meeting_repository.get(meeting_id).title
            == "移动端登录恢复方案"
        )

    asyncio.run(finish_meeting())


def test_successful_live_translation_is_persisted_before_broadcast(
    monkeypatch,
    tmp_path,
) -> None:
    main_service = importlib.import_module("main_service")
    repository = MeetingRepository(tmp_path)
    ingestion = MeetingIngestionService(repository)
    meeting_id = "translation-meeting"
    segment_id = "4E2CB506-925E-4A6E-BB68-E5006AB09BDF"
    ingestion.start(meeting_id, datetime(2026, 7, 25, tzinfo=UTC))
    original = ingestion.transcript(
        meeting_id,
        {
            "id": segment_id,
            "text": "Hello team",
            "speaker": "会议",
            "source": "system",
            "timestamp": "2026-07-25T10:00:00+00:00",
        },
    )
    persisted_at_broadcast = []
    broadcasts = []

    class TranslationAgent:
        async def translate(self, text, target_language):
            assert (text, target_language) == ("Hello team", "zh")
            return "大家好"

    async def collect(session_id, payload):
        event = repository.get(meeting_id).events[1]
        persisted_at_broadcast.append(event.payload.translated_text)
        broadcasts.append((session_id, payload))

    monkeypatch.setattr(main_service, "meeting_repository", repository)
    monkeypatch.setattr(main_service, "meeting_ingestion", ingestion)
    monkeypatch.setattr(main_service, "desktop_agent_service", TranslationAgent())
    monkeypatch.setattr(
        main_service.websocket_manager,
        "broadcast_to_session",
        collect,
    )

    asyncio.run(
        main_service.translate_native_transcript(
            meeting_id,
            segment_id,
            "Hello team",
            "zh",
        )
    )

    restored = MeetingRepository(tmp_path).get(meeting_id)
    assert restored is not None
    transcripts = [
        event for event in restored.events if event.kind == EventKind.TRANSCRIPT
    ]
    assert len(transcripts) == 1
    assert transcripts[0].event_id == original.event_id
    assert transcripts[0].payload.translated_text == "大家好"
    assert persisted_at_broadcast == ["大家好"]
    assert broadcasts[0][0] == meeting_id
    assert broadcasts[0][1]["data"] == {
        "id": segment_id,
        "translated_text": "大家好",
    }


def test_failed_live_translation_retries_once_on_safe_resubmission(
    monkeypatch,
    tmp_path,
) -> None:
    main_service = importlib.import_module("main_service")
    repository = MeetingRepository(tmp_path)
    ingestion = MeetingIngestionService(repository)
    meeting_id = "translation-retry-meeting"
    segment_id = "5E2CB506-925E-4A6E-BB68-E5006AB09BDF"
    ingestion.start(meeting_id, datetime(2026, 7, 25, tzinfo=UTC))
    attempts = 0
    retry_started = asyncio.Event()
    release_retry = asyncio.Event()

    class FlakyTranslationAgent:
        async def translate(self, text, target_language):
            nonlocal attempts
            attempts += 1
            assert (text, target_language) == ("Hello again", "zh")
            if attempts == 1:
                raise RuntimeError("transient translation failure")
            retry_started.set()
            await release_retry.wait()
            return "再次问好"

    async def ignore_broadcast(*args, **kwargs):
        return None

    monkeypatch.setattr(main_service, "DESKTOP_MODE", True)
    monkeypatch.setattr(main_service, "meeting_repository", repository)
    monkeypatch.setattr(main_service, "meeting_ingestion", ingestion)
    monkeypatch.setattr(
        main_service,
        "desktop_agent_service",
        FlakyTranslationAgent(),
    )
    monkeypatch.setattr(
        main_service.websocket_manager,
        "broadcast_to_session",
        ignore_broadcast,
    )
    monkeypatch.setattr(main_service, "persist_session", ignore_broadcast)

    transcript = {
        "id": segment_id,
        "text": "Hello again",
        "speaker": "会议",
        "source": "system",
        "timestamp": "2026-07-25T10:00:00+00:00",
        "translation_target": "zh",
    }

    async def run_scenario() -> None:
        assert await main_service.process_native_transcript(meeting_id, transcript)
        for _ in range(20):
            if attempts == 1:
                break
            await asyncio.sleep(0)
        assert attempts == 1

        assert await main_service.process_native_transcript(meeting_id, transcript)
        for _ in range(20):
            if attempts == 2:
                break
            await asyncio.sleep(0)
        assert attempts == 2
        await retry_started.wait()

        await asyncio.gather(
            main_service.process_native_transcript(meeting_id, transcript),
            main_service.process_native_transcript(meeting_id, transcript),
        )
        await asyncio.sleep(0)
        assert attempts == 2

        release_retry.set()
        for _ in range(20):
            record = repository.get(meeting_id)
            event = next(
                item for item in record.events if item.kind == EventKind.TRANSCRIPT
            )
            if event.payload.translated_text == "再次问好":
                break
            await asyncio.sleep(0)

        assert await main_service.process_native_transcript(meeting_id, transcript)
        await asyncio.sleep(0)
        assert attempts == 2

    asyncio.run(run_scenario())

    record = repository.get(meeting_id)
    transcripts = [
        event for event in record.events if event.kind == EventKind.TRANSCRIPT
    ]
    assert len(transcripts) == 1
    assert transcripts[0].payload.translated_text == "再次问好"


def test_live_translation_does_not_retry_without_bound(
    monkeypatch,
    tmp_path,
) -> None:
    main_service = importlib.import_module("main_service")
    repository = MeetingRepository(tmp_path)
    ingestion = MeetingIngestionService(repository)
    meeting_id = "translation-bounded-retry"
    segment_id = "6E2CB506-925E-4A6E-BB68-E5006AB09BDF"
    ingestion.start(meeting_id, datetime(2026, 7, 25, tzinfo=UTC))
    attempts = 0

    class FailingTranslationAgent:
        async def translate(self, text, target_language):
            nonlocal attempts
            attempts += 1
            raise RuntimeError("translation remains unavailable")

    async def ignore_broadcast(*args, **kwargs):
        return None

    monkeypatch.setattr(main_service, "DESKTOP_MODE", True)
    monkeypatch.setattr(main_service, "meeting_repository", repository)
    monkeypatch.setattr(main_service, "meeting_ingestion", ingestion)
    monkeypatch.setattr(
        main_service,
        "desktop_agent_service",
        FailingTranslationAgent(),
    )
    monkeypatch.setattr(
        main_service.websocket_manager,
        "broadcast_to_session",
        ignore_broadcast,
    )
    monkeypatch.setattr(main_service, "persist_session", ignore_broadcast)

    transcript = {
        "id": segment_id,
        "text": "Still waiting",
        "speaker": "会议",
        "source": "system",
        "timestamp": "2026-07-25T10:00:00+00:00",
        "translation_target": "zh",
    }

    async def submit_and_finish_attempt() -> None:
        assert await main_service.process_native_transcript(meeting_id, transcript)
        for _ in range(20):
            if not main_service.meeting_translation_tasks:
                return
            await asyncio.sleep(0)

    async def run_scenario() -> None:
        await submit_and_finish_attempt()
        await submit_and_finish_attempt()
        await submit_and_finish_attempt()
        await submit_and_finish_attempt()

    asyncio.run(run_scenario())

    assert attempts == 2
    record = repository.get(meeting_id)
    transcripts = [
        event for event in record.events if event.kind == EventKind.TRANSCRIPT
    ]
    assert len(transcripts) == 1
    assert transcripts[0].payload.translated_text is None


def test_rapid_questions_keep_request_scoped_snapshots_and_answers(
    monkeypatch, tmp_path
) -> None:
    main_service = importlib.import_module("main_service")
    repository = MeetingRepository(tmp_path)
    ingestion = MeetingIngestionService(repository)
    ingestion.start("meeting-fast", datetime(2026, 7, 25, tzinfo=UTC))
    monkeypatch.setattr(main_service, "meeting_repository", repository)
    monkeypatch.setattr(main_service, "meeting_ingestion", ingestion)
    releases = {"request-1": asyncio.Event(), "request-2": asyncio.Event()}
    snapshots = {}

    class DelayedAgent:
        async def answer_meeting(self, record, question, emit, **kwargs):
            request_id = "request-1" if question == "问题一" else "request-2"
            snapshots[request_id] = [
                event.payload.request_id
                for event in record.events
                if event.kind == EventKind.USER_QUESTION
            ]
            await releases[request_id].wait()
            answer = f"{question}的回答"
            await emit({"data": {"content": answer}})
            return MeetingAnswerResult(
                answer=answer,
                sources=[],
                degraded_vision=False,
                provider="fake",
                model="fake",
            )

    monkeypatch.setattr(main_service, "desktop_agent_service", DelayedAgent())
    monkeypatch.setattr(
        main_service.websocket_manager,
        "broadcast_to_session",
        lambda *args, **kwargs: asyncio.sleep(0),
    )

    async def run_questions() -> None:
        first = asyncio.create_task(
            main_service.process_meeting_question(
                "meeting-fast", "request-1", "main", "问题一"
            )
        )
        await asyncio.sleep(0)
        second = asyncio.create_task(
            main_service.process_meeting_question(
                "meeting-fast", "request-2", "main", "问题二"
            )
        )
        await asyncio.sleep(0)
        releases["request-2"].set()
        await second
        releases["request-1"].set()
        await first

    asyncio.run(run_questions())

    assert snapshots["request-1"] == ["request-1"]
    assert snapshots["request-2"] == ["request-1", "request-2"]
    answers = [
        event.payload
        for event in repository.get("meeting-fast").events
        if event.kind == EventKind.ASSISTANT_ANSWER
    ]
    assert [(answer.request_id, answer.answer) for answer in answers] == [
        ("request-2", "问题二的回答"),
        ("request-1", "问题一的回答"),
    ]


def test_unsuccessful_suggestion_generation_never_overwrites_last_good_set(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    main_service = importlib.import_module("main_service")
    root = tmp_path / "meeting-data"
    configure(main_service, root, monkeypatch)
    agent = FakeMeetingAgent()
    monkeypatch.setattr(main_service, "desktop_agent_service", agent)
    generated_payloads = []

    async def capture_generated(session_id, payload):
        generated_payloads.append(payload)

    monkeypatch.setattr(main_service, "on_questions_generated", capture_generated)
    client = TestClient(main_service.app)
    meeting_id = client.post("/api/sessions").json()["session_id"]
    client.post(
        f"/api/sessions/{meeting_id}/native-transcript",
        json={
            "id": "4E2CB506-925E-4A6E-BB68-E5006AB09BDF",
            "text": "周岚负责上线，周五冻结范围并完成回滚演练",
            "speaker": "林晨",
            "source": "microphone",
            "timestamp": "2026-07-25T10:00:00+00:00",
        },
    )

    good = client.post(
        f"/api/sessions/{meeting_id}/generate-questions",
        json={"generation_id": "generation-good", "context_revision": 1},
    )
    assert good.status_code == 200
    agent.questions = [
        {"question": "谁负责上线？"},
        {"question": "何时冻结范围？"},
    ]
    partial = client.post(
        f"/api/sessions/{meeting_id}/generate-questions",
        json={"generation_id": "generation-partial", "context_revision": 2},
    )
    assert partial.status_code == 200
    assert partial.json()["accepted"] is True
    agent.questions = [{"question": "谁负责上线？"}]
    single = client.post(
        f"/api/sessions/{meeting_id}/generate-questions",
        json={"generation_id": "generation-single", "context_revision": 3},
    )
    assert single.status_code == 200
    assert single.json()["accepted"] is False
    agent.questions = []
    empty = client.post(
        f"/api/sessions/{meeting_id}/generate-questions",
        json={"generation_id": "generation-empty", "context_revision": 4},
    )
    assert empty.status_code == 200
    assert empty.json()["accepted"] is False
    agent.questions = [
        {"question": "谁负责上线？"},
        {"question": " 谁负责上线？ "},
        {"question": "周五谁值班？"},
    ]
    duplicate = client.post(
        f"/api/sessions/{meeting_id}/generate-questions",
        json={"generation_id": "generation-duplicate", "context_revision": 5},
    )
    assert duplicate.status_code == 200
    assert duplicate.json()["accepted"] is False

    record = client.get(f"/api/meetings/{meeting_id}").json()
    suggestion_events = [
        event for event in record["events"] if event["kind"] == "suggestions"
    ]
    assert len(suggestion_events) == 2
    assert suggestion_events[-1]["payload"]["questions"] == [
        "谁负责上线？",
        "何时冻结范围？",
    ]
    assert generated_payloads[-2] == {
        "questions": [],
        "generation_id": "generation-empty",
        "context_revision": 4,
    }
    assert generated_payloads[-1] == {
        "questions": [],
        "generation_id": "generation-duplicate",
        "context_revision": 5,
    }


def test_summary_milestones_store_revision_and_source_coverage_without_double_fire(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    main_service = importlib.import_module("main_service")
    root = tmp_path / "meeting-data"
    configure(main_service, root, monkeypatch)

    class SummaryAgent(FakeMeetingAgent):
        calls = []

        async def summarize_meeting(self, record, source_events, source_progress=None):
            self.calls.append(list(source_events))
            revision = 1 + len(
                [event for event in record.events if event.kind == EventKind.SUMMARY]
            )
            return MeetingSummaryResult(
                summary={
                    "summary_text": f"第 {revision} 版摘要",
                    "tasks": (
                        [{"task": "完成回滚演练", "status": "pending"}]
                        if revision == 1
                        else []
                    ),
                    "key_points": ["冻结范围"] if revision == 1 else [],
                    "decisions": ["周五发布"] if revision == 1 else [],
                },
                provider="openai",
                model="summary-model",
                source_event_ids=[
                    event.event_id
                    for event in source_events
                    if event.kind != EventKind.SUMMARY
                ],
                source_revision=max(
                    (
                        event.sequence
                        for event in source_events
                        if event.kind != EventKind.SUMMARY
                    ),
                    default=0,
                ),
                source_progress=full_summary_progress(source_events),
            )

    agent = SummaryAgent()
    monkeypatch.setattr(main_service, "desktop_agent_service", agent)
    client = TestClient(main_service.app)
    meeting_id = client.post("/api/sessions").json()["session_id"]

    def transcript(segment_id: str, text: str) -> None:
        response = client.post(
            f"/api/sessions/{meeting_id}/native-transcript",
            json={
                "id": segment_id,
                "text": text,
                "speaker": "林晨",
                "source": "microphone",
                "timestamp": "2026-07-25T10:00:00+00:00",
            },
        )
        assert response.status_code == 200

    transcript("4E2CB506-925E-4A6E-BB68-E5006AB09BDF", "冻结范围")
    first = client.post(
        f"/api/sessions/{meeting_id}/generate-summary",
        json={"trigger": "milestone", "active_minutes": 5, "client_input_revision": 1},
    )
    assert first.status_code == 200
    assert first.json()["status"] == "generated"

    duplicate = client.post(
        f"/api/sessions/{meeting_id}/generate-summary",
        json={"trigger": "milestone", "active_minutes": 10, "client_input_revision": 1},
    )
    assert duplicate.status_code == 200
    assert duplicate.json()["status"] == "no_action"

    transcript("5E2CB506-925E-4A6E-BB68-E5006AB09BDF", "完成回滚演练")
    second = client.post(
        f"/api/sessions/{meeting_id}/generate-summary",
        json={"trigger": "milestone", "active_minutes": 15, "client_input_revision": 2},
    )
    assert second.status_code == 200
    assert second.json()["status"] == "generated"

    record = client.get(f"/api/meetings/{meeting_id}").json()
    summaries = [event for event in record["events"] if event["kind"] == "summary"]
    assert len(summaries) == 2
    assert [event["payload"]["revision"] for event in summaries] == [1, 2]
    assert summaries[0]["payload"]["active_minutes"] == 5
    assert summaries[1]["payload"]["active_minutes"] == 15
    assert (
        summaries[1]["payload"]["source_revision"]
        > summaries[0]["payload"]["source_revision"]
    )
    assert len(summaries[0]["payload"]["source_event_ids"]) == 1
    assert len(summaries[1]["payload"]["source_event_ids"]) == 1
    assert summaries[1]["provenance"]["provider"] == "openai"
    assert summaries[1]["provenance"]["model"] == "summary-model"
    assert summaries[0]["payload"]["summary_text"] == "第 1 版摘要"
    assert summaries[1]["payload"]["summary_text"] == "第 2 版摘要"
    assert summaries[1]["payload"]["tasks"][0]["task"] == "完成回滚演练"
    assert summaries[1]["payload"]["key_points"] == []
    assert summaries[1]["payload"]["decisions"] == []
    assert summaries[1]["payload"]["source_progress"]
    assert [event.kind for event in agent.calls[1]] == [
        EventKind.SUMMARY,
        EventKind.TRANSCRIPT,
    ]
    assert agent.calls[1][1].payload.text == "完成回滚演练"


def test_summary_partial_progress_persists_and_advances_without_no_action(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    main_service = importlib.import_module("main_service")
    configure(main_service, tmp_path / "meeting-data", monkeypatch)

    class ChunkSummaryAgent(FakeMeetingAgent):
        async def summarize_meeting(self, record, source_events, source_progress=None):
            evidence = next(
                event for event in source_events if event.kind == EventKind.TRANSCRIPT
            )
            current = (source_progress or {}).get(evidence.event_id, 0)
            total = len(DesktopAgentService.summary_event_text(evidence))
            advanced = min(total, current + 12)
            return MeetingSummaryResult(
                summary={
                    "summary_text": f"已处理到 {advanced}",
                    "tasks": [],
                    "key_points": [],
                    "decisions": [],
                },
                provider="openai",
                model="summary-model",
                source_event_ids=[evidence.event_id] if advanced == total else [],
                source_revision=evidence.sequence if advanced == total else 0,
                source_progress={evidence.event_id: advanced},
            )

    monkeypatch.setattr(main_service, "desktop_agent_service", ChunkSummaryAgent())
    client = TestClient(main_service.app)
    meeting_id = client.post("/api/sessions").json()["session_id"]
    transcript = client.post(
        f"/api/sessions/{meeting_id}/native-transcript",
        json={
            "id": "9E2CB506-925E-4A6E-BB68-E5006AB09BDF",
            "text": "很长的会议证据" * 20,
            "speaker": "林晨",
            "source": "system",
            "timestamp": "2026-07-25T10:00:00+00:00",
        },
    )
    assert transcript.status_code == 200

    first = client.post(f"/api/sessions/{meeting_id}/generate-summary").json()
    second = client.post(f"/api/sessions/{meeting_id}/generate-summary").json()

    assert [first["status"], second["status"]] == ["generated", "generated"]
    first_progress = next(iter(first["event"]["payload"]["source_progress"].values()))
    second_progress = next(iter(second["event"]["payload"]["source_progress"].values()))
    assert second_progress > first_progress > 0


def test_pre_progress_summary_source_ids_migrate_as_full_coverage(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    main_service = importlib.import_module("main_service")
    repository = MeetingRepository(tmp_path / "meeting-data")
    ingestion = MeetingIngestionService(repository)
    meeting_id = "legacy-progress"
    ingestion.start(meeting_id, datetime(2026, 7, 25, tzinfo=UTC))
    source = ingestion.transcript(
        meeting_id,
        {
            "id": "BE2CB506-925E-4A6E-BB68-E5006AB09BDF",
            "text": "已经总结过的证据",
            "speaker": "林晨",
            "source": "system",
            "timestamp": "2026-07-25T10:00:00+00:00",
        },
    )
    summary = ingestion.summary(
        meeting_id,
        {"summary_text": "旧版摘要"},
        source_event_ids=[source.event_id],
        trigger="milestone",
    )

    progress = main_service.accumulated_summary_progress([summary], [source])

    assert progress[source.event_id] == len(
        DesktopAgentService.summary_event_text(source)
    )


def test_create_session_accepts_canonical_client_meeting_identity(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    main_service = importlib.import_module("main_service")
    configure(main_service, tmp_path / "meeting-data", monkeypatch)
    client = TestClient(main_service.app)
    meeting_id = "CE2CB506-925E-4A6E-BB68-E5006AB09BDF"
    started_at = "2026-07-25T10:00:00+00:00"

    created = client.post(
        "/api/sessions",
        json={"session_id": meeting_id, "started_at": started_at},
    )
    main_service.session_manager.remove_session(meeting_id)
    rebound = client.post(
        "/api/sessions",
        json={"session_id": meeting_id, "started_at": started_at},
    )

    assert created.status_code == rebound.status_code == 200
    assert created.json()["session_id"] == meeting_id
    assert rebound.json()["session_id"] == meeting_id
    assert client.get(f"/api/sessions/{meeting_id}").status_code == 200


def test_completed_session_rebind_and_finalization_are_idempotent(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    main_service = importlib.import_module("main_service")
    configure(main_service, tmp_path / "meeting-data", monkeypatch)
    client = TestClient(main_service.app)
    meeting_id = "DE2CB506-925E-4A6E-BB68-E5006AB09BDF"
    started_at = "2026-07-25T10:00:00+00:00"
    assert (
        client.post(
            "/api/sessions",
            json={"session_id": meeting_id, "started_at": started_at},
        ).status_code
        == 200
    )
    assert (
        client.post(f"/api/sessions/{meeting_id}/start-native-recording").status_code
        == 200
    )
    assert (
        client.post(f"/api/sessions/{meeting_id}/stop-native-recording").status_code
        == 200
    )
    completed = client.get(f"/api/meetings/{meeting_id}").json()
    main_service.session_manager.remove_session(meeting_id)

    rebound = client.post(
        "/api/sessions",
        json={"session_id": meeting_id, "started_at": started_at},
    )
    restarted = client.post(f"/api/sessions/{meeting_id}/start-native-recording")
    stored = client.post(f"/api/sessions/{meeting_id}/store-session")
    record = client.get(f"/api/meetings/{meeting_id}").json()
    rebound_session = client.get(f"/api/sessions/{meeting_id}").json()["session"]

    assert rebound.status_code == restarted.status_code == stored.status_code == 200
    assert record["status"] == MeetingStatus.COMPLETED
    assert record["events"] == completed["events"]
    assert rebound_session["is_recording"] is False


def test_incomplete_session_cannot_be_rebound_as_completed_finalization(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    main_service = importlib.import_module("main_service")
    configure(main_service, tmp_path / "meeting-data", monkeypatch)
    client = TestClient(main_service.app)
    meeting_id = "EE2CB506-925E-4A6E-BB68-E5006AB09BDF"
    started_at = "2026-07-25T10:00:00+00:00"
    assert (
        client.post(
            "/api/sessions",
            json={"session_id": meeting_id, "started_at": started_at},
        ).status_code
        == 200
    )
    assert client.post(f"/api/sessions/{meeting_id}/mark-incomplete").status_code == 200
    main_service.session_manager.remove_session(meeting_id)

    rebound = client.post(
        "/api/sessions",
        json={"session_id": meeting_id, "started_at": started_at},
    )
    record = client.get(f"/api/meetings/{meeting_id}").json()

    assert rebound.status_code == 409
    assert record["status"] == MeetingStatus.INCOMPLETE
    assert client.get(f"/api/sessions/{meeting_id}").status_code == 404


def test_invalid_summary_tasks_do_not_advance_persisted_coverage(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    main_service = importlib.import_module("main_service")
    configure(main_service, tmp_path / "meeting-data", monkeypatch)

    class ValidatingSummaryAgent(FakeMeetingAgent):
        call_count = 0

        async def summarize_meeting(self, record, source_events, source_progress=None):
            self.call_count += 1
            evidence = [
                event for event in source_events if event.kind != EventKind.SUMMARY
            ]
            return MeetingSummaryResult(
                summary={
                    "summary_text": "摘要",
                    "tasks": (
                        [{"describe": "follow up"}]
                        if self.call_count == 1
                        else [{"task": "follow up"}]
                    ),
                    "key_points": [],
                    "decisions": [],
                },
                provider="openai",
                model="summary-model",
                source_event_ids=[event.event_id for event in evidence],
                source_revision=max((event.sequence for event in evidence), default=0),
                source_progress=full_summary_progress(source_events),
            )

    agent = ValidatingSummaryAgent()
    monkeypatch.setattr(main_service, "desktop_agent_service", agent)
    client = TestClient(main_service.app)
    meeting_id = client.post("/api/sessions").json()["session_id"]
    client.post(
        f"/api/sessions/{meeting_id}/native-transcript",
        json={
            "id": "7E2CB506-925E-4A6E-BB68-E5006AB09BDF",
            "text": "需要跟进",
            "speaker": "林晨",
            "source": "microphone",
            "timestamp": "2026-07-25T10:00:00+00:00",
        },
    )

    invalid = client.post(f"/api/sessions/{meeting_id}/generate-summary")
    after_invalid = client.get(f"/api/meetings/{meeting_id}").json()
    valid = client.post(f"/api/sessions/{meeting_id}/generate-summary")

    assert invalid.json()["status"] == "failed"
    assert not [
        event for event in after_invalid["events"] if event["kind"] == "summary"
    ]
    assert valid.json()["status"] == "generated"
    assert valid.json()["event"]["payload"]["source_event_ids"]


def test_rehydrate_restores_the_same_active_durable_session(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    main_service = importlib.import_module("main_service")
    configure(main_service, tmp_path / "meeting-data", monkeypatch)
    client = TestClient(main_service.app)
    meeting_id = client.post("/api/sessions").json()["session_id"]
    client.post(
        f"/api/sessions/{meeting_id}/native-transcript",
        json={
            "id": "8E2CB506-925E-4A6E-BB68-E5006AB09BDF",
            "text": "恢复同一会议",
            "speaker": "林晨",
            "source": "system",
            "timestamp": "2026-07-25T10:00:00+00:00",
        },
    )
    main_service.session_manager.remove_session(meeting_id)

    response = client.post(
        f"/api/sessions/{meeting_id}/rehydrate", json={"is_paused": True}
    )
    restored = client.get(f"/api/sessions/{meeting_id}").json()["session"]

    assert response.status_code == 200
    assert response.json()["session_id"] == meeting_id
    assert restored["session_id"] == meeting_id
    assert restored["is_recording"] is True
    assert restored["is_paused"] is True
    assert [segment["text"] for segment in restored["transcript_segments"]] == [
        "恢复同一会议"
    ]


def test_rehydrate_rejects_missing_and_completed_records(monkeypatch, tmp_path) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    main_service = importlib.import_module("main_service")
    configure(main_service, tmp_path / "meeting-data", monkeypatch)
    client = TestClient(main_service.app)
    missing = client.post("/api/sessions/missing/rehydrate", json={"is_paused": False})
    meeting_id = client.post("/api/sessions").json()["session_id"]
    main_service.meeting_repository.finish(
        meeting_id, datetime.now(UTC), MeetingStatus.COMPLETED
    )
    main_service.session_manager.remove_session(meeting_id)

    completed = client.post(
        f"/api/sessions/{meeting_id}/rehydrate", json={"is_paused": False}
    )

    assert missing.status_code == 404
    assert completed.status_code == 409


def test_websocket_rejects_session_lost_after_rehydrate(monkeypatch, tmp_path) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    main_service = importlib.import_module("main_service")
    configure(main_service, tmp_path / "meeting-data", monkeypatch)
    client = TestClient(main_service.app)
    meeting_id = client.post("/api/sessions").json()["session_id"]
    main_service.session_manager.remove_session(meeting_id)
    restored = client.post(
        f"/api/sessions/{meeting_id}/rehydrate", json={"is_paused": False}
    )
    assert restored.status_code == 200
    main_service.session_manager.remove_session(meeting_id)

    with pytest.raises(WebSocketDisconnect) as captured:
        with client.websocket_connect(f"/ws/{meeting_id}") as websocket:
            websocket.receive_json()

    assert captured.value.code == 4404


def test_native_transcript_replay_is_idempotent_by_stable_segment_id(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    main_service = importlib.import_module("main_service")
    configure(main_service, tmp_path / "meeting-data", monkeypatch)
    client = TestClient(main_service.app)
    meeting_id = client.post("/api/sessions").json()["session_id"]
    payload = {
        "id": "AE2CB506-925E-4A6E-BB68-E5006AB09BDF",
        "text": "断线期间的系统音频",
        "speaker": "会议",
        "source": "system",
        "timestamp": "2026-07-25T10:00:00+00:00",
    }

    first = client.post(f"/api/sessions/{meeting_id}/native-transcript", json=payload)
    replay = client.post(f"/api/sessions/{meeting_id}/native-transcript", json=payload)
    record = client.get(f"/api/meetings/{meeting_id}").json()
    session = client.get(f"/api/sessions/{meeting_id}").json()["session"]
    transcripts = [event for event in record["events"] if event["kind"] == "transcript"]

    assert first.status_code == replay.status_code == 200
    assert len(transcripts) == 1
    assert len(session["transcript_segments"]) == 1
    assert transcripts[0]["payload"]["segment_id"] == payload["id"]
    assert transcripts[0]["payload"]["source"] == "system"


def test_concurrent_summary_requests_append_one_revision_for_the_same_source(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    main_service = importlib.import_module("main_service")
    root = tmp_path / "meeting-data"
    configure(main_service, root, monkeypatch)
    client = TestClient(main_service.app)
    meeting_id = client.post("/api/sessions").json()["session_id"]
    transcript = client.post(
        f"/api/sessions/{meeting_id}/native-transcript",
        json={
            "id": "6E2CB506-925E-4A6E-BB68-E5006AB09BDF",
            "text": "冻结范围",
            "speaker": "林晨",
            "source": "microphone",
            "timestamp": "2026-07-25T10:00:00+00:00",
        },
    )
    assert transcript.status_code == 200

    async def exercise() -> tuple[list[dict], int]:
        started = asyncio.Event()
        release = asyncio.Event()

        class BlockingSummaryAgent(FakeMeetingAgent):
            call_count = 0

            async def summarize_meeting(
                self, record, source_events, source_progress=None
            ):
                self.call_count += 1
                started.set()
                await release.wait()
                return MeetingSummaryResult(
                    summary={
                        "summary_text": "并发摘要",
                        "tasks": [],
                        "key_points": ["冻结范围"],
                        "decisions": [],
                    },
                    provider="openai",
                    model="summary-model",
                    source_event_ids=[
                        event.event_id
                        for event in source_events
                        if event.kind != EventKind.SUMMARY
                    ],
                    source_revision=max(
                        (
                            event.sequence
                            for event in source_events
                            if event.kind != EventKind.SUMMARY
                        ),
                        default=0,
                    ),
                    source_progress=full_summary_progress(source_events),
                )

        agent = BlockingSummaryAgent()
        monkeypatch.setattr(main_service, "desktop_agent_service", agent)
        first = asyncio.create_task(
            main_service.generate_summary(
                meeting_id,
                main_service.SummaryGenerationRequest(trigger="manual"),
            )
        )
        await started.wait()
        second = asyncio.create_task(
            main_service.generate_summary(
                meeting_id,
                main_service.SummaryGenerationRequest(
                    trigger="milestone", active_minutes=5
                ),
            )
        )
        await asyncio.sleep(0)
        release.set()
        return list(await asyncio.gather(first, second)), agent.call_count

    responses, call_count = asyncio.run(exercise())

    assert [response["status"] for response in responses] == [
        "generated",
        "no_action",
    ]
    assert call_count == 1
    record = client.get(f"/api/meetings/{meeting_id}").json()
    summaries = [event for event in record["events"] if event["kind"] == "summary"]
    assert [event["payload"]["revision"] for event in summaries] == [1]


def test_summary_generation_accepts_screenshot_only_meeting_input(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    main_service = importlib.import_module("main_service")
    root = tmp_path / "meeting-data"
    configure(main_service, root, monkeypatch)

    class SummaryAgent(FakeMeetingAgent):
        async def summarize_meeting(self, record, source_events, source_progress=None):
            return MeetingSummaryResult(
                summary={
                    "summary_text": "截图会议摘要",
                    "tasks": [],
                    "key_points": ["截图证据"],
                    "decisions": [],
                },
                provider="openai",
                model="vision-summary-model",
                source_event_ids=[
                    event.event_id
                    for event in source_events
                    if event.kind != EventKind.SUMMARY
                ],
                source_revision=max(
                    (
                        event.sequence
                        for event in source_events
                        if event.kind != EventKind.SUMMARY
                    ),
                    default=0,
                ),
                source_progress=full_summary_progress(source_events),
            )

    monkeypatch.setattr(main_service, "desktop_agent_service", SummaryAgent())
    client = TestClient(main_service.app)
    meeting_id = client.post("/api/sessions").json()["session_id"]
    screenshot = client.post(
        f"/api/sessions/{meeting_id}/native-screenshot",
        headers={"Content-Type": "image/png"},
        content=PNG,
    )
    assert screenshot.status_code == 200

    response = client.post(
        f"/api/sessions/{meeting_id}/generate-summary",
        json={"trigger": "milestone", "active_minutes": 5, "client_input_revision": 1},
    )

    assert response.status_code == 200
    assert response.json()["status"] == "generated"
    assert response.json()["event"]["payload"]["source_event_ids"]
