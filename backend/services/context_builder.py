from __future__ import annotations

import math
import re
from dataclasses import dataclass
from datetime import UTC
from typing import Callable

from models.meeting_context import (
    AnswerPayload,
    EventKind,
    EvidenceSource,
    MeetingEvent,
    MeetingRecord,
    QuestionPayload,
    ScreenshotAnalysisPayload,
    ScreenshotPayload,
    SummaryPayload,
    TranscriptPayload,
)


@dataclass(frozen=True)
class ContextBudget:
    total_tokens: int = 8_000
    answer_reserve: int = 2_000
    summary_reserve: int = 500

    @property
    def evidence_tokens(self) -> int:
        return max(0, self.total_tokens - self.answer_reserve)


@dataclass(frozen=True)
class ContextSelection:
    meeting_id: str
    events: list[MeetingEvent]
    sources: list[EvidenceSource]
    estimated_tokens: int
    omitted_count: int
    derived_summary: str | None


class MeetingContextBuilder:
    def __init__(self, token_estimator: Callable[[str], int] | None = None):
        self.token_estimator = token_estimator or self._estimate_tokens

    def select(
        self,
        record: MeetingRecord,
        question: str,
        budget: ContextBudget,
        *,
        thread_id: str = "main",
        exclude_event_ids: set[str] | None = None,
    ) -> ContextSelection:
        excluded = exclude_event_ids or set()
        include_lifecycle = self._lifecycle_query(question)
        candidates = [
            event
            for event in record.events
            if event.event_id not in excluded
            and self._belongs_to_thread(event, thread_id)
            and (event.kind != EventKind.LIFECYCLE or include_lifecycle)
        ]
        available = budget.evidence_tokens
        reserved_summary = min(budget.summary_reserve, available // 4)
        event_budget = max(0, available - reserved_summary)
        ranked = sorted(
            candidates,
            key=lambda event: self._rank(event, question, len(record.events)),
            reverse=True,
        )
        screenshots_by_asset = {
            event.payload.asset_id: event
            for event in candidates
            if isinstance(event.payload, ScreenshotPayload)
        }
        selected: list[MeetingEvent] = []
        selected_ids: set[str] = set()
        spent = 0
        for candidate in ranked:
            if candidate.event_id in selected_ids:
                continue
            bundle = [candidate]
            if isinstance(candidate.payload, ScreenshotAnalysisPayload):
                screenshot = screenshots_by_asset.get(candidate.payload.asset_id)
                if screenshot is not None and screenshot.event_id not in selected_ids:
                    bundle.append(screenshot)
            bundle_cost = sum(self.token_estimator(self.render_event(event)) for event in bundle)
            if bundle_cost <= event_budget - spent:
                selected.extend(bundle)
                selected_ids.update(event.event_id for event in bundle)
                spent += bundle_cost
                continue
            candidate_cost = self.token_estimator(self.render_event(candidate))
            if candidate_cost <= event_budget - spent:
                selected.append(candidate)
                selected_ids.add(candidate.event_id)
                spent += candidate_cost

        selected = sorted(selected, key=lambda event: (event.sequence, event.occurred_at, event.event_id))
        omitted = [event for event in candidates if event.event_id not in selected_ids]
        summary = self._compress(omitted, max(0, available - spent)) if omitted else None
        summary_cost = self.token_estimator(summary) if summary else 0
        sources = [
            EvidenceSource(
                source_id=f"M{event.sequence}",
                event_id=event.event_id,
                label=self._source_label(event),
            )
            for event in selected
        ]
        return ContextSelection(
            meeting_id=record.meeting_id,
            events=selected,
            sources=sources,
            estimated_tokens=spent + summary_cost,
            omitted_count=len(omitted),
            derived_summary=summary,
        )

    @staticmethod
    def render_event(event: MeetingEvent) -> str:
        payload = event.payload
        if isinstance(payload, TranscriptPayload):
            return f"{payload.speaker}：{payload.text}"
        if isinstance(payload, ScreenshotPayload):
            return f"截图资产 {payload.asset_id} ({payload.mime_type})"
        if isinstance(payload, ScreenshotAnalysisPayload):
            return f"截图分析：{payload.text}"
        if isinstance(payload, QuestionPayload):
            return f"用户问题：{payload.question}"
        if isinstance(payload, AnswerPayload):
            return f"AI 回答：{payload.answer}"
        if isinstance(payload, SummaryPayload):
            return f"会议摘要：{payload.summary_text}"
        detail = getattr(payload, "detail", None)
        return f"会议状态：{getattr(payload, 'status', '')} {detail or ''}".strip()

    @staticmethod
    def _belongs_to_thread(event: MeetingEvent, thread_id: str) -> bool:
        payload = event.payload
        if isinstance(payload, (QuestionPayload, AnswerPayload)):
            return payload.thread_id == thread_id
        return True

    def _rank(self, event: MeetingEvent, question: str, event_count: int) -> tuple[float, int]:
        normalized_question = self._normalize(question)
        rendered = self._normalize(self.render_event(event))
        terms = self._terms(normalized_question)
        relevance = sum(1 for term in terms if term and term in rendered)
        recency = event.sequence / max(1, event_count)
        kind_weight = {
            EventKind.SUMMARY: 28,
            EventKind.SCREENSHOT_ANALYSIS: 24,
            EventKind.SCREENSHOT: 20,
            EventKind.ASSISTANT_ANSWER: 14,
            EventKind.USER_QUESTION: 13,
            EventKind.TRANSCRIPT: 10,
            EventKind.LIFECYCLE: 1,
        }[event.kind]
        visual_query = any(term in normalized_question for term in ("截图", "图片", "图上", "画面", "屏幕"))
        visual_bonus = 80 if visual_query and event.kind in {
            EventKind.SCREENSHOT,
            EventKind.SCREENSHOT_ANALYSIS,
        } else 0
        return relevance * 100 + visual_bonus + kind_weight + recency, event.sequence

    def _compress(self, omitted: list[MeetingEvent], token_limit: int) -> str | None:
        if token_limit <= 0:
            return None
        summaries = [self.render_event(event) for event in omitted if event.kind != EventKind.SCREENSHOT]
        if not summaries:
            return None
        value = "较早内容摘要：" + "；".join(summaries)
        while value and self.token_estimator(value) > token_limit:
            value = value[:-1]
        return value.rstrip("；：") or None

    @staticmethod
    def _source_label(event: MeetingEvent) -> str:
        label = {
            EventKind.LIFECYCLE: "会议状态",
            EventKind.TRANSCRIPT: "会议转写",
            EventKind.SCREENSHOT: "会议截图",
            EventKind.SCREENSHOT_ANALYSIS: "截图分析",
            EventKind.USER_QUESTION: "历史问题",
            EventKind.ASSISTANT_ANSWER: "历史回答",
            EventKind.SUMMARY: "会议摘要",
        }[event.kind]
        timestamp = event.occurred_at.astimezone(UTC).strftime("%m-%d %H:%M UTC")
        return f"{label} · {timestamp}"

    @classmethod
    def _lifecycle_query(cls, question: str) -> bool:
        normalized = cls._normalize(question)
        return any(
            term in normalized
            for term in ("开始", "创建", "结束", "完成", "状态", "中断", "完整", "保存")
        )

    @staticmethod
    def _normalize(value: str) -> str:
        return " ".join(value.casefold().split())

    @staticmethod
    def _terms(value: str) -> set[str]:
        words = set(re.findall(r"[a-z0-9_]+", value))
        chinese = "".join(character for character in value if "\u4e00" <= character <= "\u9fff")
        words.update(chinese[index : index + 2] for index in range(max(0, len(chinese) - 1)))
        return words

    @staticmethod
    def _estimate_tokens(value: str) -> int:
        if not value:
            return 0
        ascii_words = len(re.findall(r"[A-Za-z0-9_]+", value))
        non_ascii = sum(1 for character in value if ord(character) > 127)
        punctuation = max(0, len(value) - non_ascii) // 12
        return max(1, math.ceil(non_ascii * 0.9) + ascii_words + punctuation)
