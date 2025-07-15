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
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
import uvicorn

from models.data_models import (
    SessionState,
    TranscriptSegment,
    MeetingSummary,
    TaskItem,
    ProgressUpdate,
    MessageType,
    WebSocketMessage,
    IPCCommand,
)
from models.data_models import WebSocketMessage

from services.session_manager import SessionManager
from services.websocket_manager import WebSocketManager
from services.process_manager import ProcessManager
from processors.database import MeetingSessionStorage

# 配置日志
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """应用生命周期管理"""
    # 启动时初始化
    logger.info("PromptMeet 服务正在启动...")
    await process_manager.initialize()
    logger.info("PromptMeet 服务启动完成")
    if not db_storage.initialize_database():
        logger.error("数据库初始化失败!") 
    yield  # 应用运行期间
    
    # 关闭时清理资源
    logger.info("PromptMeet 服务正在关闭...")
    await process_manager.cleanup()
    logger.info("PromptMeet 服务已关闭")

app = FastAPI(
    title="PromptMeet API",
    description="智能会议助手 - Vue + FastAPI + IPC 架构",
    version="1.0.0",
    lifespan=lifespan,
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





# ============= HTTP API 接口 =============


@app.get("/health")
async def health_check():
    """健康检查"""
    return {
        "status": "healthy",
        "timestamp": datetime.now().isoformat(),
        "service": "PromptMeet FastAPI",
        "active_sessions": len(session_manager.sessions),
        "connected_clients": len(websocket_manager.connections),
    }


@app.get("/api/windows")
async def get_available_windows():
    """获取可用的会议窗口列表"""
    try:
        # 临时启动图像处理器来获取窗口列表
        import sys
        import os

        sys.path.append(os.path.join(os.path.dirname(__file__), "processors"))

        from image_processor import get_meeting_windows

        window_dict = get_meeting_windows()
        if not window_dict:
            return {"success": True, "windows": [], "message": "未检测到会议窗口"}

        # 格式化窗口信息供前端使用
        windows = []
        for window_id, window in window_dict.items():
            if isinstance(window, dict):
                # macOS 或 fallback 窗口
                windows.append(
                    {
                        "id": str(window_id),
                        "title": window.get("title", "Unknown"),
                        "type": window.get("type", "unknown"),
                    }
                )
            else:
                # pygetwindow 窗口对象
                windows.append(
                    {"id": str(window_id), "title": window.title, "type": "window"}
                )

        return {
            "success": True,
            "windows": windows,
            "message": f"找到 {len(windows)} 个可用窗口",
        }

    except Exception as e:
        logger.error(f"获取窗口列表失败: {e}")
        return {
            "success": False,
            "windows": [],
            "message": f"获取窗口列表失败: {str(e)}",
        }


@app.get("/api/windows")
async def get_available_windows():
    """获取可用的会议窗口列表"""
    try:
        # 临时启动图像处理器来获取窗口列表
        import sys
        import os

        sys.path.append(os.path.join(os.path.dirname(__file__), "processors"))

        from image_processor import get_meeting_windows

        window_dict = get_meeting_windows()
        if not window_dict:
            return {"success": True, "windows": [], "message": "未检测到会议窗口"}

        # 格式化窗口信息供前端使用
        windows = []
        for window_id, window in window_dict.items():
            if isinstance(window, dict):
                # macOS 或 fallback 窗口
                windows.append(
                    {
                        "id": str(window_id),
                        "title": window.get("title", "Unknown"),
                        "type": window.get("type", "unknown"),
                    }
                )
            else:
                # pygetwindow 窗口对象
                windows.append(
                    {"id": str(window_id), "title": window.title, "type": "window"}
                )

        return {
            "success": True,
            "windows": windows,
            "message": f"找到 {len(windows)} 个可用窗口",
        }

    except Exception as e:
        logger.error(f"获取窗口列表失败: {e}")
        return {
            "success": False,
            "windows": [],
            "message": f"获取窗口列表失败: {str(e)}",
        }


@app.post("/api/sessions")
async def create_session():
    """创建新的会议会话"""
    session_id = str(uuid.uuid4())
    session = SessionState(
        session_id=session_id,
        is_recording=False,
        start_time=datetime.now(),
        end_time=None,
        current_summary=None,
        participant_count=0,
        audio_file_path=None
    )

    session_manager.add_session(session)

    # 启动Agent进程
    await process_manager.start_agent_process(session_id)

    logger.info(f"创建新会话: {session_id}")
    return {"success": True, "session_id": session_id, "message": "会话创建成功"}


@app.get("/api/sessions/{session_id}")
async def get_session(session_id: str):
    """获取会话状态"""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")

    return {"success": True, "session": session.dict()}


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
    return {"success": True, "message": "会话删除成功"}


@app.post("/api/sessions/{session_id}/start-recording")
async def start_recording(session_id: str):
    """开始录音"""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")

    if session.is_recording:
        return {"success": False, "message": "会话已在录音中"}

    try:
        # 启动 Whisper 转录进程
        await process_manager.start_whisper_process(session_id)

        # 启动 Question 生成进程
        await process_manager.start_question_process(session_id)

        # 更新会话状态
        session.is_recording = True
        session_manager.update_session(session)

        # 通知前端
        await websocket_manager.broadcast_to_session(
            session_id,
            {
                "type": MessageType.AUDIO_START,
                "data": {"session_id": session_id},
                "timestamp": datetime.now(),
                "session_id": session_id,
            },
        )

        logger.info(f"会话 {session_id} 开始录音，问题生成进程已启动")
        return {"success": True, "message": "录音开始"}

    except Exception as e:
        logger.error(f"启动录音失败: {e}")
        return {"success": False, "message": f"录音启动失败: {str(e)}"}


@app.post("/api/sessions/{session_id}/stop-recording")
async def stop_recording(session_id: str):
    """停止录音"""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")

    if not session.is_recording:
        return {"success": False, "message": "会话未在录音"}

    try:
        # 停止 Whisper 进程
        await process_manager.stop_whisper_process(session_id)

        # 停止 Question 生成进程
        await process_manager.stop_question_process(session_id)

        # 更新会话状态
        session.is_recording = False
        session_manager.update_session(session)

        # 通知前端
        await websocket_manager.broadcast_to_session(
            session_id,
            {
                "type": MessageType.AUDIO_STOP,
                "data": {"session_id": session_id},
                "timestamp": datetime.now(),
                "session_id": session_id,
            },
        )

        logger.info(f"会话 {session_id} 停止录音，问题生成进程已停止")
        return {"success": True, "message": "录音停止"}

    except Exception as e:
        logger.error(f"停止录音失败: {e}")
        return {"success": False, "message": f"录音停止失败: {str(e)}"}


@app.post("/api/sessions/{session_id}/generate-summary")
async def generate_summary(session_id: str):
    """生成会议摘要"""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")

    if not session.transcript_segments:
        return {"success": False, "message": "没有转录内容可分析"}

    try:
        # 启动 Summary 分析进程
        await process_manager.start_summary_process(session_id)

        logger.info(f"会话 {session_id} 开始生成摘要")
        return {"success": True, "message": "开始生成摘要"}

    except Exception as e:
        logger.error(f"生成摘要失败: {e}")
        return {"success": False, "message": f"生成摘要失败: {str(e)}"}


@app.post("/api/sessions/{session_id}/generate-questions")
async def generate_questions(session_id: str):
    """生成会议问题"""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")

    if not session.transcript_segments:
        return {"success": False, "message": "没有转录内容可生成问题"}

    try:
        # 启动 Question 生成进程
        await process_manager.start_question_process(session_id)

        logger.info(f"会话 {session_id} 开始生成问题")
        return {"success": True, "message": "开始生成问题"}

    except Exception as e:
        logger.error(f"生成问题失败: {e}")
        return {"success": False, "message": f"生成问题失败: {str(e)}"}
        
@app.post("/api/sessions/{session_id}/store-session")
async def store_session(session_id: str):
    """存储会话数据到数据库"""
    try:
        # 验证会话是否存在
        session = session_manager.get_session(session_id)
        if not session:
            logger.warning(f"尝试存储不存在的会话: {session_id}")
            raise HTTPException(status_code=404, detail="会话不存在")
        
        # 简单验证会话数据
        if not session.session_id:
            logger.error(f"会话数据无效: {session_id}")
            raise HTTPException(status_code=400, detail="会话数据无效")
        
        # 转换为字典格式
        session_dict = session.model_dump()
        logger.info(f"会话数据: {session_dict}")
        
        # 执行存储操作
        logger.info(f"开始存储会话: {session_id}")
        success = await asyncio.get_event_loop().run_in_executor(
            None, db_storage.store_session, session_dict
        )
        
        if not success:
            logger.error(f"会话存储失败: {session_id}")
            raise HTTPException(status_code=500, detail="会话存储失败")
        
        logger.info(f"会话存储成功: {session_id}")
        return {
            "success": True, 
            "message": "会话存储成功",
            "session_id": session_id,
            "stored_at": datetime.now().isoformat()
        }
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"存储会话时发生意外错误: {session_id}, 错误: {str(e)}")
        raise HTTPException(status_code=500, detail=f"服务器内部错误: {str(e)}")


