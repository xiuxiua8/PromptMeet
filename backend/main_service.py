"""
PromptMeet FastAPI 主服务
整合 Vue 前端、Whisper 转录、Summary 分析
"""

import asyncio
import uuid
from datetime import datetime
from typing import Dict, List, Optional
import json
import logging

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
import uvicorn

from models.data_models import (
    SessionState, TranscriptSegment, MeetingSummary, 
    TaskItem, ProgressUpdate, MessageType, WebSocketMessage
)
from services.session_manager import SessionManager
from services.websocket_manager import WebSocketManager
from services.process_manager import ProcessManager
from processors.database import MeetingSessionStorage

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="PromptMeet API",
    description="智能会议助手 - Vue + FastAPI + IPC 架构",
    version="1.0.0"
)

# CORS配置
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:3000", "http://localhost:5173"],  # Vue开发服务器
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 全局管理器实例
session_manager = SessionManager()
websocket_manager = WebSocketManager()
process_manager = ProcessManager()
db_storage = MeetingSessionStorage()

@app.on_event("startup")
async def startup_event():
    """服务启动时初始化"""
    logger.info("PromptMeet 服务正在启动...")
    if not db_storage.initialize_database():
        logger.error("数据库初始化失败!")
    await process_manager.initialize()
    logger.info("PromptMeet 服务启动完成")

@app.on_event("shutdown")
async def shutdown_event():
    """服务关闭时清理资源"""
    logger.info("PromptMeet 服务正在关闭...")
    await process_manager.cleanup()
    logger.info("PromptMeet 服务已关闭")

# ============= HTTP API 接口 =============

@app.get("/health")
async def health_check():
    """健康检查"""
    return {
        "status": "healthy",
        "timestamp": datetime.now().isoformat(),
        "service": "PromptMeet FastAPI",
        "active_sessions": len(session_manager.sessions),
        "connected_clients": len(websocket_manager.connections)
    }

@app.post("/api/sessions")
async def create_session():
    """创建新的会议会话"""
    session_id = str(uuid.uuid4())
    session = SessionState(
        session_id=session_id,
        is_recording=False,
        start_time=datetime.now()
    )
    
    session_manager.add_session(session)
    
    logger.info(f"创建新会话: {session_id}")
    return {
        "success": True,
        "session_id": session_id,
        "message": "会话创建成功"
    }

@app.get("/api/sessions/{session_id}")
async def get_session(session_id: str):
    """获取会话状态"""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")
    
    return {
        "success": True,
        "session": session.dict()
    }

@app.delete("/api/sessions/{session_id}")
async def delete_session(session_id: str):
    """删除会话"""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")
    
    # 停止相关进程
    await process_manager.stop_session_processes(session_id)
    
    # 删除会话
    session_manager.remove_session(session_id)
    
    logger.info(f"删除会话: {session_id}")
    return {
        "success": True,
        "message": "会话删除成功"
    }

@app.post("/api/sessions/{session_id}/start-recording")
async def start_recording(session_id: str):
    """开始录音"""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")
    
    if session.is_recording:
        return {
            "success": False,
            "message": "会话已在录音中"
        }
    
    try:
        # 启动 Whisper 转录进程
        await process_manager.start_whisper_process(session_id)
        
        # 更新会话状态
        session.is_recording = True
        session_manager.update_session(session)
        
        # 通知前端
        await websocket_manager.broadcast_to_session(session_id, {
            "type": MessageType.AUDIO_START,
            "data": {"session_id": session_id},
            "timestamp": datetime.now(),
            "session_id": session_id
        })
        
        logger.info(f"会话 {session_id} 开始录音")
        return {
            "success": True,
            "message": "录音开始"
        }
        
    except Exception as e:
        logger.error(f"启动录音失败: {e}")
        return {
            "success": False,
            "message": f"录音启动失败: {str(e)}"
        }

