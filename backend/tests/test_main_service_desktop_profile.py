import os
from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]
DESKTOP_PYTHON = ROOT / "build/desktop-python/bin/python3"


def test_main_service_desktop_profile_keeps_original_managers(tmp_path: Path) -> None:
    if not DESKTOP_PYTHON.exists():
        pytest.skip("desktop-python bundle not available on this platform")
    backend = Path(__file__).resolve().parents[1]
    environment = os.environ.copy()
    environment.update(
        {
            "PROMPTMEET_DESKTOP_MODE": "1",
            "PROMPTMEET_DATA_DIR": str(tmp_path / "data"),
            "PROMPTMEET_WORK_DIR": str(tmp_path / "work"),
            "PYTHONDONTWRITEBYTECODE": "1",
        }
    )
    result = subprocess.run(
        [
            str(DESKTOP_PYTHON),
            "-c",
            (
                "import main_service; "
                "print(main_service.app.title); "
                "print(type(main_service.session_manager).__name__); "
                "print(type(main_service.websocket_manager).__name__); "
                "print(type(main_service.process_manager).__name__); "
                "print(type(main_service.db_storage).__name__); "
                "print(main_service.server_options())"
            ),
        ],
        cwd=backend,
        env=environment,
        capture_output=True,
        text=True,
        check=True,
    )

    assert result.stdout.splitlines() == [
        "PromptMeet API",
        "SessionManager",
        "WebSocketManager",
        "ProcessManager",
        "HybridSessionStorage",
        "{'host': '127.0.0.1', 'port': 8000, 'reload': False, 'log_level': 'info'}",
    ]
