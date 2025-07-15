#!/usr/bin/env python3
"""
测试日历功能的完整流程
包括：默认发送日程、对话补全、后续对话补全
"""

import asyncio
import os
import sys
from pathlib import Path

# 添加项目根目录到路径
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from agents.agent_processor import AgentProcessor

async def test_calendar_flow():
    """测试日历功能的完整流程"""
    
    # 初始化处理器
    processor = AgentProcessor()
    
    print("=== 测试日历功能完整流程 ===\n")
    
    # 测试1：默认发送日程（有Result.txt文件）
    print("1. 测试默认发送日程（有Result.txt文件）")
    print("用户输入：发送日程")
    
    # 创建测试用的Result.txt文件
    result_file_path = Path("agents/temp/Result.txt")
    result_file_path.parent.mkdir(exist_ok=True)
    
    with open(result_file_path, "w", encoding="utf-8") as f:
        f.write("""任务1
标题：团队会议
时间：明天下午2点
提醒：是

任务2
标题：项目评审
时间：后天上午10点
提醒：否""")
    
    response = await processor._handle_chat_message("发送日程")
    print(f"AI响应：{response}")
    print(f"等待状态：{processor.waiting_for_calendar_info}")
    print()
    
    # 测试2：默认发送日程（无Result.txt文件或文件为空）
    print("2. 测试默认发送日程（无有效任务）")
    print("用户输入：发送日程")
    
    # 清空Result.txt文件
    with open(result_file_path, "w", encoding="utf-8") as f:
        f.write("")
    
    response = await processor._handle_chat_message("发送日程")
    print(f"AI响应：{response}")
    print(f"等待状态：{processor.waiting_for_calendar_info}")
    print()
    
    # 测试3：对话补全日程信息
    print("3. 测试对话补全日程信息")
    print("用户输入：标题：客户会议，时间：下周一上午9点，提醒：是")
    
    response = await processor._handle_chat_message("标题：客户会议，时间：下周一上午9点，提醒：是")
    print(f"AI响应：{response}")
    print(f"等待状态：{processor.waiting_for_calendar_info}")
    print()
    
    # 测试4：信息不完整的对话补全
    print("4. 测试信息不完整的对话补全")
    print("用户输入：发送日程")
    
    response = await processor._handle_chat_message("发送日程")
    print(f"AI响应：{response}")
    print(f"等待状态：{processor.waiting_for_calendar_info}")
    print()
    
    print("用户输入：团队会议")
    
    response = await processor._handle_chat_message("团队会议")
    print(f"AI响应：{response}")
    print(f"等待状态：{processor.waiting_for_calendar_info}")
    print()
    
    # 测试5：直接输入具体日程内容
    print("5. 测试直接输入具体日程内容")
    print("用户输入：标题：产品发布会，时间：下周五下午3点")
    
    response = await processor._handle_chat_message("标题：产品发布会，时间：下周五下午3点")
    print(f"AI响应：{response}")
    print(f"等待状态：{processor.waiting_for_calendar_info}")
    print()
    
    # 测试6：后续发送日程（应该只通过对话补全）
    print("6. 测试后续发送日程（应该只通过对话补全）")
    print("用户输入：发送日程")
    
    response = await processor._handle_chat_message("发送日程")
    print(f"AI响应：{response}")
    print(f"等待状态：{processor.waiting_for_calendar_info}")
    print()
    
    print("=== 测试完成 ===")

if __name__ == "__main__":
    # 加载环境变量
    from dotenv import load_dotenv
    load_dotenv()
    
    asyncio.run(test_calendar_flow()) 