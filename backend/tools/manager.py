"""
工具管理器
"""
from typing import Dict, List, Any, Union
from .base import BaseTool, ToolResult
from .calculator import CalculatorTool
from .weather import WeatherTool
from .time_tool import TimeTool
from .translator import TranslatorTool
from .web_search import WebSearchTool
from .summary_tool import SummaryTool
from .feishu_calendar import FeishuCalendarTool


class ToolManager:
    """工具管理器"""
    
    def __init__(self):
        self.tools: Dict[str, BaseTool] = {}
        self._register_default_tools()
    
    def _register_default_tools(self):
        """注册默认工具"""
        self.register_tool(CalculatorTool())
        self.register_tool(WeatherTool())
        self.register_tool(TimeTool())
        self.register_tool(TranslatorTool())
        self.register_tool(WebSearchTool())
        self.register_tool(SummaryTool())
        self.register_tool(FeishuCalendarTool())
    
    def register_tool(self, tool: BaseTool):
        """注册工具"""
        self.tools[tool.name] = tool
    
    async def execute_tool(self, tool_name: str, parameters: Dict[str, Any]) -> ToolResult:
        """执行工具"""
        if tool_name not in self.tools:
            return ToolResult(
                tool_name=tool_name,
                result=None,
                success=False,
                error=f"工具 '{tool_name}' 不存在"
            )
        
        try:
            tool = self.tools[tool_name]
            return await tool.execute(**parameters)
        except Exception as e:
            return ToolResult(
                tool_name=tool_name,
                result=None,
                success=False,
                error=str(e)
            )
    
    def get_available_tools(self) -> List[Dict[str, str]]:
        """获取可用工具列表"""
        return [tool.get_info() for tool in self.tools.values()]
    
    def get_tool(self, tool_name: str) -> Union[BaseTool, None]:
        """获取指定工具"""
        return self.tools.get(tool_name) 