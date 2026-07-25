from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class ProviderCapabilities:
    provider: str
    model: str
    supports_vision: bool
    max_context_tokens: int = 32_000


@dataclass(frozen=True)
class ProviderConfiguration:
    provider: str
    model: str
    endpoint: str
    capabilities: ProviderCapabilities
    api_key: str = field(repr=False)

    @classmethod
    def from_environment(
        cls,
        environment: dict[str, str],
        *,
        purpose: str = "answer",
    ) -> ProviderConfiguration:
        preferred = environment.get("PROMPTMEET_AI_PROVIDER", "deepseek").casefold()
        if preferred == "openai":
            key = environment.get("OPENAI_API_KEY", "").strip()
            if not key:
                raise RuntimeError("请先在 PromptMeet 设置中配置 OpenAI API Key")
            model = environment.get(
                "OPENAI_QUESTION_MODEL" if purpose == "questions" else "OPENAI_ANSWER_MODEL",
                "gpt-4o-mini"
                if purpose == "questions"
                else environment.get("OPENAI_CHAT_MODEL", "gpt-4o"),
            )
            if not cls._openai_model(model):
                raise ValueError(f"OpenAI 不支持所选模型：{model}")
            capabilities = ProviderCapabilities(
                provider="openai",
                model=model,
                supports_vision=cls._openai_vision_model(model),
                max_context_tokens=128_000,
            )
            return cls(
                provider="openai",
                model=model,
                endpoint="https://api.openai.com/v1/chat/completions",
                capabilities=capabilities,
                api_key=key,
            )
        if preferred != "deepseek":
            raise ValueError(f"不支持的 AI 提供方：{preferred}")
        key = environment.get("DEEPSEEK_API_KEY", "").strip()
        if not key:
            raise RuntimeError("请先在 PromptMeet 设置中配置 DeepSeek API Key")
        model = environment.get(
            "DEEPSEEK_QUESTION_MODEL" if purpose == "questions" else "DEEPSEEK_ANSWER_MODEL",
            "deepseek-v4-flash" if purpose == "questions" else "deepseek-v4-pro",
        )
        if not model.startswith("deepseek-"):
            raise ValueError(f"DeepSeek 不支持所选模型：{model}")
        base = environment.get("DEEPSEEK_API_BASE", "https://api.deepseek.com").rstrip("/")
        return cls(
            provider="deepseek",
            model=model,
            endpoint=f"{base}/chat/completions",
            capabilities=ProviderCapabilities(
                provider="deepseek",
                model=model,
                supports_vision=False,
                max_context_tokens=64_000,
            ),
            api_key=key,
        )

    def public_status(self) -> dict[str, object]:
        return {
            "configured": True,
            "provider": self.provider,
            "model": self.model,
            "supports_vision": self.capabilities.supports_vision,
        }

    @staticmethod
    def _openai_model(model: str) -> bool:
        return model.startswith(("gpt-4o", "gpt-4.1", "gpt-5"))

    @staticmethod
    def _openai_vision_model(model: str) -> bool:
        return model.startswith(("gpt-4o", "gpt-4.1", "gpt-5"))