@app.post("/api/sessions/{session_id}/start-image-processing")
async def start_image_processing(session_id: str, window_id: Optional[str] = None):
    """启动图像 OCR 处理"""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")

    try:
        if session_id in process_manager.image_processes:
            process = process_manager.image_processes[session_id]
            pid = process.pid
            print(f"即将停止图像进程：session_id={session_id}, PID={pid}")

            await process_manager.stop_image_process(session_id)
            print(f"图像进程已停止：session_id={session_id}")

        await process_manager.start_image_process(session_id, window_id)
        process = process_manager.image_processes[session_id]
        pid = process.pid
        print(f"已启动图像进程：session_id={session_id}, PID={pid}")

        await asyncio.sleep(2.0)

        # await process_manager.stop_image_process(session_id)

        return {
            "success": True,
            "message": f"图像处理已启动{f' (窗口ID: {window_id})' if window_id else ''}",
        }

    except Exception as e:
        logger.error(f"图像处理启动失败: {e}")
        return {"success": False, "message": f"图像处理失败: {str(e)}"}


# ============= WebSocket 接口 =============


@app.websocket("/ws/{session_id}")
async def websocket_endpoint(websocket: WebSocket, session_id: str):
    """WebSocket连接端点"""
    await websocket_manager.connect(websocket, session_id)

    try:
        logger.info(f"WebSocket 连接建立: session={session_id}")

        # 发送连接确认
        await websocket.send_json(
            {
                "type": "connection_established",
                "data": {
                    "session_id": session_id,
                    "timestamp": datetime.now().isoformat(),
                },
            }
        )

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
                await websocket.send_json(
                    {"type": "error", "data": {"message": f"消息处理错误: {str(e)}"}}
                )

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
        await websocket_manager.send_to_session(
            session_id,
            {"type": "pong", "data": {"timestamp": datetime.now().isoformat()}},
        )

    elif message_type == "agent_message":
        # 转发消息到Agent进程
        session_dir = process_manager.work_dir / session_id
        ipc_input = session_dir / "agent_input.pipe"

        try:
            await process_manager._send_ipc_command(
                ipc_input,
                IPCCommand(
                    command="message",
                    session_id=session_id,
                    params={"content": data.get("content", "")},
                ),
            )
        except Exception as e:
            logger.error(f"转发消息到Agent失败: {e}")


