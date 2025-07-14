from langchain.tools import BaseTool
from typing import Optional, Type, ClassVar
from pydantic import BaseModel, Field


class SummaryToolInput(BaseModel):
    text: str = Field(..., description="需要生成摘要的文本内容")


class SummaryTool(BaseTool):
    name: ClassVar[str] = "generate_summary"  # 添加类型注解
    description: ClassVar[str] = "为会议内容生成简洁摘要"  # 添加类型注解
    args_schema: ClassVar[Type[BaseModel]] = SummaryToolInput  # 添加类型注解

    def _run(self, text: str) -> str:
        """同步执行方法"""
        return self._generate_summary(text)

    async def _arun(self, text: str) -> str:
        """异步执行方法"""
        return self._generate_summary(text)

    def _generate_summary(self, text: str) -> str:
        """实际的摘要生成逻辑"""
        if len(text) <= 100:
            return f"摘要: {text}"
        return f"摘要: {text[:100]}...[共{len(text)}字符]"
