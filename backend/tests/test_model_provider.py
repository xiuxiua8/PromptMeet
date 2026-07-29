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
            "DEEPSEEK_ANSWER_MODEL": "deepseek-v4-pro",
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


def test_provider_rejects_unsupported_model_instead_of_claiming_capabilities() -> None:
    try:
        ProviderConfiguration.from_environment(
            {
                "PROMPTMEET_AI_PROVIDER": "deepseek",
                "DEEPSEEK_API_KEY": "key",
                "DEEPSEEK_ANSWER_MODEL": "gpt-4o",
            }
        )
    except ValueError as error:
        assert "不支持" in str(error)
    else:
        raise AssertionError("Unsupported provider and model pairing was accepted")


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
