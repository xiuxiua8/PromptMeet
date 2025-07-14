"""
WebSocket 连接管理器
管理与前端的实时通信连接
"""

import json
import logging
from typing import Dict, List, Set, Any
from fastapi import WebSocket

logger = logging.getLogger(__name__)


class WebSocketManager:
    """WebSocket连接管理器"""

    def __init__(self):
        # 存储连接: session_id -> [websocket1, websocket2, ...]
        self.connections: Dict[str, List[WebSocket]] = {}
        # 存储WebSocket到session_id的映射
        self.websocket_sessions: Dict[WebSocket, str] = {}

    async def connect(self, websocket: WebSocket, session_id: str):
        """建立WebSocket连接"""
        await websocket.accept()

        if session_id not in self.connections:
            self.connections[session_id] = []

        self.connections[session_id].append(websocket)
        self.websocket_sessions[websocket] = session_id

        logger.info(
            f"WebSocket连接建立: session={session_id}, 总连接数={len(self.connections[session_id])}"
        )

    def disconnect(self, websocket: WebSocket, session_id: str):
        """断开WebSocket连接"""
        if session_id in self.connections:
            try:
                self.connections[session_id].remove(websocket)
                if not self.connections[session_id]:
                    del self.connections[session_id]
            except ValueError:
                pass

        if websocket in self.websocket_sessions:
            del self.websocket_sessions[websocket]

        logger.info(f"WebSocket连接断开: session={session_id}")

    async def send_to_session(self, session_id: str, message: Dict[str, Any]):
        """向特定会话的所有连接发送消息"""
        if session_id not in self.connections:
            logger.warning(f"会话 {session_id} 没有活跃连接")
            return

        # 准备消息
        message_json = json.dumps(message, ensure_ascii=False, default=str)

        # 发送给会话的所有连接
        disconnected_websockets = []
        for websocket in self.connections[session_id]:
            try:
                await websocket.send_text(message_json)
            except Exception as e:
                logger.error(f"发送消息失败: {e}")
                disconnected_websockets.append(websocket)

        # 清理断开的连接
        for websocket in disconnected_websockets:
            self.disconnect(websocket, session_id)

    async def broadcast_to_session(self, session_id: str, message: Dict[str, Any]):
        """向会话广播消息（别名，和send_to_session一样）"""
        await self.send_to_session(session_id, message)

    async def broadcast_to_all(self, message: Dict[str, Any]):
        """向所有连接广播消息"""
        message_json = json.dumps(message, ensure_ascii=False, default=str)

        for session_id, websockets in self.connections.items():
            disconnected_websockets = []
            for websocket in websockets:
                try:
                    await websocket.send_text(message_json)
                except Exception as e:
                    logger.error(f"广播消息失败: {e}")
                    disconnected_websockets.append(websocket)

            # 清理断开的连接
            for websocket in disconnected_websockets:
                self.disconnect(websocket, session_id)

    def get_session_connections(self, session_id: str) -> List[WebSocket]:
        """获取会话的所有连接"""
        return self.connections.get(session_id, [])

    def get_all_sessions(self) -> List[str]:
        """获取所有活跃会话ID"""
        return list(self.connections.keys())

    def get_connection_count(self, session_id: str = None) -> int:
        """获取连接数量"""
        if session_id:
            return len(self.connections.get(session_id, []))
        else:
            return sum(len(conns) for conns in self.connections.values())

    async def ping_all_connections(self):
        """向所有连接发送心跳检测"""
        ping_message = {
            "type": "ping",
            "data": {"timestamp": str(logger.info("开始心跳检测"))},
        }

        await self.broadcast_to_all(ping_message)
        logger.info(f"心跳检测完成，活跃连接数: {self.get_connection_count()}")
