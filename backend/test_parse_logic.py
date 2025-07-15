#!/usr/bin/env python3
"""
测试日程信息解析逻辑
"""

import re

def test_parse_calendar_info(user_message):
    """测试解析日程信息"""
    print(f"测试输入: {user_message}")
    
    # 检测是否为具体日程内容
    is_concrete_calendar = False
    if re.search(r'(标题|时间|提醒|\d{1,2}月\d{1,2}日|\d{4}-\d{1,2}-\d{1,2}|上午|下午|全天|点|:)', user_message):
        is_concrete_calendar = True
    
    print(f"是否为具体日程内容: {is_concrete_calendar}")
    
    if is_concrete_calendar:
        # 解析日程信息
        title = ''
        time_str = ''
        remind = ''
        
        m_title = re.search(r'标题[:：]?([\S ]+?)(,|，|$)', user_message)
        m_time = re.search(r'时间[:：]?([\S ]+?)(,|，|$)', user_message)
        m_remind = re.search(r'提醒[:：]?([\S ]+?)(,|，|$)', user_message)
        
        if m_title:
            title = m_title.group(1).strip()
        if m_time:
            time_str = m_time.group(1).strip()
        if m_remind:
            remind = m_remind.group(1).strip()
        
        # 若没显式"标题"，用整句或默认
        if not title:
            # 尝试从句子中提取更合适的标题
            # 方法1：提取"要"、"去"、"进行"等动词后面的内容
            action_patterns = [
                r'要(.+?)(?=\s|$)',  # 要实习
                r'去(.+?)(?=\s|$)',  # 去开会
                r'进行(.+?)(?=\s|$)',  # 进行面试
                r'参加(.+?)(?=\s|$)',  # 参加会议
            ]
            
            for pattern in action_patterns:
                match = re.search(pattern, user_message)
                if match:
                    title = match.group(1).strip()
                    break
            
            # 方法2：如果方法1没找到，提取句子的最后部分（通常是活动名称）
            if not title:
                # 移除时间相关词汇
                time_keywords = ['明天', '后天', '下周一', '下周二', '下周三', '下周四', '下周五', '下周六', '下周日', 
                               '上午', '下午', '晚上', '早上', '中午', '全天', '点', ':', '：', '到', '开始', '结束',
                               '八', '九', '十', '十一', '十二', '一', '二', '三', '四', '五', '六', '七']
                
                potential_title = user_message.strip()
                for keyword in time_keywords:
                    potential_title = potential_title.replace(keyword, '')
                
                # 清理多余的空格和标点
                potential_title = re.sub(r'\s+', ' ', potential_title).strip()
                potential_title = re.sub(r'^[，,、\s]+|[，,、\s]+$', '', potential_title)
                
                # 如果清理后还有内容，使用它作为标题
                if potential_title and len(potential_title) > 1:
                    title = potential_title
                else:
                    # 如果清理后没有合适内容，使用原句子的最后部分
                    title = user_message.strip().split('，')[-1].split(',')[-1].strip()
        
        if not time_str:
            # 尝试提取时间表达
            m_time2 = re.search(r'(\d{1,2}月\d{1,2}日.*?)(?:，|,|$)', user_message)
            if m_time2:
                time_str = m_time2.group(1)
            else:
                # 尝试提取其他时间表达
                time_patterns = [
                    r'(明天.*?点.*?到.*?点)',  # 明天早上八点开始到十二点
                    r'(后天.*?点.*?到.*?点)',  # 后天上午10点到12点
                    r'(下.*?.*?点.*?到.*?点)',  # 下周一上午9点面试
                    r'(明天.*?点)',  # 明天下午2点
                    r'(后天.*?点)',  # 后天上午10点
                    r'(下.*?.*?点)',  # 下周一上午9点
                    r'(\d{1,2}点.*?到.*?\d{1,2}点)',  # 八点开始到十二点
                    r'(\d{1,2}:\d{2}.*?到.*?\d{1,2}:\d{2})',  # 8:00到12:00
                ]
                for pattern in time_patterns:
                    m_time3 = re.search(pattern, user_message)
                    if m_time3:
                        time_str = m_time3.group(1)
                        break
        
        print(f"解析结果:")
        print(f"  标题: {title}")
        print(f"  时间: {time_str}")
        print(f"  提醒: {remind}")
        
        manual_task = {"title": title, "deadline": time_str, "remind": remind}
        print(f"手动任务参数: {manual_task}")
        
        return manual_task
    
    return None

# 测试用例
test_cases = [
    "明天早上八点开始到十二点要实习",
    "标题：团队会议，时间：明天下午2点，提醒：是",
    "后天上午10点到12点开会",
    "下周一上午9点面试",
    "创建日程",
    "发送日程"
]

print("=== 测试日程信息解析逻辑 ===\n")

for i, test_case in enumerate(test_cases, 1):
    print(f"测试用例 {i}:")
    result = test_parse_calendar_info(test_case)
    print() 