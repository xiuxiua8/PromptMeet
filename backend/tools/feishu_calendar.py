"""
飞书日历工具
"""
import json
import os
import re
from typing import Dict, Any, Optional
from datetime import datetime, timedelta
import pytz
from .base import BaseTool, ToolResult

# 尝试导入飞书SDK，如果未安装则记录警告
try:
    import lark_oapi as lark
    from lark_oapi.api.calendar.v4 import CalendarEvent, TimeInfo, CreateCalendarEventRequest, CreateCalendarEventResponse
    FEISHU_AVAILABLE = True
except ImportError:
    FEISHU_AVAILABLE = False
    lark = None


class FeishuCalendarTool(BaseTool):
    """飞书日历工具"""
    
    def __init__(self):
        super().__init__(
            name="feishu_calendar",
            description="从结果文件中提取待办事项并自动添加到飞书日历中"
        )
    
    async def execute(self, result_file_path: Optional[str] = None, manual_task: Optional[dict] = None) -> ToolResult:
        try:
            if manual_task:
                user_access_token = os.getenv("FEISHU_USER_ACCESS_TOKEN")
                calendar_id = os.getenv("FEISHU_CALENDAR_ID")
                if not user_access_token or not calendar_id:
                    return ToolResult(
                        tool_name=self.name,
                        result={"error": "飞书用户访问令牌或日历ID未配置"},
                        success=False,
                        error="飞书用户访问令牌或日历ID未配置"
                    )
                if not FEISHU_AVAILABLE:
                    return ToolResult(
                        tool_name=self.name,
                        result={"error": "飞书SDK未安装。请运行: pip install lark-oapi"},
                        success=False,
                        error="飞书SDK未安装"
                    )
                client = None
                if FEISHU_AVAILABLE:
                    client = lark.Client.builder().enable_set_token(True).log_level(lark.LogLevel.INFO).build()
                success, event_info = self._create_single_event(client, calendar_id, user_access_token, manual_task)
                if success:
                    return ToolResult(
                        tool_name=self.name,
                        result={"created_event": event_info, "total_tasks": 1},
                        success=True
                    )
                else:
                    return ToolResult(
                        tool_name=self.name,
                        result={"error": "日程创建失败", "total_tasks": 0},
                        success=False,
                        error="日程创建失败"
                    )
            if not FEISHU_AVAILABLE:
                return ToolResult(
                    tool_name=self.name,
                    result={
                        "file_path": result_file_path,
                        "error": "飞书SDK未安装。请运行: pip install lark-oapi",
                        "type": "error"
                    },
                    success=False,
                    error="飞书SDK未安装"
                )
            user_access_token = os.getenv("FEISHU_USER_ACCESS_TOKEN")
            if not user_access_token:
                return ToolResult(
                    tool_name=self.name,
                    result={
                        "file_path": result_file_path,
                        "error": "请先设置环境变量 FEISHU_USER_ACCESS_TOKEN",
                        "type": "error"
                    },
                    success=False,
                    error="飞书用户访问令牌未配置"
                )
            calendar_id = os.getenv("FEISHU_CALENDAR_ID")
            if not calendar_id:
                return ToolResult(
                    tool_name=self.name,
                    result={
                        "file_path": result_file_path,
                        "error": "请先设置环境变量 FEISHU_CALENDAR_ID",
                        "type": "error"
                    },
                    success=False,
                    error="飞书日历ID未配置"
                )
            if result_file_path is None:
                project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
                result_file_path = os.path.join(project_root, "agents", "temp", "Result.txt")
            if not os.path.exists(result_file_path):
                return ToolResult(
                    tool_name=self.name,
                    result={
                        "file_path": result_file_path,
                        "error": f"结果文件不存在: {result_file_path}",
                        "type": "error"
                    },
                    success=False,
                    error=f"结果文件不存在: {result_file_path}"
                )
            with open(result_file_path, 'r', encoding='utf-8') as f:
                content = f.read()
            tasks = self._extract_tasks_from_content(content)
            if not tasks:
                return ToolResult(
                    tool_name=self.name,
                    result={
                        "file_path": result_file_path,
                        "message": "未在结果文件中找到有效的待办事项",
                        "tasks_found": 0,
                        "type": "info"
                    },
                    success=True
                )
            if not FEISHU_AVAILABLE:
                return ToolResult(
                    tool_name=self.name,
                    result={"error": "飞书SDK未安装。请运行: pip install lark-oapi"},
                    success=False,
                    error="飞书SDK未安装"
                )
            client = None
            if FEISHU_AVAILABLE:
                client = lark.Client.builder().enable_set_token(True).log_level(lark.LogLevel.INFO).build()
            success_count = 0
            failed_tasks = []
            created_events = []
            for task in tasks:
                success, event_info = self._create_single_event(client, calendar_id, user_access_token, task)
                if success:
                    success_count += 1
                    created_events.append(event_info)
                else:
                    failed_tasks.append(task.get('title', '未知任务'))
            result_info = {
                "file_path": result_file_path,
                "total_tasks": len(tasks),
                "success_count": success_count,
                "failed_count": len(failed_tasks),
                "created_events": created_events,
                "failed_tasks": failed_tasks,
                "calendar_id": calendar_id,
                "type": "calendar_sync"
            }
            return ToolResult(
                tool_name=self.name,
                result=result_info,
                success=True
            )
        except Exception as e:
            return ToolResult(
                tool_name=self.name,
                result={"file_path": result_file_path, "error": f"飞书日历同步失败: {str(e)}", "type": "error"},
                success=False,
                error=str(e)
            )

    def _extract_tasks_from_content(self, content: str) -> list:
        """从内容中提取结构化待办事项"""
        try:
            # 匹配结构化待办事项部分
            json_match = re.search(
                r'【结构化待办事项】\s*```json\s*({.*?})\s*```', 
                content, 
                re.DOTALL
            )
            
            if not json_match:
                # 尝试匹配没有```json标记的情况
                json_match = re.search(
                    r'【结构化待办事项】\s*({.*?})\s*(?=【|$)', 
                    content, 
                    re.DOTALL
                )
            
            if not json_match:
                return []

            json_str = json_match.group(1)
            data = json.loads(json_str)
            
            # 提取tasks数组
            if isinstance(data, dict) and 'tasks' in data:
                return data['tasks']
            elif isinstance(data, list):
                return data
            else:
                return []

        except json.JSONDecodeError:
            return []
        except Exception:
            return []

    def _create_single_event(self, client, calendar_id: str, user_access_token: str, task: Dict[str, Any]) -> tuple:
        """创建单个日程事件"""
        try:
            title = task.get('title', '未知任务')
            description = task.get('description', '')
            deadline = task.get('deadline')
            
            if not deadline or deadline == "null":
                return False, None

            # 解析时间信息
            time_info = self._parse_datetime_info(deadline, description, title)
            
            # 构建事件描述
            event_description = f"{description}\n"
            if time_info['is_timed']:
                event_description += f"时间: {time_info['start_time']} - {time_info['end_time']}"
            else:
                event_description += f"日期: {time_info['date']}"
            
            # 构建日程事件
            if not FEISHU_AVAILABLE or lark is None:
                return False, None
            event_builder = None
            if FEISHU_AVAILABLE and lark is not None:
                event_builder = CalendarEvent.builder() \
                    .summary(title) \
                    .description(event_description) \
                    .need_notification(True) \
                    .visibility("default")
            
            # 根据是否有具体时间来设置时间信息
            if time_info['is_timed']:
                # 有具体时间的事件
                if FEISHU_AVAILABLE and lark is not None and event_builder is not None:
                    event_builder = event_builder \
                        .start_time(TimeInfo.builder()
                            .timestamp(str(time_info['start_timestamp']))
                            .timezone("Asia/Shanghai")
                            .build()) \
                        .end_time(TimeInfo.builder()
                            .timestamp(str(time_info['end_timestamp']))
                            .timezone("Asia/Shanghai")
                            .build())
            else:
                # 全天事件
                if FEISHU_AVAILABLE and lark is not None and event_builder is not None:
                    event_builder = event_builder \
                        .start_time(TimeInfo.builder()
                            .date(time_info['date'])
                            .timezone("Asia/Shanghai")
                            .build()) \
                        .end_time(TimeInfo.builder()
                            .date(time_info['date'])
                            .timezone("Asia/Shanghai")
                            .build())
            
            request = None
            response = None
            if FEISHU_AVAILABLE and lark is not None and event_builder is not None:
                request = CreateCalendarEventRequest.builder() \
                    .calendar_id(calendar_id) \
                    .user_id_type("open_id") \
                    .request_body(event_builder.build()) \
                    .build()
                option = lark.RequestOption.builder().user_access_token(user_access_token).build()
                response = client.calendar.v4.calendar_event.create(request, option)
            if response and hasattr(response, 'success') and response.success():
                event_info = {
                    "title": title,
                    "date": time_info['date'],
                    "start_time": time_info.get('start_time'),
                    "end_time": time_info.get('end_time'),
                    "is_timed": time_info['is_timed']
                }
                return True, event_info
            else:
                error_msg = "API调用失败"
                if response and hasattr(response, 'msg'):
                    error_msg = f"API错误: {response.msg}"
                elif response and hasattr(response, 'code'):
                    error_msg = f"API错误代码: {response.code}"
                print(f"飞书日历API调用失败: {error_msg}")
                return False, error_msg

        except Exception as e:
            print(f"创建日程异常: {e}")
            return False, str(e)

    def _is_date_format(self, date_str: str) -> bool:
        """检查是否为YYYY-MM-DD格式的日期"""
        return bool(re.match(r'^\d{4}-\d{2}-\d{2}$', date_str))

    def _parse_datetime_info(self, deadline: str, description: str = "", title: str = "") -> Dict:
        """解析日期时间信息，支持具体时间段和全天事件"""
        # 先获取基础日期
        base_date = self._parse_relative_date(deadline) if not self._is_date_format(deadline) else deadline
        
        # 合并所有文本进行时间检测
        full_text = f"{deadline} {description} {title}".lower()
        
        # 检测时间模式
        time_patterns = [
            # 具体时间段: 9:00-10:30, 09:00-10:30, 9点-10点30分
            r'(\d{1,2}):(\d{2})\s*[-到至]\s*(\d{1,2}):(\d{2})',
            r'(\d{1,2})点\s*[-到至]\s*(\d{1,2})点(\d{1,2})分',
            r'(\d{1,2})点\s*[-到至]\s*(\d{1,2})点',
            # 单个时间点（默认1小时）: 9:00, 下午2点, 晚上8点
            r'(?:上午|下午|晚上)?\s*(\d{1,2}):(\d{2})',
            r'(?:上午|下午|晚上)\s*(\d{1,2})点',
            r'(\d{1,2})点(?![-到至])',
            # 时间段描述: 上午, 下午, 晚上, 中午
            r'(上午|下午|晚上|中午)',
        ]
        
        time_info = {
            'is_timed': False,
            'date': base_date,
            'start_time': None,
            'end_time': None,
            'start_timestamp': None,
            'end_timestamp': None
        }
        
        # 尝试匹配时间模式
        for pattern in time_patterns:
            match = re.search(pattern, full_text)
            if match:
                time_info = self._extract_time_from_match(match, pattern, base_date, full_text)
                if time_info['is_timed']:
                    break
        
        return time_info

    def _extract_time_from_match(self, match, pattern: str, base_date: str, full_text: str) -> Dict:
        """从正则匹配中提取时间信息"""
        groups = match.groups()
        
        try:
            base_dt = datetime.strptime(base_date, '%Y-%m-%d')
            
            # 具体时间段模式
            if ':' in pattern and '[-到至]' in pattern:
                if len(groups) >= 4:
                    start_hour, start_min, end_hour, end_min = groups[:4]
                    start_dt = base_dt.replace(hour=int(start_hour), minute=int(start_min))
                    end_dt = base_dt.replace(hour=int(end_hour), minute=int(end_min))
                    
                    return {
                        'is_timed': True,
                        'date': base_date,
                        'start_time': f"{start_hour:0>2}:{start_min}",
                        'end_time': f"{end_hour:0>2}:{end_min}",
                        'start_timestamp': int(start_dt.timestamp()),
                        'end_timestamp': int(end_dt.timestamp())
                    }
            
            # X点到Y点模式
            elif '点' in pattern and '[-到至]' in pattern:
                if len(groups) >= 2:
                    start_hour = int(groups[0])
                    end_hour = int(groups[1])
                    end_min = int(groups[2]) if len(groups) > 2 and groups[2] and groups[2].isdigit() else 0
                    
                    # 调整AM/PM
                    start_hour, end_hour = self._adjust_ampm_hours(start_hour, end_hour, full_text)
                    
                    start_dt = base_dt.replace(hour=start_hour, minute=0)
                    end_dt = base_dt.replace(hour=end_hour, minute=end_min)
                    
                    return {
                        'is_timed': True,
                        'date': base_date,
                        'start_time': f"{start_hour:0>2}:00",
                        'end_time': f"{end_hour:0>2}:{end_min:0>2}",
                        'start_timestamp': int(start_dt.timestamp()),
                        'end_timestamp': int(end_dt.timestamp())
                    }
            
            # 单个时间点模式
            elif ':' in pattern and len(groups) >= 2:
                hour, minute = int(groups[0]), int(groups[1])
                hour = self._adjust_single_hour_ampm(hour, full_text)
                
                start_dt = base_dt.replace(hour=hour, minute=minute)
                end_dt = base_dt.replace(hour=hour, minute=minute) + timedelta(hours=1)  # 默认1小时
                
                return {
                    'is_timed': True,
                    'date': base_date,
                    'start_time': f"{hour:0>2}:{minute:0>2}",
                    'end_time': f"{end_dt.hour:0>2}:{end_dt.minute:0>2}",
                    'start_timestamp': int(start_dt.timestamp()),
                    'end_timestamp': int(end_dt.timestamp())
                }
            
            # X点模式
            elif '点' in pattern and len(groups) >= 1 and groups[0] and groups[0].isdigit():
                hour = int(groups[0])
                hour = self._adjust_single_hour_ampm(hour, full_text)
                
                start_dt = base_dt.replace(hour=hour, minute=0)
                end_dt = base_dt.replace(hour=hour, minute=0) + timedelta(hours=1)
                
                return {
                    'is_timed': True,
                    'date': base_date,
                    'start_time': f"{hour:0>2}:00",
                    'end_time': f"{end_dt.hour:0>2}:00",
                    'start_timestamp': int(start_dt.timestamp()),
                    'end_timestamp': int(end_dt.timestamp())
                }
            
            # 时间段描述模式
            elif len(groups) >= 1 and groups[0] in ['上午', '下午', '晚上', '中午']:
                time_period = groups[0]
                start_hour, duration = self._get_period_time(time_period)
                
                start_dt = base_dt.replace(hour=start_hour, minute=0)
                end_dt = start_dt + timedelta(hours=duration)
                
                return {
                    'is_timed': True,
                    'date': base_date,
                    'start_time': f"{start_hour:0>2}:00",
                    'end_time': f"{end_dt.hour:0>2}:00",
                    'start_timestamp': int(start_dt.timestamp()),
                    'end_timestamp': int(end_dt.timestamp())
                }
                
        except (ValueError, IndexError):
            pass
        
        # 返回全天事件
        return {
            'is_timed': False,
            'date': base_date,
            'start_time': None,
            'end_time': None,
            'start_timestamp': None,
            'end_timestamp': None
        }

    def _adjust_ampm_hours(self, start_hour: int, end_hour: int, text: str) -> tuple:
        """调整上午下午时间"""
        if '上午' in text:
            return start_hour, end_hour
        elif '下午' in text or '晚上' in text:
            if start_hour < 12:
                start_hour += 12
            if end_hour < 12:
                end_hour += 12
        return start_hour, end_hour

    def _adjust_single_hour_ampm(self, hour: int, text: str) -> int:
        """调整单个小时的上午下午"""
        if '下午' in text or '晚上' in text:
            if hour < 12:
                hour += 12
        elif '上午' in text and hour == 12:
            hour = 0
        return hour

    def _get_period_time(self, period: str) -> tuple:
        """获取时间段的开始时间和持续时长"""
        period_map = {
            '上午': (9, 3),   # 9:00-12:00
            '中午': (12, 2),  # 12:00-14:00  
            '下午': (14, 4),  # 14:00-18:00
            '晚上': (19, 3),  # 19:00-22:00
        }
        return period_map.get(period, (9, 1))

    def _parse_relative_date(self, relative_date: str) -> str:
        """解析相对日期，转换为YYYY-MM-DD格式"""
        today = datetime.now()
        
        # 简单的相对日期解析
        if "明天" in relative_date:
            target_date = today + timedelta(days=1)
            return target_date.strftime('%Y-%m-%d')
        elif "后天" in relative_date:
            target_date = today + timedelta(days=2)
            return target_date.strftime('%Y-%m-%d')
        elif "下周三" in relative_date:
            # 计算下周三的日期
            days_ahead = 2 - today.weekday()  # 2 = Wednesday
            if days_ahead <= 0:  # 如果今天是周三之后
                days_ahead += 7
            days_ahead += 7  # 下周
            target_date = today + timedelta(days=days_ahead)
            return target_date.strftime('%Y-%m-%d')
        elif "周五" in relative_date:
            # 计算这周五的日期
            days_ahead = 4 - today.weekday()  # 4 = Friday
            if days_ahead < 0:  # 如果今天是周五之后
                days_ahead += 7
            target_date = today + timedelta(days=days_ahead)
            return target_date.strftime('%Y-%m-%d')
        elif re.search(r'(\d+)天后', relative_date):
            # 匹配"X天后"
            match = re.search(r'(\d+)天后', relative_date)
            if match:
                days = int(match.group(1))
                target_date = today + timedelta(days=days)
                return target_date.strftime('%Y-%m-%d')
        
        # 如果无法解析，返回明天的日期作为默认
        target_date = today + timedelta(days=1)
        return target_date.strftime('%Y-%m-%d') 