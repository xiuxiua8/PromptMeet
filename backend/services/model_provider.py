from __future__ import annotations

from dataclasses import dataclass, field
from urllib.parse import SplitResult, urlsplit, urlunsplit


def normalize_openai_base_url(value: str) -> str:
    raw_value = value.strip()
    try:
        parsed = urlsplit(raw_value)
        port = parsed.port
    except ValueError as error:
        raise ValueError("请输入有效的 OpenAI 兼容 Base URL") from error
    scheme = parsed.scheme.casefold()
    hostname = (parsed.hostname or "").casefold()
    if (
        scheme not in {"http", "https"}
        or not hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("请输入有效的 OpenAI 兼容 Base URL")
    if scheme == "http" and hostname not in {"localhost", "127.0.0.1", "::1"}:
        raise ValueError("非本机 OpenAI 兼容服务必须使用 HTTPS")
    host = f"[{hostname}]" if ":" in hostname else hostname
    netloc = f"{host}:{port}" if port is not None else host
    path = parsed.path.rstrip("/")
    normalized = SplitResult(scheme, netloc, path, "", "")
    return urlunsplit(normalized)


def normalize_deepseek_base_url(value: str) -> str:
    raw_value = value.strip()
    try:
        parsed = urlsplit(raw_value)
        port = parsed.port
    except ValueError as error:
        raise ValueError("请输入有效的 DeepSeek HTTPS Base URL") from error
    scheme = parsed.scheme.casefold()
    hostname = (parsed.hostname or "").casefold()
    if (
        scheme != "https"
        or not hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("请输入有效的 DeepSeek HTTPS Base URL")
    host = f"[{hostname}]" if ":" in hostname else hostname
    netloc = f"{host}:{port}" if port is not None else host
    path = parsed.path.rstrip("/")
    return urlunsplit(SplitResult(scheme, netloc, path, "", ""))


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
        purpose_prefix = {
            "answer": "ANSWER",
            "questions": "QUESTION",
            "summary": "SUMMARY",
            "screenshot": "SCREENSHOT",
            "translation": "TRANSLATION",
        }.get(purpose)
        if purpose_prefix is None:
            raise ValueError(f"不支持的 AI 工作流：{purpose}")
        workflow_provider_key = f"PROMPTMEET_{purpose_prefix}_PROVIDER"
        workflow_model_key = f"PROMPTMEET_{purpose_prefix}_MODEL"
        workflow_vision_key = f"PROMPTMEET_{purpose_prefix}_SUPPORTS_VISION"
        preferred = environment.get(
            workflow_provider_key,
            environment.get("PROMPTMEET_AI_PROVIDER", "deepseek"),
        ).casefold()
        if preferred == "openai":
            model = environment.get(workflow_model_key)
            if model is None:
                model = environment.get(
                    (
                        "OPENAI_QUESTION_MODEL"
                        if purpose == "questions"
                        else "OPENAI_ANSWER_MODEL"
                    ),
                    (
                        "gpt-4o-mini"
                        if purpose == "questions"
                        else environment.get("OPENAI_CHAT_MODEL", "gpt-4o")
                    ),
                )
            model = model.strip()
            key = environment.get("OPENAI_API_KEY", "").strip()
            if not key:
                raise RuntimeError(
                    f"AI 工作流 {purpose} 使用 OpenAI 模型 {model or '未指定'}，"
                    "请先在 PromptMeet 设置中配置 OpenAI API Key"
                )
            if not model:
                raise ValueError(f"AI 工作流 {purpose} 请输入 OpenAI 兼容模型标识")
            base = normalize_openai_base_url(
                environment.get("OPENAI_API_BASE", "https://api.openai.com/v1")
            )
            configured_vision = environment.get(workflow_vision_key)
            supports_vision = (
                configured_vision == "1"
                if configured_vision is not None
                else purpose == "screenshot" or cls._openai_vision_model(model)
            )
            capabilities = ProviderCapabilities(
                provider="openai",
                model=model,
                supports_vision=supports_vision,
                max_context_tokens=128_000,
            )
            return cls(
                provider="openai",
                model=model,
                endpoint=f"{base}/chat/completions",
                capabilities=capabilities,
                api_key=key,
            )
        if preferred != "deepseek":
            raise ValueError(f"AI 工作流 {purpose} 不支持提供方：{preferred}")
        model = environment.get(workflow_model_key)
        if model is None:
            model = environment.get(
                (
                    "DEEPSEEK_QUESTION_MODEL"
                    if purpose == "questions"
                    else "DEEPSEEK_ANSWER_MODEL"
                ),
                "deepseek-chat",
            )
        model = model.strip()
        key = environment.get("DEEPSEEK_API_KEY", "").strip()
        if not key:
            raise RuntimeError(
                f"AI 工作流 {purpose} 使用 DeepSeek 模型 {model or '未指定'}，"
                "请先在 PromptMeet 设置中配置 DeepSeek API Key"
            )
        if not model:
            raise ValueError(f"AI 工作流 {purpose} 请输入 DeepSeek 模型标识")
        base = normalize_deepseek_base_url(
            environment.get("DEEPSEEK_API_BASE", "https://api.deepseek.com")
        )
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
    def _openai_vision_model(model: str) -> bool:
        normalized = model.casefold()
        return normalized.startswith(("gpt-4o", "gpt-4.1", "o3", "o4"))
