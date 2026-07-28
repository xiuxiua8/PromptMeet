from collections.abc import Callable
from datetime import datetime

from fastapi import APIRouter, Body, Header, HTTPException
from pydantic import ValidationError

from models.native_bridge import NativeAudioChunk
from services.native_audio_ingress import (
    NativeAudioIngress,
    NativeAudioSequenceError,
    NativeAudioValidationError,
)


def build_native_audio_router(
    session_exists: Callable[[str], object],
    ingress: NativeAudioIngress,
) -> APIRouter:
    router = APIRouter()

    @router.post("/api/sessions/{session_id}/native-audio")
    async def ingest_native_audio(
        session_id: str,
        payload: bytes = Body(..., media_type="application/octet-stream"),
        sequence: int = Header(..., alias="X-PromptMeet-Sequence"),
        sample_rate: int = Header(..., alias="X-PromptMeet-Sample-Rate"),
        channels: int = Header(..., alias="X-PromptMeet-Channels"),
        source: str = Header("mixed", alias="X-PromptMeet-Source"),
        captured_at: datetime | None = Header(None, alias="X-PromptMeet-Captured-At"),
        meeting_time_ms: int = Header(0, alias="X-PromptMeet-Meeting-Time-Ms"),
    ) -> dict[str, object]:
        session = session_exists(session_id)
        if not session:
            raise HTTPException(status_code=404, detail="会话不存在")
        if getattr(session, "is_paused", False):
            raise HTTPException(status_code=409, detail="录音已暂停")

        try:
            values: dict[str, object] = {
                "sequence": sequence,
                "sample_rate": sample_rate,
                "channels": channels,
                "source": source,
                "meeting_time_ms": meeting_time_ms,
            }
            if captured_at is not None:
                values["captured_at"] = captured_at
            metadata = NativeAudioChunk(
                **values,
            )
            receipt = ingress.accept(session_id, metadata, payload)
        except ValidationError as error:
            raise HTTPException(status_code=422, detail=error.errors()) from error
        except NativeAudioSequenceError as error:
            raise HTTPException(status_code=409, detail=str(error)) from error
        except NativeAudioValidationError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error

        return {"success": True, "sequence": receipt.sequence}

    return router
