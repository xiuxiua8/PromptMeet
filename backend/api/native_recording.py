from collections.abc import Awaitable, Callable

from fastapi import APIRouter, HTTPException


def build_native_recording_router(
    session_lookup: Callable[[str], object],
    start_recording: Callable[[str], Awaitable[None]],
    pause_recording: Callable[[str], Awaitable[None]],
    resume_recording: Callable[[str], Awaitable[None]],
    stop_recording: Callable[[str], Awaitable[None]],
) -> APIRouter:
    router = APIRouter()

    @router.post("/api/sessions/{session_id}/start-native-recording")
    async def start(session_id: str) -> dict[str, object]:
        if not session_lookup(session_id):
            raise HTTPException(status_code=404, detail="会话不存在")
        await start_recording(session_id)
        return {"success": True, "capture": "native"}

    @router.post("/api/sessions/{session_id}/stop-native-recording")
    async def stop(session_id: str) -> dict[str, object]:
        if not session_lookup(session_id):
            raise HTTPException(status_code=404, detail="会话不存在")
        await stop_recording(session_id)
        return {"success": True, "capture": "native"}

    @router.post("/api/sessions/{session_id}/pause-native-recording")
    async def pause(session_id: str) -> dict[str, object]:
        session = session_lookup(session_id)
        if not session:
            raise HTTPException(status_code=404, detail="会话不存在")
        if not getattr(session, "is_recording", False):
            raise HTTPException(status_code=409, detail="会话未在录音")
        await pause_recording(session_id)
        return {
            "success": True,
            "capture": "native",
            "paused": bool(getattr(session, "is_paused", True)),
        }

    @router.post("/api/sessions/{session_id}/resume-native-recording")
    async def resume(session_id: str) -> dict[str, object]:
        session = session_lookup(session_id)
        if not session:
            raise HTTPException(status_code=404, detail="会话不存在")
        if not getattr(session, "is_recording", False):
            raise HTTPException(status_code=409, detail="会话未在录音")
        if not getattr(session, "is_paused", False):
            raise HTTPException(status_code=409, detail="会话未暂停")
        await resume_recording(session_id)
        return {
            "success": True,
            "capture": "native",
            "paused": bool(getattr(session, "is_paused", False)),
        }

    return router
