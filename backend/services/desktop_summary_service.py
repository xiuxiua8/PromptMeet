class OriginalSummaryService:
    def __init__(self, processor_factory=None):
        self.processor_factory = processor_factory

    async def summarize(self, session_id: str, transcript: list) -> dict:
        text = "\n".join(getattr(segment, "text", "") for segment in transcript).strip()
        if not text:
            raise RuntimeError("当前还没有可总结的转写内容")
        factory = self.processor_factory
        if factory is None:
            from processors.summary_processor import SummaryProcessor

            factory = SummaryProcessor
        processor = factory()
        processor.current_session_id = session_id
        result = await processor.process_transcript(text)
        if not result.get("success"):
            raise RuntimeError(result.get("error") or "原摘要处理器执行失败")
        return result["summary"]
