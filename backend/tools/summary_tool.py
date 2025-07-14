"""
摘要生成工具
"""
from typing import Dict, Any
from .base import BaseTool, ToolResult


class SummaryTool(BaseTool):
    """摘要生成工具"""
    
    def __init__(self):
        super().__init__(
            name="summary",
            description="为会议内容生成简洁摘要"
        )
    
    async def execute(self, text: str) -> ToolResult:
        """执行摘要生成"""
        try:
            summary = self._generate_summary(text)
            
            return ToolResult(
                tool_name=self.name,
                result={
                    "original_text": text,
                    "summary": summary,
                    "original_length": len(text),
                    "summary_length": len(summary),
                    "type": "summary"
                },
                success=True
            )
        except Exception as e:
            return ToolResult(
                tool_name=self.name,
                result={
                    "text": text,
                    "error": f"摘要生成错误: {str(e)}",
                    "type": "error"
                },
                success=False,
                error=str(e)
            )
    
    def _generate_summary(self, text: str) -> str:
        """实际的摘要生成逻辑"""
        if len(text) <= 100:
            return f"摘要: {text}"
        return f"摘要: {text[:100]}...[共{len(text)}字符]"
