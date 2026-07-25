from __future__ import annotations

import base64
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Awaitable, Callable

import httpx


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
                "gpt-4o-mini" if purpose == "questions" else "gpt-4o",
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


class OpenAICompatibleModelProvider:
    def __init__(
        self,
        configuration: ProviderConfiguration,
        assets_root: str | Path,
        client_factory: Callable[..., httpx.AsyncClient] = httpx.AsyncClient,
    ):
        self.configuration = configuration
        self.assets_root = Path(assets_root).resolve()
        self.client_factory = client_factory

    async def stream_answer(
        self,
        request,
        emit: Callable[[str], Awaitable[None]],
    ) -> str:
        messages = [self._message(message) for message in request.messages]
        content_parts: list[str] = []
        async with self.client_factory(timeout=90) as client:
            async with client.stream(
                "POST",
                self.configuration.endpoint,
                headers={"Authorization": f"Bearer {self.configuration.api_key}"},
                json={
                    "model": self.configuration.model,
                    "messages": messages,
                    "stream": True,
                    "temperature": 0.2,
                },
            ) as response:
                response.raise_for_status()
                async for line in response.aiter_lines():
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if not data or data == "[DONE]":
                        continue
                    payload = json.loads(data)
                    choices = payload.get("choices") or []
                    delta = (choices[0].get("delta") or {}) if choices else {}
                    content = delta.get("content")
                    if isinstance(content, str) and content:
                        content_parts.append(content)
                        await emit(content)
        return "".join(content_parts)

    def _message(self, message) -> dict[str, object]:
        if isinstance(message.content, str):
            return {"role": message.role, "content": message.content}
        parts: list[dict[str, object]] = []
        for part in message.content:
            if part.type == "text":
                parts.append({"type": "text", "text": part.text or ""})
            elif part.type == "image_asset":
                data = self._asset_data(part.relative_path or "")
                mime_type = part.mime_type or "image/png"
                parts.append(
                    {
                        "type": "image_url",
                        "image_url": {
                            "url": f"data:{mime_type};base64,{base64.b64encode(data).decode('ascii')}"
                        },
                    }
                )
        return {"role": message.role, "content": parts}

    def _asset_data(self, relative_path: str) -> bytes:
        path = (self.assets_root / relative_path).resolve()
        if self.assets_root not in path.parents or not path.is_file():
            raise FileNotFoundError("截图资源不可用")
        return path.read_bytes()
