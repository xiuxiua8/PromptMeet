"""
进程管理器
负责启动、管理和协调 Whisper 转录和 Summary 分析子进程
"""
import sys
import asyncio
import json
import logging
import subprocess
import uuid
from datetime import datetime
from pathlib import Path
from typing import Dict, Optional, Callable, Any
import os
import signal
from dotenv import load_dotenv
from models.data_models import ProcessStatus, IPCMessage, IPCCommand, IPCResponse

logger = logging.getLogger(__name__)

class ProcessManager:
    """子进程管理器"""
    
    def __init__(self):
        self.processes: Dict[str, ProcessStatus] = {}
        self.whisper_processes: Dict[str, subprocess.Popen] = {}
        self.summary_processes: Dict[str, subprocess.Popen] = {}
        self.image_processes: Dict[str, subprocess.Popen] = {}

        
        # IPC 回调函数
        self.on_transcript_received: Optional[Callable] = None
        self.on_summary_generated: Optional[Callable] = None
        self.on_progress_update: Optional[Callable] = None
        self.on_image_result_received: Optional[Callable] = None
        
        # 工作目录 - 使用项目根目录下的temp_sessions，与进程cwd保持一致
        project_root = Path(__file__).parent.parent.parent
        self.work_dir = project_root / "temp_sessions"
        self.work_dir.mkdir(exist_ok=True)

    async def initialize(self):
        """初始化进程管理器"""
        logger.info("进程管理器初始化...")
        
        # 清理可能存在的僵尸进程
        await self._cleanup_orphaned_processes()
        
        logger.info("进程管理器初始化完成")

    async def cleanup(self):
        """清理所有进程"""
        logger.info("正在清理所有子进程...")
        
        # 停止所有进程
        for session_id in list(self.processes.keys()):
            await self.stop_session_processes(session_id)
        
        logger.info("子进程清理完成")

    async def start_whisper_process(self, session_id: str) -> str:
        """启动 Whisper 转录进程"""
        process_id = f"whisper_{session_id}_{uuid.uuid4().hex[:8]}"
        
        try:
            # 创建会话工作目录
            session_dir = self.work_dir / session_id
            session_dir.mkdir(exist_ok=True)
            
            # 准备启动参数
            script_path = Path(__file__).parent.parent / "processors" / "whisper_processor.py"
            
            # IPC 通信文件路径
            ipc_input = session_dir / "whisper_input.pipe"
            ipc_output = session_dir / "whisper_output.pipe"
            
            # 启动进程
            cmd = [
                sys.executable, 
                str(script_path),
                "--session-id", session_id,
                "--ipc-input", str(ipc_input),
                "--ipc-output", str(ipc_output),
                "--work-dir", str(session_dir)
            ]
            
            logger.info(f"启动 Whisper 进程: {' '.join(cmd)}")
            
            # 使用项目根目录作为工作目录
            project_root = Path(__file__).parent.parent.parent
            
            # 确保环境变量正确加载
            env_path = project_root / ".env"
            load_dotenv(env_path)
            
            # 创建完整的环境变量字典
            env = os.environ.copy()
            
            # 将子进程的日志重定向到主程序的stdout，这样日志会合并
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,  # 捕获输出以便转发到主程序日志
                stderr=subprocess.STDOUT,  # 将stderr重定向到stdout
                cwd=project_root,
                env=env,
                text=True,  # 以文本模式处理输出
                bufsize=1,  # 行缓冲
                universal_newlines=True,
                encoding='utf-8',
                errors='replace'
            )
            
            # 启动一个任务来转发子进程的日志到主程序
            asyncio.create_task(
                self._forward_process_logs(process, f"Whisper[{session_id[:8]}]")
            )
            
            # 记录进程状态
            status = ProcessStatus(
                process_id=process_id,
                module_name="whisper",
                session_id=session_id,
                status="starting",
                pid=process.pid,
                start_time=datetime.now(),
                last_update=datetime.now()
            )
            
            self.processes[process_id] = status
            self.whisper_processes[session_id] = process
            
            # 启动输出监听任务
            asyncio.create_task(
                self._monitor_whisper_output(session_id, ipc_output)
            )
            
            # 发送启动命令
            await self._send_ipc_command(
                ipc_input, 
                IPCCommand(
                    command="start",
                    session_id=session_id,
                    params={}
                )
            )
            
            # 更新进程状态
            status.status = "running"
            status.last_update = datetime.now()
            
            logger.info(f"Whisper 进程启动成功: {process_id}, PID: {process.pid}")
            return process_id
            
        except Exception as e:
            logger.error(f"启动 Whisper 进程失败: {e}")
            raise

    async def stop_whisper_process(self, session_id: str):
        """停止 Whisper 转录进程"""
        try:
            if session_id not in self.whisper_processes:
                logger.warning(f"会话 {session_id} 没有运行的 Whisper 进程")
                return
            
            process = self.whisper_processes[session_id]
            
            # 发送停止信号
            process.terminate()
            
            # 等待进程结束
            try:
                await asyncio.wait_for(
                    asyncio.to_thread(process.wait),
                    timeout=5.0
                )
            except asyncio.TimeoutError:
                logger.warning(f"Whisper 进程 {process.pid} 未在5秒内结束，强制终止")
                process.kill()
            
            # 清理进程记录
            del self.whisper_processes[session_id]
            
            # 更新进程状态
            for process_id, status in self.processes.items():
                if status.session_id == session_id and status.module_name == "whisper":
                    status.status = "stopped"
                    status.last_update = datetime.now()
                    break
            
            logger.info(f"Whisper 进程已停止: session={session_id}")
            
        except Exception as e:
            logger.error(f"停止 Whisper 进程失败: {e}")

    async def start_summary_process(self, session_id: str) -> str:
        """启动 Summary 分析进程"""
        process_id = f"summary_{session_id}_{uuid.uuid4().hex[:8]}"
        
        try:
            # 创建会话工作目录
            session_dir = self.work_dir / session_id
            session_dir.mkdir(exist_ok=True)
            
            # 准备启动参数
            script_path = Path(__file__).parent.parent / "processors" / "summary_processor.py"
            
            # IPC 通信文件路径
            ipc_input = session_dir / "summary_input.pipe"
            ipc_output = session_dir / "summary_output.pipe"
            
            # 启动进程
            cmd = [
                sys.executable,
                str(script_path),
                "--session-id", session_id,
                "--ipc-input", str(ipc_input),
                "--ipc-output", str(ipc_output),
                "--work-dir", str(session_dir)
            ]
            
            logger.info(f"启动 Summary 进程: {' '.join(cmd)}")
            
            # 使用项目根目录作为工作目录
            project_root = Path(__file__).parent.parent.parent
            
            # 确保环境变量正确加载
            env_path = project_root / ".env"
            load_dotenv(env_path)
            
            # 创建完整的环境变量字典
            env = os.environ.copy()
            
            # 将子进程的日志重定向到主程序的stdout，这样日志会合并
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,  # 捕获输出以便转发到主程序日志
                stderr=subprocess.STDOUT,  # 将stderr重定向到stdout
                cwd=project_root,
                env=env,
                text=True,  # 以文本模式处理输出
                bufsize=1,  # 行缓冲
                universal_newlines=True,
                encoding='utf-8',
                errors='replace'
            )
            
            # 启动一个任务来转发子进程的日志到主程序
            asyncio.create_task(
                self._forward_process_logs(process, f"Summary[{session_id[:8]}]")
            )
            
            # 记录进程状态
            status = ProcessStatus(
                process_id=process_id,
                module_name="summary",
                session_id=session_id,
                status="starting",
                pid=process.pid,
                start_time=datetime.now(),
                last_update=datetime.now()
            )
            
            self.processes[process_id] = status
            self.summary_processes[session_id] = process
            
            # 启动输出监听任务
            asyncio.create_task(
                self._monitor_summary_output(session_id, ipc_output)
            )
            
            # 发送启动命令
            await self._send_ipc_command(
                ipc_input,
                IPCCommand(
                    command="start",
                    session_id=session_id,
                    params={}
                )
            )
            
            # 更新进程状态
            status.status = "running"
            status.last_update = datetime.now()
            
            logger.info(f"Summary 进程启动成功: {process_id}, PID: {process.pid}")
            return process_id
            
        except Exception as e:
            logger.error(f"启动 Summary 进程失败: {e}")
            raise

    async def stop_summary_process(self, session_id: str):
        """停止 Summary 分析进程"""
        try:
            if session_id not in self.summary_processes:
                logger.warning(f"会话 {session_id} 没有运行的 Summary 进程")
                return
            
            process = self.summary_processes[session_id]
            
            # 发送停止信号
            process.terminate()
            
            # 等待进程结束
            try:
                await asyncio.wait_for(
                    asyncio.to_thread(process.wait),
                    timeout=5.0
                )
            except asyncio.TimeoutError:
                logger.warning(f"Summary 进程 {process.pid} 未在5秒内结束，强制终止")
                process.kill()
            
            # 清理进程记录
            del self.summary_processes[session_id]
            
            # 更新进程状态
            for process_id, status in self.processes.items():
                if status.session_id == session_id and status.module_name == "summary":
                    status.status = "stopped"
                    status.last_update = datetime.now()
                    break
            
            logger.info(f"Summary 进程已停止: session={session_id}")
            
        except Exception as e:
            logger.error(f"停止 Summary 进程失败: {e}")

    async def start_image_process(self, session_id: str) -> str:
        """启动 Image OCR 进程"""
        process_id = f"image_{session_id}_{uuid.uuid4().hex[:8]}"
        
        try:
            session_dir = self.work_dir / session_id
            session_dir.mkdir(exist_ok=True)

            script_path = Path(__file__).parent.parent / "processors" / "image_processor.py"
            ipc_input = session_dir / "image_input.pipe"
            ipc_output = session_dir / "image_output.pipe"

            cmd = [
                sys.executable,
                str(script_path),
                "--session-id", session_id,
                "--ipc-input", str(ipc_input),
                "--ipc-output", str(ipc_output),
                "--work-dir", str(session_dir)
            ]

            logger.info(f"启动 Image OCR 进程: {' '.join(cmd)}")

            project_root = Path(__file__).parent.parent.parent
            load_dotenv(project_root / ".env")
            env = os.environ.copy()

            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                cwd=project_root,
                env=env,
                text=True,
                bufsize=1,
                universal_newlines=True,
                encoding='utf-8',
    errors='replace'
            )

            asyncio.create_task(self._forward_process_logs(process, f"Image[{session_id[:8]}]"))

            status = ProcessStatus(
                process_id=process_id,
                module_name="image",
                session_id=session_id,
                status="starting",
                pid=process.pid,
                start_time=datetime.now(),
                last_update=datetime.now()
            )

            self.processes[process_id] = status
            self.image_processes[session_id] = process

            asyncio.create_task(self._monitor_image_output(session_id, ipc_output))

            await self._send_ipc_command(ipc_input, IPCCommand(command="start", session_id=session_id, params={}))

            status.status = "running"
            status.last_update = datetime.now()
            logger.info(f"Image 进程启动成功: {process_id}, PID: {process.pid}")
            return process_id

        except Exception as e:
            logger.error(f"启动 Image 进程失败: {e}")
            raise

    async def stop_session_processes(self, session_id: str):
        """停止会话相关的所有进程"""
        logger.info(f"停止会话 {session_id} 的所有进程")
        
        # 停止 Whisper 进程
        if session_id in self.whisper_processes:
            await self.stop_whisper_process(session_id)
        
        # 停止 Summary 进程
        if session_id in self.summary_processes:
            await self.stop_summary_process(session_id)   

        
        # 清理会话目录
        session_dir = self.work_dir / session_id
        if session_dir.exists():
            try:
                import shutil
                shutil.rmtree(session_dir)
                logger.info(f"会话目录已清理: {session_dir}")
            except Exception as e:
                logger.warning(f"清理会话目录失败: {e}")

    async def _monitor_whisper_output(self, session_id: str, output_pipe: Path):
        """监听 Whisper 进程输出"""
        logger.info(f"开始监听 Whisper 输出: {output_pipe}")
        
        # 记录已读取的行数
        last_line_count = 0
        
        try:
            while session_id in self.whisper_processes:
                if output_pipe.exists():
                    try:
                        with open(output_pipe, 'r', encoding='utf-8') as f:
                            lines = f.readlines()
                            # 只处理新的行
                            new_lines = lines[last_line_count:]
                            last_line_count = len(lines)
                            
                            for line in new_lines:
                                line = line.strip()
                                if line:
                                    message = json.loads(line)
                                    await self._handle_whisper_message(session_id, message)
                    except (json.JSONDecodeError, FileNotFoundError):
                        pass
                
                await asyncio.sleep(0.1)
        
        except Exception as e:
            logger.error(f"监听 Whisper 输出错误: {e}")

    async def _monitor_summary_output(self, session_id: str, output_pipe: Path):
        """监听 Summary 进程输出"""
        logger.info(f"开始监听 Summary 输出: {output_pipe}")
        
        # 记录已读取的行数，避免重复处理
        last_line_count = 0
        
        try:
            while session_id in self.summary_processes:
                if output_pipe.exists():
                    try:
                        with open(output_pipe, 'r', encoding='utf-8') as f:
                            lines = f.readlines()
                            # 只处理新的行
                            new_lines = lines[last_line_count:]
                            last_line_count = len(lines)
                            
                            for line in new_lines:
                                line = line.strip()
                                if line:
                                    message = json.loads(line)
                                    await self._handle_summary_message(session_id, message)
                    except (json.JSONDecodeError, FileNotFoundError):
                        pass
                
                await asyncio.sleep(0.1)
        
        except Exception as e:
            logger.error(f"监听 Summary 输出错误: {e}")

    async def _monitor_image_output(self, session_id: str, output_pipe: Path):
        """监听 Image OCR 输出"""
        logger.info(f"开始监听 Image 输出: {output_pipe}")
        last_line_count = 0

        try:
            while session_id in self.image_processes:
                if output_pipe.exists():
                    try:
                        with open(output_pipe, 'r', encoding='utf-8') as f:
                            lines = f.readlines()
                            new_lines = lines[last_line_count:]
                            last_line_count = len(lines)

                            for line in new_lines:
                                line =line.strip()
                                if line:
                                    message = json.loads(line)
                                    await self._handle_image_message(session_id, message)
                    except (json.JSONDecodeError, FileNotFoundError):
                        pass
                await asyncio.sleep(0.1)

        except Exception as e:
            logger.error(f"监听 Image 输出错误: {e}")



    async def _handle_whisper_message(self, session_id: str, message: dict):
        """处理来自 Whisper 进程的消息"""
        message_type = message.get("type")
        
        if message_type == "transcript":
            # 转录结果
            if self.on_transcript_received:
                await self.on_transcript_received(session_id, message["data"])
        
        elif message_type == "progress":
            # 进度更新
            if self.on_progress_update:
                await self.on_progress_update(session_id, {
                    "session_id": session_id,
                    "module": "whisper",
                    **message["data"]
                })

    async def _handle_summary_message(self, session_id: str, message: dict):
        """处理来自 Summary 进程的消息"""
        message_type = message.get("type")
        
        if message_type == "summary":
            # 摘要结果
            if self.on_summary_generated:
                await self.on_summary_generated(session_id, message["data"])
        
        elif message_type == "progress":
            # 进度更新
            if self.on_progress_update:
                await self.on_progress_update(session_id, {
                    "session_id": session_id,
                    "module": "summary",
                    **message["data"]
                })

    async def _handle_image_message(self, session_id: str, message: dict):
        message_type = message.get("type")

        if message_type == "ocr_result":
            if self.on_image_result_received:
                await self.on_image_result_received(session_id, message["data"])

        
        elif message_type == "progress":
            if self.on_progress_update:
                await self.on_progress_update(session_id, {
                    "session_id": session_id,
                    "module": "image",
                    **message["data"]
                })

    async def _send_ipc_command(self, input_pipe: Path, command: IPCCommand):
        """发送 IPC 命令"""
        try:
            # 确保管道文件存在
            input_pipe.parent.mkdir(parents=True, exist_ok=True)
            input_pipe.touch()
            
            # 写入命令
            with open(input_pipe, 'w', encoding='utf-8') as f:
                f.write(command.json() + '\n')
                f.flush()
            
            logger.info(f"发送IPC命令: {command.command} -> {input_pipe}")
            
        except Exception as e:
            logger.error(f"发送 IPC 命令失败: {e}")

    async def _cleanup_orphaned_processes(self):
        """清理可能存在的僵尸进程"""
        try:
            # 清理临时目录
            if self.work_dir.exists():
                import shutil
                shutil.rmtree(self.work_dir)
                self.work_dir.mkdir(exist_ok=True)
            
            logger.info("僵尸进程清理完成")
            
        except Exception as e:
            logger.warning(f"清理僵尸进程失败: {e}")

    async def _forward_process_logs(self, process: subprocess.Popen, process_name: str):
        """转发子进程的日志到主程序日志"""
        try:
            while process.poll() is None:  # 进程还在运行
                line = await asyncio.to_thread(process.stdout.readline)
                if line:
                    # 移除末尾的换行符并添加进程名前缀
                    log_line = line.rstrip('\n\r')
                    if log_line:
                        # 使用主程序的logger输出子进程日志
                        logger.info(f"[{process_name}] {log_line}")
                else:
                    # 如果没有输出，稍等一下
                    await asyncio.sleep(0.1)
        except Exception as e:
            logger.error(f"转发{process_name}日志失败: {e}")
        finally:
            # 读取剩余的输出
            try:
                if process.stdout:
                    remaining = process.stdout.read()
                    if remaining:
                        for line in remaining.split('\n'):
                            line = line.strip()
                            if line:
                                logger.info(f"[{process_name}] {line}")
            except Exception as e:
                logger.warning(f"读取{process_name}剩余日志失败: {e}")

    def get_process_status(self, session_id: str) -> Dict[str, ProcessStatus]:
        """获取会话的进程状态"""
        result = {}
        for process_id, status in self.processes.items():
            if status.session_id == session_id:
                result[process_id] = status
        return result

    def get_all_processes(self) -> Dict[str, ProcessStatus]:
        """获取所有进程状态"""
        return self.processes.copy() 