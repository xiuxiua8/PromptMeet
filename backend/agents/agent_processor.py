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

# 添加项目根目录到路径
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from langchain_openai import ChatOpenAI, OpenAIEmbeddings
from langchain.memory import ConversationBufferMemory
from langchain_core.documents import Document
from langchain_community.vectorstores import FAISS
from langchain.chains import ConversationalRetrievalChain
from langchain.schema import HumanMessage, AIMessage

# 工具导入
from tools.manager import ToolManager
from models.data_models import IPCMessage, IPCCommand, IPCResponse
from config import settings

# 重试机制导入
from tenacity import retry, stop_after_attempt, wait_exponential

logger = logging.getLogger(__name__)

class AgentProcessor:
    """Agent处理器"""
    
    def __init__(self):
        self.running = False
        self.current_session_id = None
        
        # IPC通信文件路径
        self.ipc_input_file = None
        self.ipc_output_file = None
        self.work_dir = None
        
        # 记忆系统组件
        self.vector_db: Optional[FAISS] = None
        self.qa_chain: Optional[ConversationalRetrievalChain] = None
        self.meeting_content: List[str] = []
        
        # 主服务API配置
        self.api_base_url = "http://localhost:8000"
        
        # 初始化LLM和Agent
        api_key = SecretStr(settings.DEEPSEEK_API_KEY)
        base_url = settings.DEEPSEEK_API_BASE
        
        self.llm = ChatOpenAI(
            api_key=api_key,
            base_url=base_url,
            model=settings.DEEPSEEK_MODEL,
            temperature=settings.DEEPSEEK_TEMPERATURE,
            streaming=True,
            timeout=60,  # 增加超时时间
            max_retries=3  # 增加重试次数
        )
        
        # 初始化嵌入模型
        openai_api_key = SecretStr(settings.OPENAI_API_KEY)
        
        self.embeddings = OpenAIEmbeddings(
            api_key=openai_api_key
        )
        
        # 工具管理器
        self.tool_manager = ToolManager()
        
        # 配置记忆系统
        self.memory = ConversationBufferMemory(
            memory_key="chat_history",
            return_messages=True,
            output_key="output",
        )
        
        # 直接使用LLM进行对话，不使用agent框架
        self._chat_model = None
        self.waiting_for_calendar_info = False  # 新增：标记是否等待用户补全日程信息
        self.calendar_info_buffer = {}         # 新增：临时存储用户补全信息
    
    @property
    def chat_model(self):
        """获取聊天模型"""
        if self._chat_model is None:
            self._chat_model = self.llm
        return self._chat_model
    
    def get_available_tools(self):
        """获取可用工具列表"""
        return self.tool_manager.get_available_tools()
    
    async def execute_tool(self, tool_name: str, parameters: dict):
        """执行工具"""
        result = await self.tool_manager.execute_tool(tool_name, parameters)
        return {
            "tool_name": result.tool_name,
            "result": result.result,
            "success": result.success,
            "error": result.error
        }
    
    def _convert_messages_to_dict(self, messages: List) -> List[Dict[str, str]]:
        """转换消息为字典格式"""
        result = []
        for msg in messages:
            if isinstance(msg, HumanMessage):
                result.append({"role": "user", "content": msg.content})
            elif isinstance(msg, AIMessage):
                result.append({"role": "assistant", "content": msg.content})
        return result
    
    def _convert_memory_to_history(self) -> List[Dict[str, str]]:
        """获取对话历史"""
        history = self.memory.chat_memory.messages
        return self._convert_messages_to_dict(history)
    
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

    async def _detect_and_execute_tools(self, user_message: str, ai_response: str) -> List[Dict[str, Any]]:
        """检测并执行工具调用"""
        tools_used = []
        
        # 检测时间查询 - 更精确的检测
        time_keywords = ['时间', '几点', '日期']
        weather_keywords = ['天气', '温度', '气温', '下雨', '晴天', '阴天']
        food_keywords = ['吃', '喝', '饭', '菜', '餐', '食']
        emotion_keywords = ['心情', '感觉', '情绪', '开心', '难过', '高兴']
        
        # 检查是否包含各种上下文关键词
        has_weather_context = any(keyword in user_message.lower() for keyword in weather_keywords)
        has_food_context = any(keyword in user_message.lower() for keyword in food_keywords)
        has_emotion_context = any(keyword in user_message.lower() for keyword in emotion_keywords)
        
        # 检查是否包含时间查询关键词
        has_time_keywords = any(keyword in user_message.lower() for keyword in time_keywords)
        
        # 检查是否以"今天"开头但不包含其他上下文
        starts_with_today = user_message.lower().startswith('今天')
        has_other_context = has_weather_context or has_food_context or has_emotion_context
        
        if has_time_keywords or (starts_with_today and not has_other_context):
            try:
                result = await self.execute_tool("time", {})
                if result["success"]:
                    msg = result["result"].get("message") or result["result"]
                    tools_used.append({
                        "tool": "time",
                        "parameters": {},
                        "result": msg
                    })
            except Exception as e:
                logger.error(f"时间工具执行错误: {e}")
        
        # 检测天气查询
        if has_weather_context:
            try:
                # 提取城市名（简化版本）
                import re
                city_pattern = r'([北京|上海|广州|深圳|杭州|南京|成都|武汉|西安|重庆|天津|青岛|大连|厦门|苏州|无锡|宁波|长沙|郑州|济南|哈尔滨|沈阳|长春|石家庄|太原|呼和浩特|合肥|福州|南昌|南宁|海口|贵阳|昆明|拉萨|兰州|西宁|银川|乌鲁木齐]+)'
                matches = re.findall(city_pattern, user_message)
                if matches:
                    city = matches[0]
                    result = await self.execute_tool("weather", {"city": city})
                    if result["success"]:
                        tools_used.append({
                            "tool": "weather",
                            "parameters": {"city": city},
                            "result": result["result"]
                        })
            except Exception as e:
                logger.error(f"天气工具执行错误: {e}")
        
        # 检测计算器调用
        if any(keyword in user_message.lower() for keyword in ['计算', '算', '等于', '+', '-', '*', '/']):
            try:
                import re
                # 改进的数学表达式匹配模式
                math_pattern = r'(\d+[\+\-\*\/\s\(\)\d\.]+)'
                matches = re.findall(math_pattern, user_message)
                if matches:
                    expression = matches[0].strip()
                    result = await self.execute_tool("calculator", {"expression": expression})
                    if result["success"]:
                        tools_used.append({
                            "tool": "calculator",
                            "parameters": {"expression": expression},
                            "result": result["result"]
                        })
            except Exception as e:
                logger.error(f"计算器工具执行错误: {e}")
        
        # 检测翻译需求
        if any(keyword in user_message.lower() for keyword in ['翻译', 'translate', '英文', '中文', '日文', '韩文', '法文', '德文', '西班牙文', '俄文']):
            try:
                import re
                
                # 检测目标语言
                target_lang = "en"  # 默认翻译为英文
                if any(lang in user_message.lower() for lang in ['中文', '汉语', 'chinese']):
                    target_lang = "zh"
                elif any(lang in user_message.lower() for lang in ['日文', '日语', 'japanese']):
                    target_lang = "ja"
                elif any(lang in user_message.lower() for lang in ['韩文', '韩语', 'korean']):
                    target_lang = "ko"
                elif any(lang in user_message.lower() for lang in ['法文', '法语', 'french']):
                    target_lang = "fr"
                elif any(lang in user_message.lower() for lang in ['德文', '德语', 'german']):
                    target_lang = "de"
                elif any(lang in user_message.lower() for lang in ['西班牙文', '西班牙语', 'spanish']):
                    target_lang = "es"
                elif any(lang in user_message.lower() for lang in ['俄文', '俄语', 'russian']):
                    target_lang = "ru"
                
                # 提取要翻译的文本（在引号中的内容）
                text_pattern = r'["""]([^"""]+)["""]'
                matches = re.findall(text_pattern, user_message)
                
                if matches:
                    text_to_translate = matches[0]
                    result = await self.execute_tool("translate", {
                        "text": text_to_translate,
                        "target_lang": target_lang
                    })
                    if result["success"]:
                        tools_used.append({
                            "tool": "translate",
                            "parameters": {
                                "text": text_to_translate,
                                "target_lang": target_lang
                            },
                            "result": result["result"]
                        })
            except Exception as e:
                logger.error(f"翻译工具执行错误: {e}")
        
        # 检测网络搜索需求
        if any(keyword in user_message.lower() for keyword in ['搜索', '查找', '查询', 'search', '查找', '了解', '联网', '上网']):
            try:
                import re
                
                # 提取搜索关键词
                # 移除常见的搜索指示词
                search_query = user_message
                search_indicators = ['搜索', '查找', '查询', 'search', '查找', '了解', '什么是', '什么是', '如何', '怎么']
                
                for indicator in search_indicators:
                    search_query = search_query.replace(indicator, '').strip()
                
                # 如果搜索查询不为空，执行搜索
                if search_query and len(search_query) > 2:
                    result = await self.execute_tool("web_search", {"query": search_query})
                    if result["success"]:
                        tools_used.append({
                            "tool": "web_search",
                            "parameters": {"query": search_query},
                            "result": result["result"]
                        })
            except Exception as e:
                logger.error(f"网络搜索工具执行错误: {e}")
        
        # 检测摘要生成 - 更全面的关键词检测
        summary_keywords = ['摘要', '总结', '概括', 'summary', '生成摘要', '生成总结', '帮我生成', '做一个摘要', '做一个总结']
        if any(keyword in user_message.lower() for keyword in summary_keywords):
            try:
                # 获取会议内容，如果没有内容则使用默认文本
                if self.meeting_content:
                    content = "\n".join(self.meeting_content[-5:])  # 最近5个片段
                else:
                    content = "这是一个测试会议内容，用于演示摘要生成功能。会议讨论了项目进展、技术方案和下一步计划。"
                
                result = await self.execute_tool("summary", {"text": content})
                if result["success"]:
                    tools_used.append({
                        "tool": "summary",
                        "parameters": {"text": content},
                        "result": result["result"]
                    })
            except Exception as e:
                logger.error(f"摘要工具执行错误: {e}")
        
        # 检测飞书日历同步需求
        calendar_keywords = ['日历', '日程', '飞书', 'feishu', '同步', '添加到日历', '创建日程', '安排时间']
        # 新增：检测用户输入是否为具体日程内容
        is_concrete_calendar = False
        import re
        # 简单判断：包含“时间”、“标题”或常见日期时间表达
        if re.search(r'(标题|时间|提醒|\d{1,2}月\d{1,2}日|\d{4}-\d{1,2}-\d{1,2}|上午|下午|全天|点|:)', user_message):
            is_concrete_calendar = True
        if is_concrete_calendar:
            # 直接解析用户输入并调用feishu_calendar（manual_task参数）
            title = ''
            time_str = ''
            remind = ''
            m_title = re.search(r'标题[:：]?([\S ]+?)(,|，|$)', user_message)
            m_time = re.search(r'时间[:：]?([\S ]+?)(,|，|$)', user_message)
            m_remind = re.search(r'提醒[:：]?([\S ]+?)(,|，|$)', user_message)
            if m_title:
                title = m_title.group(1).strip()
            if m_time:
                time_str = m_time.group(1).strip()
            if m_remind:
                remind = m_remind.group(1).strip()
            # 若没显式"标题"，用整句或默认
            if not title:
                # 尝试从句子中提取更合适的标题
                # 方法1：提取"要"、"去"、"进行"等动词后面的内容
                action_patterns = [
                    r'要(.+?)(?=\s|$)',  # 要实习
                    r'去(.+?)(?=\s|$)',  # 去开会
                    r'进行(.+?)(?=\s|$)',  # 进行面试
                    r'参加(.+?)(?=\s|$)',  # 参加会议
                ]
                
                for pattern in action_patterns:
                    match = re.search(pattern, user_message)
                    if match:
                        title = match.group(1).strip()
                        break
                
                # 方法2：如果方法1没找到，提取句子的最后部分（通常是活动名称）
                if not title:
                    # 移除时间相关词汇
                    time_keywords = ['明天', '后天', '下周一', '下周二', '下周三', '下周四', '下周五', '下周六', '下周日', 
                                   '上午', '下午', '晚上', '早上', '中午', '全天', '点', ':', '：', '到', '开始', '结束',
                                   '八', '九', '十', '十一', '十二', '一', '二', '三', '四', '五', '六', '七']
                    
                    potential_title = user_message.strip()
                    for keyword in time_keywords:
                        potential_title = potential_title.replace(keyword, '')
                    
                    # 清理多余的空格和标点
                    potential_title = re.sub(r'\s+', ' ', potential_title).strip()
                    potential_title = re.sub(r'^[，,、\s]+|[，,、\s]+$', '', potential_title)
                    
                    # 如果清理后还有内容，使用它作为标题
                    if potential_title and len(potential_title) > 1:
                        title = potential_title
                    else:
                        # 如果清理后没有合适内容，使用原句子的最后部分
                        title = user_message.strip().split('，')[-1].split(',')[-1].strip()
            if not time_str:
                # 尝试提取时间表达
                m_time2 = re.search(r'(\d{1,2}月\d{1,2}日.*?)(?:，|,|$)', user_message)
                if m_time2:
                    time_str = m_time2.group(1)
                else:
                    # 尝试提取其他时间表达
                    time_patterns = [
                        r'(明天.*?点.*?到.*?点)',  # 明天早上八点开始到十二点
                        r'(后天.*?点.*?到.*?点)',  # 后天上午10点到12点
                        r'(下.*?.*?点.*?到.*?点)',  # 下周一上午9点面试
                        r'(明天.*?点)',  # 明天下午2点
                        r'(后天.*?点)',  # 后天上午10点
                        r'(下.*?.*?点)',  # 下周一上午9点
                        r'(\d{1,2}点.*?到.*?\d{1,2}点)',  # 八点开始到十二点
                        r'(\d{1,2}:\d{2}.*?到.*?\d{1,2}:\d{2})',  # 8:00到12:00
                    ]
                    for pattern in time_patterns:
                        m_time3 = re.search(pattern, user_message)
                        if m_time3:
                            time_str = m_time3.group(1)
                            break
            manual_task = {"title": title, "deadline": time_str, "remind": remind}
            result = await self.execute_tool("feishu_calendar", {"manual_task": manual_task})
            tools_used.append({
                "tool": "feishu_calendar",
                "parameters": {"manual_task": manual_task},
                "result": getattr(result, 'result', result)
            })
            return tools_used
        # 只有明确“发送日程”等指令且没有具体日程输入时才读Result.txt
        if any(keyword in user_message.lower() for keyword in calendar_keywords):
            result_file_path = os.path.join("backend", "agents", "temp", "Result.txt")
            import re
            file_pattern = r'文件[：:]\s*([^\s]+)'
            file_match = re.search(file_pattern, user_message)
            if file_match:
                result_file_path = file_match.group(1)
            result = await self.execute_tool("feishu_calendar", {"result_file_path": result_file_path})
            if result["success"] and result["result"].get("total_tasks", 0) > 0:
                tools_used.append({
                    "tool": "feishu_calendar",
                    "parameters": {"result_file_path": result_file_path},
                    "result": f"已自动为你添加日程到飞书日历！详情：{result['result']}"
                })
                self.waiting_for_calendar_info = False
                self.calendar_info_buffer = {}
            else:
                self.waiting_for_calendar_info = True
                tools_used.append({
                    "tool": "feishu_calendar",
                    "parameters": {"result_file_path": result_file_path},
                    "result": "未检测到可添加的日程，请补充日程信息：标题、时间、提醒。例如：标题：实习，时间：7月20日10:00-12:00，提醒：是"
                })
        return tools_used

    @retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=4, max=10))
    async def _handle_chat_message(self, content: str) -> str:
        """处理聊天消息（带重试机制）"""
        try:
            logger.info(f"开始处理用户消息: {content[:50]}...")
            
            # 获取对话历史
            history = self.memory.chat_memory.messages
            
            # 检测并执行工具调用
            tools_used = await self._detect_and_execute_tools(content, "")
            
            # 构建完整的对话上下文
            context = ""
            for msg in history:
                if isinstance(msg, HumanMessage):
                    context += f"用户: {msg.content}\n"
                elif isinstance(msg, AIMessage):
                    context += f"助手: {msg.content}\n"
            
            # 添加工具信息到上下文
            tools_info = "可用工具:\n"
            for tool in self.get_available_tools():
                tools_info += f"- {tool['name']}: {tool['description']}\n"
            context += f"\n{tools_info}\n"
            
            # 如果有工具结果，添加到上下文中
            if tools_used:
                context += "\n工具执行结果:\n"
                for tool in tools_used:
                    context += f"- {tool['tool']}: {tool['result']}\n"
                context += "\n"
            
            # 添加当前用户消息
            context += f"用户: {content}\n助手:"
            
            # 构建包含工具结果的提示词
            system_prompt = """你是一个智能助手，可以使用各种工具来帮助用户。当用户询问需要工具支持的问题时，请基于工具执行结果来回答。

如果检测到用户需要工具支持（如查询时间、生成摘要等），请使用工具结果来提供准确的回答。

请用友好、自然的语气回答，并在适当时候使用工具结果。"""
            
            # 调用聊天模型
            messages = [
                ("system", system_prompt),
                ("human", context)
            ]
            response = await self.chat_model.ainvoke(messages)
            ai_response = response.content
            
            # 保存到记忆
            self.memory.chat_memory.add_user_message(content)
            self.memory.chat_memory.add_ai_message(ai_response)
            
            logger.info(f"Agent响应成功: {ai_response[:50]}...")
            return ai_response
        except Exception as e:
            logger.error(f"Agent处理失败: {e}")
            logger.error(f"详细错误信息: {traceback.format_exc()}")
            raise  # 重新抛出异常以触发重试
    
    def clear_memory(self):
        """清空记忆"""
        self.memory.clear()
    
    def get_conversation_history(self) -> List[Dict[str, str]]:
        """获取对话历史"""
        return self._convert_memory_to_history()

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
