import asyncio
from datetime import datetime
import json
import re
from typing import Iterator, Dict, List, AsyncGenerator, Any
from langchain.text_splitter import RecursiveCharacterTextSplitter
from langchain.prompts import ChatPromptTemplate
from langchain_openai import ChatOpenAI
from langchain_core.output_parsers import StrOutputParser
import os
from io import StringIO
import logging
from pydantic import SecretStr

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s"
)

logger = logging.getLogger(__name__)

class MeetingProcessor:
    def __init__(self, streaming: bool = True):
        """初始化处理器"""
        # 优先使用DEEPSEEK API，如果没有配置则使用OPENAI API
        deepseek_api_key = os.getenv("DEEPSEEK_API_KEY")
        deepseek_api_base = os.getenv("DEEPSEEK_API_BASE")
        if deepseek_api_key:
            api_key = deepseek_api_key
            base_url = deepseek_api_base
            model = "deepseek-chat"
            print(f"使用DEEPSEEK API: {base_url}, Key: {api_key[:8]}...")
        else:
            raise ValueError("请设置DEEPSEEK_API_KEY环境变量")
        api_key = SecretStr(api_key) if api_key else None
        self.llm = ChatOpenAI(
            api_key=api_key,
            base_url=base_url,
            model=model,
            temperature=0.2,
            streaming=streaming
        )
        self.text_splitter = RecursiveCharacterTextSplitter(
            chunk_size=1200,
            chunk_overlap=200,
            separators=["\n\n", "\n", "。", "；", "! ", "? ", "…"]
        )
        self.my_aliases = ["qin_ran", "秦然", "qinran", "ran", "秦工", "秦老师"]

    async def _stream_with_progress(self, prompt: ChatPromptTemplate, input_dict: dict, progress_msg: str) -> AsyncGenerator[str, Any]:
        """带进度提示的流式处理方法"""
        yield f"{progress_msg}...\n"
        chain = prompt | self.llm | StrOutputParser()
        async for chunk in chain.astream(input_dict):
            yield chunk

    async def _extract_my_tasks(self, text: str) -> List[Dict]:
        """提取与qin_ran(我)相关的任务（增强DDL识别能力）"""
        prompt = ChatPromptTemplate.from_template("""
            请从以下会议内容中识别出分配给[{username}](可能称呼包括：{aliases})的任务，
            以及虽然没有明确分配但可能需要我负责的任务。
            
            特别注意：必须提取所有提到的时间节点作为deadline，即使没有明确说"截止"。
            例如："下周三前完成" → "下周三", "周五评审" → "周五"
            
            要求返回严格合法的JSON数组格式，每个对象包含：
            - "task" (任务内容)
            - "deadline" (截止日期，格式YYYY-MM-DD或相对日期如"下周三")
            - "describe" (任务详情)
            
            日期转换规则：
            1. "下周三" → 转换为实际日期如"2023-12-20"
            2. "3天后" → 转换为实际日期
            3. 保持原始表述如果无法确定具体日期
            
            示例格式：
            [
                {{
                    "task": "完成需求文档", 
                    "deadline": "2023-12-20", 
                    "describe": "需要与产品经理确认所有需求点"
                }},
                {{
                    "task": "技术方案评审",
                    "deadline": "周五",
                    "describe": "准备架构图和接口设计"
                }}
            ]
            
            当前日期：{current_date}
            会议内容：
            {text}""")
        
        chain = prompt | self.llm | StrOutputParser()
        tasks_json = await chain.ainvoke({
            "username": "qin_ran",
            "aliases": "、".join(self.my_aliases),
            "current_date": datetime.now().strftime("%Y-%m-%d"),
            "text": text[:3000]  # 限制长度防止过载
        })
        
        try:
            if not tasks_json.strip() or tasks_json.strip() == "[]":
                return []
            
            # 清理可能的非JSON内容
            json_str = re.search(r'\[.*\]', tasks_json.replace('\n', ''), re.DOTALL)
            if json_str:
                tasks_json = json_str.group(0)
            tasks = json.loads(tasks_json)
            
            # 数据清洗
            for task in tasks:
                if "deadline" in task and isinstance(task["deadline"], str):
                    task["deadline"] = task["deadline"].strip() or None
                task.setdefault("describe", "")
            return tasks
        except json.JSONDecodeError:
            print(f"⚠️ JSON解析失败，原始输出:\n{tasks_json}")
            return []
        except Exception as e:
            print(f"⚠️ 任务解析错误: {str(e)}")
            return []


    async def _generate_summary(self, text: str, tasks: List[Dict]) -> AsyncGenerator[str, Any]:
        """生成整合了任务信息的会议摘要"""
        # 将任务转换为易读格式
        tasks_str = "\n".join(
            f"- {task['task']} (截止: {task['deadline'] or '无'})\n  详情: {task['describe']}"
            for task in tasks
        ) if tasks else "无特定任务"
        
        prompt = ChatPromptTemplate.from_template("""
            请用中文总结以下会议内容：
            1. 主要讨论议题（议题内容如果有重复或者相似的，请合并）
            2. 重要结论或决定
            3. 我的待办事项：
            {tasks}
            
            会议内容：
            {text}""")
        
        async for chunk in (prompt | self.llm | StrOutputParser()).astream({
            "text": text,
            "tasks": tasks_str
        }):
            yield chunk

    async def _generate_structured_tasks(self, tasks: List[Dict]) -> AsyncGenerator[str, Any]:
        """生成结构化的待办事项JSON"""
        prompt = ChatPromptTemplate.from_template("""
            请将以下任务列表转换为更结构化的JSON格式，要求：
            1. 包含所有原始信息
            2. 确保所有日期格式为YYYY-MM-DD或null
            3. 对任务内容进行简洁化处理
            
            返回格式示例：
            {{
                "tasks": [
                    {{
                        "title": "简洁任务标题",
                        "description": "任务详情",
                        "deadline": "2023-12-31"
                    }}
                ],
                "total": 任务总数
            }}
            
            原始任务列表：
            {tasks}""")
        
        # 将原始任务转换为易读格式
        tasks_str = "\n".join(
            f"- 任务: {task['task']}, 截止: {task['deadline'] or '无'}, 详情: {task['describe']}"
            for task in tasks
        ) if tasks else "无任务"
        
        async for chunk in (prompt | self.llm | StrOutputParser()).astream({
            "tasks": tasks_str
        }):
            yield chunk

    async def process_meeting(self, transcript: str) -> AsyncGenerator[str, Any]:
        """主处理流程"""
        if not transcript.strip():
            yield "⚠️ 输入内容为空"
            return

        logger.info("="*50)
        logger.info("开始处理会议内容...\n")
        
        yield "\n=== 会议内容分析开始 ===\n"
        
        # 创建StringIO缓存完整结果
        result_buffer = StringIO()
        
        # 先提取任务
        tasks = await self._extract_my_tasks(transcript)
        
        # 生成整合了任务信息的总结
        yield "\n【会议总结】\n"
        async for text_chunk in self._generate_summary(transcript, tasks):
            result_buffer.write(text_chunk)
            yield text_chunk
        
        # 原始任务JSON
        yield "\n【原始待办事项】\n"
        tasks_json = json.dumps(tasks, ensure_ascii=False, indent=2)
        result_buffer.write("\n【原始待办事项】\n")
        result_buffer.write(tasks_json)
        yield tasks_json
        
        # 结构化任务JSON
        yield "\n\n【结构化待办事项】\n"
        result_buffer.write("\n\n【结构化待办事项】\n")
        async for json_chunk in self._generate_structured_tasks(tasks):
            result_buffer.write(json_chunk)
            yield json_chunk
        
        yield "\n=== 分析完成 ===\n"
        result_buffer.write("\n=== 分析完成 ===\n")
        
        # 保存结果到文件
        try:
            with open("Result.txt", "w", encoding="utf-8") as f:
                f.write(result_buffer.getvalue())
            logger.info("\n结果已保存到 Result.txt\n")
        except Exception as e:
            logger.error(f"保存结果到文件失败: {e}")
        
        logger.info("="*50)
        logger.info(f"处理完成时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        logger.info("="*50)


async def run_processor(input_text: str):
    """执行入口，先保存结果到文件，再输出到前端"""
    processor = MeetingProcessor()
    logger.info("="*50)
    logger.info("开始处理会议内容...\n")
    # 创建StringIO缓存完整结果
    result_buffer = StringIO()
    all_chunks = []
    async for chunk in processor.process_meeting(input_text):
        all_chunks.append(chunk)
        result_buffer.write(chunk)
    # 先写入文件
    with open("Result.txt", "w", encoding="utf-8") as f:
        f.write(result_buffer.getvalue())
    logger.info("\n结果已保存到 Result.txt\n")
    # 再输出到前端/控制台
    for chunk in all_chunks:
        print(chunk, end="", flush=True)
    print("\n" + "="*50)
    print(f"处理完成时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("="*50)


if __name__ == "__main__":
    # 测试数据 - 产品需求讨论会议
    meeting_text = """
    "我们现在开始产品迭代规划会议，首先回顾一下上个版本的KPI达成情况。核心指标中，用户留存率提升了8%，但转化漏斗在第三步有显著流失。"
    "关于新版本的需求优先级，市场部反馈最紧急的是支付流程优化，特别是针对海外用户的信用卡支付成功率问题。技术团队需要评估是否可以在现有架构上实现3DS认证集成。"
    "后端服务目前使用的是2019年的支付接口规范，如果要支持最新的3DS 2.0协议，可能需要升级整个支付网关。初步估算至少需要2周开发时间和1周测试周期。"
    "UI/UX团队已经准备好了新的支付页面设计稿，主要变化是：1) 增加进度指示器 2) 简化表单字段 3) 添加实时验证反馈。视觉稿可以在共享文件夹查看。"
    "有个风险点需要提前讨论：如果选择全面升级支付网关，可能会影响现有的支付宝和微信支付接口。建议先在新加坡区域做灰度发布，验证通过后再全局推广。"
    "数据团队提醒我们需要建立更完善的支付事件埋点体系，特别是要跟踪3DS验证的各阶段耗时。这部分需要前端配合在关键节点打点。"
    "安全团队提出了新的合规要求：所有支付相关日志必须加密存储，且保留时间从30天延长到180天。这会影响当前日志服务的设计方案。"
    "运维团队反馈监控系统需要新增三个关键指标：支付超时率、3DS验证失败率和银行接口响应时间。Prometheus的仪表盘配置已经准备好了。"
    "考虑到版本发布时间窗口，建议将需求拆分为两个阶段：第一阶段先解决基础支付流程问题，第二阶段再实现完整的3DS 2.0认证。"
    "测试团队强调必须增加边界测试用例，特别是模拟各国不同的3DS验证要求。需要准备测试信用卡号列表和对应的测试场景。"
    "性能测试方案已经就绪，重点验证：1) 高并发下的支付成功率 2) 极端网络条件下的超时处理 3) 多币种结算时的精度问题。"
    "最后确认下时间节点：需求文档下周三前定稿，技术方案评审安排在周五，开发周期从下下周一正式开始，预留3天缓冲期应对可能的风险。"
    "补充一个技术决策点：关于支付结果异步通知机制，是继续使用现有轮询方案还是改用Webhook，需要架构组今天给出明确方向。"
    "数据库团队提醒支付事务表需要新增字段存储3DS认证结果，包括：认证类型、CAVV值和ECI标识。这涉及表结构变更和索引优化。"
    "前端团队提出能否在后端提供支付能力检测接口，这样可以根据用户环境动态展示不同的支付选项。这个需求优先级怎么定？"
    "客户支持部门要求在新版本发布前完成知识库更新，特别是针对3DS验证的常见问题解答。需要产品团队提供最新版的操作指引。"
    "所有与会人员确认下：支付流程优化的最终目标是将海外信用卡支付成功率从当前的62%提升到75%以上，这个KPI是否合理可行？"
    """

    # 异步处理
    try:
        import nest_asyncio
        nest_asyncio.apply()
        loop = asyncio.get_event_loop()
        loop.run_until_complete(run_processor(meeting_text))
    except ImportError:
        asyncio.run(run_processor(meeting_text))
