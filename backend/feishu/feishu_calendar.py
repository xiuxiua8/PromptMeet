import json
import os
import lark_oapi as lark
from lark_oapi.api.calendar.v4 import *

from dotenv import load_dotenv
load_dotenv()

# SDK 使用说明: https://open.feishu.cn/document/uAjLw4CM/ukTMukTMukTM/server-side-sdk/python--sdk/preparations-before-development
# 以下示例代码默认根据文档示例值填充，如果存在代码问题，请在 API 调试台填上相关必要参数后再复制代码使用
def main():
    # 创建client
    # 使用 user_access_token 需开启 token 配置, 并在 request_option 中配置 token
    user_access_token = os.getenv("FEISHU_USER_ACCESS_TOKEN")
    if not user_access_token:
        raise ValueError("请先设置环境变量 FEISHU_USER_ACCESS_TOKEN")
    calendar_id = os.getenv("FEISHU_CALENDAR_ID")
    if not calendar_id:
        raise ValueError("请先设置环境变量 FEISHU_CALENDAR_ID")

    client = lark.Client.builder() \
        .enable_set_token(True) \
        .log_level(lark.LogLevel.DEBUG) \
        .build()

    # 构造请求对象
    request: CreateCalendarEventRequest = CreateCalendarEventRequest.builder() \
        .calendar_id(calendar_id) \
        .user_id_type("open_id") \
        .request_body(CalendarEvent.builder()
            .summary("日程标题")
            .description("日程描述")
            .need_notification(False)
            .start_time(TimeInfo.builder()
                .date("2025-09-01")
                .timestamp("1602504000")
                .timezone("Asia/Shanghai")
                .build())
            .end_time(TimeInfo.builder()
                .date("2025-09-01")
                .timestamp("1602504000")
                .timezone("Asia/Shanghai")
                .build())
            .visibility("default")
            .build()) \
        .build()

    # 发起请求
    option = lark.RequestOption.builder().user_access_token(user_access_token).build()
    response: CreateCalendarEventResponse = client.calendar.v4.calendar_event.create(request, option)

    # 处理失败返回
    if not response.success():
        lark.logger.error(
            f"client.calendar.v4.calendar_event.create failed, code: {response.code}, msg: {response.msg}, log_id: {response.get_log_id()}, resp: \n{json.dumps(json.loads(response.raw.content), indent=4, ensure_ascii=False)}")
        return

    # 处理业务结果
    lark.logger.info(lark.JSON.marshal(response.data, indent=4))


if __name__ == "__main__":
    main()