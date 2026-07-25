from pathlib import Path

from fastapi import FastAPI
from fastapi.testclient import TestClient

from api.native_audio import build_native_audio_router
from services.native_audio_ingress import NativeAudioIngress


def create_client(tmp_path: Path, session_exists=lambda _: True) -> TestClient:
    app = FastAPI()
    app.include_router(build_native_audio_router(session_exists, NativeAudioIngress(tmp_path)))
    return TestClient(app)


def test_native_audio_endpoint_accepts_ordered_pcm(tmp_path: Path) -> None:
    response = create_client(tmp_path).post(
        "/api/sessions/session-1/native-audio",
        headers={
            "X-PromptMeet-Sequence": "0",
            "X-PromptMeet-Sample-Rate": "16000",
            "X-PromptMeet-Channels": "1",
            "Content-Type": "application/octet-stream",
            "X-PromptMeet-Source": "mixed",
        },
        content=b"\x01\x02",
    )

    assert response.status_code == 200
    assert response.json() == {"success": True, "sequence": 0}


def test_native_audio_endpoint_maps_session_and_sequence_errors(tmp_path: Path) -> None:
    missing = create_client(tmp_path, session_exists=lambda _: False).post(
        "/api/sessions/missing/native-audio",
        headers={
            "X-PromptMeet-Sequence": "0",
            "X-PromptMeet-Sample-Rate": "16000",
            "X-PromptMeet-Channels": "1",
            "Content-Type": "application/octet-stream",
        },
        content=b"\x00",
    )
    assert missing.status_code == 404

    client = create_client(tmp_path)
    headers = {
        "X-PromptMeet-Sequence": "0",
        "X-PromptMeet-Sample-Rate": "16000",
        "X-PromptMeet-Channels": "1",
        "Content-Type": "application/octet-stream",
    }
    assert client.post("/api/sessions/session-1/native-audio", headers=headers, content=b"\x00").status_code == 200
    assert client.post("/api/sessions/session-1/native-audio", headers=headers, content=b"\x00").status_code == 409
