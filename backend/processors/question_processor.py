"""
Question 问题生成处理器
基于 agents/ask_answer.py，作为独立子进程运行
每隔5段对话生成两个问题发送给前端
"""

import sys
import os
import json
import asyncio
import logging
from datetime import datetime
from typing import Dict, Any, List
from dotenv import load_dotenv
from pathlib import Path

# API配置 - 从项目根目录加载环境变量
project_root = Path(__file__).parent.parent.parent
env_path = project_root / ".env"
load_dotenv(env_path)

# 添加项目根目录到路径
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agents.ask_answer import QAGenerator
from models.data_models import IPCMessage, IPCCommand, IPCResponse
import re

logger = logging.getLogger(__name__)

class QuestionProcessor:
    """问题生成处理器"""
    
    def __init__(self):
        self.qa_generator = QAGenerator(buffer_size=5)  # 每5段对话生成问题
        self.running = False
        self.current_session_id = None
        self.processed_segments = 0  # 已处理的转录片段数
        self.last_question_generation = 0  # 上次生成问题的片段位置
        
        # IPC通信文件路径
        self.ipc_input_file = None
        self.ipc_output_file = None
        self.work_dir = None
    
    async def start_processing(self, session_id: str):
        """开始处理会话"""
        self.current_session_id = session_id
        self.running = True
        self.processed_segments = 0
        self.last_question_generation = 0
        logger.info(f"Question处理器启动: session={session_id}")
    
    async def stop_processing(self):
        """停止处理"""
        self.running = False
        self.current_session_id = None
        logger.info("Question处理器停止")
    
    async def process_transcript_segments(self, transcript_segments: List[Dict]) -> Dict[str, Any]:
        """处理转录片段，生成问题"""
        try:
            logger.info(f"开始处理转录片段，数量: {len(transcript_segments)}")
            
            # 清空之前的缓冲区
            self.qa_generator.segment_buffer.clear()
            
            # 将转录片段添加到缓冲区
            for segment in transcript_segments:
                text = segment.get("text", "").strip()
                if text:
                    self.qa_generator.segment_buffer.append(text)
            
            # 检查是否需要生成问题（每5段对话）
            if len(self.qa_generator.segment_buffer) >= 5:
                logger.info(f"缓冲区达到5段，开始生成问题")
                
                # 生成问题
                await self.qa_generator.generate_questions_from_buffer()
                
                # 获取生成的问题
                questions = []
                async with self.qa_generator.question_queue.lock:
                    for qid, question in self.qa_generator.question_queue.questions.items():
                        questions.append({
                            "id": qid,
                            "question": question,
                            "timestamp": datetime.now().isoformat()
                        })
                
                # 清空问题队列（避免重复）
                self.qa_generator.question_queue.questions.clear()
                
                logger.info(f"生成了 {len(questions)} 个问题")
                
                return {
                    "success": True,
                    "questions": questions,
                    "processed_segments": len(self.qa_generator.segment_buffer),
                    "generated_at": datetime.now().isoformat()
                }
            else:
                logger.info(f"缓冲区未达到5段，当前: {len(self.qa_generator.segment_buffer)}")
                return {
                    "success": True,
                    "questions": [],
                    "processed_segments": len(self.qa_generator.segment_buffer),
                    "message": "缓冲区未满，暂不生成问题"
                }
        
        except Exception as e:
            logger.error(f"问题生成失败: {e}")
            return {
                "success": False,
                "error": str(e)
            }
    
    async def _process_session_transcripts(self, session_id: str):
        """处理会话的所有转录数据，生成问题"""
        try:
            logger.info(f"开始处理会话 {session_id} 的转录数据")
            
            # 从主进程获取会话状态（通过API）
            import requests
            try:
                response = requests.get(f"http://localhost:8000/api/sessions/{session_id}")
                if response.status_code == 200:
                    session_data = response.json()
                    if session_data.get("success"):
                        session = session_data["session"]
                        transcript_segments = session.get("transcript_segments", [])
                        
                        if transcript_segments:
                            logger.info(f"获取到转录片段，数量: {len(transcript_segments)}")
                            
                            # 处理转录片段
                            result = await self.process_transcript_segments(transcript_segments)
                            
                            if result["success"] and result["questions"]:
                                # 发送问题结果
                                question_message = {
                                    "type": "questions_generated",
                                    "data": {
                                        "session_id": session_id,
                                        "questions": result["questions"],
                                        "processed_segments": result["processed_segments"]
                                    },
                                    "timestamp": datetime.now().isoformat()
                                }
                                
                                with open(self.ipc_output_file, 'a', encoding='utf-8') as out_f:
                                    out_f.write(json.dumps(question_message, ensure_ascii=False, default=str) + '\n')
                                    out_f.flush()
                                
                                logger.info(f"问题生成完成并已发送，共 {len(result['questions'])} 个问题")
                            else:
                                logger.info(f"暂未生成问题: {result.get('message', '')}")
                        else:
                            logger.warning("没有找到转录片段")
                    else:
                        logger.error(f"获取会话数据失败: {session_data}")
                else:
                    logger.error(f"API请求失败: {response.status_code}")
            except Exception as e:
                logger.error(f"请求会话数据失败: {e}")
            
        except Exception as e:
            logger.error(f"处理会话转录数据失败: {e}")
    
    async def handle_command(self, command: IPCCommand) -> IPCResponse:
        """处理IPC命令"""
        try:
            if command.command == "start":
                await self.start_processing(command.session_id)
                return IPCResponse(
                    success=True,
                    data={"message": "Question处理器已启动"},
                    timestamp=datetime.now()
                )
            
            elif command.command == "stop":
                await self.stop_processing()
                return IPCResponse(
                    success=True,
                    data={"message": "Question处理器已停止"},
                    timestamp=datetime.now()
                )
            
            elif command.command == "process":
                transcript_segments = command.params.get("transcript_segments", [])
                result = await self.process_transcript_segments(transcript_segments)
                return IPCResponse(
                    success=result["success"],
                    data=result,
                    error=result.get("error"),
                    timestamp=datetime.now()
                )
            
            elif command.command == "status":
                return IPCResponse(
                    success=True,
                    data={
                        "running": self.running,
                        "session_id": self.current_session_id,
                        "processed_segments": self.processed_segments,
                        "buffer_size": len(self.qa_generator.segment_buffer),
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
    
    processor = QuestionProcessor()
    processor.current_session_id = args.session_id
    processor.ipc_input_file = args.ipc_input
    processor.ipc_output_file = args.ipc_output
    processor.work_dir = args.work_dir
    
    logger.info(f"Question处理器进程启动: session_id={args.session_id}")
    
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
                                if command.command == "start":
                                    # 读取会话的转录数据并生成问题
                                    await processor._process_session_transcripts(command.session_id)
                                    response = IPCResponse(
                                        success=True,
                                        data={"message": "Question处理完成"},
                                        timestamp=datetime.now()
                                    )
                                else:
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
        logger.info("Question处理器进程结束")

if __name__ == "__main__":
    asyncio.run(main()) 