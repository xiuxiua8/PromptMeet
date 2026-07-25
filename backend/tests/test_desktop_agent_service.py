import asyncio

from services.desktop_agent_service import DesktopAgentService


class FakeResponse:
    def raise_for_status(self) -> None:
        pass

    def json(self) -> dict:
        return {
            "choices": [
                {
                    "message": {
                        "content": """```json
[{"question":"负责人是谁？"},{"question":"截止日期是什么时候？"}]
```"""
                    }
                }
            ]
        }


class FakeClient:
    last_payload = None

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, traceback):
        return False

    async def post(self, *args, **kwargs) -> FakeResponse:
        type(self).last_payload = kwargs["json"]
        return FakeResponse()


def test_generate_questions_returns_structured_desktop_questions(monkeypatch) -> None:
    monkeypatch.setattr(
        "services.desktop_agent_service.httpx.AsyncClient",
        lambda **kwargs: FakeClient(),
    )
    service = DesktopAgentService(environment={"DEEPSEEK_API_KEY": "test-key"})
    transcript = [type("Segment", (), {"speaker": "我", "text": "下周完成上线"})()]

    questions = asyncio.run(service.generate_questions(transcript))

    assert questions == [
        {"question": "负责人是谁？"},
        {"question": "截止日期是什么时候？"},
    ]
    assert FakeClient.last_payload["model"] == "deepseek-v4-flash"


def test_provider_status_reports_configuration_without_exposing_key() -> None:
    configured = DesktopAgentService(
        environment={
            "PROMPTMEET_AI_PROVIDER": "deepseek",
            "DEEPSEEK_API_KEY": "secret-key",
            "DEEPSEEK_ANSWER_MODEL": "deepseek-v4-pro",
            "DEEPSEEK_QUESTION_MODEL": "deepseek-v4-flash",
        }
    ).provider_status()
    missing = DesktopAgentService(environment={}).provider_status()

    assert configured == {
        "configured": True,
        "provider": "deepseek",
        "model": "deepseek-v4-pro",
        "answer_model": "deepseek-v4-pro",
        "question_model": "deepseek-v4-flash",
    }
    assert missing == {"configured": False, "provider": None, "model": None}
    assert "secret-key" not in str(configured)


def test_answer_and_question_generation_use_different_models() -> None:
    service = DesktopAgentService(
        environment={
            "DEEPSEEK_API_KEY": "test-key",
            "DEEPSEEK_ANSWER_MODEL": "deepseek-v4-pro",
            "DEEPSEEK_QUESTION_MODEL": "deepseek-v4-flash",
        }
    )

    assert service._provider("answer")[2] == "deepseek-v4-pro"
    assert service._provider("questions")[2] == "deepseek-v4-flash"
