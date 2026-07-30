import base64
import binascii
import json
from collections.abc import Awaitable, Callable
from pathlib import Path
import uuid
from typing import Any

from fastapi import APIRouter, HTTPException, Request

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
JPEG_SIGNATURE = b"\xff\xd8\xff"


def build_native_screenshot_router(
    session_lookup: Callable[[str], object],
    root: Path | Callable[[], Path],
    process_image: Callable[
        [str, Path, str | None, str | None],
        Awaitable[dict[str, Any] | None],
    ],
) -> APIRouter:
    router = APIRouter()

    @router.post("/api/sessions/{session_id}/native-screenshot")
    async def upload_native_screenshot(
        session_id: str,
        request: Request,
    ) -> dict[str, object]:
        if not session_lookup(session_id):
            raise HTTPException(status_code=404, detail="会话不存在")
        content_type = request.headers.get("Content-Type", "application/octet-stream")
        raw_payload = await request.body()
        local_ocr_text: str | None = None
        ocr_engine: str | None = None
        if content_type.startswith("application/json"):
            try:
                envelope = json.loads(raw_payload)
                encoded = envelope["image_base64"]
                supplied_mime_type = envelope["mime_type"]
                if not isinstance(encoded, str) or not isinstance(
                    supplied_mime_type, str
                ):
                    raise ValueError
                payload = base64.b64decode(encoded, validate=True)
            except (
                KeyError,
                TypeError,
                ValueError,
                json.JSONDecodeError,
                binascii.Error,
            ):
                raise HTTPException(status_code=422, detail="截图 JSON 无效") from None
            content_type = supplied_mime_type
            raw_ocr_text = envelope.get("local_ocr_text")
            if raw_ocr_text is not None and not isinstance(raw_ocr_text, str):
                raise HTTPException(status_code=422, detail="本地 OCR 文本无效")
            local_ocr_text = (raw_ocr_text or "").strip() or None
            if local_ocr_text and len(local_ocr_text) > 20_000:
                raise HTTPException(status_code=422, detail="本地 OCR 文本超过大小限制")
            raw_ocr_engine = envelope.get("ocr_engine")
            if local_ocr_text:
                if raw_ocr_engine != "apple_vision":
                    raise HTTPException(status_code=422, detail="本地 OCR 来源无效")
                ocr_engine = raw_ocr_engine
        else:
            payload = raw_payload
        if len(payload) > 20 * 1024 * 1024:
            raise HTTPException(status_code=413, detail="截图超过大小限制")

        if content_type.startswith("image/png") and payload.startswith(PNG_SIGNATURE):
            extension = "png"
        elif content_type.startswith("image/jpeg") and payload.startswith(
            JPEG_SIGNATURE
        ):
            extension = "jpg"
        else:
            raise HTTPException(status_code=422, detail="只接受 PNG 或 JPEG 截图")

        storage_root = Path(root() if callable(root) else root)
        session_dir = storage_root / session_id
        session_dir.mkdir(parents=True, exist_ok=True)
        path = session_dir / f"{uuid.uuid4().hex}.{extension}"
        path.write_bytes(payload)
        result = (
            await process_image(
                session_id,
                path,
                local_ocr_text,
                ocr_engine,
            )
            or {}
        )
        return {"success": True, "status": "analyzing", **result}

    return router
