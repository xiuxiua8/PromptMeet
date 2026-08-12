"""
PromptMeet FastAPI 主服务
整合 Vue 前端、Whisper 转录、Summary 分析
"""

import asyncio
import uuid
from datetime import UTC, datetime
from typing import Optional
import json
import logging
import os
from contextlib import asynccontextmanager
from pathlib import Path
from types import SimpleNamespace

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field, field_validator
import uvicorn
from dotenv import load_dotenv

load_dotenv(os.getenv("PROMPTMEET_ENV_FILE") or None, override=False)

from models.data_models import (  # noqa: E402
    SessionState,
    TranscriptSegment,
    MeetingSummary,
    TaskItem,
    ProgressUpdate,
    MessageType,
    IPCCommand,
)
from services.session_manager import SessionManager  # noqa: E402
from services.websocket_manager import WebSocketManager  # noqa: E402
from services.process_manager import ProcessManager  # noqa: E402
from services.native_audio_ingress import NativeAudioIngress  # noqa: E402
from services.meeting_ingestion import (
    MeetingIngestionService,
    ScreenshotAnalysisResult,
)  # noqa: E402
from services.meeting_repository import (
    MeetingNotFoundError,
    MeetingRepository,
)  # noqa: E402
from services.meeting_title_service import MeetingTitleService  # noqa: E402
from models.meeting_context import (  # noqa: E402
    EventKind,
    AnswerPayload,
    MeetingEvent,
    MeetingRecord,
    MeetingStatus,
    ScreenshotAnalysisPayload,
    ScreenshotPayload,
    QuestionPayload,
    SummaryPayload,
    TranscriptPayload,
)

DESKTOP_MODE = os.getenv("PROMPTMEET_DESKTOP_MODE") == "1"
if DESKTOP_MODE:
    from services.desktop_agent_service import DesktopAgentService  # noqa: E402
    from services.desktop_storage import HybridSessionStorage  # noqa: E402
    from services.desktop_summary_service import OriginalSummaryService  # noqa: E402
else:
    from processors.database import MeetingSessionStorage  # noqa: E402
from api.native_audio import build_native_audio_router  # noqa: E402
from api.native_recording import build_native_recording_router  # noqa: E402
from api.native_screenshot import build_native_screenshot_router  # noqa: E402
from api.native_transcript import build_native_transcript_router  # noqa: E402

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
meeting_data_root = Path(
    os.getenv("PROMPTMEET_DATA_DIR") or process_manager.work_dir / "meeting_data"
)
meeting_repository = MeetingRepository(meeting_data_root)
meeting_ingestion = MeetingIngestionService(meeting_repository)
db_storage = (
    HybridSessionStorage.from_environment(os.getenv("PROMPTMEET_DATA_DIR"))
    if DESKTOP_MODE
    else MeetingSessionStorage()
)
desktop_agent_service = (
    DesktopAgentService(assets_root=meeting_repository.root) if DESKTOP_MODE else None
)
desktop_summary_service = OriginalSummaryService() if DESKTOP_MODE else None
native_audio_ingress = NativeAudioIngress(process_manager.work_dir / "native_audio")


class MeetingQuestionRequest(BaseModel):
    request_id: str
    thread_id: str = "main"
    question: str

    @field_validator("request_id", "thread_id", "question")
    @classmethod
    def reject_blank(cls, value: str, info) -> str:
        if not value.strip():
            raise ValueError("字段不能为空")
        return value if info.field_name == "question" else value.strip()


