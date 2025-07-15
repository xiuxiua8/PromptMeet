"""
数据库配置模块 - 集中管理所有数据库相关配置
"""
from typing import Dict, Optional
from pydantic import BaseModel, Field
from dotenv import load_dotenv
import os

load_dotenv()  # 加载环境变量

class DatabaseConfig(BaseModel):
    """数据库配置模型"""
    host: str = Field('localhost', description="数据库主机地址")
    user: str = Field('root', description="数据库用户名")
    password: str = Field('root', description="数据库密码")
    database: str = Field('meeting_sessions', description="数据库名称")
    api_base_url: str = Field('http://localhost:8000', description="API基础URL")
    pool_size: int = Field(5, description="连接池大小")
    reconnect_attempts: int = Field(3, description="重连尝试次数")
    charset: str = Field('utf8mb4', description="字符编码")

    @classmethod
    def from_env(cls) -> 'DatabaseConfig':
        """从环境变量创建配置实例"""
        return cls(
            host=os.getenv('DB_HOST', 'localhost'),
            user=os.getenv('DB_USER', 'root'),
            password=os.getenv('DB_PASSWORD', 'root'),
            database=os.getenv('DB_NAME', 'meeting_sessions'),
            api_base_url=os.getenv('API_BASE_URL', 'http://localhost:8000'),
            pool_size=int(os.getenv('DB_POOL_SIZE', '5')),
            reconnect_attempts=int(os.getenv('DB_RECONNECT_ATTEMPTS', '3')),
            charset=os.getenv('DB_CHARSET', 'utf8mb4')
        )

# 全局数据库配置实例
DATABASE_CONFIG: DatabaseConfig = DatabaseConfig.from_env()

def get_database_config() -> DatabaseConfig:
    """获取当前数据库配置"""
    return DATABASE_CONFIG

def update_database_config(new_config: Dict) -> None:
    """更新数据库配置"""
    global DATABASE_CONFIG
    DATABASE_CONFIG = DatabaseConfig(**{**DATABASE_CONFIG.dict(), **new_config})