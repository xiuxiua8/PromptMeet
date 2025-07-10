import sys
import asyncio
import json
import logging
import os
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, Optional
import argparse

from langchain.agents import AgentExecutor, initialize_agent
from langchain.agents.agent_types import AgentType
from langchain_openai import ChatOpenAI
from langchain.memory import ConversationBufferMemory

# 工具导入
from tools.time_tool import TimeTool
from tools.summary_tool import SummaryTool

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class AgentProcessor:
    def __init__(self):
        self.running = False
        self.session_id: Optional[str] = None
        self.ipc_input_path: Optional[Path] = None
        self.ipc_output_path: Optional[Path] = None
        
        # 初始化LLM和Agent
        self.llm = ChatOpenAI(
            temperature=0.2,
            model="gpt-3.5-turbo",
            openai_api_key=os.getenv("OPENAI_API_KEY")
        )
        
        self.tools = [TimeTool(), SummaryTool()]
        
        self.memory = ConversationBufferMemory(
            memory_key="chat_history",
            return_messages=True  # 关键修复：确保返回消息对象而非字符串
        )
        
        self.agent = initialize_agent(
            tools=self.tools,
            llm=self.llm,
            agent=AgentType.CHAT_CONVERSATIONAL_REACT_DESCRIPTION,
            verbose=True,
            memory=self.memory,
            handle_parsing_errors=True
        
        )

    async def start(self, session_id: str, ipc_input: str, ipc_output: str, work_dir: str):
        """启动处理器"""
        self.session_id = session_id
        self.ipc_input_path = Path(ipc_input)
        self.ipc_output_path = Path(ipc_output)
        self.work_dir = Path(work_dir)
        
        # 确保工作目录存在
        self.work_dir.mkdir(parents=True, exist_ok=True)
        
        self.running = True
        logger.info(f"Agent处理器启动: session_id={session_id}")
        
        try:
            await self._ipc_loop()
        except Exception as e:
            logger.error(f"处理器运行错误: {e}")
        finally:
            await self.stop()

    async def stop(self):
        """停止处理器"""
        self.running = False
        logger.info("Agent处理器停止")

    async def _ipc_loop(self):
        """IPC通信主循环"""
        while self.running:
            try:
                await self._check_ipc_messages()
                await asyncio.sleep(0.1)
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"IPC循环错误: {e}")
                await asyncio.sleep(1)

    async def _check_ipc_messages(self):
        """检查并处理IPC消息"""
        if not self.ipc_input_path.exists():
            return

        with open(self.ipc_input_path, 'r', encoding='utf-8') as f:
            line = f.readline().strip()
            if line:
                try:
                    message = json.loads(line)
                    logger.info(f"收到消息: {message}")
                    
                    response = await self.process_message(message)
                    
                    # 写入响应
                    with open(self.ipc_output_path, 'a', encoding='utf-8') as out_f:
                        out_f.write(json.dumps(response) + '\n')
                        out_f.flush()
                    
                    # 清空输入文件
                    open(self.ipc_input_path, 'w').close()
                    
                except json.JSONDecodeError as e:
                    logger.error(f"JSON解析错误: {e}")
                except Exception as e:
                    logger.error(f"处理消息失败: {e}")

    async def process_message(self, message: Dict[str, Any]) -> Dict[str, Any]:
        """处理传入的消息"""
        try:
            # 修改为正确的输入格式
            response = await self.agent.ainvoke({"input": message.get("content", "")})
            
            return {
                "success": True,
                "response": response.get("output", str(response)),
                "timestamp": datetime.now().isoformat()
            }
        except Exception as e:
            logger.error(f"处理消息失败: {e}")
            return {
                "success": False,
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }


    @classmethod
    async def run_from_command_line(cls):
        """从命令行启动处理器"""
        parser = argparse.ArgumentParser()
        parser.add_argument('--session-id', required=True, help='会话ID')
        parser.add_argument('--ipc-input', required=True, help='IPC输入管道文件路径')
        parser.add_argument('--ipc-output', required=True, help='IPC输出管道文件路径')
        parser.add_argument('--work-dir', required=True, help='工作目录')
        args = parser.parse_args()
        
        processor = cls()
        try:
            await processor.start(
                session_id=args.session_id,
                ipc_input=args.ipc_input,
                ipc_output=args.ipc_output,
                work_dir=args.work_dir
            )
        except KeyboardInterrupt:
            logger.info("接收到中断信号，正在停止...")
        finally:
            await processor.stop()

if __name__ == "__main__":
    asyncio.run(AgentProcessor.run_from_command_line())
