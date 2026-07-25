import asyncio
import importlib

from models.data_models import SessionState, TranscriptSegment


def test_desktop_question_route_uses_in_process_agent(monkeypatch, tmp_path) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    monkeypatch.setenv("PROMPTMEET_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("PROMPTMEET_WORK_DIR", str(tmp_path / "work"))
    main_service = importlib.import_module("main_service")
    session = SessionState(
        session_id="question-session",
        start_time=main_service.datetime.now(),
        transcript_segments=[
            TranscriptSegment(
                id="line-1",
                text="下周完成上线",
                speaker="我",
                timestamp=main_service.datetime.now(),
            )
        ],
    )
    main_service.session_manager.add_session(session)

    class FakeAgentService:
        async def generate_questions(self, transcript):
            return [{"question": "谁负责上线？"}]

    generated = []

    async def collect(session_id, payload):
        generated.append((session_id, payload))

    async def fail_if_started(session_id):
        raise AssertionError("desktop mode must not start the legacy question process")

    monkeypatch.setattr(main_service, "desktop_agent_service", FakeAgentService())
    monkeypatch.setattr(main_service, "on_questions_generated", collect)
    monkeypatch.setattr(main_service.process_manager, "start_question_process", fail_if_started)

    response = asyncio.run(main_service.generate_questions("question-session"))

    assert response["success"] is True
    assert generated == [
        ("question-session", {"questions": [{"question": "谁负责上线？"}]})
    ]


def test_generated_questions_broadcast_a_live_replacement_batch(monkeypatch) -> None:
    main_service = importlib.import_module("main_service")
    events = []

    async def collect(session_id, payload):
        events.append((session_id, payload))

    monkeypatch.setattr(main_service.websocket_manager, "broadcast_to_session", collect)

    asyncio.run(
        main_service.on_questions_generated(
            "question-session",
            {
                "questions": [
                    {"question": "谁负责上线？"},
                    {"question": "何时上线？"},
                ]
            },
        )
    )

    assert events[0] == (
        "question-session",
        {
            "type": "questions",
            "data": {
                "questions": [
                    {"question": "谁负责上线？"},
                    {"question": "何时上线？"},
                ]
            },
            "timestamp": events[0][1]["timestamp"],
            "session_id": "question-session",
        },
    )
