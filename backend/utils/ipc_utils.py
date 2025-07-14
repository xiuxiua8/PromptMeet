"""
IPC 进程间通信工具
提供进程间通信的统一接口和工具函数
"""

import json
import asyncio
import logging
import queue
import threading
from typing import Dict, Any, Optional, Callable
from datetime import datetime
import uuid

from ..models.data_models import IPCMessage, IPCCommand, IPCResponse

logger = logging.getLogger(__name__)


class IPCManager:
    """IPC通信管理器"""

    def __init__(self):
        self.message_handlers: Dict[str, Callable] = {}
        self.response_queues: Dict[str, queue.Queue] = {}
        self._lock = threading.Lock()

    def register_handler(self, message_type: str, handler: Callable):
        """注册消息处理器"""
        with self._lock:
            self.message_handlers[message_type] = handler
            logger.debug(f"注册IPC消息处理器: {message_type}")

    def unregister_handler(self, message_type: str):
        """注销消息处理器"""
        with self._lock:
            if message_type in self.message_handlers:
                del self.message_handlers[message_type]
                logger.debug(f"注销IPC消息处理器: {message_type}")

    async def send_command(
        self, process_handle, command: IPCCommand, timeout: float = 30.0
    ) -> IPCResponse:
        """发送IPC命令并等待响应"""
        message_id = str(uuid.uuid4())
        message = IPCMessage(
            message_id=message_id,
            message_type="command",
            session_id=command.session_id,
            data=command.dict(),
        )

        # 创建响应队列
        response_queue = queue.Queue()
        with self._lock:
            self.response_queues[message_id] = response_queue

        try:
            # 发送消息
            message_json = json.dumps(message.dict(), ensure_ascii=False, default=str)
            process_handle.stdin.write(message_json.encode() + b"\n")
            await process_handle.stdin.drain()

            # 等待响应
            try:
                response_data = response_queue.get(timeout=timeout)
                return IPCResponse(**response_data)
            except queue.Empty:
                logger.error(f"IPC命令超时: {command.command}")
                return IPCResponse(
                    success=False, error="Command timeout", timestamp=datetime.now()
                )

        finally:
            # 清理响应队列
            with self._lock:
                if message_id in self.response_queues:
                    del self.response_queues[message_id]

    async def handle_message(self, message_data: Dict[str, Any]):
        """处理接收到的IPC消息"""
        try:
            message = IPCMessage(**message_data)

            # 检查是否是响应消息
            if message.message_type == "response":
                await self._handle_response(message)
                return

            # 查找处理器
            handler = self.message_handlers.get(message.message_type)
            if handler:
                await handler(message)
            else:
                logger.warning(f"未找到IPC消息处理器: {message.message_type}")

        except Exception as e:
            logger.error(f"处理IPC消息失败: {e}")

    async def _handle_response(self, message: IPCMessage):
        """处理响应消息"""
        response_data = message.data
        message_id = response_data.get("message_id")

        if message_id and message_id in self.response_queues:
            try:
                self.response_queues[message_id].put_nowait(response_data)
            except queue.Full:
                logger.error(f"响应队列已满: {message_id}")

    def create_response(
        self,
        original_message: IPCMessage,
        success: bool,
        data: Any = None,
        error: str = None,
    ) -> IPCMessage:
        """创建响应消息"""
        response_data = {
            "message_id": original_message.message_id,
            "success": success,
            "data": data,
            "error": error,
            "timestamp": datetime.now(),
        }

        return IPCMessage(
            message_id=str(uuid.uuid4()),
            message_type="response",
            session_id=original_message.session_id,
            data=response_data,
        )


def create_ipc_message(
    message_type: str, session_id: str, data: Dict[str, Any]
) -> IPCMessage:
    """创建IPC消息"""
    return IPCMessage(
        message_id=str(uuid.uuid4()),
        message_type=message_type,
        session_id=session_id,
        data=data,
    )


def parse_ipc_response(response_json: str) -> Optional[IPCResponse]:
    """解析IPC响应"""
    try:
        response_data = json.loads(response_json)
        return IPCResponse(**response_data)
    except Exception as e:
        logger.error(f"解析IPC响应失败: {e}")
        return None


class IPCPipeReader:
    """IPC管道读取器"""

    def __init__(self, pipe, message_handler: Callable):
        self.pipe = pipe
        self.message_handler = message_handler
        self.running = False
        self.thread = None

    def start(self):
        """开始读取管道"""
        if self.running:
            return

        self.running = True
        self.thread = threading.Thread(target=self._read_loop, daemon=True)
        self.thread.start()
        logger.debug("IPC管道读取器已启动")

    def stop(self):
        """停止读取管道"""
        self.running = False
        if self.thread:
            self.thread.join(timeout=5.0)
        logger.debug("IPC管道读取器已停止")

    def _read_loop(self):
        """读取循环"""
        while self.running:
            try:
                line = self.pipe.readline()
                if not line:
                    break

                line = line.decode().strip()
                if line:
                    message_data = json.loads(line)
                    asyncio.create_task(self.message_handler(message_data))

            except Exception as e:
                logger.error(f"IPC读取失败: {e}")
                if not self.running:
                    break