class QuestionGenerationRequest(BaseModel):
    generation_id: str
    context_revision: int = Field(ge=0)

    @field_validator("generation_id")
    @classmethod
    def reject_blank_generation(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("generation_id 不能为空")
        return value


class SummaryGenerationRequest(BaseModel):
    trigger: str = "manual"
    active_minutes: int | None = Field(default=None, ge=0)
    client_input_revision: int | None = Field(default=None, ge=0)

    @field_validator("trigger")
    @classmethod
    def validate_trigger(cls, value: str) -> str:
        if value not in {"manual", "milestone"}:
            raise ValueError("trigger 必须是 manual 或 milestone")
        return value


class SessionRehydrateRequest(BaseModel):
    is_paused: bool = False


class SessionCreateRequest(BaseModel):
    session_id: str | None = None
    started_at: datetime | None = None

    @field_validator("session_id")
    @classmethod
    def validate_session_id(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip()
        if not normalized:
            raise ValueError("session_id 不能为空")
        try:
            uuid.UUID(normalized)
        except ValueError as error:
            raise ValueError("session_id 必须是 UUID") from error
        return normalized


meeting_question_tasks: set[asyncio.Task] = set()
meeting_screenshot_tasks: set[asyncio.Task] = set()
question_generation_tasks: dict[str, asyncio.Task] = {}
latest_question_generations: dict[str, tuple[str, int]] = {}
summary_generation_locks: dict[str, asyncio.Lock] = {}
meeting_title_tasks: dict[str, asyncio.Task] = {}
meeting_translation_tasks: dict[tuple[str, str], asyncio.Task] = {}
meeting_translation_retry_keys: set[tuple[str, str]] = set()


def finish_question_task(task: asyncio.Task) -> None:
    meeting_question_tasks.discard(task)
    if task.cancelled():
        return
    try:
        task.result()
    except HTTPException:
        return
    except Exception as error:
        logger.warning("会议问题处理失败: %s", error)


def finish_screenshot_task(task: asyncio.Task) -> None:
    meeting_screenshot_tasks.discard(task)
    if task.cancelled():
        return
    try:
        task.result()
    except Exception as error:
        logger.warning("截图分析任务失败: %s", error)


def meeting_title_service() -> MeetingTitleService:
    generator = (
        getattr(desktop_agent_service, "generate_meeting_title", None)
        if desktop_agent_service is not None
        else None
    )
    return MeetingTitleService(meeting_repository, generator=generator)


def persist_meeting_title_fallback(meeting_id: str) -> None:
    try:
        meeting_title_service().persist_fallback(meeting_id)
    except Exception as error:
        logger.warning(
            "会议已结束，但本地标题回退保存失败: session=%s, error=%s",
            meeting_id,
            error.__class__.__name__,
        )


def schedule_meeting_title_generation(meeting_id: str) -> None:
    existing = meeting_title_tasks.get(meeting_id)
    if existing is not None and not existing.done():
        return
    task = asyncio.create_task(
        meeting_title_service().finalize(meeting_id),
        name=f"meeting-title-{meeting_id}",
    )
    meeting_title_tasks[meeting_id] = task

    def finish_title_task(completed: asyncio.Task) -> None:
        if meeting_title_tasks.get(meeting_id) is completed:
            meeting_title_tasks.pop(meeting_id, None)
        if completed.cancelled():
            return
        try:
            completed.result()
        except Exception as error:
            logger.warning(
                "会议标题生成失败，已保留本地回退: session=%s, error=%s",
                meeting_id,
                error.__class__.__name__,
            )

    task.add_done_callback(finish_title_task)


async def start_native_recording(session_id: str) -> None:
    session = session_manager.get_session(session_id)
    if not session or session.is_recording:
        return
    if DESKTOP_MODE:
        record = meeting_repository.get(session_id)
        if (
            record is None
            or record.status != MeetingStatus.ACTIVE
            or record.ended_at is not None
        ):
            return
    if not DESKTOP_MODE:
        await process_manager.start_question_process(session_id)
    session.is_recording = True
    session.is_paused = False
    session_manager.update_session(session)
    await websocket_manager.broadcast_to_session(
        session_id,
        {
            "type": MessageType.AUDIO_START,
            "data": {"session_id": session_id, "capture": "native"},
            "timestamp": datetime.now(),
            "session_id": session_id,
        },
    )


async def stop_native_recording(session_id: str) -> None:
    session = session_manager.get_session(session_id)
    if not session or not session.is_recording:
        return
    if not DESKTOP_MODE:
        await process_manager.stop_question_process(session_id)
    session.is_recording = False
    session.is_paused = False
    session.end_time = datetime.now()
    session_manager.update_session(session)
    try:
        meeting_ingestion.finish(session_id, MeetingStatus.COMPLETED)
    except MeetingNotFoundError:
        logger.warning("结束会议时未找到持久记录: session=%s", session_id)
    else:
        persist_meeting_title_fallback(session_id)
        schedule_meeting_title_generation(session_id)
    await websocket_manager.broadcast_to_session(
        session_id,
        {
            "type": MessageType.AUDIO_STOP,
            "data": {"session_id": session_id, "capture": "native"},
            "timestamp": datetime.now(),
            "session_id": session_id,
        },
    )


async def pause_native_recording(session_id: str) -> None:
    session = session_manager.get_session(session_id)
    if not session or not session.is_recording or session.is_paused:
        return
    session.is_paused = True
    session_manager.update_session(session)
    event = meeting_ingestion.recording_activity(session_id, "录音已暂停")
    await broadcast_meeting_event(session_id, event)
    await websocket_manager.broadcast_to_session(
        session_id,
        {
            "type": "audio_pause",
            "data": {"session_id": session_id, "capture": "native"},
            "timestamp": datetime.now(UTC).isoformat(),
            "session_id": session_id,
        },
    )


async def resume_native_recording(session_id: str) -> None:
    session = session_manager.get_session(session_id)
    if not session or not session.is_recording or not session.is_paused:
        return
    session.is_paused = False
    session_manager.update_session(session)
    event = meeting_ingestion.recording_activity(session_id, "录音已恢复")
    await broadcast_meeting_event(session_id, event)
    await websocket_manager.broadcast_to_session(
        session_id,
        {
            "type": "audio_resume",
            "data": {"session_id": session_id, "capture": "native"},
            "timestamp": datetime.now(UTC).isoformat(),
            "session_id": session_id,
        },
    )


async def broadcast_meeting_event(session_id: str, event: MeetingEvent) -> None:
    await websocket_manager.broadcast_to_session(
        session_id,
        {
            "type": "meeting_event",
            "data": event.model_dump(mode="json"),
            "timestamp": datetime.now(UTC).isoformat(),
            "session_id": session_id,
        },
    )


async def process_native_screenshot(
    session_id: str,
    image_path,
    local_ocr_text: str | None = None,
    ocr_engine: str | None = None,
) -> dict:
    mime_type = (
        "image/jpeg"
        if Path(image_path).suffix.lower() in {".jpg", ".jpeg"}
        else "image/png"
    )
    try:
        loop = asyncio.get_running_loop()
        event = await loop.run_in_executor(
            None,
            lambda: meeting_ingestion.screenshot(
                session_id,
                Path(image_path),
                mime_type,
                local_ocr_text=local_ocr_text,
                ocr_engine=ocr_engine,
            ),
        )
    except (FileNotFoundError, MeetingNotFoundError, ValueError):
        if DESKTOP_MODE:
            await process_manager.start_image_process(
                session_id,
                image_path=str(image_path),
            )
            return {"legacy_processing": True}
        raise
    await broadcast_meeting_event(session_id, event)
    if DESKTOP_MODE:
        task = asyncio.create_task(
            analyze_native_screenshot(session_id, event),
            name=f"screenshot-analysis-{session_id}-{event.event_id}",
        )
        meeting_screenshot_tasks.add(task)
        task.add_done_callback(finish_screenshot_task)
        return {"event": event.model_dump(mode="json")}
    if session_id in process_manager.image_processes:
        await process_manager.stop_image_process(session_id)
    await process_manager.start_image_process(session_id, image_path=str(image_path))
    return {"event": event.model_dump(mode="json")}


async def analyze_native_screenshot(session_id: str, event: MeetingEvent) -> None:
    payload = event.payload
    if not isinstance(payload, ScreenshotPayload):
        return
    try:
        if desktop_agent_service is None:
            raise RuntimeError("AI 服务不可用")
        record = meeting_repository.get(session_id)
        if record is None:
            raise MeetingNotFoundError(session_id)
        result = await desktop_agent_service.analyze_screenshot(record, event)
    except Exception:
        result = ScreenshotAnalysisResult(
            status="failed",
            text="截图分析失败。请检查截图分析工作流的提供方、模型和视觉能力配置。",
            vision_used=False,
            evidence_kind="none",
        )
    analysis_event = meeting_ingestion.screenshot_analysis(
        session_id,
        payload.asset_id,
        result,
    )
    await broadcast_meeting_event(session_id, analysis_event)
    await websocket_manager.broadcast_to_session(
        session_id,
        {
            "type": "image_ocr_result",
            "data": {
                "asset_id": payload.asset_id,
                "content": result.text,
                "status": result.status,
                "vision_used": result.vision_used,
                "evidence_kind": result.evidence_kind,
                "image_rejection": result.image_rejection,
            },
            "timestamp": datetime.now(UTC).isoformat(),
            "session_id": session_id,
        },
    )


async def process_native_transcript(session_id: str, transcript: dict) -> bool:
    inserted = await on_transcript_received(session_id, transcript)
    if inserted is None:
        return False
    target = transcript.get("translation_target")
    if DESKTOP_MODE and desktop_agent_service is not None and target:
        schedule_native_transcript_translation(
            session_id,
            transcript,
            target,
            is_new=inserted,
        )
    return True


def schedule_native_transcript_translation(
    session_id: str,
    transcript: dict,
    target_language: str,
    *,
    is_new: bool,
) -> None:
    transcript_id = str(transcript.get("id") or "")
    record = meeting_repository.get(session_id)
    if record is None:
        return
    event = next(
        (
            item
            for item in record.events
            if item.kind == EventKind.TRANSCRIPT
            and isinstance(item.payload, TranscriptPayload)
            and item.payload.segment_id == transcript_id
        ),
        None,
    )
    if (
        event is None
        or event.payload.translated_text
        or event.payload.text != str(transcript.get("text") or "").strip()
    ):
        return
    key = (session_id, transcript_id)
    active = meeting_translation_tasks.get(key)
    if active is not None and not active.done():
        return
    if not is_new:
        if key in meeting_translation_retry_keys:
            return
        meeting_translation_retry_keys.add(key)
    task = asyncio.create_task(
        translate_native_transcript(
            session_id,
            transcript_id,
            event.payload.text,
            target_language,
        ),
        name=f"transcript-translation-{session_id}-{transcript_id}",
    )
    meeting_translation_tasks[key] = task

    def finish_translation(completed: asyncio.Task) -> None:
        if meeting_translation_tasks.get(key) is completed:
            meeting_translation_tasks.pop(key, None)

    task.add_done_callback(finish_translation)


async def translate_native_transcript(
    session_id: str,
    transcript_id: str,
    text: str,
    target_language: str,
) -> None:
    try:
        translated_text = await desktop_agent_service.translate(text, target_language)
        meeting_ingestion.translate_transcript(
            session_id,
            transcript_id,
            translated_text,
        )
        await websocket_manager.broadcast_to_session(
            session_id,
            {
                "type": "transcript_translation",
                "data": {"id": transcript_id, "translated_text": translated_text},
                "timestamp": datetime.now(),
                "session_id": session_id,
            },
        )
    except Exception as error:
        logger.warning("实时翻译失败: session=%s, error=%s", session_id, error)


app.include_router(
    build_native_audio_router(session_manager.get_session, native_audio_ingress)
)
app.include_router(
    build_native_screenshot_router(
        session_manager.get_session,
        lambda: meeting_repository.assets_directory,
        process_native_screenshot,
    )
)
app.include_router(
    build_native_recording_router(
        session_manager.get_session,
        start_native_recording,
        pause_native_recording,
        resume_native_recording,
        stop_native_recording,
    )
)
app.include_router(
    build_native_transcript_router(
        session_manager.get_session,
        process_native_transcript,
    )
)


# ============= HTTP API 接口 =============


@app.get("/health")
async def health_check():
    """健康检查"""
    result = {
        "status": "healthy",
        "timestamp": datetime.now().isoformat(),
        "service": "PromptMeet FastAPI",
        "active_sessions": len(session_manager.sessions),
        "connected_clients": len(websocket_manager.connections),
        "storage": getattr(db_storage, "backend_name", "mysql"),
        "desktop_mode": DESKTOP_MODE,
    }
    if DESKTOP_MODE and desktop_agent_service is not None:
        result["ai"] = desktop_agent_service.provider_status()
    return result


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
async def create_session(request: SessionCreateRequest | None = None):
    """创建新的会议会话"""
    session_id = (
        request.session_id if request and request.session_id else str(uuid.uuid4())
    )
    existing_record = meeting_repository.get(session_id)
    if existing_record is not None:
        if existing_record.status == MeetingStatus.RECOVERY_REQUIRED:
            raise HTTPException(status_code=409, detail="会议记录需要恢复")
        if existing_record.status == MeetingStatus.INCOMPLETE:
            raise HTTPException(status_code=409, detail="不完整会议仍等待恢复完成")
        if existing_record.status == MeetingStatus.ACTIVE:
            if existing_record.ended_at is not None:
                raise HTTPException(status_code=409, detail="会议记录状态不一致")
            is_active = True
        elif existing_record.status == MeetingStatus.COMPLETED:
            is_active = False
        else:
            raise HTTPException(status_code=409, detail="会议状态不支持恢复")
    existing_session = session_manager.get_session(session_id)
    if existing_session is not None:
        return {"success": True, "session_id": session_id, "message": "会话已存在"}
    if existing_record is not None:
        restore_session_from_record(
            existing_record,
            is_recording=is_active,
            is_paused=False,
        )
        return {
            "success": True,
            "session_id": session_id,
            "message": "会话已恢复" if is_active else "会话已完成",
        }
    started_at = (
        request.started_at
        if request and request.started_at is not None
        else datetime.now(UTC)
    )
    session = SessionState(
        session_id=session_id,
        is_recording=False,
        start_time=started_at,
        end_time=None,
        current_summary=None,
        participant_count=0,
        audio_file_path=None,
    )

    session_manager.add_session(session)
    meeting_ingestion.start(session_id, session.start_time)
    logger.info("收到创建会话请求")
    # 启动Agent进程
    if not DESKTOP_MODE:
        await process_manager.start_agent_process(session_id)
    logger.info("Agent进程启动完成")
    logger.info(f"创建新会话: {session_id}")
    return {"success": True, "session_id": session_id, "message": "会话创建成功"}


@app.get("/api/sessions/{session_id}")
async def get_session(session_id: str):
    """获取会话状态"""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")

    return {"success": True, "session": session.model_dump(mode="json")}


@app.post("/api/sessions/{session_id}/rehydrate")
async def rehydrate_session(session_id: str, request: SessionRehydrateRequest):
    record = meeting_repository.get(session_id)
    if record is None:
        raise HTTPException(status_code=404, detail="会议持久记录不存在")
    if record.status != MeetingStatus.ACTIVE or record.ended_at is not None:
        raise HTTPException(status_code=409, detail="仅可恢复仍在进行的会议")
    restore_session_from_record(
        record,
        is_recording=True,
        is_paused=request.is_paused,
    )
    return {"success": True, "session_id": session_id, "rehydrated": True}


def restore_session_from_record(
    record: MeetingRecord,
    *,
    is_recording: bool,
    is_paused: bool,
) -> SessionState:
    session_id = record.meeting_id
    transcript_segments = [
        TranscriptSegment(
            id=event.payload.segment_id,
            text=event.payload.text,
            timestamp=event.occurred_at,
            confidence=1.0,
            speaker=event.payload.speaker,
            source=(
                event.payload.source
                if event.payload.source in {"system", "microphone", "mixed"}
                else None
            ),
            meeting_time_ms=event.payload.meeting_time_ms,
        )
        for event in record.events
        if event.kind == EventKind.TRANSCRIPT
        and isinstance(event.payload, TranscriptPayload)
    ]
    current_summary = None
    summary_events = sorted(
        (
            event
            for event in record.events
            if event.kind == EventKind.SUMMARY
            and isinstance(event.payload, SummaryPayload)
        ),
        key=lambda event: (event.payload.revision, event.sequence),
        reverse=True,
    )
    for event in summary_events:
        try:
            current_summary = MeetingSummary(
                session_id=session_id,
                summary_text=event.payload.summary_text,
                tasks=[TaskItem(**task) for task in event.payload.tasks],
                key_points=event.payload.key_points,
                decisions=event.payload.decisions,
                generated_at=event.occurred_at,
            )
            break
        except ValueError:
            continue
    existing = session_manager.get_session(session_id)
    restored = SessionState(
        session_id=session_id,
        is_recording=is_recording,
        is_paused=is_paused,
        start_time=record.started_at,
        end_time=None if is_recording else record.ended_at,
        transcript_segments=transcript_segments,
        current_summary=current_summary,
        participant_count=existing.participant_count if existing else 0,
        audio_file_path=existing.audio_file_path if existing else None,
    )
    if existing is None:
        session_manager.add_session(restored)
    else:
        session_manager.update_session(restored)
    return restored


@app.post("/api/sessions/{session_id}/mark-incomplete")
async def mark_session_incomplete(session_id: str):
    if meeting_repository.get(session_id) is None:
        raise HTTPException(status_code=404, detail="会话不存在")
    record = meeting_ingestion.finish(
        session_id,
        MeetingStatus.INCOMPLETE,
        "会议采集未完整启动，已保留当前记录",
    )
    persist_meeting_title_fallback(session_id)
    schedule_meeting_title_generation(session_id)
    return {
        "success": True,
        "status": record.status.value,
        "schema_version": record.schema_version,
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


def accumulated_summary_progress(
    summaries: list[MeetingEvent], source_events: list[MeetingEvent]
) -> dict[str, int]:
    sources = {event.event_id: event for event in source_events}
    progress: dict[str, int] = {}
    for summary_event in sorted(
        summaries, key=lambda event: (event.payload.revision, event.sequence)
    ):
        payload = summary_event.payload
        for event_id in payload.source_event_ids:
            event = sources.get(event_id)
            if event is not None:
                progress[event_id] = len(DesktopAgentService.summary_event_text(event))
        for event_id, offset in payload.source_progress.items():
            event = sources.get(event_id)
            if event is None:
                continue
            total = len(DesktopAgentService.summary_event_text(event))
            bounded = min(max(0, offset), total)
            progress[event_id] = max(progress.get(event_id, 0), bounded)
    return progress


def merge_incremental_summary(
    session_id: str,
    raw_summary: dict,
    previous_summary: SummaryPayload | None,
) -> MeetingSummary:
    generated = MeetingSummary(
        session_id=session_id,
        summary_text=raw_summary["summary_text"],
        tasks=[TaskItem(**task) for task in raw_summary.get("tasks", [])],
        key_points=raw_summary.get("key_points", []),
        decisions=raw_summary.get("decisions", []),
        generated_at=datetime.now(),
    )
    if previous_summary is None:
        return generated
    tasks = list(generated.tasks)
    task_names = {task.task.strip().casefold() for task in tasks}
    for value in previous_summary.tasks:
        try:
            task = TaskItem(**value)
        except ValueError:
            continue
        identity = task.task.strip().casefold()
        status = task.status.strip().casefold()
        if status not in {"pending", "in_progress"} or identity in task_names:
            continue
        tasks.append(task)
        task_names.add(identity)

    return generated.model_copy(update={"tasks": tasks})


async def generate_desktop_summary(
    session_id: str,
    session: SessionState,
    request: SummaryGenerationRequest | None,
) -> dict:
    record = meeting_repository.get(session_id)
    if record is None:
        raise HTTPException(status_code=404, detail="会议持久记录不存在")
    source_events = [
        event
        for event in record.events
        if event.kind
        in {
            EventKind.TRANSCRIPT,
            EventKind.SCREENSHOT,
            EventKind.SCREENSHOT_ANALYSIS,
        }
    ]
    previous_summaries = [
        event
        for event in record.events
        if event.kind == EventKind.SUMMARY and isinstance(event.payload, SummaryPayload)
    ]
    source_by_id = {event.event_id: event for event in source_events}
    source_progress = accumulated_summary_progress(previous_summaries, source_events)
    uncovered_events = [
        event
        for event in source_events
        if source_progress.get(event.event_id, 0)
        < len(DesktopAgentService.summary_event_text(event))
    ]
    if not uncovered_events:
        return {
            "success": True,
            "status": "no_action",
            "message": "没有新的会议输入，已跳过本次摘要与待办生成",
        }
    latest_previous_summary = max(
        previous_summaries,
        key=lambda event: (event.payload.revision, event.sequence),
        default=None,
    )
    summary_inputs = (
        [latest_previous_summary, *uncovered_events]
        if latest_previous_summary is not None
        else uncovered_events
    )
    result = await desktop_agent_service.summarize_meeting(
        record, summary_inputs, source_progress
    )
    latest_record = meeting_repository.get(session_id)
    if latest_record is None:
        raise HTTPException(status_code=404, detail="会议持久记录不存在")
    latest_summaries = [
        event
        for event in latest_record.events
        if event.kind == EventKind.SUMMARY and isinstance(event.payload, SummaryPayload)
    ]
    latest_progress = accumulated_summary_progress(latest_summaries, source_events)
    advanced_progress: dict[str, int] = {}
    for event_id, proposed in result.source_progress.items():
        event = source_by_id.get(event_id)
        if event is None or not isinstance(proposed, int) or isinstance(proposed, bool):
            raise ValueError("摘要服务返回了无效的证据进度")
        total = len(DesktopAgentService.summary_event_text(event))
        current = latest_progress.get(event_id, 0)
        if proposed > total:
            raise ValueError("摘要服务返回的证据进度超过原始内容")
        if proposed > current:
            advanced_progress[event_id] = proposed
    if not advanced_progress:
        return {
            "success": True,
            "status": "no_action",
            "message": "当前会议输入已由另一份摘要覆盖",
        }
    revision = (
        max(
            (event.payload.revision for event in latest_summaries),
            default=0,
        )
        + 1
    )
    completed_event_ids = [
        event.event_id
        for event in source_events
        if advanced_progress.get(event.event_id)
        == len(DesktopAgentService.summary_event_text(event))
    ]
    if set(result.source_event_ids) != set(completed_event_ids):
        raise ValueError("摘要服务返回的完成证据与进度不一致")
    latest_previous_summary = max(
        latest_summaries,
        key=lambda event: (event.payload.revision, event.sequence),
        default=None,
    )
    summary = merge_incremental_summary(
        session_id,
        result.summary,
        latest_previous_summary.payload if latest_previous_summary else None,
    )
    summary_data = {
        "summary_text": summary.summary_text,
        "tasks": [task.model_dump(mode="json") for task in summary.tasks],
        "key_points": summary.key_points,
        "decisions": summary.decisions,
    }
    combined_progress = {**latest_progress, **advanced_progress}
    source_revision = max(
        (
            event.sequence
            for event in source_events
            if combined_progress.get(event.event_id, 0)
            == len(DesktopAgentService.summary_event_text(event))
        ),
        default=0,
    )
    timeline_event = meeting_ingestion.summary(
        session_id,
        summary_data,
        revision=revision,
        source_event_ids=completed_event_ids,
        source_progress=advanced_progress,
        source_revision=source_revision,
        trigger=request.trigger if request else "manual",
        active_minutes=request.active_minutes if request else None,
        provider=result.provider,
        model=result.model,
    )
    session.current_summary = summary
    session_manager.update_session(session)
    await websocket_manager.broadcast_to_session(
        session_id,
        {
            "type": MessageType.SUMMARY_GENERATED,
            "data": summary.model_dump(mode="json"),
            "timestamp": datetime.now(),
            "session_id": session_id,
        },
    )
    await broadcast_meeting_event(session_id, timeline_event)
    return {
        "success": True,
        "status": "generated",
        "message": "会议摘要与待办已生成",
        "event": timeline_event.model_dump(mode="json"),
    }


@app.post("/api/sessions/{session_id}/generate-summary")
async def generate_summary(
    session_id: str,
    request: SummaryGenerationRequest | None = None,
):
    """生成会议摘要"""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")

    if not DESKTOP_MODE and not session.transcript_segments:
        return {"success": False, "message": "没有转录内容可分析"}

    try:
        if DESKTOP_MODE and desktop_agent_service is not None:
            lock = summary_generation_locks.setdefault(session_id, asyncio.Lock())
            async with lock:
                return await generate_desktop_summary(session_id, session, request)
        await process_manager.start_summary_process(session_id)

        logger.info(f"会话 {session_id} 开始生成摘要")
        return {"success": True, "status": "generated", "message": "开始生成摘要"}

    except Exception as e:
        logger.error(f"生成摘要失败: {e}")
        return {
            "success": False,
            "status": "failed",
            "message": f"生成摘要失败: {str(e)}",
        }


@app.post("/api/sessions/{session_id}/generate-questions")
async def generate_questions(
    session_id: str,
    request: QuestionGenerationRequest | None = None,
):
    """生成会议问题"""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")

    try:
        if DESKTOP_MODE and desktop_agent_service is not None:
            context = suggestion_context(session_id, session)
            if not context:
                return {"success": False, "message": "没有可生成问题的会议内容"}
            generation_id = request.generation_id if request else str(uuid.uuid4())
            context_revision = (
                request.context_revision
                if request
                else len(session.transcript_segments)
            )
            generation = (generation_id, context_revision)
            latest_question_generations[session_id] = generation
            previous = question_generation_tasks.get(session_id)
            if previous is not None and not previous.done():
                previous.cancel()
            generation_task = asyncio.create_task(
                desktop_agent_service.generate_questions(context),
                name=f"suggestions-{session_id}-{generation_id}",
            )
            question_generation_tasks[session_id] = generation_task
            try:
                questions = await generation_task
            except asyncio.CancelledError:
                return {"success": True, "superseded": True}
            finally:
                if question_generation_tasks.get(session_id) is generation_task:
                    question_generation_tasks.pop(session_id, None)
            if latest_question_generations.get(session_id) != generation:
                return {"success": True, "superseded": True}
            normalized = []
            seen = set()
            duplicated = False
            for item in questions:
                if not isinstance(item, dict):
                    continue
                question = item.get("question")
                if not isinstance(question, str):
                    continue
                question = question.strip()
                if not question:
                    continue
                if question in seen:
                    duplicated = True
                else:
                    seen.add(question)
                    normalized.append(item)
            accepted = not duplicated and 2 <= len(normalized) <= 3
            payload = {"questions": normalized if accepted else []}
            if request is not None:
                payload.update(
                    {
                        "generation_id": generation_id,
                        "context_revision": context_revision,
                    }
                )
            if not accepted:
                await on_questions_generated(session_id, payload)
                return {
                    "success": True,
                    "message": "本次没有足够的严格依据，已保留上次问题",
                    "superseded": False,
                    "accepted": False,
                }
            record = meeting_repository.get(session_id)
            if record is not None:
                event = meeting_ingestion.suggestions(
                    session_id,
                    generation_id,
                    context_revision,
                    [item["question"] for item in normalized],
                )
                await broadcast_meeting_event(session_id, event)
            await on_questions_generated(session_id, payload)
            logger.info(f"会话 {session_id} 已生成桌面追问")
            return {
                "success": True,
                "message": "问题已生成",
                "superseded": False,
                "accepted": True,
            }
        if not session.transcript_segments:
            return {"success": False, "message": "没有转录内容可生成问题"}
        # 启动 Question 生成进程
        await process_manager.start_question_process(session_id)

        logger.info(f"会话 {session_id} 开始生成问题")
        return {"success": True, "message": "开始生成问题"}

    except Exception as e:
        logger.error(f"生成问题失败: {e}")
        return {"success": False, "message": f"生成问题失败: {str(e)}"}


def suggestion_context(session_id: str, session: SessionState) -> list:
    record = meeting_repository.get(session_id)
    if record is None:
        return list(session.transcript_segments)
    items = []
    for event in record.events:
        payload = event.payload
        if isinstance(payload, TranscriptPayload):
            items.append(
                SimpleNamespace(
                    speaker=payload.speaker,
                    text=payload.text,
                    timestamp=event.occurred_at,
                )
            )
        elif isinstance(payload, ScreenshotAnalysisPayload):
            items.append(
                SimpleNamespace(
                    speaker="截图分析",
                    text=payload.text,
                    timestamp=event.occurred_at,
                )
            )
        elif isinstance(payload, QuestionPayload):
            items.append(
                SimpleNamespace(
                    speaker="用户问题",
                    text=payload.question,
                    timestamp=event.occurred_at,
                )
            )
        elif isinstance(payload, AnswerPayload) and payload.status == "completed":
            items.append(
                SimpleNamespace(
                    speaker="AI回答",
                    text=payload.answer,
                    timestamp=event.occurred_at,
                )
            )
    return items


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

        if DESKTOP_MODE:
            record = meeting_repository.get(session_id)
            if record is None:
                raise HTTPException(status_code=404, detail="会议持久记录不存在")
            if record.status == MeetingStatus.ACTIVE:
                record = meeting_ingestion.finish(
                    session_id,
                    MeetingStatus.INCOMPLETE,
                    "会议已保存，但尚未收到正常结束事件",
                )
                persist_meeting_title_fallback(session_id)
                schedule_meeting_title_generation(session_id)
            return {
                "success": True,
                "message": "会话存储成功",
                "session_id": session_id,
                "stored_at": datetime.now(UTC).isoformat(),
                "schema_version": record.schema_version,
            }

        # 转换为字典格式
        session_dict = session.model_dump()

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
            "stored_at": datetime.now().isoformat(),
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


# ============= 会议上下文接口 =============


@app.get("/api/meetings")
async def list_meeting_records():
    return [record.model_dump(mode="json") for record in meeting_repository.list()]


@app.get("/api/meetings/{meeting_id}")
async def get_meeting_record(meeting_id: str):
    record = meeting_repository.get(meeting_id)
    if record is None:
        raise HTTPException(status_code=404, detail="会议不存在")
    return record.model_dump(mode="json")


@app.get("/api/meetings/{meeting_id}/assets/{asset_id}")
async def get_meeting_asset(meeting_id: str, asset_id: str):
    record = meeting_repository.get(meeting_id)
    if record is None:
        raise HTTPException(status_code=404, detail="会议不存在")
    payload = next(
        (
            event.payload
            for event in record.events
            if event.kind == EventKind.SCREENSHOT
            and isinstance(event.payload, ScreenshotPayload)
            and event.payload.asset_id == asset_id
        ),
        None,
    )
    if payload is None:
        raise HTTPException(status_code=404, detail="截图记录不存在")
    root = meeting_repository.root.resolve()
    path = (root / payload.relative_path).resolve()
    if root not in path.parents or not path.is_file():
        raise HTTPException(status_code=404, detail="截图文件已丢失，会议记录仍保留")
    return FileResponse(path, media_type=payload.mime_type, filename=path.name)


async def process_meeting_question(
    meeting_id: str,
    request_id: str,
    thread_id: str,
    question: str,
):
    question_event = None
    try:
        question_event, snapshot = meeting_ingestion.question(
            meeting_id,
            request_id,
            thread_id,
            question,
        )
        await broadcast_meeting_event(meeting_id, question_event)
        if desktop_agent_service is None:
            raise RuntimeError("AI 服务不可用")
        result = await desktop_agent_service.answer_meeting(
            snapshot,
            question,
            lambda response: on_agent_response(meeting_id, response, request_id),
            thread_id=thread_id,
            exclude_event_ids={question_event.event_id},
        )
        answer_event = meeting_ingestion.answer(
            meeting_id,
            request_id,
            thread_id,
            result.answer,
            result.sources,
            degraded_vision=result.degraded_vision,
            provider=result.provider,
            model=result.model,
        )
        await broadcast_meeting_event(meeting_id, answer_event)
        return result, answer_event
    except MeetingNotFoundError as error:
        raise HTTPException(status_code=404, detail="会议不存在") from error
    except Exception as error:
        if question_event is not None:
            failure_event = meeting_ingestion.answer_failure(
                meeting_id,
                request_id,
                thread_id,
                str(error),
            )
            await broadcast_meeting_event(meeting_id, failure_event)
        await websocket_manager.broadcast_to_session(
            meeting_id,
            {
                "type": "error",
                "data": {
                    "scope": "ai",
                    "request_id": request_id,
                    "message": str(error),
                },
            },
        )
        raise


@app.post("/api/meetings/{meeting_id}/questions")
async def ask_meeting_question(meeting_id: str, request: MeetingQuestionRequest):
    try:
        result, answer_event = await process_meeting_question(
            meeting_id,
            request.request_id,
            request.thread_id,
            request.question,
        )
    except HTTPException:
        raise
    except Exception as error:
        raise HTTPException(status_code=503, detail=str(error)) from error
    return {
        "request_id": request.request_id,
        "answer": result.answer,
        "sources": [source.model_dump(mode="json") for source in result.sources],
        "degraded_vision": result.degraded_vision,
        "event": answer_event.model_dump(mode="json"),
    }


# ============= WebSocket 接口 =============


@app.websocket("/ws/{session_id}")
async def websocket_endpoint(websocket: WebSocket, session_id: str):
    """WebSocket连接端点"""
    if session_manager.get_session(session_id) is None:
        await websocket.close(code=4404, reason="会话不存在")
        return
    await websocket_manager.connect(websocket, session_id)
    if session_manager.get_session(session_id) is None:
        websocket_manager.disconnect(websocket, session_id)
        await websocket.close(code=4404, reason="会话不存在")
        return

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
        if DESKTOP_MODE and desktop_agent_service is not None:
            session = session_manager.get_session(session_id)
            request_id = data.get("request_id")
            if hasattr(desktop_agent_service, "answer_meeting"):
                task = asyncio.create_task(
                    process_meeting_question(
                        session_id,
                        str(request_id or uuid.uuid4()),
                        str(data.get("thread_id") or "main"),
                        str(data.get("content") or ""),
                    ),
                    name=f"meeting-question-{session_id}-{request_id}",
                )
                meeting_question_tasks.add(task)
                task.add_done_callback(finish_question_task)
                return
            try:
                await desktop_agent_service.answer(
                    data.get("content", ""),
                    session.transcript_segments if session else [],
                    lambda response: on_agent_response(
                        session_id, response, request_id
                    ),
                )
            except Exception as e:
                await websocket_manager.broadcast_to_session(
                    session_id,
                    {
                        "type": "error",
                        "data": {
                            "scope": "ai",
                            "request_id": request_id,
                            "message": str(e),
                        },
                    },
                )
            return
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
async def on_agent_response(
    session_id: str, response: dict, request_id: str | None = None
):
    """处理Agent响应，支持流式分片"""
    # 兼容旧结构，提取最终回答内容
    try:
        data = response.get("data", {})
        # 流式分片
        if isinstance(data, dict) and ("delta" in data or "chunk" in data):
            delta = data.get("delta") or data.get("chunk")
            await websocket_manager.broadcast_to_session(
                session_id,
                {"type": "answer", "data": {"request_id": request_id, "delta": delta}},
            )
            return
        # 完整内容
        if isinstance(data, dict) and "content" in data:
            await websocket_manager.broadcast_to_session(
                session_id,
                {
                    "type": "answer",
                    "data": {"request_id": request_id, "content": data["content"]},
                },
            )
            return
        # 邮件相关
        content = None
        if isinstance(data, str):
            content = data
        elif isinstance(data, dict):
            if isinstance(data.get("response"), str):
                content = data["response"]
            elif isinstance(data.get("output"), str):
                content = data["output"]
            elif isinstance(data.get("content"), str):
                content = data["content"]
        if content and ("邮件" in content or "email" in content.lower()):
            await websocket_manager.broadcast_to_session(
                session_id, {"type": "email_response", "data": {"content": content}}
            )
        elif content:
            await websocket_manager.broadcast_to_session(
                session_id, {"type": "answer", "data": {"content": content}}
            )
    except Exception:
        await websocket_manager.broadcast_to_session(
            session_id, {"type": "answer", "data": {"content": str(response)}}
        )


# 注册回调
process_manager.on_agent_response = on_agent_response

# ============= Database 接口 =============


def legacy_meeting_projection(record: MeetingRecord) -> dict:
    transcripts = []
    summaries = []
    image_results = []
    for event in record.events:
        if isinstance(event.payload, TranscriptPayload):
            transcripts.append(
                {
                    "id": event.payload.segment_id,
                    "text": event.payload.text,
                    "speaker": event.payload.speaker,
                    "source": event.payload.source,
                    "translated_text": event.payload.translated_text,
                    "timestamp": event.occurred_at.isoformat(),
                }
            )
        elif isinstance(event.payload, SummaryPayload):
            summaries.append(event.payload.model_dump(mode="json", exclude={"type"}))
        elif isinstance(event.payload, ScreenshotAnalysisPayload):
            image_results.append(
                {
                    "asset_id": event.payload.asset_id,
                    "content": event.payload.text,
                    "status": event.payload.status,
                    "vision_used": event.payload.vision_used,
                }
            )
    return {
        "schema_version": record.schema_version,
        "session_id": record.meeting_id,
        "start_time": record.started_at.isoformat(),
        "end_time": record.ended_at.isoformat() if record.ended_at else None,
        "status": record.status.value,
        "transcript_segments": transcripts,
        "current_summary": summaries[-1] if summaries else None,
        "image_ocr_result": image_results,
        "events": [event.model_dump(mode="json") for event in record.events],
    }


@app.get("/db/sessions", response_class=JSONResponse)
async def get_all_sessions():
    """获取所有会话列表"""
    try:
        if DESKTOP_MODE:
            return JSONResponse(
                content=[
                    legacy_meeting_projection(record)
                    for record in meeting_repository.list()
                ]
            )
        sessions_json = db_storage.get_all_sessions()
        return JSONResponse(content=json.loads(sessions_json))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"获取会话列表失败: {str(e)}")


@app.get("/db/sessions/{session_id}", response_class=JSONResponse)
async def get_session_details(session_id: str):
    """获取会话详情"""
    try:
        if DESKTOP_MODE:
            record = meeting_repository.get(session_id)
            if record is None:
                raise HTTPException(status_code=404, detail="会话不存在")
            return JSONResponse(content=legacy_meeting_projection(record))
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


async def on_transcript_received(session_id: str, transcript_data: dict) -> bool | None:
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
            end_time=transcript_data.get("end_time"),  # 或者合适的默认值
            source=transcript_data.get("source"),
            meeting_time_ms=transcript_data.get("meeting_time_ms"),
        )
        timeline_event, inserted = meeting_ingestion.transcript_with_status(
            session_id, transcript_data
        )
        if not inserted:
            return False

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
                "data": segment.model_dump(mode="json"),
                "timestamp": datetime.now(),
                "session_id": session_id,
            },
        )
        await broadcast_meeting_event(session_id, timeline_event)

        logger.info(
            f"转录片段已添加: session={session_id}, text={segment.text[:50]}..."
        )
        await persist_session(session_id)
        return True

    except Exception as e:
        logger.error(f"处理转录结果失败: {e}")
        return None


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
        timeline_event = meeting_ingestion.summary(session_id, summary_data)

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
                "data": summary.model_dump(mode="json"),
                "timestamp": datetime.now(),
                "session_id": session_id,
            },
        )
        await broadcast_meeting_event(session_id, timeline_event)

        logger.info(f"摘要已生成: session={session_id}")
        await persist_session(session_id)

    except Exception as e:
        logger.error(f"处理摘要结果失败: {e}")


