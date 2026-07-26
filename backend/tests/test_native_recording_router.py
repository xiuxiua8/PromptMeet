from fastapi import FastAPI
from fastapi.testclient import TestClient

from api.native_recording import build_native_recording_router


def test_native_recording_routes_do_not_reuse_web_audio_capture() -> None:
    calls: list[str] = []

    async def start(session_id: str) -> None:
        calls.append(f"start:{session_id}")

    async def stop(session_id: str) -> None:
        calls.append(f"stop:{session_id}")

    app = FastAPI()
    app.include_router(build_native_recording_router(lambda _: object(), start, stop))
    client = TestClient(app)

    assert (
        client.post("/api/sessions/session-1/start-native-recording").status_code == 200
    )
    assert (
        client.post("/api/sessions/session-1/stop-native-recording").status_code == 200
    )
    assert calls == ["start:session-1", "stop:session-1"]


def test_native_recording_rejects_unknown_session() -> None:
    async def no_op(_: str) -> None:
        raise AssertionError("callback must not run")

    app = FastAPI()
    app.include_router(build_native_recording_router(lambda _: None, no_op, no_op))

    assert (
        TestClient(app).post("/api/sessions/missing/start-native-recording").status_code
        == 404
    )
