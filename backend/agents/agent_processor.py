import sys
import asyncio
import json
import logging
import os
import requests
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, Optional, List
import argparse

from langchain.agents import AgentExecutor, initialize_agent
from langchain.agents.agent_types import AgentType
from langchain_openai import ChatOpenAI, OpenAIEmbeddings
from langchain.memory import ConversationBufferMemory
from langchain_core.documents import Document
from langchain_community.vectorstores import FAISS
from langchain.chains import ConversationalRetrievalChain

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
        self.work_dir: Optional[Path] = None
        
        # 记忆系统组件
        self.vector_db: Optional[FAISS] = None
        self.qa_chain: Optional[ConversationalRetrievalChain] = None
        self.meeting_content: List[str] = []
        
        # 主服务API配置
        self.api_base_url = "http://localhost:8000"
        
        # 初始化LLM和Agent
        self.llm = ChatOpenAI(
            temperature=0.2,
            model="gpt-3.5-turbo",
            openai_api_key=os.getenv("OPENAI_API_KEY")
        )
        
        # 初始化嵌入模型
        self.embeddings = OpenAIEmbeddings(
            openai_api_key=os.getenv("OPENAI_API_KEY")
        )
        
        self.tools = [TimeTool(), SummaryTool()]
        
        # 配置记忆系统
        self.memory = ConversationBufferMemory(
            memory_key="chat_history",
            return_messages=True,  # 关键修复：确保返回消息对象而非字符串
            output_key='answer'
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
        
        # 初始化记忆系统
        await self._init_memory_system()
        
        # 从主服务获取会议内容并添加到记忆系统
        await self._load_session_content()
        
        self.running = True
        logger.info(f"Agent处理器启动: session_id={session_id}")
        
        try:
            await self._ipc_loop()
        except Exception as e:
            logger.error(f"处理器运行错误: {e}")
        finally:
            await self.stop()

    async def _load_session_content(self):
        """从主服务加载会话内容到记忆系统"""
        try:
            logger.info(f"从主服务加载会话 {self.session_id} 的内容...")
            
            # 获取会话数据
            response = requests.get(f"{self.api_base_url}/api/sessions/{self.session_id}")
            if response.status_code == 200:
                session_data = response.json()
                if session_data.get("success"):
                    session = session_data["session"]
                    
                    # 获取转录片段
                    transcript_segments = session.get("transcript_segments", [])
                    if transcript_segments:
                        # 合并转录文本
                        transcript_text = ""
                        for segment in transcript_segments:
                            transcript_text += segment.get("text", "") + "\n"
                        
                        if transcript_text.strip():
                            logger.info(f"获取到转录文本，长度: {len(transcript_text)}")
                            await self._add_meeting_content(transcript_text)
                    
                    # 获取摘要内容
                    current_summary = session.get("current_summary")
                    if current_summary:
                        summary_text = current_summary.get("summary_text", "")
                        if summary_text.strip():
                            logger.info(f"获取到摘要内容，长度: {len(summary_text)}")
                            await self._add_meeting_content(summary_text)
                        
                        # 添加任务项
                        tasks = current_summary.get("tasks", [])
                        if tasks:
                            tasks_text = "待办事项:\n"
                            for i, task in enumerate(tasks, 1):
                                tasks_text += f"{i}. {task.get('description', '')}\n"
                            await self._add_meeting_content(tasks_text)
                        
                        # 添加关键点
                        key_points = current_summary.get("key_points", [])
                        if key_points:
                            points_text = "关键要点:\n"
                            for i, point in enumerate(key_points, 1):
                                points_text += f"{i}. {point}\n"
                            await self._add_meeting_content(points_text)
                    
                    logger.info(f"会话内容加载完成，共添加 {len(self.meeting_content)} 个内容片段")
                else:
                    logger.error(f"获取会话数据失败: {session_data}")
            else:
                logger.error(f"API请求失败: {response.status_code}")
                
        except Exception as e:
            logger.error(f"加载会话内容失败: {e}")

    async def _init_memory_system(self):
        """初始化记忆系统"""
        try:
            # 尝试加载现有的向量数据库
            vector_db_path = self.work_dir / "vector_db"
            if vector_db_path.exists():
                logger.info("加载现有向量数据库...")
                self.vector_db = FAISS.load_local(str(vector_db_path), self.embeddings)
            else:
                logger.info("创建新的向量数据库...")
                # 创建一个包含默认文档的向量数据库
                default_doc = Document(page_content="这是一个默认文档，用于初始化向量数据库。")
                self.vector_db = FAISS.from_documents([default_doc], self.embeddings)
                # 保存初始数据库
                self.vector_db.save_local(str(vector_db_path))
            
            # 构建问答链
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
            vector_db_path = self.work_dir / "vector_db"
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
                    
                    # 检查是否是message命令
                    if message.get("command") == "message":
                        # 先获取会话转录内容并添加到记忆
                        await self._refresh_session_content()
                    
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

    async def _refresh_session_content(self):
        """刷新会话内容 - 使用summary_processor的逻辑"""
        try:
            logger.info(f"刷新会话 {self.session_id} 的内容...")
            
            # 使用summary_processor相同的逻辑获取会话数据
            import requests
            response = requests.get(f"{self.api_base_url}/api/sessions/{self.session_id}")
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

    async def _handle_chat_message(self, content: str) -> Dict[str, Any]:
        """处理聊天消息"""
        try:
            # 普通对话，先查询记忆系统，然后使用Agent
            memory_response = ""
            if self.meeting_content:  # 如果有会议内容，先查询记忆
                memory_response = await self._query_memory(content)
            
            # 使用Agent处理
            try:
                agent_response = await self.agent.ainvoke({"input": content})
                # 处理不同的响应格式
                if isinstance(agent_response, dict):
                    agent_output = agent_response.get("output", str(agent_response))
                else:
                    agent_output = str(agent_response)
            except Exception as e:
                logger.error(f"Agent处理失败: {e}")
                agent_output = f"Agent处理失败: {str(e)}"
            
            # 组合响应
            if memory_response and memory_response != "记忆系统未初始化" and memory_response != "向量数据库未初始化":
                final_response = f"{memory_response}\n\n---\n\nAgent回答：{agent_output}"
            else:
                final_response = agent_output
            
            return {
                "success": True,
                "response": final_response,
                "timestamp": datetime.now().isoformat()
            }
        except Exception as e:
            logger.error(f"处理聊天消息失败: {e}")
            return {
                "success": False,
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }

    async def process_message(self, message: Dict[str, Any]) -> Dict[str, Any]:
        """处理传入的消息"""
        try:
            # 处理IPC命令格式
            if "command" in message:
                command = message.get("command")
                content = message.get("params", {}).get("content", "")
                
                if command == "message":
                    # 处理普通消息
                    return await self._handle_chat_message(content)
                else:
                    # 其他命令类型
                    return {
                        "success": False,
                        "error": f"未知命令: {command}",
                        "timestamp": datetime.now().isoformat()
                    }
            else:
                # 处理旧的消息格式
                message_type = message.get("type", "chat")
                content = message.get("content", "")
                
                if message_type == "add_content":
                    # 添加会议内容到记忆系统
                    await self._add_meeting_content(content)
                    return {
                        "success": True,
                        "response": "会议内容已添加到记忆系统",
                        "timestamp": datetime.now().isoformat()
                    }
                
                elif message_type == "query_memory":
                    # 查询记忆系统
                    answer = await self._query_memory(content)
                    return {
                        "success": True,
                        "response": answer,
                        "timestamp": datetime.now().isoformat()
                    }
                
                elif message_type == "refresh_content":
                    # 刷新会议内容（从主服务重新加载）
                    await self._refresh_session_content()
                    return {
                        "success": True,
                        "response": f"已刷新会议内容，当前记忆系统包含 {len(self.meeting_content)} 个内容片段",
                        "timestamp": datetime.now().isoformat()
                    }
                
                elif message_type == "chat":
                    # 普通对话，先查询记忆系统，然后使用Agent
                    return await self._handle_chat_message(content)
                
                else:
                    # 默认使用Agent处理
                    return await self._handle_chat_message(content)
                
        except Exception as e:
            logger.error(f"处理消息失败: {e}")
            return {
                "success": False,
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }

    def get_memory_stats(self) -> Dict[str, Any]:
        """获取记忆系统统计信息"""
        return {
            "meeting_content_count": len(self.meeting_content),
            "vector_db_exists": self.vector_db is not None,
            "qa_chain_exists": self.qa_chain is not None,
            "memory_initialized": self.memory is not None,
            "session_id": self.session_id
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
