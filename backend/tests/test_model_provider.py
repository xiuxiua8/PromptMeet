import pytest

from services.model_provider import ProviderConfiguration


def test_provider_capabilities_are_explicit_and_status_never_contains_key() -> None:
    openai = ProviderConfiguration.from_environment(
        {
            "PROMPTMEET_AI_PROVIDER": "openai",
            "OPENAI_API_KEY": "super-secret-openai-key",
            "OPENAI_ANSWER_MODEL": "gpt-4o",
        }
    )
    deepseek = ProviderConfiguration.from_environment(
        {
            "PROMPTMEET_AI_PROVIDER": "deepseek",
            "DEEPSEEK_API_KEY": "super-secret-deepseek-key",
            "DEEPSEEK_ANSWER_MODEL": "deepseek-chat",
        }
    )

    assert openai.capabilities.supports_vision is True
    assert openai.endpoint == "https://api.openai.com/v1/chat/completions"
    assert deepseek.capabilities.supports_vision is False
    assert "super-secret" not in repr(openai)
    assert "super-secret" not in repr(deepseek)
    assert openai.public_status() == {
        "configured": True,
        "provider": "openai",
        "model": "gpt-4o",
        "supports_vision": True,
    }


def test_deepseek_accepts_nonempty_provider_scoped_manual_model_identifier() -> None:
    configuration = ProviderConfiguration.from_environment(
        {
            "PROMPTMEET_AI_PROVIDER": "deepseek",
            "DEEPSEEK_API_KEY": "key",
            "DEEPSEEK_ANSWER_MODEL": "future-custom-id",
        }
    )

    assert configuration.provider == "deepseek"
    assert configuration.model == "future-custom-id"


def test_deepseek_uses_established_default_model_identifier() -> None:
    configuration = ProviderConfiguration.from_environment(
        {
            "PROMPTMEET_AI_PROVIDER": "deepseek",
            "DEEPSEEK_API_KEY": "key",
        }
    )

    assert configuration.model == "deepseek-chat"


@pytest.mark.parametrize(
    ("base_url", "expected_endpoint"),
    [
        (
            "http://localhost:52251/v1/",
            "http://localhost:52251/v1/chat/completions",
        ),
        (
            "http://127.0.0.1:52251/v1//",
            "http://127.0.0.1:52251/v1/chat/completions",
        ),
        (
            "http://[::1]:52251/v1/",
            "http://[::1]:52251/v1/chat/completions",
        ),
    ],
)
def test_openai_compatible_loopback_base_is_normalized_once(
    base_url: str,
    expected_endpoint: str,
) -> None:
    configuration = ProviderConfiguration.from_environment(
        {
            "PROMPTMEET_AI_PROVIDER": "openai",
            "OPENAI_API_KEY": "placeholder-key",
            "OPENAI_API_BASE": base_url,
            "OPENAI_ANSWER_MODEL": " captain/proxy:model ",
        }
    )

    assert configuration.endpoint == expected_endpoint
    assert configuration.model == "captain/proxy:model"


@pytest.mark.parametrize(
    "base_url",
    [
        "http://proxy.example/v1",
        "http://127.0.0.2/v1",
        "ftp://localhost/v1",
        "https://user:password@proxy.example/v1",
        "https://proxy.example/v1?route=other",
        "https://proxy.example/v1#fragment",
        "https:///v1",
    ],
)
def test_openai_compatible_rejects_unsafe_or_ambiguous_base(base_url: str) -> None:
    with pytest.raises(ValueError):
        ProviderConfiguration.from_environment(
            {
                "PROMPTMEET_AI_PROVIDER": "openai",
                "OPENAI_API_KEY": "placeholder-key",
                "OPENAI_API_BASE": base_url,
                "OPENAI_ANSWER_MODEL": "proxy-model",
            }
        )


def test_openai_compatible_accepts_arbitrary_nonempty_model_identifier() -> None:
    configuration = ProviderConfiguration.from_environment(
        {
            "PROMPTMEET_AI_PROVIDER": "openai",
            "OPENAI_API_KEY": "placeholder-key",
            "OPENAI_ANSWER_MODEL": "local-llama-vision",
        }
    )

    assert configuration.model == "local-llama-vision"


