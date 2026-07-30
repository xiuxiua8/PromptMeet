import asyncio
import importlib
from datetime import UTC, datetime

from fastapi.testclient import TestClient

from models.meeting_context import EventKind, EvidenceSource
from services.desktop_agent_service import MeetingAnswerResult, MeetingSummaryResult
from services.meeting_ingestion import MeetingIngestionService, ScreenshotAnalysisResult
from services.meeting_repository import MeetingRepository
from services.desktop_storage import HybridSessionStorage

PNG = b"\x89PNG\r\n\x1a\nPromptMeet screenshot"


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
    agent.questions = []
    empty = client.post(
        f"/api/sessions/{meeting_id}/generate-questions",
        json={"generation_id": "generation-empty", "context_revision": 2},
    )
    assert empty.status_code == 200

    record = client.get(f"/api/meetings/{meeting_id}").json()
    suggestion_events = [
        event for event in record["events"] if event["kind"] == "suggestions"
    ]
    assert len(suggestion_events) == 1
    assert suggestion_events[0]["payload"]["questions"] == [
        "谁负责上线？",
        "何时冻结范围？",
        "回滚标准是什么？",
    ]


def test_summary_milestones_store_revision_and_source_coverage_without_double_fire(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    main_service = importlib.import_module("main_service")
    root = tmp_path / "meeting-data"
    configure(main_service, root, monkeypatch)

    class SummaryAgent(FakeMeetingAgent):
        async def summarize_meeting(self, record, source_events):
            revision = 1 + len(
                [event for event in record.events if event.kind == EventKind.SUMMARY]
            )
            return MeetingSummaryResult(
                summary={
                    "summary_text": f"第 {revision} 版摘要",
                    "tasks": [{"task": "完成回滚演练", "status": "pending"}],
                    "key_points": ["冻结范围"],
                    "decisions": ["周五发布"],
                },
                provider="openai",
                model="summary-model",
            )

    monkeypatch.setattr(main_service, "desktop_agent_service", SummaryAgent())
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
    assert len(summaries[1]["payload"]["source_event_ids"]) == 2
    assert summaries[1]["provenance"]["provider"] == "openai"
    assert summaries[1]["provenance"]["model"] == "summary-model"


def test_summary_generation_accepts_screenshot_only_meeting_input(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    main_service = importlib.import_module("main_service")
    root = tmp_path / "meeting-data"
    configure(main_service, root, monkeypatch)

    class SummaryAgent(FakeMeetingAgent):
        async def summarize_meeting(self, record, source_events):
            return MeetingSummaryResult(
                summary={
                    "summary_text": "截图会议摘要",
                    "tasks": [],
                    "key_points": ["截图证据"],
                    "decisions": [],
                },
                provider="openai",
                model="vision-summary-model",
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
