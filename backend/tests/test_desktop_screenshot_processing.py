import asyncio
import importlib
from datetime import UTC, datetime
from pathlib import Path

from services.meeting_ingestion import MeetingIngestionService, ScreenshotAnalysisResult
from services.meeting_repository import MeetingRepository


def test_desktop_screenshot_reuses_existing_image_processor(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    monkeypatch.setenv("PROMPTMEET_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("PROMPTMEET_WORK_DIR", str(tmp_path / "work"))
    main_service = importlib.import_module("main_service")
    monkeypatch.setattr(main_service, "DESKTOP_MODE", True)
    started = []

    async def start_image_process(session_id, window_id=None, image_path=None):
        started.append((session_id, window_id, image_path))

    monkeypatch.setattr(
        main_service.process_manager, "start_image_process", start_image_process
    )
    image_path = Path(tmp_path / "slide.png")

    asyncio.run(main_service.process_native_screenshot("session-1", image_path))

    assert started == [("session-1", None, str(image_path))]


def test_durable_screenshot_analysis_task_is_retained_until_completion(
    monkeypatch,
    tmp_path,
) -> None:
    monkeypatch.setenv("PROMPTMEET_DESKTOP_MODE", "1")
    main_service = importlib.import_module("main_service")
    repository = MeetingRepository(tmp_path / "data")
    ingestion = MeetingIngestionService(repository)
    ingestion.start("meeting-1", datetime(2026, 7, 25, tzinfo=UTC))
    screenshot_path = repository.assets_directory / "meeting-1" / "screen.png"
    screenshot_path.parent.mkdir(parents=True)
    screenshot_path.write_bytes(b"\x89PNG\r\n\x1a\ncontent")
    release = asyncio.Event()

    class DelayedAgent:
        async def analyze_screenshot(self, record, screenshot_event):
            await release.wait()
            return ScreenshotAnalysisResult(
                status="completed",
                text="截图分析完成",
                vision_used=True,
                provider="fake",
                model="fake-vision",
            )

    monkeypatch.setattr(main_service, "DESKTOP_MODE", True)
    monkeypatch.setattr(main_service, "meeting_repository", repository)
    monkeypatch.setattr(main_service, "meeting_ingestion", ingestion)
    monkeypatch.setattr(main_service, "desktop_agent_service", DelayedAgent())
    monkeypatch.setattr(
        main_service,
        "broadcast_meeting_event",
        lambda *args, **kwargs: asyncio.sleep(0),
    )
    monkeypatch.setattr(
        main_service.websocket_manager,
        "broadcast_to_session",
        lambda *args, **kwargs: asyncio.sleep(0),
    )

    async def run_analysis() -> None:
        main_service.meeting_screenshot_tasks.clear()
        await main_service.process_native_screenshot("meeting-1", screenshot_path)
        await asyncio.sleep(0)
        assert len(main_service.meeting_screenshot_tasks) == 1
        task = next(iter(main_service.meeting_screenshot_tasks))
        assert not task.done()
        release.set()
        await task
        await asyncio.sleep(0)
        assert not main_service.meeting_screenshot_tasks

    asyncio.run(run_analysis())
