"""
会话管理器
管理所有活跃的会议会话状态
"""

import logging
from typing import Dict, Optional, List
from datetime import datetime
import threading

from models.data_models import SessionState, TranscriptSegment, MeetingSummary

logger = logging.getLogger(__name__)

class SessionManager:
    """会话管理器"""
    
    def __init__(self):
        self.sessions: Dict[str, SessionState] = {}
        self._lock = threading.Lock()
    
    def add_session(self, session: SessionState) -> bool:
        """添加新会话"""
        with self._lock:
            if session.session_id in self.sessions:
                logger.warning(f"会话 {session.session_id} 已存在")
                return False
            
            self.sessions[session.session_id] = session
            logger.info(f"添加会话: {session.session_id}")
            return True
    
    def get_session(self, session_id: str) -> Optional[SessionState]:
        """获取会话"""
        with self._lock:
            return self.sessions.get(session_id)
    
    def update_session(self, session: SessionState) -> bool:
        """更新会话状态"""
        with self._lock:
            if session.session_id not in self.sessions:
                logger.warning(f"会话 {session.session_id} 不存在，无法更新")
                return False
            
            self.sessions[session.session_id] = session
            logger.debug(f"更新会话: {session.session_id}")
            return True
    
    def remove_session(self, session_id: str) -> bool:
        """删除会话"""
        with self._lock:
            if session_id in self.sessions:
                del self.sessions[session_id]
                logger.info(f"删除会话: {session_id}")
                return True
            else:
                logger.warning(f"会话 {session_id} 不存在，无法删除")
                return False
    
    def get_all_sessions(self) -> List[SessionState]:
        """获取所有会话"""
        with self._lock:
            return list(self.sessions.values())
    
    def get_active_sessions(self) -> List[SessionState]:
        """获取所有活跃（正在录音）的会话"""
        with self._lock:
            return [session for session in self.sessions.values() if session.is_recording]
    
    def add_transcript_segment(self, session_id: str, segment: TranscriptSegment) -> bool:
        """添加转录片段"""
        with self._lock:
            session = self.sessions.get(session_id)
            if not session:
                logger.warning(f"会话 {session_id} 不存在，无法添加转录片段")
                return False
            
            session.transcript_segments.append(segment)
            logger.debug(f"添加转录片段到会话 {session_id}: {segment.text[:50]}...")
            return True
    
    def update_summary(self, session_id: str, summary: MeetingSummary) -> bool:
        """更新会话摘要"""
        with self._lock:
            session = self.sessions.get(session_id)
            if not session:
                logger.warning(f"会话 {session_id} 不存在，无法更新摘要")
                return False
            
            session.current_summary = summary
            logger.info(f"更新会话 {session_id} 摘要")
            return True
    
    def get_session_transcript(self, session_id: str) -> List[TranscriptSegment]:
        """获取会话的所有转录内容"""
        with self._lock:
            session = self.sessions.get(session_id)
            if not session:
                return []
            return session.transcript_segments.copy()
    
    def get_session_summary(self, session_id: str) -> Optional[MeetingSummary]:
        """获取会话摘要"""
        with self._lock:
            session = self.sessions.get(session_id)
            if not session:
                return None
            return session.current_summary
    
    def get_session_stats(self) -> Dict[str, int]:
        """获取会话统计信息"""
        with self._lock:
            total_sessions = len(self.sessions)
            active_sessions = len([s for s in self.sessions.values() if s.is_recording])
            total_segments = sum(len(s.transcript_segments) for s in self.sessions.values())
            
            return {
                "total_sessions": total_sessions,
                "active_sessions": active_sessions,
                "total_transcript_segments": total_segments
            }