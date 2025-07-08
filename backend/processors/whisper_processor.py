"""
Whisper 转录处理器
基于 transcribe/whsiper_live_2.py，作为独立子进程运行
"""

import sys
import os
import json
import asyncio
import logging
import threading
import queue
import time
import wave
import requests
import sounddevice as sd
import soundfile as sf
import numpy as np
from datetime import datetime
from typing import Dict, Any, Optional
from scipy.signal import resample_poly
from dotenv import load_dotenv
from pathlib import Path

# 添加项目根目录到路径
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from models.data_models import IPCMessage, IPCCommand, IPCResponse, TranscriptionResult

logger = logging.getLogger(__name__)

def create_directory(path):
    """创建目录"""
    os.makedirs(path, exist_ok=True)

class WhisperProcessor:
    """Whisper转录处理器"""
    
    def __init__(self):
        self.running = False
        self.current_session_id = None
        self.is_recording = False
        self.audio_queue = queue.Queue()
        self.current_frames = []
        self.device_id = None
        self.stream = None
        self.last_submit_time = time.time()
        self.audio_counter = 1
        
        # IPC通信文件路径
        self.ipc_input_file = None
        self.ipc_output_file = None
        self.work_dir = None
        
        # API配置 
        project_root = Path(__file__).parent.parent.parent
        env_path = project_root / ".env"
        load_dotenv(env_path)
        
        self.api_key = os.getenv("OPENAI_API_KEY")
        if not self.api_key:
            logger.error("未设置OPENAI_API_KEY")
            raise ValueError("请在环境变量中设置OPENAI_API_KEY")
        
        # 录音参数
        self.sample_rate = 16000
        self.chunk_size = 1024
        self.segment_duration = 10.0  # 每10秒提交一次
        self.model = "whisper-1"
        
        # 初始化音频设备
        self._find_audio_device()
    
    def _find_audio_device(self):
        """查找合适的音频设备"""
        try:
            devices = sd.query_devices()
            hostapis = sd.query_hostapis()
            
            input_devices = []
            
            for i, dev in enumerate(devices):
                if dev['max_input_channels'] > 0:
                    input_devices.append((i, dev))
                    
                    # 根据操作系统选择设备
                    if sys.platform == "win32":
                        if ("mix" in dev["name"].lower() or 
                            "stereo" in dev["name"].lower() or 
                            "混音" in dev["name"]):
                            self.device_id = i
                            logger.info(f"找到Windows扬声器设备: {dev['name']}")
                            return
                    elif sys.platform == "darwin":
                        if "blackhole" in dev["name"].lower() or "soundflower" in dev["name"].lower():
                            self.device_id = i
                            logger.info(f"找到macOS虚拟音频设备: {dev['name']}")
                            return
                    elif sys.platform.startswith("linux"):
                        if "monitor" in dev["name"].lower():
                            self.device_id = i
                            logger.info(f"找到Linux扬声器设备: {dev['name']}")
                            return
            
            # 如果没找到专用设备，使用第一个输入设备
            if input_devices:
                self.device_id = input_devices[0][0]
                logger.info(f"使用默认输入设备: {input_devices[0][1]['name']}")
            else:
                logger.error("未找到任何音频输入设备")
                raise RuntimeError("找不到可用的音频设备")
                
        except Exception as e:
            logger.error(f"音频设备初始化失败: {e}")
            raise
    
    def _audio_callback(self, indata, frames, time, status):
        """音频数据回调函数"""
        if status:
            logger.warning(f"音频流状态: {status}")
        
        # 将音频数据放入队列
        self.audio_queue.put(indata.copy())
    
    async def start_recording(self, session_id: str):
        """开始录音"""
        try:
            self.current_session_id = session_id
            self.is_recording = True
            
            # 获取设备信息
            device_info = sd.query_devices(self.device_id)
            sample_rate = int(min(device_info['default_samplerate'], 48000))
            channels = min(2, device_info['max_input_channels'])
            
            logger.info(f"开始录音: 设备={device_info['name']}, 采样率={sample_rate}Hz, 通道数={channels}")
            
            # 开始录制
            self.stream = sd.InputStream(
                device=self.device_id,
                channels=channels,
                samplerate=sample_rate,
                blocksize=self.chunk_size,
                callback=self._audio_callback
            )
            
            self.stream.start()
            
            # 在后台线程中处理音频
            self.recording_thread = threading.Thread(
                target=self._recording_loop,
                args=(sample_rate, channels),
                daemon=True
            )
            self.recording_thread.start()
            
            return True
            
        except Exception as e:
            logger.error(f"开始录音失败: {e}")
            return False
    
    def _recording_loop(self, sample_rate: int, channels: int):
        """录音循环"""
        try:
            while self.is_recording:
                # 从队列获取音频数据
                try:
                    audio_data = self.audio_queue.get(timeout=0.1)
                    self.current_frames.append(audio_data)
                except queue.Empty:
                    pass
                
                # 定时提交音频片段
                current_time = time.time()
                if current_time - self.last_submit_time >= self.segment_duration:
                    asyncio.run(self._submit_audio_segment(sample_rate, channels))
                    self.last_submit_time = current_time
                    
        except Exception as e:
            logger.error(f"录音循环错误: {e}")
    
    async def _submit_audio_segment(self, sample_rate: int, channels: int):
        """提交音频片段进行转录"""
        if not self.current_frames:
            return
        
        try:
            # 保存临时音频文件
            audio_dir = f"recordings/{self.current_session_id}"
            create_directory(audio_dir)
            
            filename = f"{audio_dir}/segment_{self.audio_counter}.wav"
            self.audio_counter += 1
            
            # 组合音频数据
            audio_data = np.concatenate(self.current_frames, axis=0)
            
            # 转换为mono如果是stereo
            if channels == 2:
                audio_data = np.mean(audio_data, axis=1)
            
            # 重采样到16kHz
            if sample_rate != 16000:
                audio_data = resample_poly(audio_data, 16000, sample_rate)
            
            # 保存为WAV文件
            with wave.open(filename, 'w') as wav_file:
                wav_file.setnchannels(1)
                wav_file.setsampwidth(2)
                wav_file.setframerate(16000)
                wav_file.writeframes((audio_data * 32767).astype(np.int16).tobytes())
            
            # 清空当前帧
            self.current_frames = []
            
            # 调用Whisper API
            transcription_result = await self._transcribe_audio(filename)
            
            if transcription_result:
                # 发送转录结果
                await self._send_transcription_result(transcription_result)
                
        except Exception as e:
            logger.error(f"提交音频片段失败: {e}")
    
    async def _transcribe_audio(self, filename: str) -> Optional[TranscriptionResult]:
        """调用Whisper API进行转录"""
        try:
            with open(filename, 'rb') as audio_file:
                logger.info(f"开始调用Whisper API...")
                response = requests.post(
                    "https://api.openai.com/v1/audio/transcriptions",
                    headers={
                        "Authorization": f"Bearer {self.api_key}"
                    },
                    files={
                        "file": audio_file
                    },
                    data={
                        "model": self.model,
                        "language": "zh",
                        "response_format": "json"
                    },
                    timeout=30
                )
            
            logger.info(f"openai API响应: {self.api_key}")
            logger.info(f"准备转录音频文件: {filename}, 大小: {os.path.getsize(filename)} bytes")
            logger.info(f"Whisper API响应状态码: {response.status_code}")
            
            if response.status_code == 200:
                result = response.json()
                text = result.get('text', '').strip()
                
                logger.info(f"API返回结果: {result}")
                
                if text:
                    transcription_result = TranscriptionResult(
                        session_id=self.current_session_id,
                        text=text,
                        timestamp=datetime.now(),
                        audio_file=filename,
                        duration=result.get('duration', 0.0)
                    )
                    
                    logger.info(f"转录成功: {text[:50]}...")
                    return transcription_result
                else:
                    logger.warning(f"转录结果为空，API返回: {result}")
                    return None
            else:
                logger.error(f"Whisper API调用失败: {response.status_code} - {response.text}")
                return None
                
        except Exception as e:
            logger.error(f"转录失败: {e}", exc_info=True)
            return None
    
    async def _send_transcription_result(self, result: TranscriptionResult):
        """发送转录结果到主进程"""
        try:
            message = {
                "type": "transcript",
                "data": result.model_dump(),
                "timestamp": datetime.now().isoformat()
            }
            
            # 写入输出文件
            if self.ipc_output_file:
                with open(self.ipc_output_file, 'a', encoding='utf-8') as f:
                    f.write(json.dumps(message, ensure_ascii=False, default=str) + '\n')
                    f.flush()
                
                logger.info(f"转录结果已发送: {result.text[:50]}...")
            else:
                # 如果没有输出文件，回退到stdout
                print(json.dumps(message, ensure_ascii=False, default=str))
                sys.stdout.flush()
            
        except Exception as e:
            logger.error(f"发送转录结果失败: {e}")
    
    async def stop_recording(self):
        """停止录音"""
        try:
            self.is_recording = False
            
            if self.stream:
                self.stream.stop()
                self.stream.close()
                self.stream = None
            
            # 提交剩余的音频数据
            if self.current_frames:
                device_info = sd.query_devices(self.device_id)
                sample_rate = int(min(device_info['default_samplerate'], 48000))
                channels = min(2, device_info['max_input_channels'])
                await self._submit_audio_segment(sample_rate, channels)
            
            logger.info("录音已停止")
            return True
            
        except Exception as e:
            logger.error(f"停止录音失败: {e}")
            return False
    
    async def handle_command(self, command: IPCCommand) -> IPCResponse:
        """处理IPC命令"""
        try:
            if command.command == "start" or command.command == "start_recording":
                success = await self.start_recording(command.session_id)
                return IPCResponse(
                    success=success,
                    data={"message": "录音已开始" if success else "录音启动失败"},
                    timestamp=datetime.now()
                )
            
            elif command.command == "stop" or command.command == "stop_recording":
                success = await self.stop_recording()
                return IPCResponse(
                    success=success,
                    data={"message": "录音已停止" if success else "录音停止失败"},
                    timestamp=datetime.now()
                )
            
            elif command.command == "status":
                return IPCResponse(
                    success=True,
                    data={
                        "running": self.running,
                        "recording": self.is_recording,
                        "session_id": self.current_session_id,
                        "device_id": self.device_id,
                        "processor_status": "ready"
                    },
                    timestamp=datetime.now()
                )
            
            else:
                return IPCResponse(
                    success=False,
                    error=f"未知命令: {command.command}",
                    timestamp=datetime.now()
                )
        
        except Exception as e:
            logger.error(f"处理命令失败: {e}")
            return IPCResponse(
                success=False,
                error=str(e),
                timestamp=datetime.now()
            )

