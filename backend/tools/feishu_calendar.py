import json
import os
import re
import lark_oapi as lark
from lark_oapi.api.calendar.v4 import *
from dotenv import load_dotenv

load_dotenv()

def extract_tasks_from_txt(txt_content):
    """从TXT文件中提取结构化待办事项的JSON数据"""
    # 使用正则表达式查找JSON部分
    json_match = re.search(r'```json\s*({.*?})\s*```', txt_content, re.DOTALL)
    
    if not json_match:
        raise ValueError("未在TXT文件中找到有效的JSON数据")
    
    try:
        # 提取并解析JSON
        json_str = json_match.group(1)
        return json.loads(json_str)
    except json.JSONDecodeError:
        raise ValueError("提取的JSON格式不正确")

def create_calendar_event(client, calendar_id, user_access_token, task):
    """创建单个日程事件"""
    deadline_date = task["deadline"]
    
    request: CreateCalendarEventRequest = CreateCalendarEventRequest.builder() \
        .calendar_id(calendar_id) \
        .user_id_type("open_id") \
        .request_body(CalendarEvent.builder()
            .summary(task["title"])
            .description(f"{task['description']}\n截止日期: {deadline_date}")
            .need_notification(True)
            .start_time(TimeInfo.builder()
                .date(deadline_date)
                .timezone("Asia/Shanghai")
                .build())
            .end_time(TimeInfo.builder()
                .date(deadline_date)
                .timezone("Asia/Shanghai")
                .build())
            .visibility("default")
            .build()) \
        .build()

    option = lark.RequestOption.builder().user_access_token(user_access_token).build()
    response: CreateCalendarEventResponse = client.calendar.v4.calendar_event.create(request, option)

    if response.success():
        print(f"✅ 成功创建日程: {task['title']} (ID: {response.data.event.event_id})")
        return True
    else:
        print(f"❌ 创建日程失败: {task['title']}, 错误信息: {response.msg}")
        return False

def feishucalendar():
    # 读取环境变量
    user_access_token = os.getenv("FEISHU_USER_ACCESS_TOKEN")
    if not user_access_token:
        raise ValueError("请先设置环境变量 FEISHU_USER_ACCESS_TOKEN")
    
    calendar_id = os.getenv("FEISHU_CALENDAR_ID")
    if not calendar_id:
        raise ValueError("请先设置环境变量 FEISHU_CALENDAR_ID")
    
    # 创建客户端
    client = lark.Client.builder() \
        .enable_set_token(True) \
        .log_level(lark.LogLevel.DEBUG) \
        .build()

    # 读取包含待办事项的TXT文件
    txt_file_path = "Result.txt"  # 修改为你的TXT文件路径
    try:
        with open(txt_file_path, 'r', encoding='utf-8') as f:
            txt_content = f.read()
        
        # 从TXT内容中提取JSON数据
        tasks_data = extract_tasks_from_txt(txt_content)
        tasks = tasks_data.get("tasks", [])
        
        if not tasks:
            raise ValueError("未找到有效的待办事项")
            
    except Exception as e:
        print(f"文件处理错误: {str(e)}")
        return

    # 为每个待办事项创建日程
    print(f"📅 开始创建日程，共 {len(tasks)} 个待办事项")
    success_count = 0
    for task in tasks:
        if create_calendar_event(client, calendar_id, user_access_token, task):
            success_count += 1

    print(f"🎉 日程创建完成! 成功: {success_count}/{len(tasks)} 个日程")

if __name__ == "__main__":
    feishucalendar()