from datetime import datetime
from langchain.tools import BaseTool
from typing import Optional, Type, ClassVar
from pydantic import BaseModel, Field

class TimeToolInput(BaseModel):
    placeholder: str = Field("", description="无需输入参数")

class TimeTool(BaseTool):
    name: ClassVar[str] = "get_current_time"  # 添加类型注解
    description: ClassVar[str] = "获取当前日期和时间"  # 同样修复description
    args_schema: ClassVar[Type[BaseModel]] = TimeToolInput  # 添加类型注解

    def _run(self, placeholder: str = "") -> str:
        """同步执行方法"""
        return datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    
    async def _arun(self, placeholder: str = "") -> str:
        """异步执行方法"""
        return self._run()