@app.post("/api/sessions/{session_id}/stop-recording")
async def stop_recording(session_id: str):
    """停止录音"""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")
    
    if not session.is_recording:
        return {
            "success": False,
            "message": "会话未在录音"
        }
    
    try:
        # 停止 Whisper 进程
        await process_manager.stop_whisper_process(session_id)
        
        # 更新会话状态
        session.is_recording = False
        session_manager.update_session(session)
        
        # 通知前端
        await websocket_manager.broadcast_to_session(session_id, {
            "type": MessageType.AUDIO_STOP,
            "data": {"session_id": session_id},
            "timestamp": datetime.now(),
            "session_id": session_id
        })
        
        logger.info(f"会话 {session_id} 停止录音")
        return {
            "success": True,
            "message": "录音停止"
        }
        
    except Exception as e:
        logger.error(f"停止录音失败: {e}")
        return {
            "success": False,
            "message": f"录音停止失败: {str(e)}"
        }

@app.post("/api/sessions/{session_id}/generate-summary")
async def generate_summary(session_id: str):
    """生成会议摘要"""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")
    
    if not session.transcript_segments:
        return {
            "success": False,
            "message": "没有转录内容可分析"
        }
    
    try:
        # 启动 Summary 分析进程
        await process_manager.start_summary_process(session_id)
        
        logger.info(f"会话 {session_id} 开始生成摘要")
        return {
            "success": True,
            "message": "开始生成摘要"
        }
        
    except Exception as e:
        logger.error(f"生成摘要失败: {e}")
        return {
            "success": False,
            "message": f"生成摘要失败: {str(e)}"
        }

@app.post("/api/sessions/{session_id}/start-image-processing")
async def start_image_processing(session_id: str):
    """启动图像 OCR 处理"""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")

    try:
        await process_manager.start_image_process(session_id)
        
        return {
            "success": True,
            "message": "图像处理已启动"
        }

    except Exception as e:
        logger.error(f"图像处理启动失败: {e}")
        return {
            "success": False,
            "message": f"图像处理失败: {str(e)}"
        }


# ============= WebSocket 接口 =============

@app.websocket("/ws/{session_id}")
async def websocket_endpoint(websocket: WebSocket, session_id: str):
    """WebSocket连接端点"""
    await websocket_manager.connect(websocket, session_id)
    
    try:
        logger.info(f"WebSocket 连接建立: session={session_id}")
        
        # 发送连接确认
        await websocket.send_json({
            "type": "connection_established",
            "data": {
                "session_id": session_id,
                "timestamp": datetime.now().isoformat()
            }
        })
        
        # 保持连接并处理客户端消息
        while True:
            try:
                # 接收客户端消息
                data = await websocket.receive_json()
                await handle_websocket_message(session_id, data)
                
            except WebSocketDisconnect:
                logger.info(f"WebSocket 连接断开: session={session_id}")
                break
            except Exception as e:
                logger.error(f"WebSocket 消息处理错误: {e}")
                await websocket.send_json({
                    "type": "error",
                    "data": {
                        "message": f"消息处理错误: {str(e)}"
                    }
                })
                
    except Exception as e:
        logger.error(f"WebSocket 连接错误: {e}")
    finally:
        websocket_manager.disconnect(websocket, session_id)

async def handle_websocket_message(session_id: str, message: dict):
    """处理WebSocket消息"""
    message_type = message.get("type")
    data = message.get("data", {})
    
    logger.info(f"收到WebSocket消息: session={session_id}, type={message_type}")
    
    if message_type == "ping":
        # 心跳检测
        await websocket_manager.send_to_session(session_id, {
            "type": "pong",
            "data": {"timestamp": datetime.now().isoformat()}
        })
    
    elif message_type == "get_status":
        # 获取会话状态
        session = session_manager.get_session(session_id)
        if session:
            await websocket_manager.send_to_session(session_id, {
                "type": "status_update",
                "data": session.dict()
            })

# ============= Database 接口 =============

@app.get("/db/sessions", response_class=JSONResponse)
async def get_all_sessions():
    """获取所有会话列表"""
    try:
        sessions_json = db_storage.get_all_sessions()
        return JSONResponse(content=json.loads(sessions_json))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"获取会话列表失败: {str(e)}")

@app.get("/db/sessions/{session_id}", response_class=JSONResponse)
async def get_session_details(session_id: str):
    """获取会话详情"""
    try:
        session_json = db_storage.get_session_details(session_id)
        if not session_json or session_json == "null":
            raise HTTPException(status_code=404, detail="会话不存在")
        return JSONResponse(content=json.loads(session_json))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"获取会话详情失败: {str(e)}")