def test_openai_compatible_rejects_empty_model_identifier() -> None:
    with pytest.raises(ValueError, match="模型标识"):
        ProviderConfiguration.from_environment(
            {
                "PROMPTMEET_AI_PROVIDER": "openai",
                "OPENAI_API_KEY": "placeholder-key",
                "OPENAI_ANSWER_MODEL": "  ",
            }
        )


def test_each_workflow_routes_to_its_own_provider_model_and_endpoint() -> None:
    environment = {
        "OPENAI_API_KEY": "openai-placeholder",
        "OPENAI_API_BASE": "https://proxy.example/v1",
        "DEEPSEEK_API_KEY": "deepseek-placeholder",
        "DEEPSEEK_API_BASE": "https://deepseek-proxy.example/v1",
        "PROMPTMEET_ANSWER_PROVIDER": "deepseek",
        "PROMPTMEET_ANSWER_MODEL": "deepseek-answer",
        "PROMPTMEET_QUESTION_PROVIDER": "openai",
        "PROMPTMEET_QUESTION_MODEL": "question-model",
        "PROMPTMEET_SUMMARY_PROVIDER": "deepseek",
        "PROMPTMEET_SUMMARY_MODEL": "deepseek-summary",
        "PROMPTMEET_SCREENSHOT_PROVIDER": "openai",
        "PROMPTMEET_SCREENSHOT_MODEL": "vision-model",
        "PROMPTMEET_SCREENSHOT_SUPPORTS_VISION": "1",
        "PROMPTMEET_TRANSLATION_PROVIDER": "openai",
        "PROMPTMEET_TRANSLATION_MODEL": "translation-model",
    }

    answer = ProviderConfiguration.from_environment(environment, purpose="answer")
    questions = ProviderConfiguration.from_environment(environment, purpose="questions")
    summary = ProviderConfiguration.from_environment(environment, purpose="summary")
    screenshot = ProviderConfiguration.from_environment(
        environment, purpose="screenshot"
    )
    translation = ProviderConfiguration.from_environment(
        environment, purpose="translation"
    )

    assert (answer.provider, answer.model) == ("deepseek", "deepseek-answer")
    assert (questions.provider, questions.model) == ("openai", "question-model")
    assert (summary.provider, summary.model) == ("deepseek", "deepseek-summary")
    assert (screenshot.provider, screenshot.model) == ("openai", "vision-model")
    assert answer.endpoint == "https://deepseek-proxy.example/v1/chat/completions"
    assert questions.endpoint == "https://proxy.example/v1/chat/completions"
    assert screenshot.capabilities.supports_vision is True
    assert (translation.provider, translation.model) == ("openai", "translation-model")


def test_custom_openai_model_is_text_only_without_explicit_vision_capability() -> None:
    configuration = ProviderConfiguration.from_environment(
        {
            "OPENAI_API_KEY": "placeholder-key",
            "PROMPTMEET_SCREENSHOT_PROVIDER": "openai",
            "PROMPTMEET_SCREENSHOT_MODEL": "captain-custom-model",
        },
        purpose="screenshot",
    )

    assert configuration.capabilities.supports_vision is False


@pytest.mark.parametrize(
    "base_url",
    [
        "http://api.deepseek.com/v1",
        "ftp://api.deepseek.com/v1",
        "https://user:secret@api.deepseek.com/v1",
        "https://api.deepseek.com/v1?route=other",
    ],
)
def test_deepseek_rejects_unsafe_or_ambiguous_endpoint(base_url: str) -> None:
    with pytest.raises(ValueError, match="DeepSeek"):
        ProviderConfiguration.from_environment(
            {
                "DEEPSEEK_API_KEY": "placeholder-key",
                "DEEPSEEK_API_BASE": base_url,
                "PROMPTMEET_ANSWER_PROVIDER": "deepseek",
                "PROMPTMEET_ANSWER_MODEL": "deepseek-chat",
            }
        )


def test_configuration_error_names_workflow_provider_and_model_without_key() -> None:
    with pytest.raises(RuntimeError) as captured:
        ProviderConfiguration.from_environment(
            {
                "PROMPTMEET_SUMMARY_PROVIDER": "openai",
                "PROMPTMEET_SUMMARY_MODEL": "summary-model",
            },
            purpose="summary",
        )

    message = str(captured.value)
    assert "summary" in message
    assert "openai" in message.casefold()
    assert "summary-model" in message
    assert "API Key" in message
