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

# 添加项目根目录到路径
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agents.summary import MeetingProcessor
from models.data_models import IPCMessage, IPCCommand, IPCResponse, TaskItem, MeetingSummary

logger = logging.getLogger(__name__)

class SummaryProcessor:
    """Summary分析处理器"""
    
    def __init__(self):
        self.meeting_processor = MeetingProcessor()
        self.running = False
        self.current_session_id = None
    
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
            
            # 调用meeting_processor进行分析
            result = await asyncio.to_thread(
                self.meeting_processor.process_meeting_content, 
                transcript_text
            )
            
            # 解析结果
            tasks = []
            if 'tasks' in result:
                for task_data in result['tasks']:
                    task = TaskItem(
                        task=task_data.get('task', ''),
                        deadline=task_data.get('deadline'),
                        describe=task_data.get('describe', ''),
                        priority=task_data.get('priority', 'medium'),
                        assignee=task_data.get('assignee'),
                        status=task_data.get('status', 'pending')
                    )
                    tasks.append(task)
            
            # 创建摘要对象
            summary = MeetingSummary(
                session_id=self.current_session_id,
                summary_text=result.get('summary', ''),
                tasks=tasks,
                key_points=result.get('key_points', []),
                decisions=result.get('decisions', []),
                generated_at=datetime.now()
            )
            
            logger.info(f"Summary分析完成: 任务数={len(tasks)}, 关键点数={len(summary.key_points)}")
            
            return {
                "success": True,
                "summary": summary.dict(),
                "analysis_result": result
            }
        
        except Exception as e:
            logger.error(f"Summary分析失败: {e}")
            return {
                "success": False,
                "error": str(e)
            }
    
    async def handle_command(self, command: IPCCommand) -> IPCResponse:
        """处理IPC命令"""
        try:
            if command.command == "start":
                await self.start_processing(command.session_id)
                return IPCResponse(
                    success=True,
                    data={"message": "Summary处理器已启动"},
                    timestamp=datetime.now()
                )
            
            elif command.command == "stop":
                await self.stop_processing()
                return IPCResponse(
                    success=True,
                    data={"message": "Summary处理器已停止"},
                    timestamp=datetime.now()
                )
            
            elif command.command == "process":
                transcript_text = command.params.get("transcript_text", "")
                result = await self.process_transcript(transcript_text)
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
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
    )
    
    processor = SummaryProcessor()
    
    logger.info("Summary处理器进程启动")
    
    # 监听标准输入的IPC消息
    try:
        while True:
            line = await asyncio.get_event_loop().run_in_executor(None, sys.stdin.readline)
            if not line:
                break
            
            line = line.strip()
            if not line:
                continue
            
            try:
                # 解析IPC消息
                message_data = json.loads(line)
                message = IPCMessage(**message_data)
                
                if message.message_type == "command":
                    command = IPCCommand(**message.data)
                    response = await processor.handle_command(command)
                    
                    # 发送响应
                    response_message = {
                        "message_id": message.message_id,
                        "message_type": "response",
                        "session_id": message.session_id,
                        "data": response.dict()
                    }
                    
                    print(json.dumps(response_message, ensure_ascii=False, default=str))
                    sys.stdout.flush()
                
                elif message.message_type == "transcript_chunk":
                    # 处理转录文本片段
                    transcript_text = message.data.get("text", "")
                    if transcript_text:
                        result = await processor.process_transcript(transcript_text)
                        
                        # 发送处理结果
                        result_message = {
                            "message_id": message.message_id,
                            "message_type": "summary_result",
                            "session_id": message.session_id,
                            "data": result
                        }
                        
                        print(json.dumps(result_message, ensure_ascii=False, default=str))
                        sys.stdout.flush()
                
            except Exception as e:
                logger.error(f"处理IPC消息失败: {e}")
                
                # 发送错误响应
                error_message = {
                    "message_id": getattr(message, 'message_id', 'unknown'),
                    "message_type": "error",
                    "session_id": getattr(message, 'session_id', 'unknown'),
                    "data": {"error": str(e)}
                }
                
                print(json.dumps(error_message, ensure_ascii=False, default=str))
                sys.stdout.flush()
    
    except KeyboardInterrupt:
        logger.info("Summary处理器进程被中断")
    except Exception as e:
        logger.error(f"Summary处理器进程异常: {e}")
    finally:
        logger.info("Summary处理器进程结束")

if __name__ == "__main__":
    asyncio.run(main())