async def main():
    """主函数 - 作为独立进程运行"""
    import argparse
    
    # 解析命令行参数
    parser = argparse.ArgumentParser()
    parser.add_argument('--session-id', required=True, help='会话ID')
    parser.add_argument('--ipc-input', required=True, help='IPC输入管道文件路径')
    parser.add_argument('--ipc-output', required=True, help='IPC输出管道文件路径')
    parser.add_argument('--work-dir', required=True, help='工作目录')
    args = parser.parse_args()
    
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
    )
    
    processor = WhisperProcessor()
    processor.current_session_id = args.session_id
    processor.ipc_input_file = args.ipc_input
    processor.ipc_output_file = args.ipc_output
    processor.work_dir = args.work_dir
    
    logger.info(f"Whisper处理器进程启动: session_id={args.session_id}")
    
    # 监听IPC输入文件
    try:
        while True:
            try:
                # 读取IPC输入文件
                if os.path.exists(processor.ipc_input_file):
                    with open(processor.ipc_input_file, 'r', encoding='utf-8') as f:
                        line = f.readline().strip()
                        if line:
                            try:
                                # 解析IPC命令
                                command_data = json.loads(line)
                                command = IPCCommand(**command_data)
                                
                                logger.info(f"收到命令: {command.command}")
                                
                                # 处理命令
                                response = await processor.handle_command(command)
                                
                                # 发送响应到输出文件
                                response_message = {
                                    "type": "response",
                                    "data": response.model_dump(),
                                    "timestamp": datetime.now().isoformat()
                                }
                                
                                with open(processor.ipc_output_file, 'a', encoding='utf-8') as out_f:
                                    out_f.write(json.dumps(response_message, ensure_ascii=False, default=str) + '\n')
                                    out_f.flush()
                                
                                # 清空输入文件
                                open(processor.ipc_input_file, 'w').close()
                
                            except json.JSONDecodeError as e:
                                logger.error(f"JSON解析错误: {e}")
                            except Exception as e:
                                logger.error(f"处理命令失败: {e}")
                
                await asyncio.sleep(0.1)
                
            except Exception as e:
                logger.error(f"IPC循环错误: {e}")
                await asyncio.sleep(1)
                
    except KeyboardInterrupt:
        logger.info("接收到中断信号，正在停止...")
    except Exception as e:
        logger.error(f"主循环错误: {e}")
    finally:
        # 清理资源
        if processor.is_recording:
            await processor.stop_recording()
        logger.info("Whisper处理器进程结束")

if __name__ == "__main__":
    asyncio.run(main()) 