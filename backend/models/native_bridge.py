from datetime import datetime, timezone
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field


class NativeAudioChunk(BaseModel):
    sequence: int = Field(ge=0)
    sample_rate: int = Field(ge=8_000, le=48_000)
    channels: int = Field(ge=1, le=2)
    source: Literal["system", "microphone", "mixed"] = "mixed"
    sample_format: Literal["pcm_s16le"] = "pcm_s16le"
    captured_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    meeting_time_ms: int = Field(default=0, ge=0)


class NativeAudioReceipt(BaseModel):
    sequence: int
    path: Path
    metadata_path: Path
