from datetime import datetime
from langchain.tools import BaseTool
from typing import Optional, Type
from pydantic import BaseModel, Field

class TimeToolInput(BaseModel):
    placeholder: str = Field("", description="无需输入参数")

class TimeTool(BaseTool):
    name = "get_current_time"
    description = "获取当前日期和时间"
    args_schema: Type[BaseModel] = TimeToolInput

    def _run(self, placeholder: str = "") -> str:
        return datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    
    async def _arun(self, placeholder: str = "") -> str:
        return self._run()
