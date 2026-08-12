import asyncio
from pathlib import Path

from services.desktop_summary_service import OriginalSummaryService


class FakeSummaryProcessor:
    current_session_id = None

    async def process_transcript(self, text: str) -> dict:
        return {
            "success": True,
            "summary": {
                "summary_text": f"原摘要：{text}",
                "tasks": [{"task": "跟进", "priority": "medium", "status": "pending"}],
                "key_points": ["关键点"],
                "decisions": ["决定"],
            },
        }


def test_original_summary_processor_imports_without_loading_full_agent_stack() -> None:
    from processors.summary_processor import SummaryProcessor

    assert SummaryProcessor.__name__ == "SummaryProcessor"


def test_original_summary_result_uses_external_work_directory(
    monkeypatch, tmp_path
) -> None:
    from agents.summary import summary_model_name, summary_result_path

    monkeypatch.setenv("PROMPTMEET_WORK_DIR", str(tmp_path))

    assert summary_result_path() == Path(tmp_path) / "summary" / "Result.txt"
    assert summary_model_name({}) == "deepseek-chat"
    assert (
        summary_model_name({"DEEPSEEK_MODEL": "future-summary-id"})
        == "future-summary-id"
    )


def test_original_summary_service_returns_original_structured_result() -> None:
    service = OriginalSummaryService(processor_factory=FakeSummaryProcessor)

    result = asyncio.run(
        service.summarize("session-1", [type("Segment", (), {"text": "确认范围"})()])
    )

    assert result["summary_text"] == "原摘要：确认范围"
    assert result["tasks"][0]["task"] == "跟进"
    assert result["key_points"] == ["关键点"]
