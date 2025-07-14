"""
网络搜索工具
"""
import requests
from typing import Dict, Any
from .base import BaseTool, ToolResult


class WebSearchTool(BaseTool):
    """网络搜索工具"""
    
    def __init__(self):
        super().__init__(
            name="web_search",
            description="网络搜索相关信息"
        )
    
    async def execute(self, query: str) -> ToolResult:
        """执行网络搜索"""
        try:
            # 使用DuckDuckGo API进行搜索
            url = f"https://api.duckduckgo.com/?q={query}&format=json&no_html=1&skip_disambig=1"
            response = requests.get(url, timeout=10)
            
            if response.status_code == 200:
                data = response.json()
                return ToolResult(
                    tool_name=self.name,
                    result={
                        "query": query,
                        "abstract": data.get("Abstract", "未找到相关信息"),
                        "related_topics": [topic.get("Text", "") for topic in data.get("RelatedTopics", [])[:3]],
                        "type": "search"
                    },
                    success=True
                )
            else:
                return ToolResult(
                    tool_name=self.name,
                    result={
                        "query": query,
                        "error": f"搜索失败: {response.status_code}",
                        "type": "error"
                    },
                    success=False,
                    error=f"搜索失败: {response.status_code}"
                )
        except Exception as e:
            return ToolResult(
                tool_name=self.name,
                result={
                    "query": query,
                    "error": f"搜索错误: {str(e)}",
                    "type": "error"
                },
                success=False,
                error=str(e)
            ) 