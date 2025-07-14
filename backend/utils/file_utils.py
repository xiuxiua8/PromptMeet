"""
文件操作工具
提供音频文件管理、目录操作等文件相关功能
"""

import os
import shutil
import logging
from typing import Optional, List
from datetime import datetime
from pathlib import Path

logger = logging.getLogger(__name__)


def ensure_dir(path: str) -> bool:
    """确保目录存在"""
    try:
        Path(path).mkdir(parents=True, exist_ok=True)
        return True
    except Exception as e:
        logger.error(f"创建目录失败 {path}: {e}")
        return False


def get_file_size(file_path: str) -> int:
    """获取文件大小（字节）"""
    try:
        return os.path.getsize(file_path)
    except Exception as e:
        logger.error(f"获取文件大小失败 {file_path}: {e}")
        return 0


def delete_file(file_path: str) -> bool:
    """删除文件"""
    try:
        if os.path.exists(file_path):
            os.remove(file_path)
            logger.debug(f"删除文件: {file_path}")
            return True
        return False
    except Exception as e:
        logger.error(f"删除文件失败 {file_path}: {e}")
        return False


def copy_file(src_path: str, dst_path: str) -> bool:
    """复制文件"""
    try:
        shutil.copy2(src_path, dst_path)
        logger.debug(f"复制文件: {src_path} -> {dst_path}")
        return True
    except Exception as e:
        logger.error(f"复制文件失败: {e}")
        return False


class AudioFileManager:
    """音频文件管理器"""

    def __init__(self, base_dir: str = "./recordings"):
        self.base_dir = Path(base_dir)
        ensure_dir(str(self.base_dir))

    def get_session_dir(self, session_id: str) -> Path:
        """获取会话目录"""
        session_dir = self.base_dir / session_id
        ensure_dir(str(session_dir))
        return session_dir

    def get_audio_file_path(self, session_id: str, file_name: str = None) -> str:
        """获取音频文件路径"""
        session_dir = self.get_session_dir(session_id)

        if not file_name:
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            file_name = f"recording_{timestamp}.wav"

        return str(session_dir / file_name)

    def save_audio_chunk(
        self, session_id: str, audio_data: bytes, chunk_index: int
    ) -> str:
        """保存音频片段"""
        session_dir = self.get_session_dir(session_id)
        chunk_file = session_dir / f"chunk_{chunk_index:06d}.wav"

        try:
            with open(chunk_file, "wb") as f:
                f.write(audio_data)
            logger.debug(f"保存音频片段: {chunk_file}")
            return str(chunk_file)
        except Exception as e:
            logger.error(f"保存音频片段失败: {e}")
            return ""

    def merge_audio_chunks(self, session_id: str, output_file: str = None) -> str:
        """合并音频片段"""
        session_dir = self.get_session_dir(session_id)

        if not output_file:
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            output_file = str(session_dir / f"merged_{timestamp}.wav")

        # 获取所有片段文件
        chunk_files = sorted(session_dir.glob("chunk_*.wav"))

        if not chunk_files:
            logger.warning(f"会话 {session_id} 没有音频片段")
            return ""

        try:
            # 简单的二进制合并（实际应用中可能需要更复杂的音频处理）
            with open(output_file, "wb") as output:
                for chunk_file in chunk_files:
                    with open(chunk_file, "rb") as chunk:
                        shutil.copyfileobj(chunk, output)

            logger.info(f"合并音频文件: {output_file}")
            return output_file

        except Exception as e:
            logger.error(f"合并音频文件失败: {e}")
            return ""

    def cleanup_session(self, session_id: str, keep_merged: bool = True):
        """清理会话文件"""
        session_dir = self.get_session_dir(session_id)

        try:
            if keep_merged:
                # 只删除片段文件，保留合并后的文件
                chunk_files = session_dir.glob("chunk_*.wav")
                for chunk_file in chunk_files:
                    delete_file(str(chunk_file))
            else:
                # 删除整个会话目录
                shutil.rmtree(str(session_dir))

            logger.info(f"清理会话文件: {session_id}")

        except Exception as e:
            logger.error(f"清理会话文件失败: {e}")

    def get_session_files(self, session_id: str) -> List[str]:
        """获取会话的所有文件"""
        session_dir = self.get_session_dir(session_id)

        try:
            files = [str(f) for f in session_dir.iterdir() if f.is_file()]
            return files
        except Exception as e:
            logger.error(f"获取会话文件失败: {e}")
            return []

    def get_storage_stats(self) -> dict:
        """获取存储统计信息"""
        try:
            total_size = 0
            file_count = 0
            session_count = 0

            for session_dir in self.base_dir.iterdir():
                if session_dir.is_dir():
                    session_count += 1
                    for file_path in session_dir.iterdir():
                        if file_path.is_file():
                            file_count += 1
                            total_size += get_file_size(str(file_path))

            return {
                "total_size_bytes": total_size,
                "total_size_mb": total_size / (1024 * 1024),
                "file_count": file_count,
                "session_count": session_count,
                "base_dir": str(self.base_dir),
            }

        except Exception as e:
            logger.error(f"获取存储统计失败: {e}")
            return {}
