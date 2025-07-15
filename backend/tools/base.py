"""
基础工具类
"""
from abc import ABC, abstractmethod
from typing import Dict, Any, Optional
from pydantic import BaseModel


class ToolResult(BaseModel):
    """工具执行结果模型"""
    tool_name: str
    result: Optional[Any] = None
    success: bool = True
    error: Optional[str] = None


class BaseTool(ABC):
    """工具基类"""
    
    def __init__(self, name: str, description: str):
        self.name = name
        self.description = description
    
    @abstractmethod
    async def execute(self, **parameters) -> ToolResult:
        """执行工具"""
        pass
    
    def get_info(self) -> Dict[str, str]:
        """获取工具信息"""
        return {
            "name": self.name,
            "description": self.description
        } 