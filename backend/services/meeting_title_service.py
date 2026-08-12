from __future__ import annotations

import re
from collections.abc import Awaitable, Callable, Iterable

from models.meeting_context import (
    MeetingRecord,
    SummaryPayload,
    TranscriptPayload,
)
from services.meeting_repository import MeetingNotFoundError, MeetingRepository

TitleGenerator = Callable[[MeetingRecord], Awaitable[str]]


class MeetingTitleService:
    MAX_TITLE_LENGTH = 18
    GENERIC_TITLES = {
        "会议",
        "会议记录",
        "会议总结",
        "历史会议",
        "新会议",
        "未命名会议",
    }
    FILLER_CONTENT = {
        "ok",
        "okay",
        "um",
        "嗯",
        "好",
        "好的",
        "对",
        "是",
        "是的",
        "行",
    }

    def __init__(
        self,
        repository: MeetingRepository,
        generator: TitleGenerator | None = None,
    ) -> None:
        self.repository = repository
        self.generator = generator

    def persist_fallback(self, meeting_id: str) -> str:
        record = self._required(meeting_id)
        existing = self.normalize_generated_title(record.title or "")
        title = existing or self.fallback_title(record)
        if record.title != title:
            self.repository.set_title(meeting_id, title)
        return title

    async def finalize(self, meeting_id: str) -> str:
        fallback = self.persist_fallback(meeting_id)
        record = self._required(meeting_id)
        if self.generator is None or not self._content_candidates(record):
            return fallback
        try:
            generated = await self.generator(record)
        except Exception:
            return fallback
        title = self.normalize_generated_title(generated) or fallback
        if title != record.title:
            self.repository.set_title(meeting_id, title)
        return title

    def fallback_title(self, record: MeetingRecord) -> str:
        for candidate in self._content_candidates(record):
            title = self.normalize_generated_title(candidate)
            if title:
                return title
        return record.started_at.strftime("%Y%m%d %H:%M 空会议")

    @classmethod
    def normalize_generated_title(cls, value: str) -> str | None:
        title = cls._concise_candidate(value)
        if not title or cls._normalized_key(title) in cls.GENERIC_TITLES:
            return None
        return title

    @classmethod
    def _concise_candidate(cls, value: object) -> str | None:
        if not isinstance(value, str):
            return None
        plain = re.sub(r"```.*?```", " ", value, flags=re.DOTALL)
        plain = re.sub(r"\[([^\]]+)]\([^)]+\)", r"\1", plain)
        plain = re.sub(r"^(?:会议)?标题\s*[:：]\s*", "", plain.strip())
        plain = re.sub(r"^(?:#{1,6}|[>*+\-])\s+", "", plain)
        plain = re.sub(r"^\d+[.)]\s+", "", plain)
        plain = re.sub(r"^\[[ xX]]\s*", "", plain)
        plain = re.sub(r"[*_`~]", "", plain)
        plain = re.sub(r"\s+", " ", plain).strip(" \t\r\n'\"“”‘’")
        plain = re.split(r"[。！？!?\n]", plain, maxsplit=1)[0]
        plain = plain.strip(" ，,、；;：:.。")
        if not cls._is_meaningful(plain):
            return None
        return plain[: cls.MAX_TITLE_LENGTH]

    @classmethod
    def _is_meaningful(cls, value: str) -> bool:
        key = cls._normalized_key(value)
        return len(key) >= 2 and key not in cls.FILLER_CONTENT

    @staticmethod
    def _normalized_key(value: str) -> str:
        return "".join(value.casefold().split())

    @staticmethod
    def _content_candidates(record: MeetingRecord) -> list[str]:
        ordered_events = sorted(
            record.events,
            key=lambda event: (event.sequence, event.occurred_at),
        )
        transcripts = [
            event.payload.text
            for event in ordered_events
            if isinstance(event.payload, TranscriptPayload)
        ]
        summaries = [
            event.payload
            for event in ordered_events
            if isinstance(event.payload, SummaryPayload)
        ]
        summary_content: list[str] = []
        for summary in reversed(summaries):
            summary_content.append(summary.summary_text)
            summary_content.extend(summary.decisions)
            summary_content.extend(MeetingTitleService._task_titles(summary.tasks))
        return [*transcripts, *summary_content]

    @staticmethod
    def _task_titles(tasks: Iterable[dict]) -> list[str]:
        return [
            str(task.get("task") or "")
            for task in tasks
            if isinstance(task, dict) and str(task.get("task") or "").strip()
        ]

    def _required(self, meeting_id: str) -> MeetingRecord:
        record = self.repository.get(meeting_id)
        if record is None:
            raise MeetingNotFoundError(meeting_id)
        return record
