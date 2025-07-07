"""
Whisper 转录处理器
整合现有的 whsiper_live_2.py，作为独立进程运行
"""

import asyncio
import argparse
import json
import logging
import sys
import uuid
from datetime import datetime
from pathlib import Path
from typing import Optional

# 导入现有的whisper模块
sys.path.append(str(Path(__file__).parent.parent / "transcribe"))
from whsiper_live_2 import SystemAudioRecorder

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class WhisperProcessor:
    """Whisper转录处理器"""
    
    def __init__(self, session_id: str, ipc_input: Path, ipc_output: Path, work_dir: Path):
        self.session_id = session_id
        self.ipc_input = ipc_input
        self.ipc_output = ipc_output
        self.work_dir = work_dir
        self.recorder: Optional[SystemAudioRecorder] = None
        self.is_running = False
        
        # 确保输出文件存在
        self.ipc_output.touch()
    
    async def start(self):
        """启动处理器"""
        logger.info(f"Whisper处理器启动: session={self.session_id}")
        self.is_running = True
        
        # 修改现有录音器，添加回调
        self.recorder = EnhancedSystemAudioRecorder(
            session_id=self.session_id,
            callback=self._on_transcript_received
        )
        
        # 启动IPC监听和录音
        await asyncio.gather(
            self._listen_ipc_commands(),
            self._start_recording()
        )
    
    async def stop(self):
        """停止处理器"""
        logger.info(f"Whisper处理器停止: session={self.session_id}")
        self.is_running = False
        
        if self.recorder:
            self.recorder.stop_recording()
    
    async def _listen_ipc_commands(self):
        """监听IPC命令"""
        while self.is_running:
            try:
                if self.ipc_input.exists():
                    with open(self.ipc_input, 'r', encoding='utf-8') as f:
                        line = f.readline().strip()
                        if line:
                            command = json.loads(line)
                            await self._handle_command(command)
                            # 清空输入文件
                            self.ipc_input.unlink()
                            self.ipc_input.touch()
            except Exception as e:
                logger.error(f"处理IPC命令错误: {e}")
            
            await asyncio.sleep(0.1)
    
    async def _handle_command(self, command: dict):
        """处理IPC命令"""
        cmd_type = command.get("command")
        
        if cmd_type == "start":
            logger.info("收到启动录音命令")
            # 录音在启动时就开始了
        elif cmd_type == "stop":
            logger.info("收到停止录音命令")
            await self.stop()
    
    async def _start_recording(self):
        """启动录音"""
        try:
            if self.recorder:
                # 在线程中运行录音（因为是阻塞操作）
                await asyncio.to_thread(self.recorder.start_recording)
        except Exception as e:
            logger.error(f"录音启动失败: {e}")
            await self._send_error("录音启动失败", str(e))
    
    def _on_transcript_received(self, text: str, confidence: float = 0.0):
        """转录结果回调"""
        try:
            message = {
                "type": "transcript",
                "data": {
                    "id": str(uuid.uuid4()),
                    "text": text,
                    "timestamp": datetime.now().isoformat(),
                    "confidence": confidence,
                    "speaker": None
                }
            }
            
            # 写入输出管道
            with open(self.ipc_output, 'a', encoding='utf-8') as f:
                f.write(json.dumps(message, ensure_ascii=False) + '\n')
                f.flush()
            
            logger.info(f"转录结果: {text[:50]}...")
            
        except Exception as e:
            logger.error(f"发送转录结果失败: {e}")
    
    async def _send_progress(self, progress: float, message: str):
        """发送进度更新"""
        try:
            msg = {
                "type": "progress",
                "data": {
                    "progress": progress,
                    "message": message,
                    "status": "running"
                }
            }
            
            with open(self.ipc_output, 'a', encoding='utf-8') as f:
                f.write(json.dumps(msg, ensure_ascii=False) + '\n')
                f.flush()
                
        except Exception as e:
            logger.error(f"发送进度更新失败: {e}")
    
    async def _send_error(self, message: str, details: str):
        """发送错误信息"""
        try:
            msg = {
                "type": "error",
                "data": {
                    "message": message,
                    "details": details,
                    "timestamp": datetime.now().isoformat()
                }
            }
            
            with open(self.ipc_output, 'a', encoding='utf-8') as f:
                f.write(json.dumps(msg, ensure_ascii=False) + '\n')
                f.flush()
                
        except Exception as e:
            logger.error(f"发送错误信息失败: {e}")

class EnhancedSystemAudioRecorder(SystemAudioRecorder):
    """增强的音频录制器，添加回调支持"""
    
    def __init__(self, session_id: str, callback=None):
        super().__init__()
        self.session_id = session_id
        self.callback = callback
        
        # 重定向输出文件到会话目录
        self.OUTPUT_FILE = f"temp_sessions/{session_id}/transcript_log.txt"
        Path(self.OUTPUT_FILE).parent.mkdir(parents=True, exist_ok=True)
    
    def _transcribe_and_save(self, filename: str):
        """重写转录保存方法，添加回调"""
        try:
            # 调用原始的API转录逻辑
            import requests
            import os
            
            API_KEY = os.getenv("OPENAI_API_KEY")
            url = "https://api.openai.com/v1/audio/transcriptions"
            headers = {"Authorization": f"Bearer {API_KEY}"}
            
            with open(filename, "rb") as audio_file:
                response = requests.post(
                    url,
                    headers=headers,
                    files={"file": audio_file},
                    data={"model": "whisper-1"},
                    timeout=30
                )
            
            if response.status_code == 200:
                result = response.json()
                text = result.get("text", "").strip()
                if text:
                    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                    output = f"[{timestamp}] {text}"
                    print(f"\n🔊 识别结果: {output}")
                    
                    # 保存到日志文件
                    with open(self.OUTPUT_FILE, "a", encoding="utf-8") as f:
                        f.write(output + "\n")
                    
                    # 调用回调函数
                    if self.callback:
                        confidence = result.get("confidence", 0.0)
                        self.callback(text, confidence)
            else:
                print(f"API错误: {response.status_code} - {response.text}")
                
        except Exception as e:
            print(f"转录失败: {str(e)}")
        finally:
            # 删除临时文件
            try:
                os.remove(filename)
            except:
                pass

    def stop_recording(self):
        """停止录音"""
        self.is_recording = False

async def main():
    """主函数"""
    parser = argparse.ArgumentParser(description="Whisper转录处理器")
    parser.add_argument("--session-id", required=True, help="会话ID")
    parser.add_argument("--ipc-input", required=True, help="IPC输入管道路径")
    parser.add_argument("--ipc-output", required=True, help="IPC输出管道路径")
    parser.add_argument("--work-dir", required=True, help="工作目录")
    
    args = parser.parse_args()
    
    # 创建处理器
    processor = WhisperProcessor(
        session_id=args.session_id,
        ipc_input=Path(args.ipc_input),
        ipc_output=Path(args.ipc_output),
        work_dir=Path(args.work_dir)
    )
    
    try:
        await processor.start()
    except KeyboardInterrupt:
        logger.info("收到中断信号，正在停止...")
        await processor.stop()
    except Exception as e:
        logger.error(f"处理器运行错误: {e}")
        await processor.stop()

if __name__ == "__main__":
    asyncio.run(main()) 