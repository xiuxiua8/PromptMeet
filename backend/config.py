"""
配置文件
"""
import os
from dotenv import load_dotenv

# 加载环境变量
load_dotenv()

class Settings:
    """应用配置类"""
    
    # DeepSeek API配置
    DEEPSEEK_API_KEY: str = os.getenv("DEEPSEEK_API_KEY", "")
    DEEPSEEK_API_BASE: str = os.getenv("DEEPSEEK_API_BASE", "")
    DEEPSEEK_MODEL: str = "deepseek-chat"
    DEEPSEEK_TEMPERATURE: float = 0.3
    DEEPSEEK_MAX_TOKENS: int = 1000
    
    # OpenAI API配置（用于嵌入）
    OPENAI_API_KEY: str = os.getenv("OPENAI_API_KEY", "")
    
    # 天气API配置
    OPENWEATHER_API_KEY: str = os.getenv("OPENWEATHER_API_KEY", "")
    
    # 飞书API配置
    FEISHU_USER_ACCESS_TOKEN: str = os.getenv("FEISHU_USER_ACCESS_TOKEN", "")
    FEISHU_CALENDAR_ID: str = os.getenv("FEISHU_CALENDAR_ID", "")
    
    # CORS配置
    ALLOWED_ORIGINS: list = [
        "http://localhost:5173",
        "http://127.0.0.1:5173",
        "http://localhost:3000",
        "http://127.0.0.1:3000"
    ]
    
    # 应用配置
    APP_TITLE: str = "PromptMeet API"
    APP_DESCRIPTION: str = "智能会议助手API"
    APP_VERSION: str = "1.0.0"
    
    @classmethod
    def validate_config(cls):
        """验证配置"""
        if not cls.DEEPSEEK_API_KEY:
            raise ValueError("DeepSeek API密钥未配置，请在.env文件中设置DEEPSEEK_API_KEY")
        if not cls.DEEPSEEK_API_BASE:
            raise ValueError("DeepSeek API基础URL未配置，请在.env文件中设置DEEPSEEK_API_BASE")
        if not cls.OPENAI_API_KEY:
            raise ValueError("OpenAI API密钥未配置，请在.env文件中设置OPENAI_API_KEY")

# 全局配置实例
settings = Settings()

# 验证配置
try:
    settings.validate_config()
except ValueError as e:
    print(f"配置错误: {e}")
    print("请在backend/.env文件中设置相应的API密钥") 