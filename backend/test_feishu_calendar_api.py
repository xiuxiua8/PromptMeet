from dotenv import load_dotenv
import os
import asyncio
from tools.feishu_calendar import FeishuCalendarTool

# 加载环境变量
load_dotenv()

async def main():
    tool = FeishuCalendarTool()
    # 你可以把 Result.txt 放在项目根目录或 backend 目录
    # 这里假设你有一个结构化待办事项的 Result.txt
    result = await tool.execute(result_file_path="Result.txt")
    print("执行结果：", result)

if __name__ == "__main__":
    asyncio.run(main())