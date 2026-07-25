import json
import os
from collections.abc import Awaitable, Callable

import httpx


class DesktopAgentService:
    def __init__(self, environment: dict[str, str] | None = None):
        self.environment = os.environ if environment is None else environment

    async def answer(
        self,
        prompt: str,
        transcript: list,
        emit: Callable[[dict], Awaitable[None]],
    ) -> None:
        endpoint, api_key, model = self._provider("answer")
        context = "\n".join(
            f"{getattr(item, 'speaker', None) or '发言人'}：{getattr(item, 'text', '')}"
            for item in transcript[-30:]
        )
        messages = [
            {"role": "system", "content": "你是克制、准确的会议助手。只根据会议上下文回答，信息不足时明确说明。"},
            {"role": "user", "content": f"会议上下文：\n{context or '暂无转写'}\n\n用户问题：{prompt}"},
        ]
        answer = ""
        async with httpx.AsyncClient(timeout=90) as client:
            async with client.stream(
                "POST",
                endpoint,
                headers={"Authorization": f"Bearer {api_key}"},
                json={"model": model, "messages": messages, "stream": True, "temperature": 0.2},
            ) as response:
                response.raise_for_status()
                async for line in response.aiter_lines():
                    if not line.startswith("data: ") or line == "data: [DONE]":
                        continue
                    payload = json.loads(line[6:])
                    delta = payload.get("choices", [{}])[0].get("delta", {}).get("content")
                    if not delta:
                        continue
                    answer += delta
                    await emit({"data": {"delta": delta}})
        await emit({"data": {"content": answer}})

    async def summarize(self, transcript: list) -> str:
        text = "\n".join(getattr(item, "text", "") for item in transcript).strip()
        if not text:
            return "当前还没有可总结的转写内容。"
        try:
            result: list[str] = []

            async def collect(message: dict) -> None:
                content = message.get("data", {}).get("content")
                if content is not None:
                    result.append(content)

            await self.answer("请生成简洁会议摘要，包含关键结论和待办。", transcript, collect)
            return result[-1] if result else text[:600]
        except Exception:
            return text if len(text) <= 600 else f"{text[:600]}…"

    async def generate_questions(self, transcript: list) -> list[dict]:
        endpoint, api_key, model = self._provider("questions")
        context = "\n".join(
            f"{getattr(item, 'speaker', None) or '发言人'}：{getattr(item, 'text', '')}"
            for item in transcript[-50:]
        )
        async with httpx.AsyncClient(timeout=60) as client:
            response = await client.post(
                endpoint,
                headers={"Authorization": f"Bearer {api_key}"},
                json={
                    "model": model,
                    "messages": [
                        {
                            "role": "system",
                            "content": (
                                "从会议记录中找出2到3个尚未解决、值得继续追问的问题。"
                                "只输出JSON数组，每项格式为{\"question\":\"问题\"}。"
                            ),
                        },
                        {"role": "user", "content": context},
                    ],
                    "stream": False,
                    "temperature": 0.2,
                },
            )
            response.raise_for_status()
            content = response.json()["choices"][0]["message"]["content"].strip()
        if content.startswith("```"):
            content = content.split("\n", 1)[1].rsplit("```", 1)[0].strip()
        questions = json.loads(content)
        return [
            {"question": item["question"].strip()}
            for item in questions[:3]
            if isinstance(item, dict) and isinstance(item.get("question"), str) and item["question"].strip()
        ]

    async def translate(self, text: str, target_language: str) -> str:
        endpoint, api_key, model = self._provider("answer")
        language_names = {
            "zh": "简体中文",
            "en": "English",
            "ja": "日本語",
            "ko": "한국어",
        }
        target = language_names.get(target_language, target_language)
        async with httpx.AsyncClient(timeout=60) as client:
            response = await client.post(
                endpoint,
                headers={"Authorization": f"Bearer {api_key}"},
                json={
                    "model": model,
                    "messages": [
                        {
                            "role": "system",
                            "content": f"将用户文本准确翻译为{target}。只输出译文，不解释。",
                        },
                        {"role": "user", "content": text},
                    ],
                    "stream": False,
                    "temperature": 0,
                },
            )
            response.raise_for_status()
            payload = response.json()
        return payload["choices"][0]["message"]["content"].strip()

    def _provider(self, purpose: str = "answer") -> tuple[str, str, str]:
        preferred_provider = self.environment.get("PROMPTMEET_AI_PROVIDER", "").lower()
        deepseek_key = self.environment.get("DEEPSEEK_API_KEY")
        openai_key = self.environment.get("OPENAI_API_KEY")
        if preferred_provider == "openai" and openai_key:
            model = (
                self.environment.get("OPENAI_QUESTION_MODEL", "gpt-4o-mini")
                if purpose == "questions"
                else self.environment.get(
                    "OPENAI_ANSWER_MODEL",
                    self.environment.get("OPENAI_CHAT_MODEL", "gpt-4o"),
                )
            )
            return (
                "https://api.openai.com/v1/chat/completions",
                openai_key,
                model,
            )
        if deepseek_key:
            base = self.environment.get("DEEPSEEK_API_BASE", "https://api.deepseek.com").rstrip("/")
            model = (
                self.environment.get("DEEPSEEK_QUESTION_MODEL", "deepseek-v4-flash")
                if purpose == "questions"
                else self.environment.get(
                    "DEEPSEEK_ANSWER_MODEL",
                    self.environment.get("DEEPSEEK_MODEL", "deepseek-v4-pro"),
                )
            )
            return f"{base}/chat/completions", deepseek_key, model
        if openai_key:
            model = (
                self.environment.get("OPENAI_QUESTION_MODEL", "gpt-4o-mini")
                if purpose == "questions"
                else self.environment.get(
                    "OPENAI_ANSWER_MODEL",
                    self.environment.get("OPENAI_CHAT_MODEL", "gpt-4o"),
                )
            )
            return (
                "https://api.openai.com/v1/chat/completions",
                openai_key,
                model,
            )
        raise RuntimeError("请先在 PromptMeet 设置中将 AI Key 存入 Keychain")

    def provider_status(self) -> dict[str, object]:
        try:
            endpoint, _, answer_model = self._provider("answer")
            _, _, question_model = self._provider("questions")
        except RuntimeError:
            return {"configured": False, "provider": None, "model": None}
        provider = "openai" if "api.openai.com" in endpoint else "deepseek"
        return {
            "configured": True,
            "provider": provider,
            "model": answer_model,
            "answer_model": answer_model,
            "question_model": question_model,
        }
