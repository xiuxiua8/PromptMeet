from fastapi import FastAPI
from fastapi.testclient import TestClient

from api.native_transcript import build_native_transcript_router


def test_native_transcript_is_dispatched_to_existing_session() -> None:
    received: list[tuple[str, dict]] = []

    async def dispatch(session_id: str, transcript: dict) -> bool:
        received.append((session_id, transcript))
        return True

    app = FastAPI()
    app.include_router(build_native_transcript_router(lambda _: object(), dispatch))
    response = TestClient(app).post(
        "/api/sessions/session-1/native-transcript",
        json={
            "id": "08f0900a-a756-48db-bf38-d3040ddcd986",
            "text": "本地识别完成",
            "speaker": "我",
            "source": "microphone",
            "meeting_time_ms": 1_250,
            "translation_target": "zh",
            "timestamp": "2026-07-24T20:00:00+08:00",
        },
    )

    assert response.status_code == 200
    assert received[0][0] == "session-1"
    assert received[0][1]["text"] == "本地识别完成"
    assert received[0][1]["translation_target"] == "zh"
    assert received[0][1]["source"] == "microphone"
    assert received[0][1]["meeting_time_ms"] == 1_250


def test_native_transcript_rejects_unknown_session_and_blank_text() -> None:
    async def dispatch(_: str, __: dict) -> bool:
        raise AssertionError("must not dispatch")

    missing = FastAPI()
    missing.include_router(build_native_transcript_router(lambda _: None, dispatch))
    payload = {
        "id": "08f0900a-a756-48db-bf38-d3040ddcd986",
        "text": "有效文本",
        "speaker": "会议",
        "source": "system",
        "timestamp": "2026-07-24T20:00:00+08:00",
    }
    assert (
        TestClient(missing)
        .post("/api/sessions/missing/native-transcript", json=payload)
        .status_code
        == 404
    )

    existing = FastAPI()
    existing.include_router(
        build_native_transcript_router(lambda _: object(), dispatch)
    )
    payload["text"] = "   "
    assert (
        TestClient(existing)
        .post("/api/sessions/session-1/native-transcript", json=payload)
        .status_code
        == 422
    )


def test_native_transcript_requires_persistence_acknowledgement() -> None:
    async def dispatch(_: str, __: dict) -> bool:
        return False

    app = FastAPI()
    app.include_router(build_native_transcript_router(lambda _: object(), dispatch))

    response = TestClient(app).post(
        "/api/sessions/session-1/native-transcript",
        json={
            "id": "08f0900a-a756-48db-bf38-d3040ddcd986",
            "text": "本地识别完成",
            "speaker": "我",
            "source": "microphone",
            "timestamp": "2026-07-24T20:00:00+08:00",
        },
    )

    assert response.status_code == 500
