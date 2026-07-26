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
