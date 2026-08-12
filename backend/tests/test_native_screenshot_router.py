import base64
from pathlib import Path

from fastapi import FastAPI
from fastapi.testclient import TestClient

from api.native_screenshot import build_native_screenshot_router


def test_native_screenshot_is_saved_and_dispatched(tmp_path: Path) -> None:
    dispatched: list[Path] = []

    async def process(
        _: str,
        path: Path,
        __: str | None,
        ___: str | None,
    ) -> dict:
        dispatched.append(path)
        return {"event": {"kind": "screenshot"}}

    app = FastAPI()
    app.include_router(
        build_native_screenshot_router(lambda _: object(), tmp_path, process)
    )
    response = TestClient(app).post(
        "/api/sessions/session-1/native-screenshot",
        headers={"Content-Type": "image/png"},
        content=b"\x89PNG\r\n\x1a\ncontent",
    )

    assert response.status_code == 200
    assert dispatched[0].read_bytes().startswith(b"\x89PNG")
    assert dispatched[0].parent == tmp_path / "session-1"
    assert response.json()["event"]["kind"] == "screenshot"


def test_native_screenshot_json_preserves_pixels_and_local_ocr_provenance(
    tmp_path: Path,
) -> None:
    dispatched = []

    async def process(
        session_id: str,
        path: Path,
        local_ocr_text: str | None,
        ocr_engine: str | None,
    ) -> dict:
        dispatched.append((session_id, path, local_ocr_text, ocr_engine))
        return {"event": {"kind": "screenshot", "asset_id": path.stem}}

    app = FastAPI()
    app.include_router(
        build_native_screenshot_router(lambda _: object(), tmp_path, process)
    )
    pixels = b"\x89PNG\r\n\x1a\ncaptain-shape-chinese-pixels"

    response = TestClient(app).post(
        "/api/sessions/session-1/native-screenshot",
        json={
            "mime_type": "image/png",
            "image_base64": base64.b64encode(pixels).decode("ascii"),
            "local_ocr_text": "截图证据：青岚计划在 14:30 部署，负责人周岚。",
            "ocr_engine": "apple_vision",
        },
    )

    assert response.status_code == 200
    assert len(dispatched) == 1
    session_id, path, ocr_text, ocr_engine = dispatched[0]
    assert session_id == "session-1"
    assert path.read_bytes() == pixels
    assert ocr_text == "截图证据：青岚计划在 14:30 部署，负责人周岚。"
    assert ocr_engine == "apple_vision"


def test_native_screenshot_rejects_unknown_session_and_non_image(
    tmp_path: Path,
) -> None:
    async def no_op(
        _: str,
        __: Path,
        ___: str | None,
        ____: str | None,
    ) -> None:
        raise AssertionError("must not process")

    missing_app = FastAPI()
    missing_app.include_router(
        build_native_screenshot_router(lambda _: None, tmp_path, no_op)
    )
    assert (
        TestClient(missing_app)
        .post(
            "/api/sessions/missing/native-screenshot",
            headers={"Content-Type": "image/png"},
            content=b"\x89PNG\r\n\x1a\ncontent",
        )
        .status_code
        == 404
    )

    invalid_app = FastAPI()
    invalid_app.include_router(
        build_native_screenshot_router(lambda _: object(), tmp_path, no_op)
    )
    assert (
        TestClient(invalid_app)
        .post(
            "/api/sessions/session-1/native-screenshot",
            headers={"Content-Type": "application/octet-stream"},
            content=b"not-an-image",
        )
        .status_code
        == 422
    )
