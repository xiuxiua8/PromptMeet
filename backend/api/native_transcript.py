from collections.abc import Awaitable, Callable
from datetime import datetime
from typing import Literal
from uuid import UUID

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, field_validator


class NativeTranscript(BaseModel):
    id: UUID
    text: str
    speaker: str
    source: Literal["system", "microphone", "mixed"]
    timestamp: datetime
    translation_target: Literal["zh", "en", "ja", "ko"] | None = None

    @field_validator("text")
    @classmethod
    def reject_blank_text(cls, value: str) -> str:
        text = value.strip()
        if not text:
            raise ValueError("转写文本不能为空")
        return text


def build_native_transcript_router(
    session_lookup: Callable[[str], object],
    dispatch: Callable[[str, dict], Awaitable[None]],
) -> APIRouter:
    router = APIRouter()

    @router.post("/api/sessions/{session_id}/native-transcript")
    async def submit_native_transcript(
        session_id: str,
        transcript: NativeTranscript,
    ) -> dict[str, object]:
        if not session_lookup(session_id):
            raise HTTPException(status_code=404, detail="会话不存在")
        payload = transcript.model_dump(mode="json")
        await dispatch(session_id, payload)
        return {"success": True, "id": str(transcript.id)}

    return router
