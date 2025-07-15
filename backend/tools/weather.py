"""
天气查询工具
"""
import requests
import os
from typing import Dict, Any
from .base import BaseTool, ToolResult
from config import settings


class WeatherTool(BaseTool):
    """天气查询工具"""
    
    def __init__(self):
        super().__init__(
            name="weather",
            description="获取天气信息"
        )
    
    async def execute(self, city: str) -> ToolResult:
        """执行天气查询"""
        try:
            # 检查API密钥
            api_key = settings.OPENWEATHER_API_KEY
            if not api_key:
                return ToolResult(
                    tool_name=self.name,
                    result={
                        "city": city,
                        "error": "天气API密钥未配置",
                        "type": "error"
                    },
                    success=False,
                    error="天气API密钥未配置"
                )
            
            # 调用OpenWeatherMap API
            url = f"http://api.openweathermap.org/data/2.5/weather?q={city}&appid={api_key}&units=metric&lang=zh_cn"
            response = requests.get(url, timeout=10)
            
            if response.status_code == 200:
                data = response.json()
                return ToolResult(
                    tool_name=self.name,
                    result={
                        "city": city,
                        "temperature": data["main"]["temp"],
                        "description": data["weather"][0]["description"],
                        "humidity": data["main"]["humidity"],
                        "wind_speed": data["wind"]["speed"],
                        "type": "weather"
                    },
                    success=True
                )
            else:
                return ToolResult(
                    tool_name=self.name,
                    result={
                        "city": city,
                        "error": f"获取天气信息失败: {response.status_code}",
                        "type": "error"
                    },
                    success=False,
                    error=f"获取天气信息失败: {response.status_code}"
                )
        except Exception as e:
            return ToolResult(
                tool_name=self.name,
                result={
                    "city": city,
                    "error": f"天气查询错误: {str(e)}",
                    "type": "error"
                },
                success=False,
                error=str(e)
            ) 