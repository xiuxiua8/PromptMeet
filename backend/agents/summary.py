import asyncio
from datetime import datetime
import json
import re
from typing import Iterator, Dict, List, Literal, Union
from langchain.text_splitter import RecursiveCharacterTextSplitter
from langchain.prompts import ChatPromptTemplate
from langchain_openai import ChatOpenAI
from langchain_core.output_parsers import StrOutputParser
import os

class StreamingMeetingSummarizer:
    def __init__(self, streaming: bool = True):
        """初始化摘要生成器（纯文本输出版）"""
        self.llm = ChatOpenAI(
            openai_api_key=os.getenv("DEEPSEEK_API_KEY"),
            base_url=os.getenv("DEEPSEEK_API_URL"),
            model="deepseek-chat",
            temperature=0.2,
            streaming=streaming
        )
        self.text_splitter = RecursiveCharacterTextSplitter(
            chunk_size=1200,
            chunk_overlap=200,
            separators=["\n\n", "\n", "。", "；", "! ", "? ", "…"]
        )
        self.meeting_types = {
            "course": "学术课程",
            "research": "学术研讨",
            "progress": "进度汇报",
            "task": "任务部署", 
            "decision": "决策会议",
            "default": "常规会议"
        }
        
        self.type_keywords = {
            "course": ["课程", "教学", "学习", "讲座", "知识", "概念", "理论", "讲解", "章节", "教材"],
            "research": ["研究", "论文", "实验", "数据", "方法论", "学术", "发现", "成果"],
            "progress": ["进度", "完成率", "报告", "周报", "月报", "阶段性", "里程碑"],
            "task": ["分配", "负责", "任务", "计划", "安排", "分工", "部署"],
            "decision": ["决定", "决议", "投票", "表决", "审批", "批准"]
        }

    async def _stream_with_progress(self, prompt: ChatPromptTemplate, input_dict: dict, progress_msg: str) -> Iterator[str]:
        """带进度提示的流式处理方法"""
        yield f"{progress_msg}...\n"
        chain = prompt | self.llm | StrOutputParser()
        async for chunk in chain.astream(input_dict):
            yield chunk

    async def _quick_detect_meeting_type(self, text: str) -> str:
        """快速会议类型检测"""
        text_sample = text[:1000].lower()
        for mtype, keywords in self.type_keywords.items():
            if any(keyword in text_sample for keyword in keywords):
                return mtype
        return "default"

    async def _detailed_detect_meeting_type(self, text: str) -> Iterator[str]:
        """详细的LLM会议类型检测（纯文本输出）"""
        prompt = ChatPromptTemplate.from_template("""
            根据内容判断会议类型并直接回答，只需返回以下之一：
            [学术课程/学术研讨/进度汇报/任务部署/决策会议/常规会议]
            
            内容摘录：
            {text}""")
        
        async for chunk in self._stream_with_progress(prompt, {"text": text[:1800]}, "正在分析会议类型"):
            yield chunk

    async def _detect_meeting_type(self, text: str) -> str:
        """会议类型检测总入口"""
        if not text.strip():
            return "default"

        quick_type = await self._quick_detect_meeting_type(text)
        if quick_type != "default":
            return quick_type
        
        final_type = "default"
        async for chunk in self._detailed_detect_meeting_type(text):
            for k, v in self.meeting_types.items():
                if v in chunk:
                    final_type = k
                    break
        return final_type

    async def _extract_metadata(self, text: str, mtype: str) -> str:
        """纯文本元数据提取"""
        prompt = ChatPromptTemplate.from_template("""
            请从{meeting_type}内容中提取以下信息（用中文直接回答）：
            - 会议主题
            - 主要参与人
            - 核心关键词（3-5个）
            
            内容：
            {text}""")
        
        metadata = ""
        async for chunk in self._stream_with_progress(prompt, {"meeting_type": self.meeting_types.get(mtype, "会议"), "text": text[:2500]}, "正在提取关键信息"):
            metadata += chunk
        return metadata

    async def _generate_summary(self, text: str, mtype: str) -> Iterator[str]:
        """纯文本摘要生成"""
        templates = {
            "course": """请用中文总结以下课程内容（直接回答不要标记序号）：
· 核心知识点
· 教学难点
· 推荐学习资料

内容：{text}""",
            "research": """请用中文总结以下研讨内容：
· 研究问题
· 使用方法
· 重要发现

内容：{text}""",
            "default": """请用中文总结以下会议内容：
· 讨论主题
· 达成共识
· 后续任务

内容：{text}"""
        }
        
        prompt = ChatPromptTemplate.from_template(templates.get(mtype, templates["default"]))
        async for chunk in (prompt | self.llm | StrOutputParser()).astream({"text": text}):
            yield chunk

    async def astream_summary(self, transcript: str) -> Iterator[str]:
        """纯文本流式处理主入口"""
        if not transcript.strip():
            yield "⚠️ 输入内容为空"
            return

        yield "\n=== 会议内容分析开始 ===\n"
        
        # 阶段1：类型识别
        mtype = await self._detect_meeting_type(transcript)
        yield f"会议类型：{self.meeting_types[mtype]}\n"
        
        # 阶段2：元数据提取
        metadata = await self._extract_metadata(transcript, mtype)
        yield f"\n【会议概览】\n{metadata}\n"
        
        # 阶段3：分段摘要（暗分但无提示）
        chunks = self.text_splitter.split_text(transcript)
        yield "\n【内容摘要】\n"
        
        for chunk in chunks:
            async for text_chunk in self._generate_summary(chunk, mtype):
                yield text_chunk
        
        yield "\n=== 分析完成 ===\n"

async def run_summary(input_text: str):
    """纯文本版运行入口"""
    summarizer = StreamingMeetingSummarizer()
    
    print("="*50)
    print("开始处理会议内容...\n")
    
    async for chunk in summarizer.astream_summary(input_text):
        print(chunk, end="", flush=True)
    
    print("\n" + "="*50)
    print(f"处理完成时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("="*50)

if __name__ == "__main__":
    with open('testvideo_simplified.json', 'r', encoding='utf-8') as f:
        video_data = json.load(f)
    meeting_text = video_data['text']

    try:
        import nest_asyncio
        nest_asyncio.apply()
        loop = asyncio.get_event_loop()
        loop.run_until_complete(run_summary(meeting_text))
    except:
        asyncio.run(run_summary(meeting_text))