# 添加Agent响应回调
async def on_agent_response(session_id: str, response: dict):
    """处理Agent响应"""
    # 兼容旧结构，提取最终回答内容
    content = None
    # response 可能是多层嵌套
    try:
        # 兼容多层data
        if isinstance(response, dict):
            # 兼容直接返回字符串
            if isinstance(response.get("data"), str):
                content = response["data"]
            elif isinstance(response.get("data"), dict):
                # 兼容多层data
                data = response["data"]
                # 可能有response字段
                if isinstance(data.get("response"), str):
                    content = data["response"]
                elif isinstance(data.get("data"), dict) and isinstance(
                    data["data"].get("response"), str
                ):
                    content = data["data"]["response"]
                elif isinstance(data.get("output"), str):
                    content = data["output"]
                elif isinstance(data.get("content"), str):
                    content = data["content"]
    except Exception as e:
        content = str(response)

    if not content:
        content = str(response)

    # 检查是否是邮件相关的响应
    if content and ("邮件" in content or "email" in content.lower()):
        await websocket_manager.broadcast_to_session(session_id, {
            "type": "email_response",
            "data": {
                "content": content
            }
        })
    else:
        await websocket_manager.broadcast_to_session(session_id, {
            "type": "answer",
            "data": {
                "content": content
            }
        })
