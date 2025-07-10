from langchain.tools import BaseTool
from typing import Optional, Type
from pydantic import BaseModel, Field

class SummaryToolInput(BaseModel):
    text: str = Field(..., description="需要生成摘要的文本内容")

class SummaryTool(BaseTool):
    name = "generate_summary"
    description = "为会议内容生成简洁摘要"
    args_schema: Type[BaseModel] = SummaryToolInput

    def _run(self, text: str) -> str:
        return self._generate_summary(text)
    
    async def _arun(self, text: str) -> str:
        return self._generate_summary(text)
    
    def _generate_summary(self, text: str) -> str:
        if len(text) <= 100:
            return f"摘要: {text}"
        return f"摘要: {text[:100]}...[共{len(text)}字符]"