async def persist_session(session_id: str) -> bool:
    if DESKTOP_MODE:
        return meeting_repository.get(session_id) is not None
    session = session_manager.get_session(session_id)
    if not session:
        return False
    return await asyncio.get_running_loop().run_in_executor(
        None,
        db_storage.store_session,
        session.model_dump(),
    )


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
                "data": progress.model_dump(mode="json"),
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

        batch_message = {
            "type": "questions",
            "data": {"questions": questions},
            "timestamp": datetime.now().isoformat(),
            "session_id": session_id,
        }
        if questions_data.get("generation_id") is not None:
            batch_message["data"]["generation_id"] = questions_data["generation_id"]
            batch_message["data"]["context_revision"] = questions_data[
                "context_revision"
            ]
        await websocket_manager.broadcast_to_session(session_id, batch_message)

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
                "data": {"id": i, "content": question_content},
                "timestamp": datetime.now().isoformat(),
                "session_id": session_id,
            }

            if questions_data.get("generation_id") is None:
                await websocket_manager.broadcast_to_session(
                    session_id, question_message
                )
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


def server_options() -> dict:
    if DESKTOP_MODE:
        return {
            "host": "127.0.0.1",
            "port": 8000,
            "reload": False,
            "log_level": "info",
        }
    return {
        "host": "0.0.0.0",
        "port": 8000,
        "reload": True,
        "log_level": "info",
    }


if __name__ == "__main__":
    target = app if DESKTOP_MODE else "main_service:app"
    uvicorn.run(target, **server_options())
