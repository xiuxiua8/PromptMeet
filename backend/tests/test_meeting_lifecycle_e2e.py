import asyncio
import importlib
from datetime import UTC, datetime

from fastapi.testclient import TestClient

from models.meeting_context import EventKind, EvidenceSource
from services.desktop_agent_service import MeetingAnswerResult
from services.meeting_ingestion import MeetingIngestionService, ScreenshotAnalysisResult
from services.meeting_repository import MeetingRepository
from services.desktop_storage import HybridSessionStorage

PNG = b"\x89PNG\r\n\x1a\nPromptMeet screenshot"


class FakeMeetingAgent:
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
        client.post(f"/api/sessions/{meeting_id}/stop-native-recording").status_code
        == 200
    )
    assert client.post(f"/api/sessions/{meeting_id}/store-session").status_code == 200
    assert not (root / "desktop-sessions.json").exists()

    configure(main_service, root, monkeypatch)
    history = client.get("/api/meetings").json()
    assert [meeting["meeting_id"] for meeting in history] == [meeting_id]
    assert history[0]["status"] == "completed"
    kinds = [event["kind"] for event in history[0]["events"]]
    assert EventKind.TRANSCRIPT in kinds
    assert EventKind.SCREENSHOT in kinds
    assert EventKind.SCREENSHOT_ANALYSIS in kinds
    assert EventKind.USER_QUESTION in kinds
    assert EventKind.ASSISTANT_ANSWER in kinds
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
