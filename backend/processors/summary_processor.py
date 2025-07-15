"""
Summary 分析处理器
基于 agents/summary.py，作为独立子进程运行
"""

import sys
import os
import json
import asyncio
import logging
from datetime import datetime
from typing import Dict, Any
from dotenv import load_dotenv
from pathlib import Path

# API配置 - 从项目根目录加载环境变量
project_root = Path(__file__).parent.parent.parent
env_path = project_root / ".env"
load_dotenv(env_path)

# 添加项目根目录到路径
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agents.summary import MeetingProcessor
from models.data_models import (
    IPCMessage,
    IPCCommand,
    IPCResponse,
    TaskItem,
    MeetingSummary,
)
import re

logger = logging.getLogger(__name__)


class SummaryProcessor:
    """Summary分析处理器"""

    def __init__(self):
        self.meeting_processor = MeetingProcessor()
        self.running = False
        self.current_session_id = None
        self.accumulated_text = ""  # 累积的转录文本

        # IPC通信文件路径
        self.ipc_input_file = None
        self.ipc_output_file = None
        self.work_dir = None

    async def start_processing(self, session_id: str):
        """开始处理会话"""
        self.current_session_id = session_id
        self.running = True
        logger.info(f"Summary处理器启动: session={session_id}")

    async def stop_processing(self):
        """停止处理"""
        self.running = False
        self.current_session_id = None
        logger.info("Summary处理器停止")

    async def process_transcript(self, transcript_text: str) -> Dict[str, Any]:
        """处理转录文本，生成摘要"""
        try:
            logger.info(f"开始分析转录文本，长度: {len(transcript_text)}")

            # 累积转录文本
            self.accumulated_text += transcript_text + "\n"

            # 调用meeting_processor进行分析
            full_result = ""
            async for chunk in self.meeting_processor.process_meeting(transcript_text):
                full_result += chunk

            logger.info(f"AI分析完成，结果长度: {len(full_result)}")

            # 解析结果
            tasks = []
            summary_text = ""
            key_points = []
            decisions = []
            email_info = {}
            
            try:
                # 解析原始待办事项JSON
                raw_tasks_match = re.search(
                    r"【原始待办事项】\n(.*?)(?=\n\n【|$)", full_result, re.DOTALL
                )
                if raw_tasks_match:
                    raw_tasks_json = raw_tasks_match.group(1).strip()
                    try:
                        raw_tasks = json.loads(raw_tasks_json)
                        for task_data in raw_tasks:
                            task = TaskItem(
                                task=task_data.get("task", ""),
                                deadline=task_data.get("deadline"),
                                describe=task_data.get("describe", ""),
                                priority="medium",  # 默认优先级
                                assignee=task_data.get("assignee"),
                                status="pending",
                            )
                            tasks.append(task)
                    except json.JSONDecodeError:
                        logger.warning("无法解析原始待办事项JSON")
                
                # 解析邮件信息JSON
                email_match = re.search(r'【邮件信息】\n(.*?)(?=\n\n【|$)', full_result, re.DOTALL)
                if email_match:
                    email_json = email_match.group(1).strip()
                    try:
                        email_info = json.loads(email_json)
                        logger.info(f"解析到邮件信息: {email_info}")
                    except json.JSONDecodeError:
                        logger.warning("无法解析邮件信息JSON")
                        email_info = {"need_email": False, "recipient_name": "", "recipient_email": "", "subject": "", "content": ""}
                else:
                    email_info = {"need_email": False, "recipient_name": "", "recipient_email": "", "subject": "", "content": ""}
                
                # 提取会议总结
                summary_match = re.search(
                    r"【会议总结】\n(.*?)(?=\n【|$)", full_result, re.DOTALL
                )
                if summary_match:
                    summary_text = summary_match.group(1).strip()

                # 从总结中提取关键点和决定
                if summary_text:
                    # 简单的关键点提取
                    lines = summary_text.split("\n")
                    for line in lines:
                        line = line.strip()
                        if line and (line.startswith("- ") or line.startswith("• ")):
                            if "决定" in line or "决策" in line:
                                decisions.append(line.lstrip("- •"))
                            else:
                                key_points.append(line.lstrip("- •"))

            except Exception as e:
                logger.error(f"解析AI结果失败: {e}")
                # 如果解析失败，至少保留原始文本
                summary_text = full_result

            # 创建摘要对象
            summary = MeetingSummary(
                session_id=self.current_session_id if self.current_session_id is not None else "",
                summary_text=summary_text,
                tasks=tasks,
                key_points=key_points,
                decisions=decisions,
                generated_at=datetime.now(),
            )

            logger.info(
                f"Summary分析完成: 任务数={len(tasks)}, 关键点数={len(key_points)}, 决定数={len(decisions)}"
            )

            return {
                "success": True,
                "summary": summary.dict(),
                "full_ai_result": full_result,
                "raw_tasks": tasks,
                "email_info": email_info,
                "processed_text_length": len(transcript_text)
            }

        except Exception as e:
            logger.error(f"Summary分析失败: {e}")
            return {"success": False, "error": str(e)}

    async def _process_session_transcripts(self, session_id: str):
        """处理会话的所有转录数据，生成摘要"""
        try:
            logger.info(f"开始处理会话 {session_id} 的转录数据")

            # 获取会话的转录数据
            # 这里我们需要从主进程的session_manager中获取数据
            # 由于是独立进程，我们可以通过读取会话数据文件或请求主进程

            # 首先尝试从主进程获取会话状态（通过API）
            import requests

            try:
                response = requests.get(
                    f"http://localhost:8000/api/sessions/{session_id}"
                )
                if response.status_code == 200:
                    session_data = response.json()
                    if session_data.get("success"):
                        session = session_data["session"]
                        transcript_segments = session.get("transcript_segments", [])

                        # 合并所有转录文本
                        transcript_text = ""
                        for segment in transcript_segments:
                            transcript_text += segment.get("text", "") + "\n"

                        if transcript_text.strip():
                            logger.info(f"获取到转录文本，长度: {len(transcript_text)}")

                            # 处理转录文本
                            result = await self.process_transcript(transcript_text)

                            if result["success"]:
                                # 发送摘要结果
                                summary_message = {
                                    "type": "summary",
                                    "data": result["summary"],
                                    "timestamp": datetime.now().isoformat(),
                                }
                                if not self.ipc_output_file:
                                    logger.error("ipc_output_file 未设置，无法写入摘要结果")
                                else:
                                    with open(self.ipc_output_file, 'a', encoding='utf-8') as out_f:
                                        out_f.write(json.dumps(summary_message, ensure_ascii=False, default=str) + '\n')
                                        out_f.flush()
                                
                                logger.info("摘要生成完成并已发送")
                            else:
                                logger.error(f"摘要生成失败: {result.get('error')}")
                        else:
                            logger.warning("没有找到转录文本")
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
                    data={"message": "Summary处理器已启动"},
                    error=None,
                    timestamp=datetime.now()
                )

            elif command.command == "stop":
                await self.stop_processing()
                return IPCResponse(
                    success=True,
                    data={"message": "Summary处理器已停止"},
                    error=None,
                    timestamp=datetime.now()
                )

            elif command.command == "process":
                transcript_text = command.params.get("transcript_text", "")
                result = await self.process_transcript(transcript_text)
                return IPCResponse(
                    success=result["success"],
                    data=result,
                    error=result.get("error"),
                    timestamp=datetime.now(),
                )

            elif command.command == "status":
                return IPCResponse(
                    success=True,
                    data={
                        "running": self.running,
                        "session_id": self.current_session_id,
                        "processor_status": "ready",
                    },
                    error=None,
                    timestamp=datetime.now()
                )

            else:
                return IPCResponse(
                    success=False,
                    data=None,
                    error=f"未知命令: {command.command}",
                    timestamp=datetime.now(),
                )

        except Exception as e:
            logger.error(f"处理命令失败: {e}")
            return IPCResponse(
                success=False,
                data=None,
                error=str(e),
                timestamp=datetime.now()
            )

