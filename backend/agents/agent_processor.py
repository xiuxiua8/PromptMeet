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

try:
    from pydantic import SecretStr
except ImportError:
    SecretStr = str

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
            max_retries=3,  # 增加重试次数
        )

        # 初始化嵌入模型
        openai_api_key = SecretStr(settings.OPENAI_API_KEY)

        self.embeddings = OpenAIEmbeddings(api_key=openai_api_key)

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
        self.calendar_info_buffer = {}  # 新增：临时存储用户补全信息

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
            "error": result.error,
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
                default_doc = Document(
                    page_content="这是一个默认文档，用于初始化向量数据库。"
                )
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
                    return_source_documents=True,
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
            logger.info("=" * 100)
            logger.info(f"result: {result}")
            logger.info("=" * 100)

            # 获取答案和来源
            answer = result.get("answer", "")
            source_docs = result.get("source_documents", [])

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
            response = requests.get(
                f"{self.api_base_url}/api/sessions/{self.current_session_id}"
            )
            if response.status_code == 200:
                session_data = response.json()
                if session_data.get("success"):
                    session = session_data["session"]
                    transcript_segments = session.get("transcript_segments", [])
                    image_ocr_result = session.get("image_ocr_result", [])

                    # 合并转录文本
                    if transcript_segments:
                        transcript_text = ""
                        for segment in transcript_segments:
                            transcript_text += segment.get("text", "") + "\n"
                        if transcript_text.strip():
                            logger.info(f"获取到转录文本，长度: {len(transcript_text)}")
                            # 添加到记忆系统，带标记
                            await self._add_meeting_content(
                                "[转录]\n" + transcript_text
                            )

                    # 合并OCR文本
                    if image_ocr_result:
                        ocr_text = ""
                        for ocr in image_ocr_result:
                            ocr_text += ocr.get("text", "") + "\n"
                        if ocr_text.strip():
                            logger.info(f"获取到OCR文本，长度: {len(ocr_text)}")
                            # 添加到记忆系统，带标记
                            await self._add_meeting_content("[截图OCR]\n" + ocr_text)

                    logger.info(
                        f"会话内容刷新完成，当前内容片段数: {len(self.meeting_content)}"
                    )
                else:
                    logger.error(f"获取会话数据失败: {session_data}")
            else:
                logger.error(f"API请求失败: {response.status_code}")

        except Exception as e:
            logger.error(f"刷新会话内容失败: {e}")

    def _read_result_file(self) -> dict:
        """读取Result.txt文件并解析邮件信息"""
        try:
            # 尝试多个可能的路径
            possible_paths = [
                Path(self.work_dir) / "Result.txt",
                Path(self.work_dir).parent / "temp" / "Result.txt",
                Path(__file__).parent / "temp" / "Result.txt",
                Path(__file__).parent.parent / "temp" / "Result.txt",
            ]

            logger.info(f"当前work_dir: {self.work_dir}")
            logger.info(f"当前文件路径: {__file__}")

            result_file_path = None
            for i, path in enumerate(possible_paths):
                logger.info(f"检查路径 {i+1}: {path} - 存在: {path.exists()}")
                if path.exists():
                    result_file_path = path
                    break

            if not result_file_path:
                logger.warning("未找到Result.txt文件，尝试的路径:")
                for path in possible_paths:
                    logger.warning(f"  - {path}")
                return {
                    "need_email": False,
                    "recipient_name": "",
                    "recipient_email": "",
                    "subject": "",
                    "content": "",
                }

            logger.info(f"找到Result.txt文件: {result_file_path}")

            with open(result_file_path, "r", encoding="utf-8") as f:
                content = f.read()

            logger.info(f"文件内容长度: {len(content)} 字符")
            logger.info(f"文件内容前200字符: {content[:200]}")

            # 解析邮件信息部分
            import re

            # 尝试多种匹配模式
            email_match = re.search(
                r"【邮件信息】\n(.*?)(?=\n\n【|$)", content, re.DOTALL
            )
            if not email_match:
                # 如果第一种模式失败，尝试更宽松的模式
                email_match = re.search(
                    r"【邮件信息】\n(.*?)(?=\n【|$)", content, re.DOTALL
                )
            if not email_match:
                # 如果还是失败，尝试最简单的模式
                email_match = re.search(
                    r"【邮件信息】\n(.*?)(?=\n===|$)", content, re.DOTALL
                )

            if email_match:
                email_json = email_match.group(1).strip()
                try:
                    email_info = json.loads(email_json)
                    return email_info
                except json.JSONDecodeError as e:
                    return {
                        "need_email": False,
                        "recipient_name": "",
                        "recipient_email": "",
                        "subject": "",
                        "content": "",
                    }
            else:
                # 尝试查找是否包含邮件相关的文本
                if "邮件" in content:
                    return {
                        "need_email": False,
                        "recipient_name": "",
                        "recipient_email": "",
                        "subject": "",
                        "content": "",
                    }
                # 如果没有匹配，直接返回空dict
                return {
                    "need_email": False,
                    "recipient_name": "",
                    "recipient_email": "",
                    "subject": "",
                    "content": "",
                }
        except Exception as e:
            logger.error(f"读取Result.txt文件失败: {e}")
            import traceback

            logger.error(f"详细错误: {traceback.format_exc()}")
            return {
                "need_email": False,
                "recipient_name": "",
                "recipient_email": "",
                "subject": "",
                "content": "",
            }

    async def _detect_and_execute_tools(
        self, user_message: str, ai_response: str
    ) -> List[Dict[str, Any]]:
        """检测并执行工具调用"""
        tools_used = []

        # 检测时间查询 - 更精确的检测
        time_keywords = ["时间", "几点", "日期"]
        weather_keywords = ["天气", "温度", "气温", "下雨", "晴天", "阴天"]
        food_keywords = ["吃", "喝", "饭", "菜", "餐", "食"]
        emotion_keywords = ["心情", "感觉", "情绪", "开心", "难过", "高兴"]

        # 检查是否包含各种上下文关键词
        has_weather_context = any(
            keyword in user_message.lower() for keyword in weather_keywords
        )
        has_food_context = any(
            keyword in user_message.lower() for keyword in food_keywords
        )
        has_emotion_context = any(
            keyword in user_message.lower() for keyword in emotion_keywords
        )

        # 检查是否包含时间查询关键词
        has_time_keywords = any(
            keyword in user_message.lower() for keyword in time_keywords
        )

        # 检查是否以"今天"开头但不包含其他上下文
        starts_with_today = user_message.lower().startswith("今天")
        has_other_context = (
            has_weather_context or has_food_context or has_emotion_context
        )

        if has_time_keywords or (starts_with_today and not has_other_context):
            try:
                result = await self.execute_tool("time", {})
                if result["success"]:
                    msg = result["result"].get("message") or result["result"]
                    tools_used.append({"tool": "time", "parameters": {}, "result": msg})
            except Exception as e:
                logger.error(f"时间工具执行错误: {e}")

        # 检测天气查询
        if has_weather_context:
            try:
                # 提取城市名（简化版本）
                import re

                city_pattern = r"([北京|上海|广州|深圳|杭州|南京|成都|武汉|西安|重庆|天津|青岛|大连|厦门|苏州|无锡|宁波|长沙|郑州|济南|哈尔滨|沈阳|长春|石家庄|太原|呼和浩特|合肥|福州|南昌|南宁|海口|贵阳|昆明|拉萨|兰州|西宁|银川|乌鲁木齐]+)"
                matches = re.findall(city_pattern, user_message)
                if matches:
                    city = matches[0]
                    result = await self.execute_tool("weather", {"city": city})
                    if result["success"]:
                        tools_used.append(
                            {
                                "tool": "weather",
                                "parameters": {"city": city},
                                "result": result["result"],
                            }
                        )
            except Exception as e:
                logger.error(f"天气工具执行错误: {e}")

        # 检测计算器调用
        if any(
            keyword in user_message.lower()
            for keyword in ["计算", "算", "等于", "+", "-", "*", "/"]
        ):
            try:
                import re

                # 改进的数学表达式匹配模式
                math_pattern = r"(\d+[\+\-\*\/\s\(\)\d\.]+)"
                matches = re.findall(math_pattern, user_message)
                if matches:
                    expression = matches[0].strip()
                    result = await self.execute_tool(
                        "calculator", {"expression": expression}
                    )
                    if result["success"]:
                        tools_used.append(
                            {
                                "tool": "calculator",
                                "parameters": {"expression": expression},
                                "result": result["result"],
                            }
                        )
            except Exception as e:
                logger.error(f"计算器工具执行错误: {e}")

        # 检测翻译需求
        if any(
            keyword in user_message.lower()
            for keyword in [
                "翻译",
                "translate",
                "英文",
                "中文",
                "日文",
                "韩文",
                "法文",
                "德文",
                "西班牙文",
                "俄文",
            ]
        ):
            try:
                import re

                # 检测目标语言
                target_lang = "en"  # 默认翻译为英文
                if any(
                    lang in user_message.lower() for lang in ["中文", "汉语", "chinese"]
                ):
                    target_lang = "zh"
                elif any(
                    lang in user_message.lower()
                    for lang in ["日文", "日语", "japanese"]
                ):
                    target_lang = "ja"
                elif any(
                    lang in user_message.lower() for lang in ["韩文", "韩语", "korean"]
                ):
                    target_lang = "ko"
                elif any(
                    lang in user_message.lower() for lang in ["法文", "法语", "french"]
                ):
                    target_lang = "fr"
                elif any(
                    lang in user_message.lower() for lang in ["德文", "德语", "german"]
                ):
                    target_lang = "de"
                elif any(
                    lang in user_message.lower()
                    for lang in ["西班牙文", "西班牙语", "spanish"]
                ):
                    target_lang = "es"
                elif any(
                    lang in user_message.lower() for lang in ["俄文", "俄语", "russian"]
                ):
                    target_lang = "ru"

                # 提取要翻译的文本（在引号中的内容）
                text_pattern = r'["""]([^"""]+)["""]'
                matches = re.findall(text_pattern, user_message)

                if matches:
                    text_to_translate = matches[0]
                    result = await self.execute_tool(
                        "translate",
                        {"text": text_to_translate, "target_lang": target_lang},
                    )
                    if result["success"]:
                        tools_used.append(
                            {
                                "tool": "translate",
                                "parameters": {
                                    "text": text_to_translate,
                                    "target_lang": target_lang,
                                },
                                "result": result["result"],
                            }
                        )
            except Exception as e:
                logger.error(f"翻译工具执行错误: {e}")

        # 检测网络搜索需求
        if any(
            keyword in user_message.lower()
            for keyword in [
                "搜索",
                "查找",
                "查询",
                "search",
                "查找",
                "了解",
                "联网",
                "上网",
            ]
        ):
            try:
                import re

                # 提取搜索关键词
                # 移除常见的搜索指示词
                search_query = user_message
                search_indicators = [
                    "搜索",
                    "查找",
                    "查询",
                    "search",
                    "查找",
                    "了解",
                    "什么是",
                    "什么是",
                    "如何",
                    "怎么",
                ]

                for indicator in search_indicators:
                    search_query = search_query.replace(indicator, "").strip()

                # 如果搜索查询不为空，执行搜索
                if search_query and len(search_query) > 2:
                    result = await self.execute_tool(
                        "web_search", {"query": search_query}
                    )
                    if result["success"]:
                        tools_used.append(
                            {
                                "tool": "web_search",
                                "parameters": {"query": search_query},
                                "result": result["result"],
                            }
                        )
            except Exception as e:
                logger.error(f"网络搜索工具执行错误: {e}")

        # 检测摘要生成 - 更全面的关键词检测
        summary_keywords = [
            "摘要",
            "总结",
            "概括",
            "summary",
            "生成摘要",
            "生成总结",
            "帮我生成",
            "做一个摘要",
            "做一个总结",
        ]
        if any(keyword in user_message.lower() for keyword in summary_keywords):
            try:
                # 获取会议内容，如果没有内容则使用默认文本
                if self.meeting_content:
                    content = "\n".join(self.meeting_content[-5:])  # 最近5个片段
                else:
                    content = "这是一个测试会议内容，用于演示摘要生成功能。会议讨论了项目进展、技术方案和下一步计划。"

                result = await self.execute_tool("summary", {"text": content})
                if result["success"]:
                    tools_used.append(
                        {
                            "tool": "summary",
                            "parameters": {"text": content},
                            "result": result["result"],
                        }
                    )
            except Exception as e:
                logger.error(f"摘要工具执行错误: {e}")

        # 检测飞书日历同步需求
        calendar_keywords = [
            "日历",
            "日程",
            "飞书",
            "feishu",
            "同步",
            "添加到日历",
            "创建日程",
            "安排时间",
        ]
        # 新增：检测用户输入是否为具体日程内容
        is_concrete_calendar = False
        import re

        # 简单判断：包含"时间"、"标题"或常见日期时间表达
        if re.search(
            r"(标题|时间|提醒|\d{1,2}月\d{1,2}日|\d{4}-\d{1,2}-\d{1,2}|上午|下午|全天|点|:)",
            user_message,
        ):
            is_concrete_calendar = True
        if is_concrete_calendar:
            # 直接解析用户输入并调用feishu_calendar（manual_task参数）
            title = ""
            time_str = ""
            remind = ""
            m_title = re.search(r"标题[:：]?([\S ]+?)(,|，|$)", user_message)
            m_time = re.search(r"时间[:：]?([\S ]+?)(,|，|$)", user_message)
            m_remind = re.search(r"提醒[:：]?([\S ]+?)(,|，|$)", user_message)
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
                    r"要(.+?)(?=\s|$)",  # 要实习
                    r"去(.+?)(?=\s|$)",  # 去开会
                    r"进行(.+?)(?=\s|$)",  # 进行面试
                    r"参加(.+?)(?=\s|$)",  # 参加会议
                ]

                for pattern in action_patterns:
                    match = re.search(pattern, user_message)
                    if match:
                        title = match.group(1).strip()
                        break

                # 方法2：如果方法1没找到，提取句子的最后部分（通常是活动名称）
                if not title:
                    # 移除时间相关词汇
                    time_keywords = [
                        "明天",
                        "后天",
                        "下周一",
                        "下周二",
                        "下周三",
                        "下周四",
                        "下周五",
                        "下周六",
                        "下周日",
                        "上午",
                        "下午",
                        "晚上",
                        "早上",
                        "中午",
                        "全天",
                        "点",
                        ":",
                        "：",
                        "到",
                        "开始",
                        "结束",
                        "八",
                        "九",
                        "十",
                        "十一",
                        "十二",
                        "一",
                        "二",
                        "三",
                        "四",
                        "五",
                        "六",
                        "七",
                    ]

                    potential_title = user_message.strip()
                    for keyword in time_keywords:
                        potential_title = potential_title.replace(keyword, "")

                    # 清理多余的空格和标点
                    potential_title = re.sub(r"\s+", " ", potential_title).strip()
                    potential_title = re.sub(
                        r"^[，,、\s]+|[，,、\s]+$", "", potential_title
                    )

                    # 如果清理后还有内容，使用它作为标题
                    if potential_title and len(potential_title) > 1:
                        title = potential_title
                    else:
                        # 如果清理后没有合适内容，使用原句子的最后部分
                        title = (
                            user_message.strip().split("，")[-1].split(",")[-1].strip()
                        )
            if not time_str:
                # 尝试提取时间表达
                m_time2 = re.search(r"(\d{1,2}月\d{1,2}日.*?)(?:，|,|$)", user_message)
                if m_time2:
                    time_str = m_time2.group(1)
                else:
                    # 尝试提取其他时间表达
                    time_patterns = [
                        r"(明天.*?点.*?到.*?点)",  # 明天早上八点开始到十二点
                        r"(后天.*?点.*?到.*?点)",  # 后天上午10点到12点
                        r"(下.*?.*?点.*?到.*?点)",  # 下周一上午9点面试
                        r"(明天.*?点)",  # 明天下午2点
                        r"(后天.*?点)",  # 后天上午10点
                        r"(下.*?.*?点)",  # 下周一上午9点
                        r"(\d{1,2}点.*?到.*?\d{1,2}点)",  # 八点开始到十二点
                        r"(\d{1,2}:\d{2}.*?到.*?\d{1,2}:\d{2})",  # 8:00到12:00
                    ]
                    for pattern in time_patterns:
                        m_time3 = re.search(pattern, user_message)
                        if m_time3:
                            time_str = m_time3.group(1)
                            break
            manual_task = {"title": title, "deadline": time_str, "remind": remind}
            result = await self.execute_tool(
                "feishu_calendar", {"manual_task": manual_task}
            )
            tools_used.append(
                {
                    "tool": "feishu_calendar",
                    "parameters": {"manual_task": manual_task},
                    "result": getattr(result, "result", result),
                }
            )
            return tools_used
        # 只有明确"发送日程"等指令且没有具体日程输入时才读Result.txt
        if any(keyword in user_message.lower() for keyword in calendar_keywords):
            import os
            import re

            # 优先尝试读取Result.txt中的结构化日程
            result_file_path = os.path.join("backend", "agents", "temp", "Result.txt")
            file_pattern = r"文件[：:]\s*([^\s]+)"
            file_match = re.search(file_pattern, user_message)
            if file_match:
                result_file_path = file_match.group(1)
            # 读取Result.txt内容
            content = ""
            if os.path.exists(result_file_path):
                try:
                    with open(result_file_path, "r", encoding="utf-8") as f:
                        content = f.read()
                except Exception as e:
                    logger.error(f"读取Result.txt文件失败: {e}")
            # 检查是否有结构化待办事项
            tasks = []
            if content:
                # 复用feishu_calendar的提取方法
                try:
                    from tools.feishu_calendar import FeishuCalendarTool

                    tasks = FeishuCalendarTool()._extract_tasks_from_content(content)
                except Exception as e:
                    logger.error(f"结构化日程提取失败: {e}")
            if tasks:
                # 有结构化日程，直接传递给feishu_calendar
                result = await self.execute_tool(
                    "feishu_calendar", {"result_file_path": result_file_path}
                )
            else:
                # 没有结构化日程，走原有逻辑
                result = await self.execute_tool(
                    "feishu_calendar", {"result_file_path": result_file_path}
                )
            if result["success"] and result["result"].get("total_tasks", 0) > 0:
                tools_used.append(
                    {
                        "tool": "feishu_calendar",
                        "parameters": {"result_file_path": result_file_path},
                        "result": f"已自动为你添加日程到飞书日历！详情：{result['result']}",
                    }
                )
                self.waiting_for_calendar_info = False
                self.calendar_info_buffer = {}
            else:
                self.waiting_for_calendar_info = True
                tools_used.append(
                    {
                        "tool": "feishu_calendar",
                        "parameters": {"result_file_path": result_file_path},
                        "result": "未检测到可添加的日程，请补充日程信息：标题、时间、提醒。例如：标题：实习，时间：7月20日10:00-12:00，提醒：是",
                    }
                )

        # 检测邮件发送需求
        email_keywords = [
            "邮件",
            "email",
            "发送邮件",
            "发邮件",
            "邮件发送",
            "寄邮件",
            "写邮件",
        ]

        # 检查是否包含邮件关键词，或者是否在补充邮件信息
        has_email_keywords = any(
            keyword in user_message.lower() for keyword in email_keywords
        )

        # 检查用户消息是否包含邮箱地址
        import re

        email_pattern = r"([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})"
        email_matches = re.findall(email_pattern, user_message)
        has_email_address = len(email_matches) > 0

        # 检查对话历史中是否有邮件相关的对话
        has_email_history = False
        if self.memory.chat_memory.messages:
            recent_messages = self.memory.chat_memory.messages[-5:]  # 检查最近5条消息
            for msg in recent_messages:
                if isinstance(msg, (HumanMessage, AIMessage)):
                    msg_content = msg.content.lower()
                    # 检查是否包含邮件相关关键词或补充提示
                    if any(
                        keyword in msg_content
                        for keyword in email_keywords
                        + ["收件人", "邮箱", "发送", "邮件信息不完整", "缺少", "补充"]
                    ):
                        has_email_history = True
                        break
                    # 检查是否包含邮箱地址模式
                    if re.search(
                        r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}", msg_content
                    ):
                        has_email_history = True
                        break

        # 如果包含邮件关键词，或者包含邮箱地址且有邮件历史，则触发邮件检测
        logger.info(
            f"邮件检测: 关键词={has_email_keywords}, 邮箱地址={has_email_address}, 邮件历史={has_email_history}"
        )

        # 检查对话历史中是否已经有成功的邮件发送记录
        has_successful_email = False
        if self.memory.chat_memory.messages:
            recent_messages = self.memory.chat_memory.messages[-3:]  # 检查最近3条消息
            for msg in recent_messages:
                if isinstance(msg, AIMessage):
                    msg_content = msg.content.lower()
                    if ("邮件发送成功" in msg_content) or (
                        "✅ 邮件发送成功" in msg_content
                    ):
                        has_successful_email = True
                        break

        if has_successful_email:
            tools_used.append(
                {
                    "tool": "email",
                    "parameters": {},
                    "result": {
                        "status": "success",
                        "message": "邮件已成功发送（历史记录检测）",
                    },
                }
            )
            return tools_used

        if has_email_keywords or (has_email_address and has_email_history):
            try:
                # 从.env文件读取邮件配置
                import os
                from dotenv import load_dotenv

                # 加载.env文件
                project_root = os.path.dirname(
                    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
                )
                env_path = os.path.join(project_root, ".env")
                load_dotenv(env_path)

                # 从环境变量读取邮件配置
                sender_email = os.getenv("SENDER_EMAIL")  # 发件人邮箱
                auth_code = os.getenv("EMAIL_AUTH_CODE")  # 邮箱授权码

                # 从用户消息中提取邮件信息
                import re

                # 提取收件人邮箱
                email_pattern = r"([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})"
                email_matches = re.findall(email_pattern, user_message)
                recipient_email = email_matches[0] if email_matches else ""

                # 提取邮件主题（多种格式）
                subject_patterns = [
                    r'主题[：:]\s*["""]([^"""]+)["""]',
                    r"主题[：:]\s*([^\s，。！？]+)",
                    r'标题[：:]\s*["""]([^"""]+)["""]',
                    r"标题[：:]\s*([^\s，。！？]+)",
                ]
                subject = ""
                for pattern in subject_patterns:
                    subject_match = re.search(pattern, user_message)
                    if subject_match:
                        subject = subject_match.group(1)
                        break

                # 提取邮件内容（多种格式）
                content_patterns = [
                    r'内容[：:]\s*["""]([^"""]+)["""]',
                    r"内容[：:]\s*([^，。！？]+)",
                    r'正文[：:]\s*["""]([^"""]+)["""]',
                    r"正文[：:]\s*([^，。！？]+)",
                    r"收件人[：:]\s*[^，。！？]*[，。！？]\s*主题[：:]\s*[^，。！？]*[，。！？]\s*(.+)",  # 提取完整格式中的内容
                ]
                content = ""
                for pattern in content_patterns:
                    content_match = re.search(pattern, user_message)
                    if content_match:
                        content = content_match.group(1)
                        break

                # 如果没有明确指定，尝试从Result.txt文件中读取邮件信息
                if not recipient_email or not subject or not content:
                    logger.info("尝试从Result.txt文件读取邮件信息...")
                    email_info = self._read_result_file()
                    logger.info(f"读取到的邮件信息: {email_info}")

                    if email_info.get("need_email", False):
                        logger.info("检测到需要发送邮件，开始填充信息...")
                        if not recipient_email:
                            recipient_email = email_info.get("recipient_email", "")
                            logger.info(f"设置收件人邮箱: {recipient_email}")
                        if not subject:
                            subject = email_info.get("subject", "会议纪要")
                            logger.info(f"设置邮件主题: {subject}")
                        if not content:
                            content = email_info.get(
                                "content", "会议纪要已生成，请查看附件。"
                            )
                            logger.info(f"设置邮件内容: {content}")

                        # 如果从Result.txt成功获取了所有必要信息，直接发送邮件
                        if recipient_email and subject and content:
                            logger.info(
                                "从Result.txt获取到完整的邮件信息，准备发送邮件..."
                            )
                            result = await self.execute_tool(
                                "email",
                                {
                                    "sender": sender_email,
                                    "auth_code": auth_code,
                                    "recipient": recipient_email,
                                    "subject": subject,
                                    "content": content,
                                },
                            )
                            if result["success"]:
                                tools_used.append(
                                    {
                                        "tool": "email",
                                        "parameters": {
                                            "sender": sender_email,
                                            "recipient": recipient_email,
                                            "subject": subject,
                                            "content": content,
                                        },
                                        "result": {
                                            "status": "success",
                                            "message": f"邮件已成功发送至 {recipient_email}",
                                            "details": {
                                                "sender": sender_email,
                                                "recipient": recipient_email,
                                                "subject": subject,
                                                "send_time": result["result"].get(
                                                    "send_time", ""
                                                ),
                                                "content_length": len(content),
                                            },
                                        },
                                    }
                                )
                                return tools_used  # 直接返回，不再检查缺失信息
                    else:
                        logger.info("Result.txt中未检测到邮件需求")

                # 智能检查缺失信息并提供友好提示
                missing_info = []
                current_info = {}

                if not recipient_email:
                    missing_info.append("收件人邮箱地址")
                else:
                    current_info["收件人邮箱"] = recipient_email

                if not subject:
                    missing_info.append("邮件主题")
                else:
                    current_info["邮件主题"] = subject

                if not content:
                    missing_info.append("邮件正文内容")
                else:
                    current_info["邮件内容"] = (
                        content[:50] + "..." if len(content) > 50 else content
                    )

                if missing_info:
                    # 构建智能提示信息
                    current_info_text = ""
                    if current_info:
                        current_info_text = f"\n\n📋 当前已有信息：\n"
                        for key, value in current_info.items():
                            current_info_text += f"• {key}: {value}\n"

                    # 根据缺失信息数量提供不同的提示
                    if len(missing_info) == 1:
                        message = f"检测到您需要发送邮件，还缺少：{missing_info[0]}。{current_info_text}\n\n请提供{missing_info[0]}，我会立即为您发送邮件。"
                    else:
                        message = f"检测到您需要发送邮件，还缺少以下信息：\n• {chr(10).join('• ' + item for item in missing_info)}{current_info_text}\n\n请提供这些信息，我会立即为您发送邮件。"

                    tools_used.append(
                        {
                            "tool": "email",
                            "parameters": {},
                            "result": {
                                "status": "missing_info",
                                "missing_fields": missing_info,
                                "current_info": current_info,
                                "message": message,
                            },
                        }
                    )
                elif recipient_email:
                    # 发送邮件
                    logger.info(
                        f"准备发送邮件: 收件人={recipient_email}, 主题={subject}"
                    )
                    result = await self.execute_tool(
                        "email",
                        {
                            "sender": sender_email,
                            "auth_code": auth_code,
                            "recipient": recipient_email,
                            "subject": subject,
                            "content": content,
                        },
                    )
                    logger.info(f"邮件发送结果: {result}")

                    if result["success"]:
                        logger.info("邮件发送成功，添加到工具结果")
                        tools_used.append(
                            {
                                "tool": "email",
                                "parameters": {
                                    "sender": sender_email,
                                    "recipient": recipient_email,
                                    "subject": subject,
                                    "content": content,
                                },
                                "result": {
                                    "status": "success",
                                    "message": f"邮件已成功发送至 {recipient_email}",
                                    "details": {
                                        "sender": sender_email,
                                        "recipient": recipient_email,
                                        "subject": subject,
                                        "send_time": result["result"].get(
                                            "send_time", ""
                                        ),
                                        "content_length": len(content),
                                    },
                                },
                            }
                        )
                    else:
                        logger.error(f"邮件发送失败: {result.get('error')}")
                        tools_used.append(
                            {
                                "tool": "email",
                                "parameters": {},
                                "result": {
                                    "status": "error",
                                    "message": f"邮件发送失败: {result.get('error', '未知错误')}",
                                    "error": result.get("error", "邮件发送失败"),
                                },
                            }
                        )
                else:
                    tools_used.append(
                        {
                            "tool": "email",
                            "parameters": {},
                            "result": {
                                "status": "error",
                                "error": "未找到有效的收件人邮箱地址",
                            },
                        }
                    )

            except Exception as e:
                logger.error(f"邮件工具执行错误: {e}")
                tools_used.append(
                    {
                        "tool": "email",
                        "parameters": {},
                        "result": {
                            "status": "error",
                            "error": f"邮件处理异常: {str(e)}",
                        },
                    }
                )

        # 检测Notion写入需求
        notion_keywords = [
            "notion",
            "写入notion",
            "保存到notion",
            "创建notion页面",
            "记录到notion",
            "添加到notion",
            "notion文档",
            "写入文档",
            "保存文档",
            "创建文档页面",
        ]

        # 检查是否包含Notion关键词
        has_notion_keywords = any(
            keyword in user_message.lower() for keyword in notion_keywords
        )

        # 检查是否有"写入"、"保存"、"记录"等动作词汇 + 内容指示
        import re

        action_patterns = [
            r"(写入|保存|记录|添加|创建).*?(notion|文档)",
            r"把.*?(写入|保存到|记录到|添加到).*?(notion|文档)",
            r"将.*?(内容|信息|纪要|摘要).*?(写入|保存|记录|添加).*?(notion|文档)",
            r"(notion|文档).*?(写入|保存|记录|添加)",
        ]
        has_action_pattern = any(
            re.search(pattern, user_message.lower()) for pattern in action_patterns
        )

        logger.info(
            f"Notion检测: 关键词={has_notion_keywords}, 动作模式={has_action_pattern}"
        )

        if has_notion_keywords or has_action_pattern:
            try:
                # 提取页面标题
                title_patterns = [
                    r'标题[：:]\s*["""]([^"""]+)["""]',
                    r"标题[：:]\s*([^\s，。！？\n]+)",
                    r"标题是\s*([^\s，。！？\n]+)",  # 新增：匹配"标题是"
                    r'页面标题[：:]\s*["""]([^"""]+)["""]',
                    r"页面标题[：:]\s*([^\s，。！？\n]+)",
                    r"页面标题是\s*([^\s，。！？\n]+)",  # 新增：匹配"页面标题是"
                    r'名称[：:]\s*["""]([^"""]+)["""]',
                    r"名称[：:]\s*([^\s，。！？\n]+)",
                    r"名称是\s*([^\s，。！？\n]+)",  # 新增：匹配"名称是"
                ]
                title = ""
                for pattern in title_patterns:
                    title_match = re.search(pattern, user_message)
                    if title_match:
                        title = title_match.group(1).strip()
                        break

                # 如果没有明确标题，尝试从会议内容或用户消息中智能提取
                if not title:
                    # 尝试提取时间作为标题
                    import datetime

                    now = datetime.datetime.now()

                    # 检查是否有会议相关内容
                    if self.meeting_content:
                        title = f"会议纪要 - {now.strftime('%Y年%m月%d日')}"
                    else:
                        # 尝试从用户消息中提取主要内容作为标题
                        content_keywords = [
                            "内容",
                            "信息",
                            "纪要",
                            "摘要",
                            "讨论",
                            "总结",
                        ]
                        for keyword in content_keywords:
                            if keyword in user_message:
                                title = f"{keyword} - {now.strftime('%Y年%m月%d日')}"
                                break

                        if not title:
                            title = f"文档 - {now.strftime('%Y年%m月%d日')}"

                # 提取要写入的内容
                content_patterns = [
                    r'内容[：:]\s*["""]([^"""]+)["""]',
                    r"内容[：:]\s*(.+?)(?=\s*$)",
                    r'正文[：:]\s*["""]([^"""]+)["""]',
                    r"正文[：:]\s*(.+?)(?=\s*$)",
                    r'写入[：:]?\s*["""]([^"""]+)["""]',
                    r'保存[：:]?\s*["""]([^"""]+)["""]',
                ]
                content = ""
                for pattern in content_patterns:
                    content_match = re.search(pattern, user_message, re.DOTALL)
                    if content_match:
                        content = content_match.group(1).strip()
                        break

                # 如果没有明确指定内容，尝试使用不同来源
                if not content:
                    # 检查是否要求写入当前对话
                    conversation_keywords = [
                        "对话",
                        "聊天记录",
                        "当前对话",
                        "这次对话",
                        "聊天的内容",
                        "聊天内容",
                        "我们的对话",
                    ]
                    is_conversation_request = any(
                        keyword in user_message for keyword in conversation_keywords
                    )

                    if is_conversation_request:
                        # 获取最近的对话记录
                        recent_messages = []
                        if (
                            hasattr(self.memory, "chat_memory")
                            and self.memory.chat_memory.messages
                        ):
                            for msg in self.memory.chat_memory.messages[
                                -10:
                            ]:  # 最近10条消息
                                if hasattr(msg, "content"):
                                    msg_type = (
                                        "用户"
                                        if msg.__class__.__name__ == "HumanMessage"
                                        else "AI助手"
                                    )
                                    recent_messages.append(
                                        f"**{msg_type}**: {msg.content}"
                                    )

                        # 确保对话请求有内容，即使没有历史记录
                        if recent_messages:
                            content = "\n\n".join(recent_messages)
                            logger.info(
                                f"使用对话记录作为Notion页面内容，共{len(recent_messages)}条消息"
                            )
                        else:
                            import datetime

                            content = f"# 对话记录\n\n暂无对话历史记录。\n\n*记录时间: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}*"
                            logger.info("没有对话历史，使用默认对话内容")

                    # 如果不是对话内容需求，优先使用会议内容
                    elif self.meeting_content:
                        content = "\n".join(self.meeting_content[-10:])  # 最近10个片段
                        logger.info("使用会议内容作为Notion页面内容")

                    # 如果还是没有内容，使用用户消息本身
                    if not content:
                        # 移除Notion相关的指令词汇，保留实际内容
                        clean_content = user_message
                        for keyword in notion_keywords:
                            clean_content = re.sub(
                                rf"\b{re.escape(keyword)}\b",
                                "",
                                clean_content,
                                flags=re.IGNORECASE,
                            )

                        # 移除常见的指令词汇
                        instruction_words = [
                            "请",
                            "帮我",
                            "帮忙",
                            "麻烦",
                            "标题:",
                            "内容:",
                            "写入:",
                            "保存:",
                            "记录:",
                        ]
                        for word in instruction_words:
                            clean_content = clean_content.replace(word, "")

                        content = clean_content.strip()
                        if len(content) < 10:  # 内容太短，使用默认内容
                            content = f"用户请求: {user_message}\n\n创建时间: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"

                # 将内容转换为Markdown格式
                markdown_content = self._format_content_as_markdown(content, title)

                # 硬编码父页面ID - 答辩成果展示页面 (从URL提取的原始格式)
                parent_id = "23346aa64eeb8077b1fdfa557c8a09ef"
                specified_parent_name = None
                logger.info(f"🎯 使用硬编码的父页面ID: {parent_id}")

                # 检查是否有用户自定义的父页面ID覆盖硬编码值
                parent_id_patterns = [
                    r"父页面[：:]\s*([a-f0-9\-]{32,})",
                    r"parent[：:]\s*([a-f0-9\-]{32,})",
                    r"页面ID[：:]\s*([a-f0-9\-]{32,})",
                ]
                for pattern in parent_id_patterns:
                    parent_match = re.search(pattern, user_message)
                    if parent_match:
                        parent_id = parent_match.group(1)
                        logger.info(
                            f"🔄 用户指定了新的父页面ID，覆盖硬编码值: {parent_id}"
                        )
                        break

                # 由于已经有硬编码的父页面ID，以下逻辑仅作为备用（通常不会执行）
                if not parent_id:
                    parent_name_patterns = [
                        r"页面是\s*([^\s，。！？\n]+)",
                        r"页面[：:]\s*([^\s，。！？\n]+)",
                        r"父页面是\s*([^\s，。！？\n]+)",
                        r"父页面[：:]\s*([^\s，。！？\n]+)",
                        r"保存到\s*([^\s，。！？\n]+)\s*页面",
                        r"写入\s*([^\s，。！？\n]+)\s*页面",
                    ]
                    for pattern in parent_name_patterns:
                        parent_name_match = re.search(pattern, user_message)
                        if parent_name_match:
                            specified_parent_name = parent_name_match.group(1).strip()
                            logger.info(
                                f"🎯 检测到明确指定的父页面名称: '{specified_parent_name}'"
                            )
                            break

                # 如果有明确指定的父页面名称，直接搜索该页面
                if specified_parent_name:
                    logger.info(f"🔍 搜索指定的父页面: '{specified_parent_name}'")

                    search_result = await self.execute_tool(
                        "notion",
                        {
                            "action": "search",
                            "query": specified_parent_name,
                            "filter_type": "page",
                        },
                    )

                    if search_result.get("success") and search_result.get(
                        "result", {}
                    ).get("results"):
                        results = search_result["result"]["results"]
                        # 寻找最佳匹配的页面（标题完全匹配或包含指定名称）
                        best_match = None
                        for result in results:
                            result_title = result.get("title", "").strip()
                            if result_title.lower() == specified_parent_name.lower():
                                # 完全匹配，优先选择
                                best_match = result
                                break
                            elif specified_parent_name.lower() in result_title.lower():
                                # 部分匹配，作为备选
                                if not best_match:
                                    best_match = result

                        if best_match:
                            parent_id = best_match["id"]
                            parent_title = best_match.get("title", "无标题")
                            logger.info(
                                f"✅ 找到指定的父页面: {parent_title} (ID: {parent_id[:8]}...)"
                            )
                        else:
                            logger.warning(
                                f"❌ 找到了页面但无法匹配指定名称: '{specified_parent_name}'"
                            )
                    else:
                        logger.warning(
                            f"❌ 未找到指定的父页面: '{specified_parent_name}'"
                        )

                # 如果没有指定父页面或未找到指定页面，尝试智能搜索合适的页面作为父页面
                if not parent_id:
                    # 获取智能推断的搜索查询
                    search_queries = await self._infer_parent_page_queries(user_message)

                    parent_page_found = False
                    selected_parent = None

                    # 按优先级尝试不同的搜索查询
                    for query in search_queries:
                        logger.info(f"🔍 搜索父页面: '{query}'")

                        search_result = await self.execute_tool(
                            "notion",
                            {"action": "search", "query": query, "filter_type": "page"},
                        )

                        if search_result.get("success") and search_result.get(
                            "result", {}
                        ).get("results"):
                            results = search_result["result"]["results"]
                            logger.info(
                                f"✅ 找到 {len(results)} 个匹配页面，使用查询: '{query}'"
                            )

                            # 选择第一个匹配的页面
                            selected_parent = results[0]
                            parent_id = selected_parent["id"]
                            parent_page_found = True
                            break
                        else:
                            logger.info(f"❌ 未找到匹配页面，查询: '{query}'")

                    # 如果智能搜索都没找到，尝试获取任意可用页面
                    if not parent_page_found:
                        logger.info("🔍 尝试获取任意可用页面作为父页面...")
                        fallback_result = await self.execute_tool(
                            "notion",
                            {"action": "search", "query": "", "filter_type": "page"},
                        )

                        if fallback_result.get("success") and fallback_result.get(
                            "result", {}
                        ).get("results"):
                            selected_parent = fallback_result["result"]["results"][0]
                            parent_id = selected_parent["id"]
                            parent_page_found = True
                            logger.info(f"✅ 使用默认页面作为父页面")

                    if parent_page_found and selected_parent:
                        parent_title = selected_parent.get("title", "无标题")
                        logger.info(
                            f"📄 选择的父页面: {parent_title} (ID: {parent_id[:8]}...)"
                        )

                if parent_id:
                    # 创建Notion页面
                    result = await self.execute_tool(
                        "notion",
                        {
                            "action": "create_page",
                            "parent_id": parent_id,
                            "title": title,
                            "content": markdown_content,
                        },
                    )

                    if result.get("success"):
                        page_info = result.get("result", {})
                        tools_used.append(
                            {
                                "tool": "notion",
                                "parameters": {
                                    "action": "create_page",
                                    "parent_id": parent_id,
                                    "title": title,
                                    "content": markdown_content,
                                },
                                "result": {
                                    "status": "success",
                                    "message": f"✅ 已成功创建Notion页面: {title}",
                                    "details": {
                                        "page_id": page_info.get("page_id"),
                                        "title": title,
                                        "url": page_info.get("url"),
                                        "created_time": page_info.get("created_time"),
                                        "content_length": len(markdown_content),
                                    },
                                },
                            }
                        )
                        logger.info(f"Notion页面创建成功: {page_info}")
                    else:
                        error_msg = result.get("error", "未知错误")
                        tools_used.append(
                            {
                                "tool": "notion",
                                "parameters": {},
                                "result": {
                                    "status": "error",
                                    "message": f"❌ Notion页面创建失败: {error_msg}",
                                    "error": error_msg,
                                },
                            }
                        )
                        logger.error(f"Notion页面创建失败: {error_msg}")
                else:
                    # 没有找到合适的父页面
                    tools_used.append(
                        {
                            "tool": "notion",
                            "parameters": {},
                            "result": {
                                "status": "missing_parent",
                                "message": "❌ 无法创建Notion页面: 未找到合适的父页面。请确保您的Notion集成已被邀请到至少一个页面，或者在消息中指定父页面ID。",
                                "suggestion": "请先在Notion中邀请您的集成到一个页面，或者提供父页面ID，格式如: 父页面: your-page-id",
                            },
                        }
                    )
                    logger.warning("Notion页面创建失败: 未找到父页面")

            except Exception as e:
                logger.error(f"Notion工具执行错误: {e}")
                tools_used.append(
                    {
                        "tool": "notion",
                        "parameters": {},
                        "result": {
                            "status": "error",
                            "error": f"Notion处理异常: {str(e)}",
                        },
                    }
                )

        return tools_used

    async def _infer_parent_page_queries(self, user_message: str) -> list:
        """智能推断父页面搜索查询列表，按优先级排序"""
        queries = []

        try:
            import datetime
            import re

            now = datetime.datetime.now()

            # 1. 从用户消息中提取时间相关信息
            time_patterns = [
                r"(\d+)/(\d+)",  # 如 "7/13"
                r"(\d+)月(\d+)日",  # 如 "7月13日"
                r"今天",
                r"昨天",
                r"本周",
                r"这周",
            ]

            for pattern in time_patterns:
                matches = re.findall(pattern, user_message)
                if matches:
                    if pattern == r"(\d+)/(\d+)":
                        for month, day in matches:
                            queries.append(f"{month}/{day}")
                            queries.append(f"{int(month)}/{int(day)}")
                    elif pattern == r"(\d+)月(\d+)日":
                        for month, day in matches:
                            queries.append(f"{month}/{day}")
                            queries.append(f"{month}月{day}日")

            # 2. 基于当前时间推断
            queries.extend(
                [
                    f"{now.month}/{now.day}",  # 今天，如 "1/13"
                    f"{now.strftime('%m/%d')}",  # 带前导零，如 "01/13"
                    f"{now.month}月{now.day}日",  # 中文格式
                    f"{now.strftime('%Y-%m-%d')}",  # 标准日期格式
                    f"{now.strftime('%Y年%m月%d日')}",  # 中文日期格式
                ]
            )

            # 3. 基于会议内容推断相关主题
            if self.meeting_content:
                # 分析会议内容中的关键词
                content_text = " ".join(self.meeting_content[-5:])  # 最近5个片段

                # 提取可能的项目名称、会议主题等
                topic_patterns = [
                    r"项目[：:]?\s*([^\s，。！？\n]{2,10})",
                    r"关于\s*([^\s，。！？\n]{2,10})",
                    r"讨论\s*([^\s，。！？\n]{2,10})",
                    r"会议主题[：:]?\s*([^\s，。！？\n]{2,10})",
                ]

                for pattern in topic_patterns:
                    matches = re.findall(pattern, content_text)
                    for match in matches:
                        if len(match.strip()) >= 2:
                            queries.append(match.strip())

            # 4. 从用户消息中提取可能的页面名称
            page_indicators = [
                r"页面[：:]?\s*([^\s，。！？\n]{2,15})",
                r"文档[：:]?\s*([^\s，。！？\n]{2,15})",
                r"记录到\s*([^\s，。！？\n]{2,15})",
                r"保存到\s*([^\s，。！？\n]{2,15})",
            ]

            for pattern in page_indicators:
                matches = re.findall(pattern, user_message)
                for match in matches:
                    clean_match = match.strip()
                    if len(clean_match) >= 2 and not any(
                        keyword in clean_match.lower() for keyword in ["notion", "文档"]
                    ):
                        queries.append(clean_match)

            # 5. 基于星期推断
            weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
            today_weekday = weekdays[now.weekday()]
            queries.extend(
                [today_weekday, f"本{today_weekday}", f"这个{today_weekday}"]
            )

            # 6. 通用的会议相关搜索词
            general_queries = [
                "会议",
                "今日会议",
                "会议纪要",
                "工作日志",
                "日报",
                "周报",
            ]
            queries.extend(general_queries)

            # 去重并保持顺序
            unique_queries = []
            seen = set()
            for query in queries:
                if query and query not in seen:
                    unique_queries.append(query)
                    seen.add(query)

            logger.info(
                f"智能推断的父页面搜索查询: {unique_queries[:5]}..."
            )  # 只显示前5个
            return unique_queries[:10]  # 限制最多10个查询，避免过多API调用

        except Exception as e:
            logger.error(f"推断父页面查询失败: {e}")
            return ["会议", "文档"]  # 返回默认查询

    @retry(
        stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=4, max=10)
    )
    async def _handle_chat_message(self, content: str) -> str:
        """处理聊天消息（带重试机制）"""
        try:
            logger.info(f"开始处理用户消息: {content[:50]}...")

            # 先刷新会议内容，确保有最新的转录数据
            await self._refresh_session_content()

            # 获取对话历史
            history = self.memory.chat_memory.messages

            # 检测并执行工具调用
            tools_used = await self._detect_and_execute_tools(content, "")

            # 构建完整的对话上下文
            context = ""

            # 添加会议内容作为背景知识
            logger.info(f"当前会议内容片段数: {len(self.meeting_content)}")
            if self.meeting_content:
                context += "=== 会议内容背景 ===\n"

                # 使用向量数据库检索最相关的会议内容
                if self.vector_db is not None:
                    try:
                        # 检索与当前问题最相关的会议内容
                        relevant_docs = self.vector_db.similarity_search(content, k=2)
                        if relevant_docs:
                            context += "相关会议内容:\n"
                            for i, doc in enumerate(relevant_docs, 1):
                                context += f"相关内容{i}: {doc.page_content}\n"
                        else:
                            # 如果没有找到相关内容，使用最近的会议片段
                            for i, content in enumerate(self.meeting_content[-2:], 1):
                                context += f"会议片段{i}: {content}\n"
                    except Exception as e:
                        logger.warning(f"向量检索失败，使用最近会议片段: {e}")
                        # 回退到使用最近的会议片段
                        for i, content in enumerate(self.meeting_content[-2:], 1):
                            context += f"会议片段{i}: {content}\n"
                else:
                    # 向量数据库不可用时，使用最近的会议片段
                    for i, content in enumerate(self.meeting_content[-2:], 1):
                        context += f"会议片段{i}: {content}\n"

                context += "=== 会议内容背景结束 ===\n\n"

            # 添加对话历史
            for msg in history:
                if isinstance(msg, HumanMessage):
                    context += f"用户: {msg.content}\n"
                elif isinstance(msg, AIMessage):
                    context += f"助手: {msg.content}\n"

            # 如果有工具结果，添加到上下文中
            if tools_used:
                logger.info(f"工具执行结果: {tools_used}")
                context += "\n=== 工具执行结果 ===\n"
                for tool in tools_used:
                    if tool["tool"] == "email":
                        result = tool["result"]
                        if isinstance(result, dict):
                            if result.get("status") == "success":
                                context += f"✅ 邮件发送成功！\n"
                                context += f"📧 收件人: {result.get('details', {}).get('recipient', '')}\n"
                                context += f"📌 主题: {result.get('details', {}).get('subject', '')}\n"
                                context += f"⏰ 发送时间: {result.get('details', {}).get('send_time', '')}\n"
                                context += f"📝 内容长度: {result.get('details', {}).get('content_length', 0)} 字符\n"
                            elif result.get("status") == "missing_info":
                                context += (
                                    f"❌ 邮件信息不完整: {result.get('message', '')}\n"
                                )
                            elif result.get("status") == "error":
                                context += (
                                    f"❌ 邮件发送失败: {result.get('error', '')}\n"
                                )
                        else:
                            context += f"邮件工具结果: {result}\n"
                    else:
                        context += f"- {tool['tool']}: {tool['result']}\n"
                context += "=== 工具执行结果结束 ===\n\n"

            # 添加当前用户消息
            context += f"用户: {content}\n助手:"

            # 记录完整上下文用于调试
            logger.info(f"传递给AI模型的上下文长度: {len(context)}")
            # logger.info(f"上下文最后200字符: {context[-200:]}")

            # 构建包含工具结果的提示词
            system_prompt = """你是一个智能会议助手，可以帮助用户回答关于会议内容的问题，也可以使用各种工具来帮助用户。

重要说明：
1. 会议内容背景：在"=== 会议内容背景 ==="部分包含了相关的会议内容，请基于这些内容回答用户的问题
2. 如果用户询问会议相关的问题，请优先参考会议内容背景中的信息
3. 如果会议内容背景中没有相关信息，可以根据自己的知识和理解自由生成答案，不必只说"没有相关信息"

工具使用规则：
- 当用户询问需要工具支持的问题时，请基于工具执行结果来回答
- 请仔细查看工具执行结果部分，并根据结果提供准确的回答

邮件处理规则：
1. 如果看到"✅ 邮件发送成功！"，请告知用户邮件已成功发送，并重复发送详情
2. 如果看到"❌ 邮件信息不完整"，请告知用户缺少哪些信息，并请求补充
3. 如果看到"❌ 邮件发送失败"，请告知用户发送失败的原因
4. 不要在没有工具执行结果的情况下假设邮件发送状态

请用友好、自然的语气回答，确保回答准确且有用。"""
            # 调用聊天模型
            messages = [("system", system_prompt), ("human", context)]
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

    def _format_content_as_markdown(self, content: str, title: str) -> str:
        """将内容格式化为Markdown格式"""
        try:
            import datetime

            now = datetime.datetime.now()

            # 检查内容是否已经是Markdown格式
            if any(
                marker in content for marker in ["#", "**", "*", "`", "---", "[]", "##"]
            ):
                # 已经是Markdown格式，只需要添加元数据
                markdown_content = f"""# {title}

> 创建时间: {now.strftime('%Y-%m-%d %H:%M:%S')}
> 来源: PromptMeet 会议助手

---

{content}

---

*自动生成于 PromptMeet*"""
            else:
                # 纯文本内容，需要格式化
                lines = content.split("\n")
                formatted_lines = []

                for line in lines:
                    line = line.strip()
                    if not line:
                        formatted_lines.append("")
                        continue

                    # 检测是否是对话格式
                    if line.startswith("**用户**:") or line.startswith("**AI助手**:"):
                        formatted_lines.append(line)
                    elif line.startswith("用户:") or line.startswith("AI助手:"):
                        # 转换为Markdown格式
                        if line.startswith("用户:"):
                            formatted_lines.append(f"**用户**: {line[3:].strip()}")
                        else:
                            formatted_lines.append(f"**AI助手**: {line[6:].strip()}")
                    elif ":" in line and not line.startswith("http"):
                        # 可能是标题或时间戳
                        parts = line.split(":", 1)
                        if len(parts) == 2:
                            formatted_lines.append(
                                f"**{parts[0].strip()}**: {parts[1].strip()}"
                            )
                        else:
                            formatted_lines.append(line)
                    else:
                        # 普通文本行
                        formatted_lines.append(line)

                formatted_content = "\n".join(formatted_lines)

                markdown_content = f"""# {title}

> 创建时间: {now.strftime('%Y-%m-%d %H:%M:%S')}
> 来源: PromptMeet 会议助手

---

{formatted_content}

---

*自动生成于 PromptMeet*"""

            return markdown_content

        except Exception as e:
            logger.error(f"格式化Markdown内容失败: {e}")
            # 返回简单格式
            return f"""# {title}

{content}

*创建时间: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}*"""

    def get_conversation_history(self) -> List[Dict[str, str]]:
        """获取对话历史"""
        return self._convert_memory_to_history()

    async def handle_command(self, command: IPCCommand) -> IPCResponse:
        """处理IPC命令"""
        try:
            if command.command == "message":
                # 先刷新会话内容
                await self._refresh_session_content()
                content = command.params.get("content", "")
                try:
                    # ====== 流式AI回复实现 ======
                    # 获取对话历史
                    history = self.memory.chat_memory.messages

                    # 构建完整的对话上下文
                    context = ""

                    # 添加会议内容作为背景知识
                    logger.info(f"当前会议内容片段数: {len(self.meeting_content)}")
                    if self.meeting_content:
                        context += "=== 会议内容背景 ===\n"
                        if self.vector_db is not None:
                            try:
                                relevant_docs = self.vector_db.similarity_search(
                                    content, k=2
                                )
                                if relevant_docs:
                                    context += "相关会议内容:\n"
                                    for i, doc in enumerate(relevant_docs, 1):
                                        context += f"相关内容{i}: {doc.page_content}\n"
                                else:
                                    for i, c in enumerate(self.meeting_content[-2:], 1):
                                        context += f"会议片段{i}: {c}\n"
                            except Exception as e:
                                logger.warning(f"向量检索失败，使用最近会议片段: {e}")
                                for i, c in enumerate(self.meeting_content[-2:], 1):
                                    context += f"会议片段{i}: {c}\n"
                        else:
                            for i, c in enumerate(self.meeting_content[-2:], 1):
                                context += f"会议片段{i}: {c}\n"
                        context += "=== 会议内容背景结束 ===\n\n"
                    # 添加对话历史
                    for msg in history:
                        if isinstance(msg, HumanMessage):
                            context += f"用户: {msg.content}\n"
                        elif isinstance(msg, AIMessage):
                            context += f"助手: {msg.content}\n"
                    # 检测并执行工具调用
                    tools_used = await self._detect_and_execute_tools(content, context)
                    # 如果有工具执行结果，添加到上下文
                    if tools_used:
                        context += "\n=== 工具执行结果 ===\n"
                        for tool in tools_used:
                            if tool["tool"] == "email":
                                result = tool["result"]
                                if isinstance(result, dict):
                                    if result.get("status") == "success":
                                        context += f"✅ 邮件发送成功！\n"
                                        context += f"📧 收件人: {result.get('details', {}).get('recipient', '')}\n"
                                        context += f"📌 主题: {result.get('details', {}).get('subject', '')}\n"
                                        context += f"⏰ 发送时间: {result.get('details', {}).get('send_time', '')}\n"
                                    elif result.get("status") == "missing_info":
                                        context += f"❌ 邮件信息不完整: {result.get('message', '')}\n"
                                    elif result.get("status") == "error":
                                        context += f"❌ 邮件发送失败: {result.get('error', '')}\n"
                                else:
                                    context += f"邮件工具结果: {result}\n"
                            else:
                                context += f"- {tool['tool']}: {tool['result']}\n"
                        context += "=== 工具执行结果结束 ===\n\n"
                    # 添加当前用户消息
                    context += f"用户: {content}\n助手:"
                    # 构建系统提示词
                    system_prompt = '你是一个智能会议助手，可以帮助用户回答关于会议内容的问题，也可以使用各种工具来帮助用户。\n\n重要说明：\n1. 会议内容背景：在"=== 会议内容背景 ==="部分包含了相关的会议内容，请基于这些内容回答用户的问题\n2. 如果用户询问会议相关的问题，请优先参考会议内容背景中的信息\n3. 如果会议内容背景中没有相关信息，可以根据自己的知识和理解自由生成答案，不必只说"没有相关信息"\n4. 请记住对话历史，理解用户的上下文和意图\n\n工具使用规则：\n- 当用户询问需要工具支持的问题时，请基于工具执行结果来回答\n- 请仔细查看工具执行结果部分，并根据结果提供准确的回答\n\n邮件处理规则：\n1. 如果看到"✅ 邮件发送成功！"，请告知用户邮件已成功发送，并重复发送详情\n2. 如果看到"❌ 邮件信息不完整"，请告知用户缺少哪些信息，并请求补充\n3. 如果看到"❌ 邮件发送失败"，请告知用户发送失败的原因\n4. 不要在没有工具执行结果的情况下假设邮件发送状态\n\n请用友好、自然的语气回答，确保回答准确且有用。'
                    messages = [("system", system_prompt), ("human", context)]
                    full_response = ""
                    async for chunk in self.chat_model.astream(messages):
                        text = getattr(chunk, "content", str(chunk))  # 取出内容
                        response_message = {
                            "type": "response",
                            "data": {"delta": text},
                            "timestamp": datetime.now().isoformat(),
                        }
                        if self.ipc_output_file:
                            with open(
                                self.ipc_output_file, "a", encoding="utf-8"
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
                        full_response += text
                    # 写入最终完整内容
                    final_message = {
                        "type": "response",
                        "data": {"content": full_response},
                        "timestamp": datetime.now().isoformat(),
                    }
                    if self.ipc_output_file:
                        with open(self.ipc_output_file, "a", encoding="utf-8") as out_f:
                            out_f.write(
                                json.dumps(
                                    final_message, ensure_ascii=False, default=str
                                )
                                + "\n"
                            )
                            out_f.flush()
                    # 保存到记忆
                    self.memory.chat_memory.add_user_message(content)
                    self.memory.chat_memory.add_ai_message(full_response)
                    logger.info(f"Agent响应成功: {full_response[:50]}...")
                    return IPCResponse(
                        success=True,
                        data={"response": full_response},
                        error=None,
                        timestamp=datetime.now(),
                    )
                except Exception as e:
                    logger.error(f"Agent处理消息失败: {e}")
                    return IPCResponse(
                        success=False,
                        data=None,
                        error=f"Agent处理失败: {str(e)}",
                        timestamp=datetime.now(),
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
                success=False, data=None, error=str(e), timestamp=datetime.now()
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
                    with open(processor.ipc_input_file, "r", encoding="utf-8") as f:
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
                                    "timestamp": datetime.now().isoformat(),
                                }

                                if processor.ipc_output_file:
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
        logger.info("Agent处理器进程结束")


if __name__ == "__main__":
    asyncio.run(main())
