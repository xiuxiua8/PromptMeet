from pathlib import Path

from fastapi import FastAPI
from fastapi.testclient import TestClient

from api.native_screenshot import build_native_screenshot_router


def test_native_screenshot_is_saved_and_dispatched(tmp_path: Path) -> None:
    dispatched: list[Path] = []

    async def process(_: str, path: Path) -> dict:
        dispatched.append(path)
        return {"event": {"kind": "screenshot"}}

    app = FastAPI()
    app.include_router(build_native_screenshot_router(lambda _: object(), tmp_path, process))
    response = TestClient(app).post(
        "/api/sessions/session-1/native-screenshot",
        headers={"Content-Type": "image/png"},
        content=b"\x89PNG\r\n\x1a\ncontent",
    )

    assert response.status_code == 200
    assert dispatched[0].read_bytes().startswith(b"\x89PNG")
    assert dispatched[0].parent == tmp_path / "session-1"
    assert response.json()["event"]["kind"] == "screenshot"


def test_native_screenshot_rejects_unknown_session_and_non_image(tmp_path: Path) -> None:
    async def no_op(_: str, __: Path) -> None:
        raise AssertionError("must not process")

    missing_app = FastAPI()
    missing_app.include_router(build_native_screenshot_router(lambda _: None, tmp_path, no_op))
    assert TestClient(missing_app).post(
        "/api/sessions/missing/native-screenshot",
        headers={"Content-Type": "image/png"},
        content=b"\x89PNG\r\n\x1a\ncontent",
    ).status_code == 404

    invalid_app = FastAPI()
    invalid_app.include_router(build_native_screenshot_router(lambda _: object(), tmp_path, no_op))
    assert TestClient(invalid_app).post(
        "/api/sessions/session-1/native-screenshot",
        headers={"Content-Type": "application/octet-stream"},
        content=b"not-an-image",
    ).status_code == 422
