import re
from pathlib import Path
from threading import Lock

from models.native_bridge import NativeAudioChunk, NativeAudioReceipt

SESSION_ID = re.compile(r"^[A-Za-z0-9_-]+$")


class NativeAudioValidationError(ValueError):
    pass


class NativeAudioSequenceError(ValueError):
    def __init__(self, expected: int, received: int) -> None:
        super().__init__(f"音频分片顺序错误：期望 {expected}，收到 {received}")
        self.expected = expected
        self.received = received


class NativeAudioIngress:
    def __init__(self, root: Path, max_payload_bytes: int = 4 * 1024 * 1024) -> None:
        self.root = Path(root)
        self.max_payload_bytes = max_payload_bytes
        self._seen_sequences: dict[str, set[int]] = {}
        self._lock = Lock()

    def accept(
        self,
        session_id: str,
        chunk: NativeAudioChunk,
        payload: bytes,
    ) -> NativeAudioReceipt:
        self._validate(session_id, payload)

        with self._lock:
            seen = self._seen_sequences.setdefault(session_id, set())
            if chunk.sequence in seen:
                raise NativeAudioSequenceError(
                    max(seen, default=-1) + 1, chunk.sequence
                )

            session_dir = self.root / session_id
            session_dir.mkdir(parents=True, exist_ok=True)
            path = session_dir / f"{chunk.sequence:08d}-{chunk.source}.pcm"
            metadata_path = path.with_suffix(".json")
            path.write_bytes(payload)
            metadata_path.write_text(chunk.model_dump_json(), encoding="utf-8")
            seen.add(chunk.sequence)

        return NativeAudioReceipt(
            sequence=chunk.sequence,
            path=path,
            metadata_path=metadata_path,
        )

    def reset(self, session_id: str) -> None:
        with self._lock:
            self._seen_sequences.pop(session_id, None)

    def _validate(self, session_id: str, payload: bytes) -> None:
        if not SESSION_ID.fullmatch(session_id):
            raise NativeAudioValidationError("会话 ID 无效")
        if not payload:
            raise NativeAudioValidationError("音频分片不能为空")
        if len(payload) > self.max_payload_bytes:
            raise NativeAudioValidationError("音频分片超过大小限制")
