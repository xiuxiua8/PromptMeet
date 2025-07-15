#!/usr/bin/env python3
"""
测试飞书日历工具的问题
"""

import os
import sys
import asyncio
from dotenv import load_dotenv

# 添加项目根目录到路径
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from tools.feishu_calendar import FeishuCalendarTool

async def test_feishu_calendar():
    """测试飞书日历工具"""
    
    print("=== 测试飞书日历工具 ===\n")
    
    # 加载环境变量
    load_dotenv()
    
    # 检查环境变量
    print("1. 检查环境变量:")
    user_token = os.getenv("FEISHU_USER_ACCESS_TOKEN")
    calendar_id = os.getenv("FEISHU_CALENDAR_ID")
    
    print(f"   FEISHU_USER_ACCESS_TOKEN: {'已设置' if user_token else '未设置'}")
    print(f"   FEISHU_CALENDAR_ID: {'已设置' if calendar_id else '未设置'}")
    
    if not user_token:
        print("   ❌ 缺少飞书用户访问令牌")
        return
    
    if not calendar_id:
        print("   ❌ 缺少飞书日历ID")
        return
    
    print("   ✅ 环境变量配置正确")
    print()
    
    # 测试工具初始化
    print("2. 测试工具初始化:")
    try:
        tool = FeishuCalendarTool()
        print("   ✅ 工具初始化成功")
    except Exception as e:
        print(f"   ❌ 工具初始化失败: {e}")
        return
    print()
    
    # 测试Result.txt文件
    print("3. 测试Result.txt文件:")
    result_file_path = os.path.join("agents", "temp", "Result.txt")
    if os.path.exists(result_file_path):
        print(f"   ✅ 文件存在: {result_file_path}")
        with open(result_file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        print(f"   文件大小: {len(content)} 字符")
    else:
        print(f"   ❌ 文件不存在: {result_file_path}")
        return
    print()
    
    # 测试工具执行
    print("4. 测试工具执行:")
    try:
        result = await tool.execute(result_file_path=result_file_path)
        print(f"   执行结果: {result.success}")
        if result.success:
            print(f"   成功创建: {result.result.get('success_count', 0)} 个日程")
            print(f"   失败: {result.result.get('failed_count', 0)} 个日程")
            if result.result.get('failed_tasks'):
                print(f"   失败的任务: {result.result['failed_tasks']}")
        else:
            print(f"   错误: {result.error}")
    except Exception as e:
        print(f"   ❌ 执行失败: {e}")
        import traceback
        traceback.print_exc()
    print()
    
    # 测试手动任务创建
    print("5. 测试手动任务创建:")
    try:
        manual_task = {
            "title": "测试任务",
            "deadline": "明天下午2点",
            "remind": "是"
        }
        result = await tool.execute(manual_task=manual_task)
        print(f"   执行结果: {result.success}")
        if result.success:
            print("   ✅ 手动任务创建成功")
        else:
            print(f"   ❌ 手动任务创建失败: {result.error}")
    except Exception as e:
        print(f"   ❌ 手动任务执行失败: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    asyncio.run(test_feishu_calendar()) 