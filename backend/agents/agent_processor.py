"""
Agent 处理器
基于 agents/agent_processor.py，作为独立子进程运行
"""

import sys
import os
import json
import asyncio
import logging
import requests
from datetime import datetime
from typing import Dict, Any, Optional, List
from dotenv import load_dotenv
from pathlib import Path
import traceback
from pydantic import SecretStr

# API配置 - 从项目根目录加载环境变量
project_root = Path(__file__).parent.parent.parent
env_path = project_root / ".env"
load_dotenv(env_path)

# 添加项目根目录到路径
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from langchain.agents import initialize_agent
from langchain.agents.agent_types import AgentType
from langchain_openai import ChatOpenAI, OpenAIEmbeddings
from langchain.memory import ConversationBufferMemory
from langchain_core.documents import Document
from langchain_community.vectorstores import FAISS
from langchain.chains import ConversationalRetrievalChain

# 工具导入
from tools.time_tool import TimeTool
from tools.summary_tool import SummaryTool
from models.data_models import IPCMessage, IPCCommand, IPCResponse

# 重试机制导入
from tenacity import retry, stop_after_attempt, wait_exponential

logger = logging.getLogger(__name__)

class AgentProcessor:
    """Agent处理器"""
    
    def __init__(self):
        self.running = False
        self.current_session_id = None
        
        # 记忆系统组件
        self.vector_db: Optional[FAISS] = None
        self.qa_chain: Optional[ConversationalRetrievalChain] = None
        self.meeting_content: List[str] = []
        
        # 主服务API配置
        self.api_base_url = "http://localhost:8000"
        
        # 初始化LLM和Agent
        api_key = os.getenv("DEEPSEEK_API_KEY")
        if not api_key:
            logger.error("未设置DEEPSEEK_API_KEY环境变量")
            raise ValueError("请在环境变量中设置DEEPSEEK_API_KEY")
            
        api_key = SecretStr(api_key)
        base_url = os.getenv("DEEPSEEK_API_BASE")
        if not base_url:
            logger.error("未设置DEEPSEEK_API_BASE环境变量")
            raise ValueError("请在环境变量中设置DEEPSEEK_API_BASE")
            
        self.llm = ChatOpenAI(
            api_key=api_key,
            base_url=base_url,
            model="deepseek-chat",
            temperature=0.3,
            streaming=True,
            timeout=60,  # 增加超时时间
            max_retries=3  # 增加重试次数
        )
        
        # 初始化嵌入模型
        openai_api_key = os.getenv("OPENAI_API_KEY")
        if not openai_api_key:
            logger.error("未设置OPENAI_API_KEY环境变量")
            raise ValueError("请在环境变量中设置OPENAI_API_KEY")
            
        self.embeddings = OpenAIEmbeddings(
            api_key=SecretStr(openai_api_key)
        )
        
        self.tools = [TimeTool(), SummaryTool()]
        
        # 配置记忆系统
        self.memory = ConversationBufferMemory(
            memory_key="chat_history",
            return_messages=True,
            output_key="output",  # 或 "output"，取决于你的Agent链路实际返回的key
        )
        
        self.agent = initialize_agent(
            tools=self.tools,
            llm=self.llm,
            agent=AgentType.CHAT_CONVERSATIONAL_REACT_DESCRIPTION,
            verbose=True,
            memory=self.memory,
            handle_parsing_errors=True,
            output_key="output"
        )
        
        # IPC通信文件路径
        self.ipc_input_file = None
        self.ipc_output_file = None
        self.work_dir = None
    

    
    async def _init_memory_system(self):
        """初始化记忆系统"""
        try:
            # 尝试加载现有的向量数据库
            if not self.work_dir:
                raise ValueError("work_dir未设置")
            vector_db_path = Path(self.work_dir) / "vector_db"
            if vector_db_path.exists():
                logger.info("加载现有向量数据库...")
                self.vector_db = FAISS.load_local(str(vector_db_path), self.embeddings)
            else:
                logger.info("创建新的向量数据库...")
                # 创建一个包含默认文档的向量数据库
                default_doc = Document(page_content="这是一个默认文档，用于初始化向量数据库。")
                self.vector_db = FAISS.from_documents([default_doc], self.embeddings)
                # 保存初始数据库
                if self.vector_db is not None:
                    self.vector_db.save_local(str(vector_db_path))
            
            # 构建问答链
            if self.vector_db is not None:
                self.qa_chain = ConversationalRetrievalChain.from_llm(
                    llm=self.llm,
                    retriever=self.vector_db.as_retriever(),
                    memory=self.memory,
                    return_source_documents=True
                )
            
            logger.info("记忆系统初始化完成")
            
        except Exception as e:
            logger.error(f"初始化记忆系统失败: {e}")
            # 如果失败，尝试创建一个最小的向量数据库
            try:
                default_doc = Document(page_content="初始化文档")
                self.vector_db = FAISS.from_documents([default_doc], self.embeddings)
                logger.info("使用备用方法创建向量数据库成功")
            except Exception as e2:
                logger.error(f"备用方法也失败: {e2}")
                self.vector_db = None

    async def _add_meeting_content(self, content: str):
        """添加会议内容到记忆系统"""
        try:
            if not content.strip():
                return
            
            # 检查向量数据库是否可用
            if self.vector_db is None:
                logger.warning("向量数据库未初始化，无法添加内容")
                return
            
            # 添加到会议内容列表
            self.meeting_content.append(content)
            
            # 创建文档
            doc = Document(page_content=content)
            
            # 添加到向量数据库
            self.vector_db.add_documents([doc])
            
            # 保存向量数据库
            if not self.work_dir:
                raise ValueError("work_dir未设置")
            vector_db_path = Path(self.work_dir) / "vector_db"
            if self.vector_db is not None:
                self.vector_db.save_local(str(vector_db_path))
            
            logger.info(f"已添加会议内容到记忆系统: {content[:50]}...")
            
        except Exception as e:
            logger.error(f"添加会议内容失败: {e}")

    async def _query_memory(self, question: str) -> str:
        """查询记忆系统"""
        try:
            if not self.qa_chain:
                return "记忆系统未初始化"
            
            if self.vector_db is None:
                return "向量数据库未初始化"
            
            # 执行查询
            result = self.qa_chain.invoke({"question": question})
            logger.info("="*100)
            logger.info(f"result: {result}")
            logger.info("="*100)
            
            # 获取答案和来源
            answer = result.get('answer', '')
            source_docs = result.get('source_documents', [])
            
            # 构建响应
            response = f"答案：{answer}"
            
            if source_docs:
                response += "\n\n来源："
                for i, doc in enumerate(source_docs[:3], 1):  # 最多显示3个来源
                    response += f"\n{i}. {doc.page_content[:100]}..."
            
            return response
            
        except Exception as e:
            logger.error(f"查询记忆系统失败: {e}")
            return f"查询失败: {str(e)}"

    async def _refresh_session_content(self):
        """刷新会话内容 - 从主服务获取最新转录数据"""
        try:
            logger.info(f"刷新会话 {self.current_session_id} 的内容...")
            
            # 获取会话数据
            response = requests.get(f"{self.api_base_url}/api/sessions/{self.current_session_id}")
            if response.status_code == 200:
                session_data = response.json()
                if session_data.get("success"):
                    session = session_data["session"]
                    transcript_segments = session.get("transcript_segments", [])
                    
                    # 合并转录文本
                    if transcript_segments:
                        transcript_text = ""
                        for segment in transcript_segments:
                            transcript_text += segment.get("text", "") + "\n"
                        
                        if transcript_text.strip():
                            logger.info(f"获取到转录文本，长度: {len(transcript_text)}")
                            # 添加到记忆系统
                            await self._add_meeting_content(transcript_text)
                    
                    logger.info(f"会话内容刷新完成，当前内容片段数: {len(self.meeting_content)}")
                else:
                    logger.error(f"获取会话数据失败: {session_data}")
            else:
                logger.error(f"API请求失败: {response.status_code}")
                
        except Exception as e:
            logger.error(f"刷新会话内容失败: {e}")

    @retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=4, max=10))
    async def _handle_chat_message(self, content: str) -> str:
        """处理聊天消息（带重试机制）"""
        try:
            logger.info(f"开始处理用户消息: {content[:50]}...")
            agent_response = await self.agent.ainvoke({"input": content})
            response_text = agent_response.get("output", "抱歉，我无法处理您的请求。")
            logger.info(f"Agent响应成功: {response_text[:50]}...")
            return response_text
        except Exception as e:
            logger.error(f"Agent处理失败: {e}")
            logger.error(f"详细错误信息: {traceback.format_exc()}")
            raise  # 重新抛出异常以触发重试

    async def handle_command(self, command: IPCCommand) -> IPCResponse:
        """处理IPC命令"""
        try:
            if command.command == "message":
                # 先刷新会话内容
                await self._refresh_session_content()
                
                # 处理消息
                content = command.params.get("content", "")
                try:
                    result = await self._handle_chat_message(content)
                    return IPCResponse(
                        success=True,
                        data={"response": result},
                        error=None,
                        timestamp=datetime.now()
                    )
                except Exception as e:
                    logger.error(f"Agent处理消息失败: {e}")
                    return IPCResponse(
                        success=False,
                        data=None,
                        error=f"Agent处理失败: {str(e)}",
                        timestamp=datetime.now()
                    )
            
            else:
                return IPCResponse(
                    success=False,
                    data=None,
                    error=f"未知命令: {command.command}",
                    timestamp=datetime.now()
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
    parser.add_argument('--session-id', required=True, help='会话ID')
    parser.add_argument('--ipc-input', required=True, help='IPC输入管道文件路径')
    parser.add_argument('--ipc-output', required=True, help='IPC输出管道文件路径')
    parser.add_argument('--work-dir', required=True, help='工作目录')
    args = parser.parse_args()
    
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
    )
    
    processor = AgentProcessor()
    processor.current_session_id = args.session_id
    processor.ipc_input_file = args.ipc_input
    processor.ipc_output_file = args.ipc_output
    processor.work_dir = args.work_dir
    
    logger.info(f"Agent处理器进程启动: session_id={args.session_id}")
    
    # 初始化记忆系统
    await processor._init_memory_system()
    
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
        logger.info("Agent处理器进程结束")

if __name__ == "__main__":
    asyncio.run(main())
