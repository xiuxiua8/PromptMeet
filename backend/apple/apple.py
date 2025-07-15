import subprocess
from datetime import datetime, timedelta


def add_event_to_apple_calendar(
    title, location, notes, start_time, duration_minutes, calendar_name="个人"
):
    end_time = start_time + timedelta(minutes=duration_minutes)

    # 计算从现在开始的分钟数偏移
    now = datetime.now()
    start_offset_minutes = int((start_time - now).total_seconds() / 60)
    end_offset_minutes = int((end_time - now).total_seconds() / 60)

    # 使用AppleScript原生日期计算，避免字符串解析问题
    applescript = f"""tell application "Calendar"
activate
set now to current date
set startTime to now + ({start_offset_minutes} * minutes)
set endTime to now + ({end_offset_minutes} * minutes)
tell calendar "{calendar_name}"
set newEvent to make new event with properties {{summary:"{title}", location:"{location}", description:"{notes}", start date:startTime, end date:endTime}}
return "事件已创建: " & summary of newEvent & " ID: " & id of newEvent
end tell
end tell"""

    try:
        print(f"🔄 执行 AppleScript...")
        print(f"目标日历: {calendar_name}")
        print(f"开始时间偏移: {start_offset_minutes} 分钟")
        print(f"结束时间偏移: {end_offset_minutes} 分钟")

        process = subprocess.Popen(
            ["osascript", "-"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        stdout, stderr = process.communicate(applescript)

        if process.returncode == 0:
            print("✅ 成功添加事件到 Apple Calendar")
            print(f"📋 返回信息: {stdout.strip()}")
            return True
        else:
            print("❌ 添加失败:", stderr)
            print("📝 AppleScript 内容:")
            print(applescript)
            return False
    except Exception as e:
        print(f"❌ 执行出错: {e}")
        return False


def list_available_calendars():
    """列出所有可用的日历"""
    applescript = """tell application "Calendar"
set calendarList to name of every calendar where writable is true
return calendarList
end tell"""

    try:
        process = subprocess.Popen(
            ["osascript", "-"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        stdout, stderr = process.communicate(applescript)

        if process.returncode == 0:
            print("📅 可用的日历:")
            calendars = stdout.strip().split(", ")
            for i, cal in enumerate(calendars, 1):
                print(f"  {i}. {cal}")
            return calendars
        else:
            print("❌ 获取日历列表失败:", stderr)
            return []
    except Exception as e:
        print(f"❌ 获取日历列表出错: {e}")
        return []


# 示例使用
if __name__ == "__main__":
    print("📋 首先列出可用的日历:")
    available_calendars = list_available_calendars()

    # 使用当前时间后1分钟（立即可见）
    now = datetime.now()
    start_time = now + timedelta(minutes=1)  # 1分钟后开始

    print(f"\n📅 准备添加会议事件: {start_time.strftime('%Y-%m-%d %H:%M')}")

    # 使用个人日历
    target_calendar = (
        "个人"
        if "个人" in available_calendars
        else available_calendars[0] if available_calendars else "个人"
    )
    print(f"🎯 使用日历: {target_calendar}")

    success = add_event_to_apple_calendar(
        title="🟢 Python脚本测试",
        location="Python测试",
        notes="通过修复后的Python脚本创建的事件",
        start_time=start_time,
        duration_minutes=30,
        calendar_name=target_calendar,
    )

    if success:
        print(f"🎉 测试成功！请检查您的 Apple Calendar 应用中的'{target_calendar}'日历")
        print("💡 提示：事件应该立即可见")
    else:
        print("🔧 需要进一步调试...")
