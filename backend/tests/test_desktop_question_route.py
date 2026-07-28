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
    monkeypatch.setattr(
        main_service.process_manager, "start_question_process", fail_if_started
    )

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


def test_new_generation_cancels_stale_model_work_and_broadcasts_only_latest(
    monkeypatch,
) -> None:
    main_service = importlib.import_module("main_service")
    session = SessionState(
        session_id="fresh-session",
        start_time=main_service.datetime.now(),
        transcript_segments=[
            TranscriptSegment(
                id="line-1",
                text="确认新的发布风险",
                speaker="会议",
                timestamp=main_service.datetime.now(),
            )
        ],
    )
    main_service.session_manager.add_session(session)
    main_service.question_generation_tasks.clear()
    main_service.latest_question_generations.clear()
    broadcasts = []

    class SlowThenFreshAgent:
        def __init__(self):
            self.calls = 0
            self.first_started = asyncio.Event()
            self.first_cancelled = False

        async def generate_questions(self, transcript):
            self.calls += 1
            if self.calls == 1:
                self.first_started.set()
                try:
                    await asyncio.Event().wait()
                except asyncio.CancelledError:
                    self.first_cancelled = True
                    raise
            return [{"question": "最新问题"}]

    agent = SlowThenFreshAgent()

    async def collect(session_id, payload):
        broadcasts.append((session_id, payload))

    monkeypatch.setattr(main_service, "desktop_agent_service", agent)
    monkeypatch.setattr(main_service, "on_questions_generated", collect)

    async def run():
        first = asyncio.create_task(
            main_service.generate_questions(
                "fresh-session",
                main_service.QuestionGenerationRequest(
                    generation_id="11111111-1111-1111-1111-111111111111",
                    context_revision=1,
                ),
            )
        )
        await agent.first_started.wait()
        second = await main_service.generate_questions(
            "fresh-session",
            main_service.QuestionGenerationRequest(
                generation_id="22222222-2222-2222-2222-222222222222",
                context_revision=2,
            ),
        )
        first_result = await first
        return first_result, second

    first_result, second_result = asyncio.run(run())

    assert first_result["superseded"] is True
    assert second_result["success"] is True
    assert agent.first_cancelled is True
    assert broadcasts == [
        (
            "fresh-session",
            {
                "questions": [{"question": "最新问题"}],
                "generation_id": "22222222-2222-2222-2222-222222222222",
                "context_revision": 2,
            },
        )
    ]
