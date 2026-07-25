import json
import os
from pathlib import Path
from typing import Protocol


class SessionStorage(Protocol):
    def initialize_database(self) -> bool:
        ...

    def store_session(self, session: dict) -> bool:
        ...

    def get_all_sessions(self) -> str:
        ...

    def get_session_details(self, session_id: str) -> str:
        ...

    def save_session_to_json_file(self, session_id: str) -> str | None:
        ...


class DesktopSessionStorage:
    def __init__(self, root: str | Path | None = None):
        self.root = Path(root) if root else Path.home() / "Library/Application Support/PromptMeet"
        self.root.mkdir(parents=True, exist_ok=True)

    def initialize_database(self) -> bool:
        return True

    def store_session(self, session: dict) -> bool:
        sessions = self._read_sessions()
        sessions[session["session_id"]] = session
        self._write_sessions(sessions)
        return True

    def get_all_sessions(self) -> str:
        return json.dumps(list(self._read_sessions().values()), ensure_ascii=False, default=str)

    def get_session_details(self, session_id: str) -> str:
        return json.dumps(self._read_sessions().get(session_id), ensure_ascii=False, default=str)

    def save_session_to_json_file(self, session_id: str) -> str | None:
        session = self._read_sessions().get(session_id)
        if session is None:
            return None
        export_directory = self.root / "exports"
        export_directory.mkdir(parents=True, exist_ok=True)
        path = export_directory / f"{session_id}.json"
        path.write_text(json.dumps(session, ensure_ascii=False, indent=2, default=str), encoding="utf-8")
        return str(path)

    def _read_sessions(self) -> dict[str, dict]:
        path = self.root / "desktop-sessions.json"
        if not path.exists():
            return {}
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}

    def _write_sessions(self, sessions: dict[str, dict]) -> None:
        path = self.root / "desktop-sessions.json"
        temporary = path.with_suffix(".tmp")
        temporary.write_text(json.dumps(sessions, ensure_ascii=False, indent=2, default=str), encoding="utf-8")
        temporary.replace(path)


class HybridSessionStorage:
    def __init__(self, primary: SessionStorage | None, fallback: DesktopSessionStorage):
        self.primary = primary
        self.fallback = fallback
        self.active: SessionStorage = fallback
        self.backend_name = "local"

    @classmethod
    def from_environment(
        cls,
        local_root: str | Path | None = None,
        environment: dict[str, str] | None = None,
    ) -> "HybridSessionStorage":
        environment = os.environ if environment is None else environment
        primary = None
        if environment.get("PROMPTMEET_STORAGE", "local").lower() == "mysql":
            try:
                from processors.database import MeetingSessionStorage

                primary = MeetingSessionStorage()
            except (ImportError, ModuleNotFoundError):
                primary = None
        return cls(primary=primary, fallback=DesktopSessionStorage(local_root))

    def initialize_database(self) -> bool:
        if self.primary is not None:
            try:
                if self.primary.initialize_database():
                    self.active = self.primary
                    self.backend_name = "mysql"
                    return True
            except Exception:
                pass
        self.active = self.fallback
        self.backend_name = "local"
        return self.fallback.initialize_database()

    def store_session(self, session: dict) -> bool:
        local_success = self.fallback.store_session(session)
        if self.active is self.fallback:
            return local_success
        try:
            return bool(self.active.store_session(session))
        except Exception:
            return local_success

    def get_all_sessions(self) -> str:
        return self._read("get_all_sessions")

    def get_session_details(self, session_id: str) -> str:
        return self._read("get_session_details", session_id)

    def save_session_to_json_file(self, session_id: str) -> str | None:
        return self.fallback.save_session_to_json_file(session_id)

    def _read(self, method: str, *args) -> str:
        if self.active is not self.fallback:
            try:
                return getattr(self.active, method)(*args)
            except Exception:
                pass
        return getattr(self.fallback, method)(*args)
