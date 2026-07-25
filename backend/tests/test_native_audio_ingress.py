from pathlib import Path

import pytest

from models.native_bridge import NativeAudioChunk
from services.native_audio_ingress import (
    NativeAudioIngress,
    NativeAudioSequenceError,
    NativeAudioValidationError,
)


def test_accept_writes_first_pcm_chunk_in_session_directory(tmp_path: Path) -> None:
    ingress = NativeAudioIngress(tmp_path)

    receipt = ingress.accept(
        "session-1",
        NativeAudioChunk(sequence=0, sample_rate=16_000, channels=1, source="mixed"),
        b"\x01\x02",
    )

    assert receipt.sequence == 0
    assert receipt.path.read_bytes() == b"\x01\x02"
    assert receipt.path.parent == tmp_path / "session-1"


def test_accept_allows_out_of_order_sources_but_rejects_duplicate_sequence(
    tmp_path: Path,
) -> None:
    ingress = NativeAudioIngress(tmp_path)
    late = NativeAudioChunk(sequence=2, sample_rate=16_000, channels=1, source="system")
    first = NativeAudioChunk(
        sequence=0, sample_rate=16_000, channels=1, source="microphone"
    )

    ingress.accept("session-1", late, b"\x02")
    ingress.accept("session-1", first, b"\x00")

    with pytest.raises(NativeAudioSequenceError):
        ingress.accept("session-1", late, b"\x02")


def test_accept_rejects_empty_payload_and_unsafe_session_id(tmp_path: Path) -> None:
    ingress = NativeAudioIngress(tmp_path)
    chunk = NativeAudioChunk(sequence=0, sample_rate=16_000, channels=1)

    with pytest.raises(NativeAudioValidationError):
        ingress.accept("session-1", chunk, b"")

    with pytest.raises(NativeAudioValidationError):
        ingress.accept("../escape", chunk, b"\x00")