@app.post("/db/sessions/{session_id}/export")
async def export_session(session_id: str):
    """导出会话数据"""
    try:
        filepath = db_storage.save_session_to_json_file(session_id)
        if not filepath:
            raise HTTPException(status_code=404, detail="会话不存在")
        return {"success": True, "filepath": filepath}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"导出会话失败: {str(e)}")

# ============= IPC 回调处理 =============

async def on_transcript_received(session_id: str, transcript_data: dict):
    """收到转录结果的回调"""
    try:
        # 创建转录片段对象
        segment = TranscriptSegment(
            id=transcript_data.get("id", str(uuid.uuid4())),
            text=transcript_data["text"],
            timestamp=datetime.fromisoformat(transcript_data["timestamp"]),
            confidence=transcript_data.get("confidence", 0.0),
            speaker=transcript_data.get("speaker")
        )
        
        # 更新会话状态
        session = session_manager.get_session(session_id)
        if session:
            session.transcript_segments.append(segment)
            session_manager.update_session(session)
        
        # 通知前端
        await websocket_manager.broadcast_to_session(session_id, {
            "type": MessageType.AUDIO_TRANSCRIPT,
            "data": segment.dict(),
            "timestamp": datetime.now(),
            "session_id": session_id
        })
        
        logger.info(f"转录片段已添加: session={session_id}, text={segment.text[:50]}...")
        
    except Exception as e:
        logger.error(f"处理转录结果失败: {e}")

async def on_summary_generated(session_id: str, summary_data: dict):
    """收到摘要生成结果的回调"""
    try:
        # 创建摘要对象
        summary = MeetingSummary(
            session_id=session_id,
            summary_text=summary_data["summary_text"],
            tasks=[TaskItem(**task) for task in summary_data.get("tasks", [])],
            key_points=summary_data.get("key_points", []),
            decisions=summary_data.get("decisions", []),
            generated_at=datetime.now()
        )
        
        # 更新会话状态
        session = session_manager.get_session(session_id)
        if session:
            session.current_summary = summary
            session_manager.update_session(session)
        
        # 通知前端
        await websocket_manager.broadcast_to_session(session_id, {
            "type": MessageType.SUMMARY_GENERATED,
            "data": summary.dict(),
            "timestamp": datetime.now(),
            "session_id": session_id
        })
        
        logger.info(f"摘要已生成: session={session_id}")
        
    except Exception as e:
        logger.error(f"处理摘要结果失败: {e}")

async def on_image_result_received(session_id: str, image_result: dict):
    """收到图像 OCR 结果的回调"""
    try:
         # 更新会话状态
        session = session_manager.get_session(session_id)
        if session:
            session.image_ocr_result.append(image_result)
            session_manager.update_session(session)
        # 通知前端
        await websocket_manager.broadcast_to_session(session_id, {
            "type": "image_ocr_result",
            "data": image_result,
            "timestamp": datetime.now(),
            "session_id": session_id
        })

        logger.info(f"图像 OCR 结果已发送: session={session_id}")

    except Exception as e:
        logger.error(f"处理图像 OCR 结果失败: {e}")


async def on_progress_update(session_id: str, progress_data: dict):
    """收到进度更新的回调"""
    try:
        progress = ProgressUpdate(**progress_data)
        
        # 通知前端
        await websocket_manager.broadcast_to_session(session_id, {
            "type": MessageType.PROGRESS_UPDATE,
            "data": progress.dict(),
            "timestamp": datetime.now(),
            "session_id": session_id
        })
        
    except Exception as e:
        logger.error(f"处理进度更新失败: {e}")

# 注册IPC回调
process_manager.on_transcript_received = on_transcript_received
process_manager.on_summary_generated = on_summary_generated
process_manager.on_progress_update = on_progress_update
process_manager.on_image_result_received = on_image_result_received

if __name__ == "__main__":
    uvicorn.run(
        "main_service:app",
        host="0.0.0.0",
        port=8000,
        reload=True,
        log_level="info"
    ) 