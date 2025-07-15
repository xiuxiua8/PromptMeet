import mysql.connector
from mysql.connector import Error
from datetime import datetime
import json
import requests 
import re
import uuid
from dotenv import load_dotenv
import os
import sys
from pathlib import Path
from fastapi import FastAPI, HTTPException, APIRouter
from fastapi.responses import JSONResponse
from typing import Optional, Dict, List
sys.path.append(str(Path(__file__).parent.parent.parent))
from backend.models.database_config import get_database_config

load_dotenv()  # 加载.env文件

class MeetingSessionStorage:
    def __init__(self, host: Optional[str] = None, 
                 user: Optional[str] = None,
                 password: Optional[str] = None,
                 database: Optional[str] = None,
                 api_base_url: Optional[str] = None):
        """初始化数据库存储类"""
        config = get_database_config()
        self.db_config = {
            'host': host or config.host,
            'user': user or config.user,
            'password': password or config.password,
            'database': database or config.database
        }
        self.api_base_url = api_base_url or config.api_base_url
        self.connection = None
    def txt_to_json(self, txt_content):
        """将TXT格式的响应内容转换为JSON"""
        try:
            # 尝试解析可能的JSON字符串
            if txt_content.strip().startswith('{') or txt_content.strip().startswith('['):
                return json.loads(txt_content)
            
            # 处理非标准格式的TXT内容
            # 示例格式：key=value形式或每行一个字段
            data = {}
            for line in txt_content.split('\n'):
                line = line.strip()
                if '=' in line:
                    key, value = line.split('=', 1)
                    data[key.strip()] = value.strip()
            
            return {'session': data} if data else None
            
        except json.JSONDecodeError as e:
            print(f"TXT内容转换为JSON失败: {e}")
            return None
    def is_valid_json(self, data_str):
        """验证字符串是否为有效JSON格式"""
        try:
            json.loads(data_str)
            return True
        except ValueError:
            return False

    def clean_json_string(self, dirty_str):
        """尝试清理非JSON字符"""
        # 保留JSON相关字符：{}[]",:字母数字和基本符号
        cleaned = re.sub(r'[^\w{}\\[\]",:\-. ]', '', dirty_str)
        # 修复常见问题：未闭合的引号、缺少逗号等
        cleaned = re.sub(r'([{\[,])\s*([}\]])', r'\1\2', cleaned)  # 移除空对象的多余逗号
        cleaned = re.sub(r',\s*([}\]])', r'\1', cleaned)  # 移除末尾多余逗号
        return cleaned

    def safe_json_load(self, data_str):
        """安全加载JSON，尝试修复格式"""
        try:
            # 首先尝试直接解析
            return json.loads(data_str)
        except json.JSONDecodeError:
            try:
                # 尝试清理后解析
                cleaned = self.clean_json_string(data_str)
                return json.loads(cleaned)
            except json.JSONDecodeError as e:
                print(f"无法修复JSON格式: {e}")
                return None

    def store_from_txt_file(self, file_path):
        """从TXT文件读取数据并存储到数据库"""
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                content = f.read()
            
            if not content.strip():
                print("文件内容为空")
                return False

            # 尝试解析为JSON（自动尝试修复格式）
            json_data = self.safe_json_load(content)
            if not json_data:
                print("无法将文件内容转换为有效JSON格式")
                return False
            
            if isinstance(json_data, list):
                # 处理多个会话的情况
                results = []
                for item in json_data:
                    if isinstance(item, dict) and 'session' in item:
                        results.append(self.store_session(item))
                return all(results)
            elif isinstance(json_data, dict) and 'session' in json_data:
                # 处理单个会话的情况
                return self.store_session(json_data)
            else:
                print("文件内容格式不正确，缺少'session'字段")
                return False
                
        except FileNotFoundError:
            print(f"文件未找到: {file_path}")
            return False
        except Exception as e:
            print(f"从文件存储数据时发生错误: {e}")
            return False
    def fetch_from_api(self, session_id):
        """从API获取会话数据并验证JSON格式"""
        try:
            response = requests.get(f"{self.api_base_url}/api/sessions/{session_id}")
            response.raise_for_status()
            
            # 获取原始响应内容并验证/修复JSON格式
            response_text = response.text
            json_data = self.safe_json_load(response_text)
            
            if not json_data:
                print(f"API返回的数据不是有效JSON格式: {response_text[:100]}...")
                return None
                
            return json_data
            
        except requests.exceptions.RequestException as e:
            print(f"API请求失败: {e}")
            return None

    def store_from_api(self, session_id):
        """从API获取数据、验证格式并存储到数据库"""
        api_data = self.fetch_from_api(session_id)
        if not api_data:
            return False
            
        # 验证数据结构
        if not isinstance(api_data, dict) or 'session' not in api_data:
            print("API返回的数据结构不正确")
            return False
            
        return self.store_session(api_data)

    def create_database(self):
        """单独创建数据库的方法"""
        try:
            # 连接MySQL服务器但不指定数据库
            conn = mysql.connector.connect(
                host=self.db_config['host'],
                user=self.db_config['user'],
                password=self.db_config['password']
            )
            cursor = conn.cursor()
            
            # 创建数据库
            cursor.execute(f"""
                CREATE DATABASE IF NOT EXISTS {self.db_config['database']} 
                CHARACTER SET utf8mb4 
                COLLATE utf8mb4_unicode_ci
            """)
            conn.commit()
            print(f"数据库 {self.db_config['database']} 创建成功或已存在")
            return True
            
        except Error as e:
            print(f"创建数据库失败: {e}")
            return False
        finally:
            if conn.is_connected():
                cursor.close()
                conn.close()
    
    def connect(self, create_if_not_exists=True):
        """建立数据库连接"""
        try:
            # 先尝试直接连接
            self.connection = mysql.connector.connect(**self.db_config)
            return True
        except Error as e:
            if "Unknown database" in str(e) and create_if_not_exists:
                print(f"数据库不存在，尝试创建...")
                if self.create_database():
                    # 数据库创建成功后再次尝试连接
                    try:
                        self.connection = mysql.connector.connect(**self.db_config)
                        return True
                    except Error as e:
                        print(f"连接新创建的数据库失败: {e}")
                        return False
            else:
                print(f"数据库连接失败: {e}")
                return False
    
    def close(self):
        """关闭数据库连接"""
        if self.connection and self.connection.is_connected():
            self.connection.close()
    
    def initialize_database(self):
        """初始化数据库和表结构"""
        if not self.connect():
            return False
        
        try:
            cursor = self.connection.cursor()
            
            # 创建数据库(如果不存在)
            cursor.execute("CREATE DATABASE IF NOT EXISTS meeting_sessions CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
            cursor.execute("USE meeting_sessions")
            
            # 创建会话主表
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS sessions (
                    session_id VARCHAR(36) PRIMARY KEY COMMENT '会话唯一标识',
                    is_recording BOOLEAN COMMENT '是否正在录制',
                    start_time DATETIME COMMENT '开始时间',
                    end_time DATETIME NULL COMMENT '结束时间',
                    participant_count INT COMMENT '参与人数',
                    audio_file_path VARCHAR(255) NULL COMMENT '音频文件路径',
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间'
                ) COMMENT '会议会话主表'
            """)
            # 创建转录文本片段表
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS transcript_segments (
                    id VARCHAR(36) PRIMARY KEY COMMENT '片段ID',
                    session_id VARCHAR(36) COMMENT '关联会话ID',
                    text TEXT COMMENT '转录文本内容',
                    timestamp DATETIME COMMENT '时间戳',
                    confidence FLOAT COMMENT '置信度',
                    speaker VARCHAR(50) NULL COMMENT '发言人',
                    start_time DATETIME NULL COMMENT '开始时间',
                    end_time DATETIME NULL COMMENT '结束时间',
                    FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
                ) COMMENT '会议转录文本片段'
            """)
            
            # 创建会议摘要表
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS session_summaries (
                    id INT AUTO_INCREMENT PRIMARY KEY COMMENT '摘要ID',
                    session_id VARCHAR(36) COMMENT '关联会话ID',
                    summary_text TEXT COMMENT '摘要内容',
                    generated_at DATETIME COMMENT '生成时间',
                    FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
                ) COMMENT '会议内容摘要'
            """)
            
            # 创建任务表
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS tasks (
                    id INT AUTO_INCREMENT PRIMARY KEY COMMENT '任务ID',
                    session_id VARCHAR(36) COMMENT '关联会话ID',
                    task_name VARCHAR(255) COMMENT '任务名称',
                    deadline DATE COMMENT '截止日期',
                    description TEXT COMMENT '任务描述',
                    priority ENUM('low', 'medium', 'high') COMMENT '优先级',
                    assignee VARCHAR(100) NULL COMMENT '负责人',
                    status ENUM('pending', 'in_progress', 'completed') DEFAULT 'pending' COMMENT '任务状态',
                    FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
                ) COMMENT '会议生成的任务'
            """)
            
            # 创建关键点表
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS key_points (
                    id INT AUTO_INCREMENT PRIMARY KEY COMMENT '关键点ID',
                    session_id VARCHAR(36) COMMENT '关联会话ID',
                    point_text TEXT COMMENT '关键点内容',
                    FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
                ) COMMENT '会议关键点'
            """)
            
            # 创建决策表
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS decisions (
                    id INT AUTO_INCREMENT PRIMARY KEY COMMENT '决策ID',
                    session_id VARCHAR(36) COMMENT '关联会话ID',
                    decision_text TEXT COMMENT '决策内容',
                    FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
                ) COMMENT '会议决策'
            """)
            
            self.create_views()
            self.connection.commit()
            print("数据库初始化成功!")
            return True
            
        except Error as e:
            print(f"数据库初始化失败: {e}")
            self.connection.rollback()
            return False
        finally:
            if cursor:
                cursor.close()
            self.close()
        # === 视图功能 ===

    def create_views(self):
        """创建核心数据库视图"""
        views = {
            'vw_session_overview': """
                CREATE OR REPLACE VIEW vw_session_overview AS
                SELECT 
                    s.session_id,
                    s.start_time,
                    s.end_time,
                    TIMESTAMPDIFF(MINUTE, s.start_time, s.end_time) AS duration_minutes,
                    COUNT(DISTINCT ts.id) AS transcript_count,
                    COUNT(DISTINCT t.id) AS task_count,
                    COUNT(DISTINCT kp.id) AS keypoint_count
                FROM sessions s
                LEFT JOIN transcript_segments ts ON s.session_id = ts.session_id
                LEFT JOIN session_summaries ss ON s.session_id = ss.session_id
                LEFT JOIN tasks t ON ss.id = t.session_id
                LEFT JOIN key_points kp ON ss.id = kp.session_id
                GROUP BY s.session_id
            """,
            'vw_unfinished_tasks': """
                CREATE OR REPLACE VIEW vw_unfinished_tasks AS
                SELECT 
                    t.id,
                    t.task_name,
                    t.deadline,
                    DATEDIFF(t.deadline, CURDATE()) AS days_remaining,
                    s.start_time AS session_time,
                    s.session_id,
                    CASE 
                        WHEN DATEDIFF(t.deadline, CURDATE()) < 0 THEN 'overdue'
                        WHEN DATEDIFF(t.deadline, CURDATE()) <= 3 THEN 'urgent'
                        ELSE 'normal'
                    END AS priority_flag
                FROM tasks t
                JOIN session_summaries ss ON t.session_id = ss.id
                JOIN sessions s ON ss.session_id = s.session_id
                WHERE t.status != 'completed'
                ORDER BY days_remaining ASC
            """,
            'vw_meeting_insights': """
                CREATE OR REPLACE VIEW vw_meeting_insights AS
                SELECT 
                    s.session_id,
                    s.start_time,
                    GROUP_CONCAT(DISTINCT kp.point_text SEPARATOR '|') AS key_points,
                    GROUP_CONCAT(DISTINCT d.decision_text SEPARATOR '|') AS decisions,
                    COUNT(DISTINCT t.id) AS total_tasks,
                    MAX(t.deadline) AS nearest_deadline
                FROM sessions s
                LEFT JOIN session_summaries ss ON s.session_id = ss.session_id
                LEFT JOIN key_points kp ON ss.id = kp.session_id
                LEFT JOIN decisions d ON ss.id = d.session_id
                LEFT JOIN tasks t ON ss.id = t.session_id
                GROUP BY s.session_id
            """
        }

        try:
            cursor = self.connection.cursor()
            for view_name, view_sql in views.items():
                cursor.execute(view_sql)
            self.connection.commit()
            return True
        except Error as e:
            print(f"创建视图失败: {e}")
            self.connection.rollback()
            return False
        finally:
            if cursor:
                cursor.close()

    # === 数据操作 ===
    def store_session(self, session_data):
        """存储完整会议数据"""
        if not self.connect():
            return False
        
        try:
            cursor = self.connection.cursor()
            session = session_data['session']
            
            # 存储会话基本信息
            cursor.execute("""
                INSERT INTO sessions (
                    session_id, is_recording, start_time, end_time,
                    participant_count, audio_file_path
                ) VALUES (%s, %s, %s, %s, %s, %s)
                ON DUPLICATE KEY UPDATE
                    is_recording = VALUES(is_recording),
                    end_time = VALUES(end_time),
                    participant_count = VALUES(participant_count)
            """, (
                session['session_id'],
                session['is_recording'],
                session['start_time'],
                session.get('end_time'),
                session['participant_count'],
                session.get('audio_file_path')
            ))
            
            # 存储转录文本片段
            if 'transcript_segments' in session:
                for segment in session['transcript_segments']:
                    cursor.execute("""
                        INSERT INTO transcript_segments (
                            id, session_id, text, timestamp, 
                            confidence, speaker, start_time, end_time
                        ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                        ON DUPLICATE KEY UPDATE
                            text = VALUES(text),
                            confidence = VALUES(confidence)
                    """, (
                        segment['id'],
                        session['session_id'],
                        segment['text'],
                        segment['timestamp'],
                        segment.get('confidence'),
                        segment.get('speaker'),
                        segment.get('start_time'),
                        segment.get('end_time')
                    ))
            
            # 存储摘要和相关数据
            if 'current_summary' in session:
                summary = session['current_summary']
                cursor.execute("""
                    INSERT INTO session_summaries (
                        session_id, summary_text, generated_at
                    ) VALUES (%s, %s, %s)
                    ON DUPLICATE KEY UPDATE
                        summary_text = VALUES(summary_text),
                        generated_at = VALUES(generated_at)
                """, (
                    session['session_id'],
                    summary['summary_text'],
                    summary['generated_at']
                ))
                
                # 存储任务
                if 'tasks' in summary:
                    for task in summary['tasks']:
                        cursor.execute("""
                            INSERT INTO tasks (
                                session_id, task_name, deadline, 
                                description, priority, assignee, status
                            ) VALUES (%s, %s, %s, %s, %s, %s, %s)
                            ON DUPLICATE KEY UPDATE
                                deadline = VALUES(deadline),
                                status = VALUES(status)
                        """, (
                            session['session_id'],
                            task['task'],
                            task['deadline'],
                            task.get('description', ''),
                            task['priority'],
                            task.get('assignee'),
                            task['status']
                        ))
                
                # 存储关键点和决策...
            
            self.connection.commit()
            return True
        except Error as e:
            print(f"存储失败: {e}")
            self.connection.rollback()
            return False
        finally:
            if cursor:
                cursor.close()
            self.close()

    # === 视图查询接口 ===
    def get_session_overview(self, session_id):
        """获取会议概览数据"""
        return self._query_view("""
            SELECT * FROM vw_session_overview 
            WHERE session_id = %s
        """, (session_id,))

    def get_pending_tasks(self, days_threshold=7):
        """获取紧急待办任务"""
        return self._query_view("""
            SELECT * FROM vw_unfinished_tasks
            WHERE days_remaining <= %s
            ORDER BY days_remaining ASC
        """, (days_threshold,), fetch_all=True)

    def _query_view(self, query, params=None, fetch_all=False):
        """通用视图查询方法"""
        try:
            self.connect()
            cursor = self.connection.cursor(dictionary=True)
            cursor.execute(query, params or ())
            return cursor.fetchall() if fetch_all else cursor.fetchone()
        except Error as e:
            print(f"视图查询失败: {e}")
            return None
        finally:
            if cursor:
                cursor.close()
            self.close()

    def store_session(self, session_data):
        """存储完整的会议会话数据"""
        if not self.connect():
            print("数据库连接失败")
            return False
        
        cursor = None
        try:
            cursor = self.connection.cursor()
            session = session_data
            session_id = session['session_id']
            
            # 开始事务
            self.connection.start_transaction()
            
            # 检查会话是否已存在
            cursor.execute("SELECT session_id FROM sessions WHERE session_id = %s", (session_id,))
            if cursor.fetchone():
                print(f"会话 {session_id} 已存在，执行更新操作")
                return self._update_existing_session(cursor, session_data)
            
            # 1. 存储会话基本信息
            print(f"存储会话基本信息: {session_id}")
            cursor.execute("""
                INSERT INTO sessions (
                    session_id, is_recording, start_time, end_time,
                    participant_count, audio_file_path, created_at
                ) VALUES (%s, %s, %s, %s, %s, %s, %s)
            """, (
                session_id,
                session.get('is_recording', False),
                self._format_datetime(session.get('start_time')),
                self._format_datetime(session.get('end_time')),
                session.get('participant_count', 0),
                session.get('audio_file_path'),
                datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            ))
            
            # 2. 批量存储转录文本片段
            if 'transcript_segments' in session and session['transcript_segments']:
                print(f"存储 {len(session['transcript_segments'])} 个转录片段")
                segment_values = []
                for segment in session['transcript_segments']:
                    segment_values.append((
                        segment.get('id', str(uuid.uuid4())),
                        session_id,
                        segment.get('text', ''),
                        self._format_datetime(segment.get('timestamp')),
                        segment.get('confidence', 0.0),
                        segment.get('speaker'),
                        self._format_datetime(segment.get('start_time')),
                        self._format_datetime(segment.get('end_time'))
                    ))
                
                if segment_values:
                    cursor.executemany("""
                        INSERT INTO transcript_segments (
                            id, session_id, text, timestamp, 
                            confidence, speaker, start_time, end_time
                        ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                    """, segment_values)
            
            # 3. 存储会议摘要和相关数据
            if 'current_summary' in session and session['current_summary'] is not None:
                summary = session['current_summary']
                self._store_summary_data(cursor, summary)
            
            # 提交事务
            self.connection.commit()
            print(f"会话 {session_id} 存储成功!")
            return True
            
        except Error as e:
            print(f"会话存储失败: {e}")
            if self.connection:
                self.connection.rollback()
            return False
        except Exception as e:
            print(f"存储过程中发生意外错误: {e}")
            if self.connection:
                self.connection.rollback()
            return False
        finally:
            if cursor:
                cursor.close()
            self.close()
    
    def _update_existing_session(self, cursor, session_data):
        """更新已存在的会话"""
        try:
            session = session_data
            session_id = session['session_id']
            
            # 更新会话基本信息
            cursor.execute("""
                UPDATE sessions SET 
                    is_recording = %s, end_time = %s, 
                    participant_count = %s, audio_file_path = %s
                WHERE session_id = %s
            """, (
                session.get('is_recording', False),
                self._format_datetime(session.get('end_time')),
                session.get('participant_count', 0),
                session.get('audio_file_path'),
                session_id
            ))
            
            # 删除旧的转录片段（如果有新的）
            if 'transcript_segments' in session:
                cursor.execute("DELETE FROM transcript_segments WHERE session_id = %s", (session_id,))
                
                # 重新插入转录片段
                if session['transcript_segments']:
                    segment_values = []
                    for segment in session['transcript_segments']:
                        segment_values.append((
                            segment.get('id', str(uuid.uuid4())),
                            session_id,
                            segment.get('text', ''),
                            self._format_datetime(segment.get('timestamp')),
                            segment.get('confidence', 0.0),
                            segment.get('speaker'),
                            self._format_datetime(segment.get('start_time')),
                            self._format_datetime(segment.get('end_time'))
                        ))
                    
                    cursor.executemany("""
                        INSERT INTO transcript_segments (
                            id, session_id, text, timestamp, 
                            confidence, speaker, start_time, end_time
                        ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                    """, segment_values)
            
            # 更新摘要信息
            if 'current_summary' in session and session['current_summary'] is not None:
                # 删除旧的摘要相关数据
                cursor.execute("DELETE FROM session_summaries WHERE session_id = %s", (session_id,))
                cursor.execute("DELETE FROM tasks WHERE session_id = %s", (session_id,))
                cursor.execute("DELETE FROM key_points WHERE session_id = %s", (session_id,))
                cursor.execute("DELETE FROM decisions WHERE session_id = %s", (session_id,))
                
                # 重新插入摘要数据
                summary = session['current_summary']
                self._store_summary_data(cursor, summary)
            
            self.connection.commit()
            print(f"会话 {session_id} 更新成功!")
            return True
            
        except Exception as e:
            print(f"更新会话失败: {e}")
            return False
    
    def _store_summary_data(self, cursor, summary):
        """存储摘要相关数据"""
        try:
            # 检查摘要数据是否为None
            if summary is None:
                print("摘要数据为None，跳过存储")
                return
            
            session_id = summary.get('session_id')
            if not session_id:
                print("摘要数据缺少session_id")
                return
            
            print(f"存储会议摘要: {session_id}")
            
            # 存储摘要
            if summary.get('summary_text'):
                cursor.execute("""
                    INSERT INTO session_summaries (
                        session_id, summary_text, generated_at
                    ) VALUES (%s, %s, %s)
                """, (
                    session_id,
                    summary['summary_text'],
                    self._format_datetime(summary.get('generated_at', datetime.now().isoformat()))
                ))
            
            # 批量存储任务
            if 'tasks' in summary and summary['tasks']:
                print(f"存储 {len(summary['tasks'])} 个任务")
                task_values = []
                for task in summary['tasks']:
                    task_values.append((
                        session_id,
                        task.get('task', task.get('task_name', '')),
                        self._format_date(task.get('deadline')),
                        task.get('describe', task.get('description', '')),
                        task.get('priority', 'medium'),
                        task.get('assignee'),
                        task.get('status', 'pending')
                    ))
                
                cursor.executemany("""
                    INSERT INTO tasks (
                        session_id, task_name, deadline, 
                        description, priority, assignee, status
                    ) VALUES (%s, %s, %s, %s, %s, %s, %s)
                """, task_values)
            
            # 批量存储关键点
            if 'key_points' in summary and summary['key_points']:
                print(f"存储 {len(summary['key_points'])} 个关键点")
                point_values = [(session_id, point) for point in summary['key_points']]
                cursor.executemany("""
                    INSERT INTO key_points (session_id, point_text)
                    VALUES (%s, %s)
                """, point_values)
            
            # 批量存储决策
            if 'decisions' in summary and summary['decisions']:
                print(f"存储 {len(summary['decisions'])} 个决策")
                decision_values = [(session_id, decision) for decision in summary['decisions']]
                cursor.executemany("""
                    INSERT INTO decisions (session_id, decision_text)
                    VALUES (%s, %s)
                """, decision_values)
                
        except Exception as e:
            print(f"存储摘要数据失败: {e}")
            raise
    
    def _format_datetime(self, dt_value):
        """格式化日期时间值"""
        if not dt_value:
            return None
        
        if isinstance(dt_value, str):
            try:
                # 处理ISO格式日期
                if 'T' in dt_value:
                    dt_value = dt_value.replace('Z', '+00:00')
                    parsed_dt = datetime.fromisoformat(dt_value)
                    return parsed_dt.strftime('%Y-%m-%d %H:%M:%S')
                else:
                    return dt_value
            except ValueError:
                print(f"日期格式错误: {dt_value}")
                return None
        elif isinstance(dt_value, datetime):
            return dt_value.strftime('%Y-%m-%d %H:%M:%S')
        
        return str(dt_value)
    
    def _format_date(self, date_value):
        """格式化日期值"""
        if not date_value:
            return None
        
        if isinstance(date_value, str):
            try:
                if 'T' in date_value:
                    date_value = date_value.split('T')[0]
                return date_value
            except ValueError:
                print(f"日期格式错误: {date_value}")
                return None
        
        return str(date_value)
    def get_all_sessions(self) -> str:
        """获取所有会话的元数据，返回JSON格式字符串，只包含session_id和前1个清理过格式的关键词"""
        if not self.connect():  # 确保连接已建立
            return json.dumps([])
            
        try:
            cursor = self.connection.cursor(dictionary=True)
            # 只查询session_id
            cursor.execute("""
                SELECT session_id 
                FROM sessions 
                ORDER BY start_time DESC
            """)
            sessions = cursor.fetchall()
            
            # 为每个会话获取前1个关键词并清理格式
            for session in sessions:
                session_id = session['session_id']
                
                # 获取关键词
                cursor.execute("""
                    SELECT point_text 
                    FROM key_points 
                    WHERE session_id = %s 
                    LIMIT 1
                """, (session_id,))
                
                # 清理格式字符并存储
                session['key_points'] = [
                    re.sub(r'\*\*|\*|`', '', point['point_text'])  # 去除**等格式字符
                    for point in cursor.fetchall()
                ]
            
            return json.dumps(sessions, ensure_ascii=False, default=str)
            
        except Error as e:
            print(f"获取所有会话失败: {e}")
            return json.dumps([])
        finally:
            if hasattr(self, 'connection') and self.connection.is_connected():
                cursor.close()
                self.close()

    def get_session_details(self, session_id: str) -> str:
        """获取指定会话的完整详情(包含所有关联数据),返回JSON格式字符串"""
        if not self.connect():
            return json.dumps(None)
            
        try:
            cursor = self.connection.cursor(dictionary=True)
            
            # 1. 获取会话元数据
            cursor.execute("""
                SELECT * FROM sessions 
                WHERE session_id = %s
            """, (session_id,))
            session_data = cursor.fetchone()
            if not session_data:
                return json.dumps(None)
            
            # 2. 获取转录文本片段
            cursor.execute("""
                SELECT id, text, timestamp, confidence, 
                    speaker, start_time, end_time
                FROM transcript_segments 
                WHERE session_id = %s 
                ORDER BY timestamp
            """, (session_id,))
            transcripts = cursor.fetchall()
            
            # 3. 获取会议摘要
            cursor.execute("""
                SELECT id, summary_text, generated_at
                FROM session_summaries
                WHERE session_id = %s
            """, (session_id,))
            summaries = cursor.fetchall()
            
            # 4. 获取任务列表
            cursor.execute("""
                SELECT id, task_name, deadline, description,
                    priority, assignee, status
                FROM tasks
                WHERE session_id = %s
            """, (session_id,))
            tasks = cursor.fetchall()
            
            # 5. 获取关键点
            cursor.execute("""
                SELECT id, point_text
                FROM key_points
                WHERE session_id = %s
            """, (session_id,))
            key_points = [point['point_text'] for point in cursor.fetchall()]
            
            # 6. 获取决策
            cursor.execute("""
                SELECT id, decision_text
                FROM decisions
                WHERE session_id = %s
            """, (session_id,))
            decisions = [decision['decision_text'] for decision in cursor.fetchall()]
            
            # 构建完整响应结构
            result = {
                "metadata": session_data,
                "transcript_segments": [{
                    "id": transcript['id'],
                    "text": transcript['text'],
                    "timestamp": transcript['timestamp'],
                    "confidence": transcript['confidence'],
                    "speaker": transcript['speaker'],
                    "start_time": transcript['start_time'],
                    "end_time": transcript['end_time']
                } for transcript in transcripts],
                "current_summary": {
                    "summary_text": summaries[0]['summary_text'] if summaries else "",
                    "generated_at": summaries[0]['generated_at'] if summaries else None,
                    "tasks": [{
                        "task": task['task_name'],
                        "deadline": str(task['deadline']),
                        "description": task['description'],
                        "priority": task['priority'],
                        "assignee": task['assignee'],
                        "status": task['status']
                    } for task in tasks],
                    "key_points": key_points,
                    "decisions": decisions
                } if summaries else None
            }
            
            return json.dumps(result, ensure_ascii=False, default=str)
            
        except Error as e:
            print(f"获取会话详情失败: {e}")
            return json.dumps(None)
        finally:
            if hasattr(self, 'connection') and self.connection.is_connected():
                cursor.close()
                self.close()
    
    def save_session_to_json_file(self, session_id: str, output_dir: str = os.path.join(".", "backend", "db", "session_data")) -> str:
        """将会话数据(完整)保存为格式良好的JSON文件"""
        try:
            # 获取完整会话详情
            session_details = json.loads(self.get_session_details(session_id))
            if not session_details:
                print(f"找不到会话 {session_id}")
                return None
                
            # 创建输出目录
            os.makedirs(output_dir, exist_ok=True)
            
            # 构建文件名
            filename = f"{session_id}.json"
            filepath = os.path.join(output_dir, filename)
            
            # 写入格式良好的JSON文件
            with open(filepath, 'w', encoding='utf-8') as f:
                json.dump(session_details, f, ensure_ascii=False, indent=4)
                
            print(f"完整会话数据已保存到: {filepath}")
            return filepath
            
        except Exception as e:
            print(f"保存会话数据到文件失败: {e}")
            return None


def load_sample_data(file_path):
    """从文件加载示例数据"""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception as e:
        print(f"加载示例数据失败: {e}")
        return None

if __name__ == "__main__":
    # 创建存储实例
    storage = MeetingSessionStorage()#, api_base_url='http://localhost:3000')
    
    # 初始化数据库
    if not storage.initialize_database():
        print("数据库初始化失败，请检查数据库连接!")
        exit(1)

    #storage.store_from_api('cecc947e-0d28-4486-aaa1-d83ec925cd9a')
    #storage.store_from_txt_file('D:\L\Vscode\Python\internship-ii\mysql\session_data.txt')
    
    # === 测试代码 ===
    print("\n=== 开始测试 ===")
    
    # 1. 测试存储功能
    print("\n[测试存储功能]")
    if storage.store_session(test_data):
        print("✅ 测试数据存储成功")
    else:
        print("❌ 测试数据存储失败")
        exit(1)
