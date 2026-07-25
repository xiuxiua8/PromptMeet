from collections.abc import Awaitable, Callable
from pathlib import Path
import uuid

from fastapi import APIRouter, Body, Header, HTTPException


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
JPEG_SIGNATURE = b"\xff\xd8\xff"


def build_native_screenshot_router(
    session_lookup: Callable[[str], object],
    root: Path,
    process_image: Callable[[str, Path], Awaitable[None]],
) -> APIRouter:
    router = APIRouter()
    root = Path(root)

    @router.post("/api/sessions/{session_id}/native-screenshot")
    async def upload_native_screenshot(
        session_id: str,
        payload: bytes = Body(...),
        content_type: str = Header("application/octet-stream", alias="Content-Type"),
    ) -> dict[str, object]:
        if not session_lookup(session_id):
            raise HTTPException(status_code=404, detail="会话不存在")
        if len(payload) > 20 * 1024 * 1024:
            raise HTTPException(status_code=413, detail="截图超过大小限制")

        if content_type.startswith("image/png") and payload.startswith(PNG_SIGNATURE):
            extension = "png"
        elif content_type.startswith("image/jpeg") and payload.startswith(JPEG_SIGNATURE):
            extension = "jpg"
        else:
            raise HTTPException(status_code=422, detail="只接受 PNG 或 JPEG 截图")

        session_dir = root / session_id
        session_dir.mkdir(parents=True, exist_ok=True)
        path = session_dir / f"{uuid.uuid4().hex}.{extension}"
        path.write_bytes(payload)
        await process_image(session_id, path)
        return {"success": True, "status": "analyzing"}

    return router