async def main():
    """主函数 - 作为独立进程运行"""
    import argparse

    # 解析命令行参数
    parser = argparse.ArgumentParser()
    parser.add_argument("--session-id", required=True, help="会话ID")
    parser.add_argument("--ipc-input", required=True, help="IPC输入管道文件路径")
    parser.add_argument("--ipc-output", required=True, help="IPC输出管道文件路径")
    parser.add_argument("--work-dir", required=True, help="工作目录")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    )

    processor = SummaryProcessor()
    processor.current_session_id = args.session_id
    processor.ipc_input_file = args.ipc_input
    processor.ipc_output_file = args.ipc_output
    processor.work_dir = args.work_dir

    logger.info(f"Summary处理器进程启动: session_id={args.session_id}")

    # 监听IPC输入文件
    try:
        while True:
            try:
                # 读取IPC输入文件
                if os.path.exists(processor.ipc_input_file):
                    with open(processor.ipc_input_file, "r", encoding="utf-8") as f:
                        line = f.readline().strip()
                        if line:
                            try:
                                # 解析IPC命令
                                command_data = json.loads(line)
                                command = IPCCommand(**command_data)

                                logger.info(f"收到命令: {command.command}")

                                # 处理命令
                                if command.command == "start":
                                    # 读取会话的转录数据并生成摘要
                                    await processor._process_session_transcripts(
                                        command.session_id
                                    )
                                    response = IPCResponse(
                                        success=True,
                                        data={"message": "Summary处理完成"},
                                        error=None,
                                        timestamp=datetime.now()
                                    )
                                else:
                                    response = await processor.handle_command(command)

                                # 发送响应到输出文件
                                response_message = {
                                    "type": "response",
                                    "data": response.model_dump(),
                                    "timestamp": datetime.now().isoformat(),
                                }

                                with open(
                                    processor.ipc_output_file, "a", encoding="utf-8"
                                ) as out_f:
                                    out_f.write(
                                        json.dumps(
                                            response_message,
                                            ensure_ascii=False,
                                            default=str,
                                        )
                                        + "\n"
                                    )
                                    out_f.flush()

                                # 清空输入文件
                                open(processor.ipc_input_file, "w").close()

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
        logger.info("Summary处理器进程结束")


if __name__ == "__main__":
    asyncio.run(main())
