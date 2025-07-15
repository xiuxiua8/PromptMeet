"""
时间查询工具
"""
import datetime
from typing import Dict, Any
from .base import BaseTool, ToolResult


class TimeTool(BaseTool):
    """时间查询工具"""
    
    def __init__(self):
        super().__init__(
            name="time",
            description="获取当前时间"
        )
    
    async def execute(self, timezone: str = "Asia/Shanghai") -> ToolResult:
        """执行时间查询"""
        try:
            import pytz
            import datetime
            now = datetime.datetime.now(pytz.timezone(timezone))
            msg = f"现在是北京时间{now.strftime('%Y年%m月%d日 %H:%M:%S')}"
            return ToolResult(
                tool_name=self.name,
                result={
                    "current_time": now.strftime("%Y-%m-%d %H:%M:%S"),
                    "message": msg
                },
                success=True
            )
        except Exception as e:
            return ToolResult(
                tool_name=self.name,
                result={"error": str(e)},
                success=False,
                error=str(e)
            )
