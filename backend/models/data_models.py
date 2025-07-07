"""
数据模型定义
定义所有用于前后端通信和数据存储的模型
"""

from pydantic import BaseModel, Field
from typing import List, Optional, Dict, Any
from datetime import datetime
from enum import Enum

class MessageType(str, Enum):
    """WebSocket消息类型枚举"""
    # 连接相关
    CONNECTION_ESTABLISHED = "connection_established"
    PING = "ping"
    PONG = "pong"
    
    # 音频录制相关
    AUDIO_START = "audio_start"
    AUDIO_STOP = "audio_stop"
    AUDIO_TRANSCRIPT = "audio_transcript"
    
    # 分析相关
    SUMMARY_GENERATED = "summary_generated"
    TASK_EXTRACTED = "task_extracted"
    
    # 进度和状态
    PROGRESS_UPDATE = "progress_update"
    STATUS_UPDATE = "status_update"
    
    # 错误处理
    ERROR = "error"
    WARNING = "warning"

class WebSocketMessage(BaseModel):
    """WebSocket消息统一格式"""
    type: MessageType
    data: Dict[str, Any]
    timestamp: datetime
    session_id: str

class TranscriptSegment(BaseModel):
    """音频转录片段"""
    id: str = Field(..., description="片段唯一标识")
    text: str = Field(..., description="转录文本")
    timestamp: datetime = Field(..., description="生成时间")
    confidence: float = Field(0.0, ge=0.0, le=1.0, description="置信度")
    speaker: Optional[str] = Field(None, description="说话人标识")
    start_time: Optional[float] = Field(None, description="音频开始时间(秒)")
    end_time: Optional[float] = Field(None, description="音频结束时间(秒)")

class TaskItem(BaseModel):
    """任务项"""
    task: str = Field(..., description="任务内容")
    deadline: Optional[str] = Field(None, description="截止日期")
    describe: str = Field("", description="任务详细描述")
    priority: str = Field("medium", description="优先级: high/medium/low")
    assignee: Optional[str] = Field(None, description="负责人")
    status: str = Field("pending", description="状态: pending/in_progress/completed")

class MeetingSummary(BaseModel):
    """会议摘要"""
    session_id: str = Field(..., description="会话ID")
    summary_text: str = Field(..., description="摘要文本")
    tasks: List[TaskItem] = Field(default_factory=list, description="提取的任务列表")
    key_points: List[str] = Field(default_factory=list, description="关键要点")
    decisions: List[str] = Field(default_factory=list, description="决策内容")
    generated_at: datetime = Field(..., description="生成时间")

class SessionState(BaseModel):
    """会话状态"""
    session_id: str = Field(..., description="会话唯一标识")
    is_recording: bool = Field(False, description="是否正在录音")
    start_time: datetime = Field(..., description="会话开始时间")
    end_time: Optional[datetime] = Field(None, description="会话结束时间")
    transcript_segments: List[TranscriptSegment] = Field(default_factory=list, description="转录片段列表")
    current_summary: Optional[MeetingSummary] = Field(None, description="当前摘要")
    participant_count: int = Field(1, description="参与人数")
    audio_file_path: Optional[str] = Field(None, description="音频文件路径")

class ProgressUpdate(BaseModel):
    """进度更新"""
    session_id: str = Field(..., description="会话ID")
    module: str = Field(..., description="模块名称: whisper/summary/export")
    progress: float = Field(..., ge=0.0, le=100.0, description="进度百分比")
    message: str = Field(..., description="进度描述")
    status: str = Field(..., description="状态: running/completed/error")
    details: Optional[Dict[str, Any]] = Field(None, description="额外详情")

class ProcessStatus(BaseModel):
    """进程状态"""
    process_id: str = Field(..., description="进程ID")
    module_name: str = Field(..., description="模块名称")
    session_id: str = Field(..., description="关联的会话ID")
    status: str = Field(..., description="状态: starting/running/stopped/error")
    pid: Optional[int] = Field(None, description="系统进程ID")
    start_time: datetime = Field(..., description="启动时间")
    last_update: datetime = Field(..., description="最后更新时间")

class APIResponse(BaseModel):
    """API响应统一格式"""
    success: bool = Field(..., description="操作是否成功")
    message: str = Field("", description="响应消息")
    data: Optional[Any] = Field(None, description="响应数据")
    error_code: Optional[str] = Field(None, description="错误代码")
    timestamp: datetime = Field(default_factory=datetime.now, description="响应时间")

class AudioSettings(BaseModel):
    """音频配置"""
    sample_rate: int = Field(16000, description="采样率")
    chunk_size: int = Field(1024, description="音频块大小")
    segment_duration: float = Field(10.0, description="自动提交间隔(秒)")
    language: str = Field("zh", description="识别语言")
    device_id: Optional[int] = Field(None, description="音频设备ID")

class SummarySettings(BaseModel):
    """摘要生成配置"""
    model_name: str = Field("deepseek-chat", description="使用的LLM模型")
    temperature: float = Field(0.2, description="生成温度")
    max_tokens: int = Field(2000, description="最大令牌数")
    chunk_size: int = Field(1200, description="文本分块大小")
    chunk_overlap: int = Field(200, description="分块重叠大小")

class ExportRequest(BaseModel):
    """导出请求"""
    session_id: str = Field(..., description="会话ID")
    format: str = Field(..., description="导出格式: markdown/json/txt")
    include_audio: bool = Field(False, description="是否包含音频文件")
    output_path: Optional[str] = Field(None, description="输出路径")

class ExportResult(BaseModel):
    """导出结果"""
    session_id: str = Field(..., description="会话ID")
    format: str = Field(..., description="导出格式")
    file_path: str = Field(..., description="导出文件路径")
    file_size: int = Field(..., description="文件大小(字节)")
    exported_at: datetime = Field(..., description="导出时间")

# ============= IPC 通信模型 =============

class IPCMessage(BaseModel):
    """进程间通信消息格式"""
    message_id: str = Field(..., description="消息ID")
    message_type: str = Field(..., description="消息类型")
    session_id: str = Field(..., description="会话ID")
    data: Dict[str, Any] = Field(..., description="消息数据")
    timestamp: datetime = Field(default_factory=datetime.now, description="时间戳")

class IPCCommand(BaseModel):
    """IPC命令"""
    command: str = Field(..., description="命令类型: start/stop/status")
    session_id: str = Field(..., description="会话ID")
    params: Dict[str, Any] = Field(default_factory=dict, description="命令参数")

class IPCResponse(BaseModel):
    """IPC响应"""
    success: bool = Field(..., description="执行是否成功")
    data: Optional[Any] = Field(None, description="响应数据")
    error: Optional[str] = Field(None, description="错误信息")
    timestamp: datetime = Field(default_factory=datetime.now, description="响应时间") 