# 注册回调
process_manager.on_agent_response = on_agent_response

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
            speaker=transcript_data.get("speaker"),
            start_time=transcript_data.get("start_time"),  # 或者合适的默认值
            end_time=transcript_data.get("end_time")       # 或者合适的默认值
        )

        # 更新会话状态
        session = session_manager.get_session(session_id)
        if session:
            session.transcript_segments.append(segment)
            session_manager.update_session(session)

        # 通知前端
        await websocket_manager.broadcast_to_session(
            session_id,
            {
                "type": MessageType.AUDIO_TRANSCRIPT,
                "data": segment.dict(),
                "timestamp": datetime.now(),
                "session_id": session_id,
            },
        )

        logger.info(
            f"转录片段已添加: session={session_id}, text={segment.text[:50]}..."
        )

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
            generated_at=datetime.now(),
        )

        # 更新会话状态
        session = session_manager.get_session(session_id)
        if session:
            session.current_summary = summary
            session_manager.update_session(session)

        # 通知前端
        await websocket_manager.broadcast_to_session(
            session_id,
            {
                "type": MessageType.SUMMARY_GENERATED,
                "data": summary.dict(),
                "timestamp": datetime.now(),
                "session_id": session_id,
            },
        )

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
            logger.info(f"image_ocr_result: {image_result}")
            session_manager.update_session(session)
        # 通知前端
        await websocket_manager.broadcast_to_session(
            session_id,
            {
                "type": MessageType.IMAGE_OCR_RESULT,
                "data": image_result,
                "timestamp": datetime.now(),
                "session_id": session_id,
            },
        )

        logger.info(f"图像 OCR 结果已发送: session={session_id}")
        process = process_manager.image_processes[session_id]
        pid = process.pid
        print(f"发送图像的进程：session_id={session_id}, PID={pid}")
        # await process_manager.stop_image_process(session_id)

    except Exception as e:
        logger.error(f"处理图像 OCR 结果失败: {e}")


async def on_progress_update(session_id: str, progress_data: dict):
    """收到进度更新的回调"""
    try:
        progress = ProgressUpdate(**progress_data)

        # 通知前端
        await websocket_manager.broadcast_to_session(
            session_id,
            {
                "type": MessageType.PROGRESS_UPDATE,
                "data": progress.dict(),
                "timestamp": datetime.now(),
                "session_id": session_id,
            },
        )

    except Exception as e:
        logger.error(f"处理进度更新失败: {e}")


async def on_questions_generated(session_id: str, questions_data: dict):
    """收到问题生成结果的回调"""
    try:
        questions = questions_data.get("questions", [])

        # 直接打印问题到终端
        print("\n" + "=" * 80)
        print(f"🎯 会话 {session_id[:8]} 生成了 {len(questions)} 个问题:")
        print("=" * 80)

        # 为每个问题生成递增的ID并发送给前端
        for i, question in enumerate(questions, 1):
            question_content = question.get("question", "")
            print(f"\n❓ 问题{i}: {question_content}")
            if "timestamp" in question:
                print(f"   时间: {question['timestamp']}")

            # 发送单个问题给前端
            question_message = {
                "type": "question",
                "data": {
                    "id": i,
                    "content": question_content
                },
                "timestamp": datetime.now().isoformat(),
                "session_id": session_id,
            }

            await websocket_manager.broadcast_to_session(session_id, question_message)
            print(f"   📤 已发送问题{i}给前端")

        print("\n" + "=" * 80)

        logger.info(f"问题已生成并发送: session={session_id}, 问题数={len(questions)}")

    except Exception as e:
        logger.error(f"处理问题生成结果失败: {e}")


# 注册IPC回调
process_manager.on_transcript_received = on_transcript_received
process_manager.on_summary_generated = on_summary_generated
process_manager.on_progress_update = on_progress_update
process_manager.on_questions_generated = on_questions_generated
process_manager.on_image_result_received = on_image_result_received

if __name__ == "__main__":
    uvicorn.run(
        "main_service:app", host="0.0.0.0", port=8000, reload=True, log_level="info"
    )
