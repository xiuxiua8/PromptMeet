import asyncio
import importlib
from pathlib import Path


def test_desktop_screenshot_reuses_existing_image_processor(monkeypatch, tmp_path) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    monkeypatch.setenv("PROMPTMEET_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("PROMPTMEET_WORK_DIR", str(tmp_path / "work"))
    main_service = importlib.import_module("main_service")
    monkeypatch.setattr(main_service, "DESKTOP_MODE", True)
    started = []

    async def start_image_process(session_id, window_id=None, image_path=None):
        started.append((session_id, window_id, image_path))

    monkeypatch.setattr(main_service.process_manager, "start_image_process", start_image_process)
    image_path = Path(tmp_path / "slide.png")

    asyncio.run(main_service.process_native_screenshot("session-1", image_path))

    assert started == [("session-1", None, str(image_path))]
