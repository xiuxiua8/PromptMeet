import json

from services.desktop_storage import DesktopSessionStorage, HybridSessionStorage


class MemoryPrimaryStorage:
    def __init__(self, available: bool):
        self.available = available
        self.sessions = {}

    def initialize_database(self) -> bool:
        return self.available

    def store_session(self, session: dict) -> bool:
        self.sessions[session["session_id"]] = session
        return True

    def get_all_sessions(self) -> str:
        return json.dumps(list(self.sessions.values()))

    def get_session_details(self, session_id: str) -> str:
        return json.dumps(self.sessions.get(session_id))

    def save_session_to_json_file(self, session_id: str) -> str | None:
        return f"mysql://{session_id}" if session_id in self.sessions else None


def test_hybrid_storage_prefers_original_database_and_mirrors_locally(tmp_path) -> None:
    primary = MemoryPrimaryStorage(available=True)
    local = DesktopSessionStorage(tmp_path)
    storage = HybridSessionStorage(primary=primary, fallback=local)

    assert storage.initialize_database()
    assert storage.backend_name == "mysql"
    assert storage.store_session({"session_id": "session-1", "transcript_segments": []})

    assert "session-1" in primary.sessions
    assert json.loads(local.get_session_details("session-1"))["session_id"] == "session-1"


def test_hybrid_storage_falls_back_when_original_database_is_unavailable(tmp_path) -> None:
    storage = HybridSessionStorage(
        primary=MemoryPrimaryStorage(available=False),
        fallback=DesktopSessionStorage(tmp_path),
    )

    assert storage.initialize_database()
    assert storage.backend_name == "local"
    assert storage.store_session({"session_id": "session-2"})
    assert json.loads(storage.get_session_details("session-2"))["session_id"] == "session-2"


def test_desktop_storage_defaults_to_local_without_explicit_mysql_opt_in(tmp_path) -> None:
    storage = HybridSessionStorage.from_environment(tmp_path, environment={})

    assert storage.primary is None
    assert storage.initialize_database()
    assert storage.backend_name == "local"
