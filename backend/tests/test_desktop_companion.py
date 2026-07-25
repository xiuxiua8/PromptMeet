import os
from pathlib import Path
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]
BACKEND = ROOT / "backend"
DESKTOP_PYTHON = ROOT / "build/desktop-python/bin/python3"


def test_desktop_companion_is_only_a_compatibility_alias_for_main_service(tmp_path: Path) -> None:
    if not DESKTOP_PYTHON.exists():
        pytest.skip("desktop-python bundle not available on this platform")
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
                "import desktop_companion, main_service; "
                "print(desktop_companion.app is main_service.app); "
                "print(desktop_companion.app.title)"
            ),
        ],
        cwd=BACKEND,
        env=environment,
        capture_output=True,
        text=True,
        check=True,
    )

    assert result.stdout.splitlines() == ["True", "PromptMeet API"]
