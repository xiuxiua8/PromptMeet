from fastapi import FastAPI
from fastapi.testclient import TestClient

from api.native_recording import build_native_recording_router


def test_native_recording_routes_do_not_reuse_web_audio_capture() -> None:
    calls: list[str] = []

    class Session:
        is_recording = False
        is_paused = False

    session = Session()

    async def start(session_id: str) -> None:
        calls.append(f"start:{session_id}")
        session.is_recording = True

    async def stop(session_id: str) -> None:
        calls.append(f"stop:{session_id}")
        session.is_recording = False
        session.is_paused = False

    async def pause(session_id: str) -> None:
        calls.append(f"pause:{session_id}")
        session.is_paused = True

    async def resume(session_id: str) -> None:
        calls.append(f"resume:{session_id}")
        session.is_paused = False

    app = FastAPI()
    app.include_router(
        build_native_recording_router(lambda _: session, start, pause, resume, stop)
    )
    client = TestClient(app)

    assert (
        client.post("/api/sessions/session-1/start-native-recording").status_code == 200
    )
    assert (
        client.post("/api/sessions/session-1/pause-native-recording").status_code == 200
    )
    assert (
        client.post("/api/sessions/session-1/resume-native-recording").status_code
        == 200
    )
    assert (
        client.post("/api/sessions/session-1/stop-native-recording").status_code == 200
    )
    assert calls == [
        "start:session-1",
        "pause:session-1",
        "resume:session-1",
        "stop:session-1",
    ]


def test_native_recording_rejects_unknown_session() -> None:
    async def no_op(_: str) -> None:
        raise AssertionError("callback must not run")

    app = FastAPI()
    app.include_router(
        build_native_recording_router(lambda _: None, no_op, no_op, no_op, no_op)
    )

    assert (
        TestClient(app).post("/api/sessions/missing/start-native-recording").status_code
        == 404
    )


def test_pause_and_resume_reject_invalid_recording_state() -> None:
    class Session:
        is_recording = False
        is_paused = False

    async def no_op(_: str) -> None:
        raise AssertionError("callback must not run")

    app = FastAPI()
    app.include_router(
        build_native_recording_router(lambda _: Session(), no_op, no_op, no_op, no_op)
    )
    client = TestClient(app)

    paused = client.post("/api/sessions/session-1/pause-native-recording")
    resumed = client.post("/api/sessions/session-1/resume-native-recording")

    assert paused.status_code == 409
    assert paused.json()["detail"] == "会话未在录音"
    assert resumed.status_code == 409
    assert resumed.json()["detail"] == "会话未在录音"
