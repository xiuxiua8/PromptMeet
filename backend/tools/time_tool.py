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
            tz = pytz.timezone(timezone)
            current_time = datetime.datetime.now(tz)
            
            return ToolResult(
                tool_name=self.name,
                result={
                    "timezone": timezone,
                    "current_time": current_time.strftime("%Y-%m-%d %H:%M:%S"),
                    "date": current_time.strftime("%Y-%m-%d"),
                    "time": current_time.strftime("%H:%M:%S"),
                    "day_of_week": current_time.strftime("%A"),
                    "type": "time"
                },
                success=True
            )
        except Exception as e:
            return ToolResult(
                tool_name=self.name,
                result={
                    "timezone": timezone,
                    "error": f"时间查询错误: {str(e)}",
                    "type": "error"
                },
                success=False,
                error=str(e)
            )
