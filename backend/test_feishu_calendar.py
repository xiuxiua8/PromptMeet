import sys
import os
import asyncio

# 确保 backend 目录在 sys.path
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from tools.feishu_calendar import FeishuCalendarTool

if __name__ == "__main__":
    tool = FeishuCalendarTool()
    result = asyncio.run(tool.execute())
    print("飞书日历工具执行结果：")
    print(result) 