import asyncio
import importlib

from models.data_models import SessionState


def test_desktop_ai_response_echoes_request_id(monkeypatch, tmp_path) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    monkeypatch.setenv("PROMPTMEET_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("PROMPTMEET_WORK_DIR", str(tmp_path / "work"))
    main_service = importlib.import_module("main_service")
    main_service.session_manager.add_session(
        SessionState(session_id="ai-session", start_time=main_service.datetime.now())
    )

    class FakeAgentService:
        async def answer(self, prompt, transcript, emit):
            await emit({"data": {"delta": "测试"}})
            await emit({"data": {"content": "测试成功"}})

    events = []

    async def collect(session_id, payload):
        events.append((session_id, payload))

    monkeypatch.setattr(main_service, "desktop_agent_service", FakeAgentService())
    monkeypatch.setattr(main_service.websocket_manager, "broadcast_to_session", collect)

    asyncio.run(
        main_service.handle_websocket_message(
            "ai-session",
            {
                "type": "agent_message",
                "data": {"request_id": "request-1", "content": "测试"},
            },
        )
    )

    assert events == [
        (
            "ai-session",
            {"type": "answer", "data": {"request_id": "request-1", "delta": "测试"}},
        ),
        (
            "ai-session",
            {
                "type": "answer",
                "data": {"request_id": "request-1", "content": "测试成功"},
            },
        ),
    ]
